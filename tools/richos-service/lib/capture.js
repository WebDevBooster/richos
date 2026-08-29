/**
 * RichOS local service — the correction flywheel's IN-RICHOS capture half (2026-08-24).
 *
 * loro's shared vocabulary (`loro/entities.json`) is what the transcription pipeline's
 * loro-correction stage (lib/correct.js) uses to fix names/terms a generic ASR mangles. This module
 * is the OTHER direction of the flywheel: corrections the CEO makes inside our OWN artifacts are
 * folded back INTO that vocabulary, so both dictation and call transcription get more accurate over
 * time — Wispr-Flow's learn-from-corrections behaviour, but LOCAL and SHARED (one file, both flows).
 *
 * Two intake paths, split by difficulty (the loro architecture notes, §"The correction flywheel"):
 *
 *   1. EXPLICIT intake — learnTerm(): "the term is Deepgram, it came out as Deep Graham." A canonical
 *      term + optional observed manglings are added/merged into entities.json. Simple, reliable,
 *      auto-apply. This is what Rich invokes on a direct CEO instruction.
 *
 *   2. TRANSCRIPT-EDIT diff intake — extractTermCorrections(): a landed transcript.md the CEO edits
 *      to fix a name IS a correction signal. We diff the edit against its committed baseline and
 *      PROPOSE conservative canonical<-mangled pairs from the changed spans. PRECISION OVER RECALL:
 *      only proper-noun / term-shaped substitutions that look like real ASR manglings, never ordinary
 *      word edits. Propose by default; apply is opt-in.
 *
 * The captured correction bumps the entities `version`; correct.js already surfaces `entitiesVersion`,
 * so the loop closes: capture -> entities.json -> the next transcript is corrected with the new term.
 *
 * PURE core (no fs, no git) so it is node-testable with literal docs/strings. The CLI
 * (bin/richos-service.js) is the only place that touches disk and git.
 *
 * SEAMS (deferred, not built here — documented so nobody assumes they exist):
 *   - External-app dictation-edit capture (Gmail/etc. edits after dictated text lands) needs
 *     accessibility-API/clipboard monitoring — a separate, harder spike.
 *   - Feeding entities into whisper `initial_prompt` for up-front biasing (bias BEFORE the ASR runs,
 *     vs. correct AFTER) is a separate follow-on; entities.json is already the right source for it.
 */

import { normalizeTerm, similarity } from './correct.js';

/**
 * @typedef {{canonical:string, type?:string, aliases?:string[], mangled?:string[],
 *   fuzzy?:boolean, caseSensitive?:boolean, minScore?:(number|null)}} RawEntity
 * @typedef {{schemaVersion?:number, version:string, note?:string, entities:RawEntity[]}} EntitiesDoc
 */

/** Lowercase words that may appear inside a multi-word TERM without disqualifying it as a proper noun. */
const CONNECTORS = new Set(['of', 'the', 'and', 'for', 'to', 'a', 'an', 'de', 'van', 'von', 'la', 'le', 'di', 'da']);

/**
 * A changed span is only learned as a mangling->canonical pair when the NEW (canonical) side is at
 * least this similar to the OLD (mangled) side — i.e. a real ASR mangling, not a wholesale rewrite
 * ("um" -> "Marcus Whitfield", pronoun -> name). Precision guard, tuned conservative.
 */
export const MIN_EDIT_SIMILARITY = 0.34;

/**
 * A LONE (single-token) mangled side needs a HIGHER bar than a multi-word phrase: it must be an
 * obvious spelling variant of the canonical ("Deepgraham" -> "Deepgram"), not a different word the
 * CEO swapped in ("great" -> "Grant"). Multi-word manglings bypass this (a phrase can't corrupt an
 * ordinary single word).
 */
export const LONE_TOKEN_MIN_SIMILARITY = 0.6;

// ---------------------------------------------------------------------------------------------------
// Version bumping
// ---------------------------------------------------------------------------------------------------

function todayStamp(date = new Date()) {
  return date.toISOString().slice(0, 10); // YYYY-MM-DD
}

