// Loro public component. SPDX-License-Identifier: AGPL-3.0-only
export const SCOPES = ['ceo-private', 'org-shared', 'external'];

export const KINDS = [
  'principle',
  'decision',
  'constraint',
  'preference',
  'strategy',
  'lesson',
  'commitment',
  'risk',
  'goal',
  'metric',
  'fact',
  'event',
  'entity',
  'passage',
];

export const KIND_PRIOR = {
  principle: 1.35,
  decision: 1.3,
  constraint: 1.3,
  preference: 1.28,
  strategy: 1.22,
  lesson: 1.15,
  commitment: 1.1,
  risk: 1.05,
  goal: 1.05,
  metric: 1.0,
  fact: 1.0,
  event: 0.95,
  entity: 0.9,
  passage: 0.85,
};

export const AUTHORITY_WEIGHT = { self: 1.1, internal: 1.0, unknown: 0.95, external: 0.85 };

function str(v, fallback = '') {
  return typeof v === 'string' ? v : fallback;
}
function num(v, fallback) {
  return typeof v === 'number' && Number.isFinite(v) ? v : fallback;
}
function arr(v) {
  return Array.isArray(v) ? v.filter((x) => typeof x === 'string' && x.trim()) : [];
}
function ms(iso) {
  if (!iso) return null;
  const t = Date.parse(iso);
  return Number.isNaN(t) ? null : t;
}

export const DATE_FIELDS = ['observedAt', 'occurredAt', 'validFrom', 'validUntil'];

const NUMERIC_DMY = /^(\d{1,2})([/.-])(\d{1,2})\2(\d{2}|\d{4})$/;

const AMBIGUOUS_STAKE = {
  observedAt: "and a record's date is what decides how stale loro thinks this belief is",
  occurredAt: "and a record's date is what decides how stale loro thinks this belief is",
  validFrom: 'and this field is what decides when loro starts counting this belief as current',
  validUntil: 'and this field is what decides when loro stops counting this belief as current',
};

const UNREADABLE_STAKE = {
  observedAt: 'so this record is UNDATED: not penalized for age, but not credited as recent either',
  occurredAt: 'so this record is UNDATED: not penalized for age, but not credited as recent either',
  validFrom: 'so this record reads as valid from the beginning of time',
  validUntil: 'so this record NEVER expires — a belief with an end date keeps reading as current',
};

