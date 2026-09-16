// Loro public component. SPDX-License-Identifier: AGPL-3.0-only
import { normalizeRecord } from '../lib/record.js';

export const SCALE_NOW = Date.parse('2026-08-24T12:00:00Z');

export const EXECUTIVE_VOCAB =
  ('deadline commitment quality pricing margin hiring decision risk customer contract revenue ' +
    'roadmap launch deliver review budget forecast partner supplier renewal churn retention ' +
    'positioning segment pipeline proposal negotiation scope milestone escalation dependency ' +
    'headcount runway invoice discount onboarding retainer referral warranty compliance')
    .split(' ');

export const SCALE_TOPIC = 'the deadline and the commitment behind this launch';
export const SCALE_TOPIC_TERMS = ['deadline', 'commitment', 'launch'];

function lcg(seed) {
  let s = (seed >>> 0) || 1;
  return () => {
    s = (Math.imul(s, 1664525) + 1013904223) >>> 0;
    return s / 4294967296;
  };
}

function zipfPick(pool, rnd) {
  const r = rnd();
  return pool[Math.min(pool.length - 1, Math.floor(pool.length * r * r))];
}

function jargonPool(companyId, size) {
  return Array.from({ length: size }, (_, i) => `${companyId}term${i}`);
}

function drawExec(k, rnd) {
  const pool = EXECUTIVE_VOCAB.slice();
  const out = [];
  for (let i = 0; i < k && pool.length; i += 1) out.push(pool.splice(Math.floor(rnd() * pool.length), 1)[0]);
  return out;
}

export function makeScaleCorpus(spec) {
  const rnd = lcg(spec.seed || 20260829);
  const words = spec.wordsPerRecord ?? 30;
  const execPer = spec.execTermsPerRecord ?? 5;
  const poolSize = spec.jargonPoolSize ?? 400;
  const records = [];

  const push = (raw, company) =>
    records.push(
      normalizeRecord(
        { ...raw, company, path: `${company || 'person'}/records/${raw.id}.md` },
        { now: SCALE_NOW, source: 'records', defaultScope: 'org-shared' },
      ),
    );

  const ceo = spec.ceo || {};

  const ceoKind = ceo.typed === false ? 'passage' : 'principle';
  const ceoAuthority = ceo.typed === false ? 'unknown' : 'self';
  for (const [i, text] of (ceo.principles || []).entries()) {
    push(
      { id: `person-principle-${i}`, kind: ceoKind, title: `Principle ${i}`, text, authority: ceoAuthority, confidence: 0.95 },
      null,
    );
  }
  const ceoPool = jargonPool('person', poolSize);
  const ceoExec = ceo.execPer ?? execPer;
  for (let i = 0; i < (ceo.records || 0); i += 1) {
    const body = [...drawExec(ceoExec, rnd), ...Array.from({ length: words - ceoExec }, () => zipfPick(ceoPool, rnd))];
    push(
      {
        id: `person-${i}`,
        kind: ceo.typed === false ? 'passage' : 'preference',
        title: `How I work ${i}`,
        text: `${body.join(' ')}.`,
        authority: ceoAuthority,
      },
      null,
    );
  }

  for (const c of spec.companies || []) {
    const pool = jargonPool(c.id, poolSize);

    for (let i = 0; i < (c.distractors || 0); i += 1) {

      const body = [
        ...SCALE_TOPIC_TERMS,
        ...SCALE_TOPIC_TERMS,
        ...Array.from({ length: words - SCALE_TOPIC_TERMS.length * 2 }, () => pool[Math.floor(rnd() * pool.length)]),
      ];
      push(
        {
          id: `${c.id}-hit-${i}`,
          kind: 'decision',
          title: `${c.id} launch commitment ${i}`,
          text: `${body.join(' ')}.`,
          authority: 'self',
          confidence: 0.9,
        },
        c.id,
      );
    }
    const cExec = c.execPer ?? execPer;
    for (let i = 0; i < c.records; i += 1) {
      const body = [...drawExec(cExec, rnd), ...Array.from({ length: words - cExec }, () => zipfPick(pool, rnd))];
      push(
        {
          id: `${c.id}-${i}`,
          kind: i % 7 === 0 ? 'decision' : i % 5 === 0 ? 'fact' : 'passage',
          title: `${c.id} note ${i}`,
          text: `${body.join(' ')}.`,
        },
        c.id,
      );
    }
  }

  const byId = new Map(records.map((r) => [r.id, r]));
  const counts = { total: records.length };
  for (const r of records) counts[r.kind] = (counts[r.kind] || 0) + 1;

  return {
    root: '(synthetic)',
    layout: 'corpus',
    rootSource: '(synthetic)',
    dogfood: false,
    companies: (spec.companies || []).map((c) => c.id),
    retiredCompanies: [],
    records,
    byId,
    notes: [],
    problems: [],
    sources: ['records'],
    entities: [],
    entitiesVersion: null,
    fingerprint: `sha256:synthetic-${records.length}`,
    counts,
  };
}

export const EXEC_DENSITY = { halstead: 12, northwind: 8, brightseam: 4, quarry: 2 };

export const DISTRACTOR_RATE = { halstead: 0.02, northwind: 0.02, brightseam: 0.02, quarry: 0 };

export function fourCompanies(total, opts = {}) {
  const shares = { halstead: 0.62, northwind: 0.28, brightseam: 0.08, quarry: 0.02 };
  return makeScaleCorpus({
    seed: opts.seed || 20260829,
    ceo: {
      typed: opts.typedCeo !== false,

      records: 40,
      principles: [
        'I decide slowly on a decision that is hard to reverse and fast on everything else. A decision I can undo inside a week is not worth a meeting.',
        'A deadline I did not agree to out loud is not a commitment. I would rather refuse a deadline than quietly miss one.',
        'Quality is what a customer notices after the invoice clears, so I will not trade it for a launch date.',
      ],
    },
    companies: Object.entries(shares).map(([id, share]) => ({
      id,
      records: Math.max(1, Math.round(total * share)),

      execPer: EXEC_DENSITY[id],

      distractors: Math.round(total * share * DISTRACTOR_RATE[id]),
    })),
  });
}

export function flattenPartitions(corpus) {
  const records = corpus.records.map((r) => ({ ...r, company: null }));
  return { ...corpus, records, byId: new Map(records.map((r) => [r.id, r])), companies: [] };
}