/**
 * Bump the entities `version` so every captured change is a distinct, roughly-monotonic marker
 * (consumed opaquely by correct.js as `entitiesVersion`). Scheme: date-based with a `.N` intra-day
 * revision counter. Cross-day => the date itself changes; same-day => the counter increments.
 * @param {string|null|undefined} current
 * @param {string} [today]
 * @returns {string}
 */
export function bumpVersion(current, today = todayStamp()) {
  const cur = typeof current === 'string' ? current.trim() : '';
  const m = cur.match(/^(\d{4}-\d{2}-\d{2})(?:\.(\d+))?$/);
  if (m && m[1] === today) {
    const n = m[2] ? parseInt(m[2], 10) : 0;
    return `${today}.${n + 1}`;
  }
  // Different day (or an unrecognized/empty version): the new date IS the bump. Guard the degenerate
  // case where a non-date version happens to equal today's date string by falling to `.1`.
  return cur === today ? `${today}.1` : today;
}

// ---------------------------------------------------------------------------------------------------
// Explicit intake — learnTerm
// ---------------------------------------------------------------------------------------------------

/** Case/space/punctuation-insensitive equality used for dedup across canonicals, aliases, manglings. */
function sameTerm(a, b) {
  return normalizeTerm(a) === normalizeTerm(b);
}

/**
 * Fold an explicit "the term is X, it came out as Y" correction into an entities doc. Dedups against
 * existing entries and NEVER clobbers curated data — it only ADDS (new manglings/aliases, or a new
 * entity). Returns a NEW doc (the input is not mutated) plus a report of what changed.
 *
 * @param {EntitiesDoc} doc the raw entities.json object
 * @param {{canonical:string, mangled?:(string|string[]), aliases?:(string|string[]), type?:string,
 *   fuzzy?:boolean, caseSensitive?:boolean, minScore?:(number|null)}} input
 * @param {{today?:string}} [opts]
 * @returns {{doc:EntitiesDoc, changed:boolean, created:boolean,
 *   added:{mangled:string[], aliases:string[]}, conflicts:string[], entity:RawEntity|null}}
 */
export function learnTerm(doc, input, opts = {}) {
  const base = doc && typeof doc === 'object' ? doc : {};
  const entities = Array.isArray(base.entities) ? base.entities.map((e) => ({ ...e })) : [];
  const canonical = typeof input?.canonical === 'string' ? input.canonical.trim() : '';
  const added = { mangled: [], aliases: [] };
  const conflicts = [];

  if (!canonical) {
    return { doc: base, changed: false, created: false, added, conflicts: ['missing canonical'], entity: null };
  }

  const manglings = toList(input.mangled)
    .map((s) => s.trim())
    .filter(Boolean)
    // A mangling that normalizes to the canonical is useless — correct.js skips it (a no-op / casing
    // change can't be a curated replacement). Drop it here so we never pollute the file.
    .filter((m) => !sameTerm(m, canonical));
  const newAliases = toList(input.aliases).map((s) => s.trim()).filter(Boolean);

  // Guard: a mangling that already maps to a DIFFERENT canonical would make the corrector ambiguous.
  // Skip it and report a conflict rather than silently overwriting a curated mapping.
  const claimedElsewhere = new Map(); // normalized mangling -> owning canonical
  for (const e of entities) {
    for (const m of e.mangled || []) claimedElsewhere.set(normalizeTerm(m), e.canonical);
  }

  let entity = entities.find((e) => sameTerm(e.canonical, canonical)
    || (e.aliases || []).some((a) => sameTerm(a, canonical)));
  let created = false;

  if (!entity) {
    created = true;
    entity = {
      canonical,
      type: typeof input.type === 'string' && input.type.trim() ? input.type.trim() : 'unknown',
      aliases: [],
      mangled: [],
    };
    if (input.fuzzy === false) entity.fuzzy = false;
    if (input.caseSensitive === true) entity.caseSensitive = true;
    if (typeof input.minScore === 'number') entity.minScore = input.minScore;
    entities.push(entity);
  } else {
    // Merge into an existing curated entity: fill only ABSENT optional fields; never overwrite.
    entity.aliases = Array.isArray(entity.aliases) ? [...entity.aliases] : [];
    entity.mangled = Array.isArray(entity.mangled) ? [...entity.mangled] : [];
    if ((!entity.type || entity.type === 'unknown') && typeof input.type === 'string' && input.type.trim()) {
      entity.type = input.type.trim();
    }
    if (entity.fuzzy === undefined && input.fuzzy === false) entity.fuzzy = false;
    if (entity.caseSensitive === undefined && input.caseSensitive === true) entity.caseSensitive = true;
    if (entity.minScore === undefined && typeof input.minScore === 'number') entity.minScore = input.minScore;
  }

  for (const raw of manglings) {
    // Manglings are matched case-insensitively (correct.js normalizes them), so store them lowercased
    // to match the curated file convention and keep the file tidy.
    const m = raw.toLowerCase();
    if ((entity.mangled || []).some((x) => sameTerm(x, m))) continue; // dedup within the entity
    const owner = claimedElsewhere.get(normalizeTerm(m));
    if (owner && !sameTerm(owner, canonical)) {
      conflicts.push(`mangling "${m}" already maps to "${owner}" — skipped`);
      continue;
    }
    entity.mangled = entity.mangled || [];
    entity.mangled.push(m);
    added.mangled.push(m);
    claimedElsewhere.set(normalizeTerm(m), canonical);
  }

  for (const a of newAliases) {
    if (sameTerm(a, canonical)) continue;
    if ((entity.aliases || []).some((x) => sameTerm(x, a))) continue;
    entity.aliases = entity.aliases || [];
    entity.aliases.push(a);
    added.aliases.push(a);
  }

  const changed = created || added.mangled.length > 0 || added.aliases.length > 0;
  if (!changed) {
    return { doc: base, changed: false, created: false, added, conflicts, entity };
  }

  const nextDoc = { ...base, entities, version: bumpVersion(base.version, opts.today) };
  return { doc: nextDoc, changed: true, created, added, conflicts, entity };
}

