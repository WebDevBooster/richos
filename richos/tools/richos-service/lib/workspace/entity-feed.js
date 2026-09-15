/**
 * RichOS Workspace source — the ENTITY-MEMORY FEED (the system architecture §4.5, the two flywheels converge).
 *
 * Workspace ingestion is a PRODUCER for the exact entity memory the transcription corrector already
 * consumes (`loro/entities.json` via `lib/entities.js` / `correct()`). People from Calendar attendees
 * are precisely the `person` entity type `entities.json` defines. The result: the CEO's meetings teach
 * loro the vocabulary that makes the NEXT call transcript more accurate — one shared local entity store,
 * two flywheels, at ZERO new seam cost.
 *
 * We REUSE `lib/capture.js`'s `learnTerm` intake VERBATIM — the same precision-guarded, no-clobber-of-
 * curated-rows path `learn-term` uses. Two precision guards on top, because a calendar has far more
 * noise than a CEO-confirmed correction:
 *   1. CORROBORATION THRESHOLD — only promote an attendee seen ≥ N times across the batch (a real,
 *      recurring collaborator), never a one-off external invitee. "corroborated entities seen across
 *      many events" (§4.5).
 *   2. learnTerm's own no-clobber discipline protects every curated row — a bad auto-add can only ADD a
 *      new person entity, never overwrite Deepgram/loro/etc.
 *
 * PURE (operates on an in-memory entities doc; the CORE persists it via serializeEntitiesDoc). Feeding
 * the file today; the same output satisfies the future structured loro entity store behind the
 * `{entities, entitiesVersion}` seam — this is the first concrete driver toward that store.
 */

import { learnTerm } from '../capture.js';

/** Default: an attendee must appear on at least this many events to be promoted (corroboration). */
export const DEFAULT_MIN_CORROBORATION = 2;

/** Case/space-insensitive key for counting the same person across events. */
function entityKey(c) {
  const email = (c.aliases && c.aliases[0]) || '';
  return (email || c.canonical || '').trim().toLowerCase();
}

/**
 * Count corroboration for a batch of entity candidates (from `extractCandidates` across many events).
 * @param {Array<{canonical:string, type:string, aliases?:string[]}>} candidates
 * @returns {Map<string, {candidate:Object, count:number}>}
 */
export function tallyCorroboration(candidates) {
  const tally = new Map();
  for (const c of candidates || []) {
    if (!c || !c.canonical) continue;
    const k = entityKey(c);
    if (!k) continue;
    const prev = tally.get(k);
    if (prev) prev.count += 1;
    else tally.set(k, { candidate: c, count: 1 });
  }
  return tally;
}

/**
 * Fold corroborated Calendar entity candidates into an entities doc via `learnTerm` (no-clobber).
 * Only candidates meeting the corroboration threshold are promoted. Returns a NEW doc + a report; the
 * input doc is never mutated (learnTerm is pure). PROPOSE-ONLY unless `apply` is true.
 *
 * @param {Object} doc  the raw entities.json object
 * @param {Array<{canonical:string, type:string, aliases?:string[]}>} candidates
 * @param {{minCorroboration?:number, today?:string, apply?:boolean}} [opts]
 * @returns {{doc:Object, applied:boolean, promoted:Array, held:Array, changed:boolean}}
 */
export function promoteEntities(doc, candidates, opts = {}) {
  const min = opts.minCorroboration ?? DEFAULT_MIN_CORROBORATION;
  const apply = opts.apply === true;
  const tally = tallyCorroboration(candidates);

  const promoted = [];
  const held = [];
  let working = doc;
  let changed = false;

  for (const { candidate, count } of tally.values()) {
    if (count < min) {
      held.push({ canonical: candidate.canonical, count, reason: `below corroboration threshold (${count} < ${min})` });
      continue;
    }
    if (!apply) {
      promoted.push({ canonical: candidate.canonical, count, applied: false });
      continue;
    }
    const res = learnTerm(
      working,
      { canonical: candidate.canonical, type: candidate.type || 'person', aliases: candidate.aliases || [] },
      { today: opts.today },
    );
    if (res.changed) {
      working = res.doc;
      changed = true;
    }
    promoted.push({ canonical: candidate.canonical, count, applied: res.changed, created: res.created, conflicts: res.conflicts });
  }

  return { doc: working, applied: apply, promoted, held, changed };
}