function localIsoDay(t) {
  const d = new Date(t);
  const pad = (n) => String(n).padStart(2, '0');
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`;
}

export function dateFieldProblem(field, value) {
  if (value === null || value === undefined) return null;
  if (Array.isArray(value) && value.length === 0) return null;
  const unreadable = (shown) =>
    `${field}: ${shown} is not a date loro can read, ${UNREADABLE_STAKE[field] || 'so the field was dropped'}. ` +
    'Fix: write it in ISO form, YYYY-MM-DD (for example 2026-09-01), optionally with a time. ' +
    'Never repaired for you: guessing the date would be guessing at your memory.';
  if (typeof value !== 'string') return unreadable(`${JSON.stringify(value)} (a date must be text)`);
  const t = value.trim();
  if (!t) return null;

  const m = NUMERIC_DMY.exec(t);
  if (m) {
    const first = Number(m[1]);
    const second = Number(m[3]);

    if (first >= 1 && first <= 12 && second >= 1 && second <= 12 && first !== second) {
      const monthFirst = Date.parse(`${m[1]}/${m[3]}/${m[4]}`);
      const dayFirst = Date.parse(`${m[3]}/${m[1]}/${m[4]}`);
      if (!Number.isNaN(monthFirst) && !Number.isNaN(dayFirst)) {
        const us = localIsoDay(monthFirst);
        const other = localIsoDay(dayFirst);
        const gap = Math.round(Math.abs(monthFirst - dayFirst) / 86400000);
        return (
          `${field}: "${t}" is AMBIGUOUS — it is ${us} read month-first (US order, which is how loro ` +
          `READ it) and ${other} read day-first. Those readings are ${gap} days apart, ` +
          `${AMBIGUOUS_STAKE[field] || 'and the difference changes what loro believes'}. ` +
          `Fix: write the one you meant in ISO form — ${us} or ${other}; YYYY-MM-DD has exactly one ` +
          'reading. Never repaired for you: guessing which you meant would be guessing at your memory.'
        );
      }
    }
  }

  if (Number.isNaN(Date.parse(t))) return unreadable(`"${t}"`);
  return null;
}

export function dateFieldProblems(fields) {
  const problems = [];
  if (!fields || typeof fields !== 'object') return problems;
  for (const field of DATE_FIELDS) {
    const problem = dateFieldProblem(field, fields[field]);
    if (problem) problems.push(problem);
  }
  return problems;
}

export function deriveStatus(raw, now) {
  if (str(raw.supersededBy)) return 'superseded';
  if (str(raw.status) === 'superseded') return 'superseded';
  const until = ms(raw.validUntil);
  if (until !== null && until <= now) return 'expired';
  const from = ms(raw.validFrom);
  if (from !== null && from > now) return 'future';
  return 'current';
}

export function normalizeRecord(raw, ctx) {
  const now = ctx.now;
  const kindRaw = str(raw.kind).toLowerCase();
  const kind = KINDS.includes(kindRaw) ? kindRaw : 'passage';
  const scopeRaw = str(raw.scope).toLowerCase();

  const scope = SCOPES.includes(scopeRaw) ? scopeRaw : str(ctx.defaultScope) || 'ceo-private';
  const authorityRaw = str(raw.authority).toLowerCase();
  const authority = Object.prototype.hasOwnProperty.call(AUTHORITY_WEIGHT, authorityRaw)
    ? authorityRaw
    : 'unknown';

  return {
    id: str(raw.id),
    kind,

    kindInferred: raw.kindInferred === true,
    title: str(raw.title).trim(),
    text: str(raw.text).trim(),
    scope,
    authority,
    confidence: Math.min(1, Math.max(0, num(raw.confidence, 0.7))),

    status: deriveStatus(raw, now),
    validFrom: str(raw.validFrom) || null,
    validUntil: str(raw.validUntil) || null,
    observedAt: str(raw.observedAt) || str(raw.occurredAt) || null,
    supersededBy: str(raw.supersededBy) || null,
    tags: arr(raw.tags).map((t) => t.toLowerCase()),
    related: arr(raw.related),

    company: str(raw.company) || null,
    provenance: {
      source: str(ctx.source, 'unknown'),
      path: str(raw.path) || str(raw.provenancePath) || null,
      anchor: str(raw.anchor) || null,
      link: str(raw.link) || null,

      method: str(raw.promotionMethod) || null,
      ref: str(raw.promotionRef) || null,
    },

    supersedes: str(raw.supersedes) || null,
  };
}

export function validateRecord(rec) {
  const problems = [];
  if (!rec.id) problems.push('record has no id (needed as a stable deep-fetch ref)');
  if (!rec.title && !rec.text) problems.push(`record "${rec.id}" has neither title nor text`);
  if (!SCOPES.includes(rec.scope)) problems.push(`record "${rec.id}" has unknown scope "${rec.scope}"`);
  if (!KINDS.includes(rec.kind)) problems.push(`record "${rec.id}" has unknown kind "${rec.kind}"`);
  return problems;
}

export function kindPrior(kind) {
  return KIND_PRIOR[kind] !== undefined ? KIND_PRIOR[kind] : KIND_PRIOR.passage;
}

export function authorityWeight(authority) {
  return AUTHORITY_WEIGHT[authority] !== undefined ? AUTHORITY_WEIGHT[authority] : AUTHORITY_WEIGHT.unknown;
}