function toList(v) {
  if (v == null) return [];
  return Array.isArray(v) ? v.map(String) : [String(v)];
}

// ---------------------------------------------------------------------------------------------------
// Transcript-edit diff intake — extractTermCorrections
// ---------------------------------------------------------------------------------------------------

/**
 * Is this string a proper-noun / term (worth learning), rather than an ordinary word? The core
 * precision gate on the "canonical" side of an edit. A single lowercase content word ("great",
 * "shall", "the") is NOT a term; capitalized / internal-caps / dotted tokens ("Deepgram", "RichOS",
 * "whisper.cpp", "Rich Hanna") ARE. Lowercase connectors inside a multi-word term are tolerated.
 */
export function looksLikeTerm(text) {
  const raw = String(text == null ? '' : text).trim();
  if (!raw) return false;
  const tokens = raw.split(/\s+/);
  let hasTermToken = false;
  for (const tok of tokens) {
    const letters = tok.replace(/[^\p{L}]/gu, '');
    if (!letters) continue; // pure number/punctuation token — neutral, doesn't disqualify
    const isCap = /^\p{Lu}/u.test(tok);
    const internalCap = /\p{Ll}\p{Lu}/u.test(tok) || /\p{Lu}[^\p{Lu}]*\p{Lu}/u.test(tok);
    const dottedTerm = /\p{L}\.\p{L}/u.test(tok); // whisper.cpp
    if (isCap || internalCap || dottedTerm) { hasTermToken = true; continue; }
    if (CONNECTORS.has(tok.toLowerCase().replace(/[^\p{L}]/gu, ''))) continue;
    return false; // an ordinary lowercase content word disqualifies the whole span
  }
  return hasTermToken;
}

/** Strip a rendered transcript line's `**[mm:ss] Label:**` prefix; return {key, body} for alignment. */
function splitTranscriptLine(line) {
  const m = line.match(/^(\*\*\[[0-9:]+\]\s+[^:]+:\*\*)\s?(.*)$/);
  if (m) return { key: m[1], body: m[2] };
  return { key: null, body: line };
}

/** Tokenize a line into whitespace-delimited raw tokens (punctuation kept on the token). */
function words(line) {
  return String(line || '').split(/\s+/).filter(Boolean);
}

/**
 * Does the token at `i` begin a sentence? Its capital letter is then grammar, not evidence of a name,
 * so hunk expansion must not absorb it. Judged from the token BEFORE it in the operation stream —
 * which is the token that actually precedes it in the text, changed or unchanged.
 */
function startsSentence(ops, i) {
  if (i <= 0) return true; // nothing before it: it is the start of the body
  const prev = String(ops[i - 1]?.v ?? '');
  return /[.?!\u2026]["')\]]?$/.test(prev);
}

/** A single token that is proper-noun / term shaped (capitalized, internal-caps, or dotted). */
function isTermToken(tok) {
  const t = String(tok || '');
  if (/^\p{Lu}/u.test(t)) return true; // Capitalized
  if (/\p{Ll}\p{Lu}/u.test(t) || /\p{Lu}[^\p{Lu}]*\p{Lu}/u.test(t)) return true; // internal caps (RichOS)
  if (/\p{L}\.\p{L}/u.test(t)) return true; // dotted term (whisper.cpp)
  return false;
}

/**
 * Longest-common-subsequence token diff between two token arrays, reduced to REPLACE hunks: adjacent
 * runs of (removed tokens, added tokens). Pure insertions or deletions (no counterpart on the other
 * side) are ignored — a name FIX is a substitution, and ignoring insert/delete keeps us conservative.
 *
 * A replace hunk is then EXPANDED across immediately adjacent unchanged term tokens (proper-noun
 * context), so a name fix like "Rich Hand" -> "Rich Hanna" yields the WHOLE name pair, never the
 * dangerous lone-word delta "Hand" -> "Hanna" (which as a curated mangling would corrupt the ordinary
 * word "hand").
 *
 * EXPANSION STOPS AT A SENTENCE BOUNDARY, and this is not a nicety. A capital letter is the ONLY
 * evidence this function has that a token is part of a name, and the first word of a sentence is
 * capitalized for a reason that has nothing to do with names. Absorbing it produces a "term" like
 * `Cannery Street. That` — which, put to the CEO as *Add "Cannery Street. That" to your vocabulary?*,
 * is the kind of question that gets a feature switched off. Measured on the 2026-08-29 short-call
 * corpus: 3 of 6 captured corrections came out this way before the guard. The very first body token
 * was already excluded for exactly this reason; a token following `.`, `?` or `!` is the same case
 * and was not. The cost is that a genuine name immediately after a full stop is not absorbed as
 * CONTEXT — conservative in the safe direction, since the changed span itself is never dropped.
 * @returns {{from:string, to:string}[]}
 */
export function tokenReplaceHunks(oldTokens, newTokens) {
  const a = oldTokens;
  const b = newTokens;
  const n = a.length;
  const mLen = b.length;
  const dp = Array.from({ length: n + 1 }, () => new Array(mLen + 1).fill(0));
  for (let i = n - 1; i >= 0; i -= 1) {
    for (let j = mLen - 1; j >= 0; j -= 1) {
      dp[i][j] = a[i] === b[j] ? dp[i + 1][j + 1] + 1 : Math.max(dp[i + 1][j], dp[i][j + 1]);
    }
  }
  const ops = [];
  let i = 0;
  let j = 0;
  while (i < n && j < mLen) {
    if (a[i] === b[j]) { ops.push({ t: 'eq', v: a[i] }); i += 1; j += 1; }
    else if (dp[i + 1][j] >= dp[i][j + 1]) { ops.push({ t: 'del', v: a[i] }); i += 1; }
    else { ops.push({ t: 'ins', v: b[j] }); j += 1; }
  }
  while (i < n) { ops.push({ t: 'del', v: a[i] }); i += 1; }
  while (j < mLen) { ops.push({ t: 'ins', v: b[j] }); j += 1; }

  const hunks = [];
  let k = 0;
  while (k < ops.length) {
    if (ops[k].t === 'del' || ops[k].t === 'ins') {
      const blockStart = k;
      const dels = [];
      const inss = [];
      while (k < ops.length && (ops[k].t === 'del' || ops[k].t === 'ins')) {
        if (ops[k].t === 'del') dels.push(ops[k].v);
        else inss.push(ops[k].v);
        k += 1;
      }
      if (!dels.length || !inss.length) continue; // pure insert/delete — ignore
      // Expand left across adjacent unchanged term tokens (but never the very first body token, and
      // never across a sentence boundary — see the note above).
      const left = [];
      for (let p = blockStart - 1; p > 0 && ops[p].t === 'eq' && isTermToken(ops[p].v); p -= 1) {
        if (startsSentence(ops, p)) break;
        left.unshift(ops[p].v);
      }
      // Expand right across adjacent unchanged term tokens, under the same sentence guard.
      const right = [];
      for (let p = k; p < ops.length && ops[p].t === 'eq' && isTermToken(ops[p].v); p += 1) {
        if (startsSentence(ops, p)) break;
        right.push(ops[p].v);
      }
      hunks.push({
        from: [...left, ...dels, ...right].join(' '),
        to: [...left, ...inss, ...right].join(' '),
      });
    } else {
      k += 1;
    }
  }
  return hunks;
}

/**
 * Diff an edited transcript against its baseline and PROPOSE conservative mangling->canonical pairs.
 * PURE (both texts are strings). Precision over recall: a proposal must (a) have a term-shaped
 * canonical side, (b) not have a term-shaped mangled side that's identical after normalization, and
 * (c) be a plausible ASR mangling (edit-similarity gate), so ordinary word edits and wholesale
 * rewrites are rejected.
 *
 * @param {string} baselineText the committed/emitted transcript
 * @param {string} editedText the CEO-edited transcript
 * @returns {{proposals:{from:string,to:string,confidence:number,reason:string}[],
 *            rejected:{from:string,to:string,reason:string}[]}}
 */
export function extractTermCorrections(baselineText, editedText) {
  const proposals = [];
  const rejected = [];
  const seen = new Set();

  // Align lines by their transcript prefix (timestamp+label). A name fix never changes the prefix,
  // so same-prefix lines pair up; unprefixed lines (headers, blanks) pair positionally as a fallback.
  const baseLines = String(baselineText || '').split('\n');
  const editLines = String(editedText || '').split('\n');
  const byKey = new Map();
  for (const line of baseLines) {
    const { key, body } = splitTranscriptLine(line);
    if (key) byKey.set(key, body);
  }

  /** @type {{from:string,to:string}[]} */
  const hunks = [];
  const usedPositional = Math.max(baseLines.length, editLines.length);
  for (let idx = 0; idx < usedPositional; idx += 1) {
    const editRaw = editLines[idx];
    if (editRaw == null) continue;
    const { key, body: editBody } = splitTranscriptLine(editRaw);
    let baseBody = null;
    if (key && byKey.has(key)) baseBody = byKey.get(key);
    else if (!key) baseBody = baseLines[idx] != null ? splitTranscriptLine(baseLines[idx]).body : null;
    if (baseBody == null || baseBody === editBody) continue;
    for (const h of tokenReplaceHunks(words(baseBody), words(editBody))) hunks.push(h);
  }

  for (const h of hunks) {
    // Compare on the proper-noun core: strip surrounding punctuation but keep internal dots/case.
    const fromCore = trimEdgePunct(h.from);
    const toCore = trimEdgePunct(h.to);
    const dedupKey = `${normalizeTerm(fromCore)}=>${normalizeTerm(toCore)}`;
    if (seen.has(dedupKey)) continue;
    seen.add(dedupKey);

    if (!toCore || !fromCore) { rejected.push({ from: h.from, to: h.to, reason: 'empty span' }); continue; }
    if (sameTerm(fromCore, toCore)) {
      // Casing-only change can't be a curated mangling (correct.js skips norm===canonical).
      rejected.push({ from: fromCore, to: toCore, reason: 'casing-only change (not a learnable mangling)' });
      continue;
    }
    if (!looksLikeTerm(toCore)) {
      rejected.push({ from: fromCore, to: toCore, reason: 'canonical side is not proper-noun/term shaped' });
      continue;
    }
    const sim = similarity(normalizeTerm(fromCore), normalizeTerm(toCore));
    if (sim < MIN_EDIT_SIMILARITY) {
      rejected.push({ from: fromCore, to: toCore, reason: `edit-similarity ${sim.toFixed(2)} < ${MIN_EDIT_SIMILARITY} (likely a rewrite, not a mangling)` });
      continue;
    }
    // SAFETY of the MANGLED side: it becomes a curated replacement that fires on every future match,
    // so it must not be an ordinary word. Multi-word phrases are inherently safe; a LONE token is only
    // safe when it's clearly a spelling variant of the canonical (high edit-similarity), never a
    // different ordinary word swapped in ("great" -> "Grant").
    const multiWord = /\s/.test(fromCore);
    if (!multiWord && sim < LONE_TOKEN_MIN_SIMILARITY) {
      rejected.push({ from: fromCore, to: toCore, reason: `lone-token mangling too low-confidence (sim ${sim.toFixed(2)} < ${LONE_TOKEN_MIN_SIMILARITY}) — unsafe as a curated replacement` });
      continue;
    }
    proposals.push({ from: fromCore, to: toCore, confidence: Math.round(sim * 1000) / 1000, reason: 'term-shaped substitution' });
  }

  return { proposals, rejected };
}

function trimEdgePunct(s) {
  return String(s == null ? '' : s)
    .replace(/^[^\p{L}\p{N}]+/u, '')
    .replace(/[^\p{L}\p{N}.]+$/u, '')
    .trim();
}

/**
 * Combine extract + learnTerm: turn transcript edits into entity updates. Default is PROPOSE-ONLY
 * (safe): it returns the proposals without touching the doc. With apply=true it folds each proposal
 * in (canonical = the new side, mangled = the old side) and bumps the version once.
 * @param {EntitiesDoc} doc
 * @param {string} baselineText
 * @param {string} editedText
 * @param {{apply?:boolean, today?:string}} [opts]
 * @returns {{doc:EntitiesDoc, proposals:object[], rejected:object[], applied:boolean, results:object[]}}
 */
export function learnFromEdits(doc, baselineText, editedText, opts = {}) {
  const { proposals, rejected } = extractTermCorrections(baselineText, editedText);
  if (!opts.apply || proposals.length === 0) {
    return { doc, proposals, rejected, applied: false, results: [] };
  }
  let workingDoc = doc;
  const results = [];
  for (const p of proposals) {
    const res = learnTerm(workingDoc, { canonical: p.to, mangled: p.from }, { today: opts.today });
    workingDoc = res.doc;
    results.push({ canonical: p.to, mangled: p.from, created: res.created, added: res.added, conflicts: res.conflicts });
  }
  return { doc: workingDoc, proposals, rejected, applied: true, results };
}

// ---------------------------------------------------------------------------------------------------
// Serialization — keep entities.json in its curated, hand-editable style (inline string arrays)
// ---------------------------------------------------------------------------------------------------

function serializeEntity(e) {
  // Preserve each entity's EXISTING key order (learnTerm spreads {...e} then appends new fields), so
  // rewriting the file never reorders keys on entities the capture didn't touch — the diff stays
  // scoped to exactly what changed.
  const keys = Object.keys(e);
  const lines = keys.map((k) => {
    const v = e[k];
    let rendered;
    if (Array.isArray(v)) rendered = `[${v.map((x) => JSON.stringify(x)).join(', ')}]`;
    else rendered = JSON.stringify(v);
    return `      ${JSON.stringify(k)}: ${rendered}`;
  });
  return `    {\n${lines.join(',\n')}\n    }`;
}

/**
 * Serialize an entities doc back to disk in the repo's curated style: 2-space top level, one object
 * per entity, inline string arrays (so a captured change is a minimal, reviewable git diff rather
 * than a whole-file reformat). Preserves all top-level scalar keys in their original order.
 * @param {EntitiesDoc} doc
 * @returns {string}
 */
export function serializeEntitiesDoc(doc) {
  const entities = Array.isArray(doc.entities) ? doc.entities : [];
  const topKeys = Object.keys(doc).filter((k) => k !== 'entities');
  const parts = [];
  parts.push('{');
  for (const k of topKeys) parts.push(`  ${JSON.stringify(k)}: ${JSON.stringify(doc[k])},`);
  if (entities.length === 0) {
    parts.push('  "entities": []');
  } else {
    parts.push('  "entities": [');
    parts.push(entities.map(serializeEntity).join(',\n'));
    parts.push('  ]');
  }
  parts.push('}');
  return `${parts.join('\n')}\n`;
}
