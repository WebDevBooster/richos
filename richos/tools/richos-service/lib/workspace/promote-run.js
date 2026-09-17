/**
 * RichOS Workspace source — THE PROMOTION STEP OF A SYNC (§4.4 step 4, wired).
 *
 * `promotion.js` decides WHAT to promote. `promotion-writer.js` knows HOW to write it. Neither had a
 * caller: a `workspace sync` pulled the CEO's calendar into the evidence zone, reported honest counts,
 * and stopped one step short of the only thing the pull is FOR — Rich being able to answer "what came
 * out of Tuesday's meeting?". Evidence nobody promoted answers nothing. This module is that step, and
 * it exists as its own file rather than inside `commands.js` for one reason: WHERE THE CORPUS COMES
 * FROM is the whole difficulty, and it deserves to be stated somewhere a reader will find it.
 *
 * ── THE CORPUS IS DERIVED FROM THE ZONE, NEVER FROM THE ENVIRONMENT ──────────────────────────────
 * The engineer who wired multi-account left this step deliberately unwired and said why: the existing
 * sync tests do not set `LORO_CORPUS`, so a promotion that resolved its corpus with `corpusRoot()`
 * would have written into the CEO'S REAL `~/RichOS` from a unit test. That is not a test problem to be
 * papered over with an env var in a fixture — it is the wrong dependency. A sync's promotion must land
 * beside the evidence THAT SYNC read, and the evidence zone is inside the corpus by construction
 * (`config.js:evidenceRoot` → `<corpus>/{ceo/evidence/unfiled|companies/<id>/evidence}`). So the corpus is
 * derived BACKWARD from the zone the sync actually used:
 *
 *     <corpus>/ceo/evidence/unfiled/workspace        ->  <corpus>
 *     <corpus>/companies/<id>/evidence/workspace     ->  <corpus>
 *     anything else                                  ->  null, and promotion does not run
 *
 * That null is not a shrug. A zone outside a corpus is a deliberate arrangement — a diagnostic run
 * pointed at a scratch directory with `RICHOS_WORKSPACE_ZONE` — and there is no corpus for its
 * evidence to become memory in. It is reported BY NAME, with the sentence that would fix it, exactly
 * like a skipped source. What it is NOT allowed to do is fall back to `corpusRoot()` and write the
 * CEO's real memory from a run that was reading somebody else's evidence.
 *
 * The consequence worth stating out loud: `corpusFromZone(workspaceZone())` === `corpusRoot()` for
 * every real configuration, which the suite asserts, so the derivation changes nothing about the
 * product and removes the only way a test could have reached the CEO's corpus.
 *
 * ── THE ENTITY FEED IS PART OF THIS, AND IS NOT THE WRITER'S JOB ─────────────────────────────────
 * `promoteFromEvidence` writes calendar-event records. It does NOT write entities and says so: the
 * §4.5 candidates are RETURNED, because the corroboration threshold is a decision about a batch and
 * `promotion.js` "has no business owning the entity file". The caller owns it, the caller is a sync,
 * and this is the caller. Drive and mail items contribute their PEOPLE here even though the documents
 * and messages themselves are never promoted — which is §4.5's flywheel and the reason the feed cannot
 * be skipped whenever the record count happens to be zero.
 */

import fs from 'node:fs';
import path from 'node:path';

import { corpusRoot, corpusRootConfigured, activeCompany } from '../config.js';
import { entitiesFilePath } from '../entities.js';
import { serializeEntitiesDoc } from '../capture.js';
import { promoteFromEvidence, entityCandidatesFromEvidence } from './promotion.js';
import { promoteEntities } from './entity-feed.js';
import { loroWriter } from './promotion-writer.js';

/** The two partition shapes `evidenceRoot()` can produce, longest first. */
const EVIDENCE_TAILS = [
  ['ceo', 'evidence', 'unfiled', 'workspace'], // the zone moved out of the compiled tree (cc/norm-opus-zone1, 2026-09-17)
  ['companies', null, 'evidence', 'workspace'], // `null` matches any one company id
];

/**
 * The corpus a Workspace evidence zone lives in, or null when the zone is not inside one.
 *
 * `null` is a legitimate, reported answer — see the module docblock. Never a fallback.
 * @param {string} zone
 * @returns {string|null}
 */
export function corpusFromZone(zone) {
  const parts = path.resolve(String(zone || '')).split(path.sep);
  for (const tail of EVIDENCE_TAILS) {
    if (parts.length <= tail.length) continue;
    const candidate = parts.slice(-tail.length);
    const matches = tail.every((expected, i) => expected === null || candidate[i] === expected);
    if (matches) return parts.slice(0, -tail.length).join(path.sep) || path.sep;
  }
  return null;
}

/**
 * The entities file a promotion writes into.
 *
 * An explicit `RICHOS_ENTITIES_FILE` is an operator's own statement and wins. Otherwise it is
 * `<corpus>/ceo/entities.json` — the corpus THIS SYNC read from, never `entitiesFilePath()`'s
 * unconfigured-corpus fallback, which is the product repo. The CEO's network of names does not go in
 * a checkout that ships publicly.
 * @param {string} corpus
 */
export function entitiesFileFor(corpus) {
  if (process.env.RICHOS_ENTITIES_FILE) return entitiesFilePath();
  return path.join(corpus, 'ceo', 'entities.json');
}

function readEntitiesDoc(file, today) {
  try {
    const parsed = JSON.parse(fs.readFileSync(file, 'utf8'));
    if (parsed && typeof parsed === 'object') return parsed;
  } catch { /* no vocabulary yet is the normal state of a machine that has not transcribed a call */ }
  return { schemaVersion: 1, version: today, entities: [] };
}

/**
 * ONE promotion pass for a whole sync run.
 *
 * Called once per `sync`, after every account of every vendor has been polled — not once per account.
 * The pass reads the zone, and the zone holds every account's and every vendor's evidence, so running
 * it inside the per-account loop would redo the identical work N times and write the same records N
 * times for the ledger to reject.
 *
 * @param {{zone:string, now?:() => number, dryRun?:boolean, loroDir?:string}} opts
 * @returns {Promise<{ran:boolean, reason?:string, corpus?:string, events?:number, entities?:number,
 *   held?:Array<{reason:string, count:number}>, failed?:Array, entitiesHeld?:number, memory?:string}>}
 */
export async function runPromotion(opts) {
  const zone = opts.zone;
  const now = opts.now || (() => Date.now());
  const corpus = corpusFromZone(zone);
  if (!corpus) {
    return {
      ran: false,
      reason: `this evidence zone is not inside a loro corpus, so there is nowhere for its evidence to become memory: ${zone}. `
        + 'Promotion writes beside the evidence it promotes. Unset RICHOS_WORKSPACE_ZONE, or point '
        + 'LORO_CORPUS at the corpus this zone belongs to.',
    };
  }

  let writer;
  try {
    writer = await loroWriter({
      corpus,
      now: now(),
      ...(opts.loroDir ? { loroDir: opts.loroDir } : {}),
      // No `env` override: `resolveCorpusRoot` ranks `opts.corpus` ABOVE `LORO_CORPUS`, so the zone
      // this sync actually read already wins, and the ambient environment is still what tells
      // `resolveLoroDir` where the loro component is installed. Blanking it would win the argument
      // here and break the deployment that names its loro dir.
    });
  } catch (err) {
    return { ran: false, corpus, reason: String(err.message || err) };
  }

  const result = promoteFromEvidence({
    zone,
    write: writer.write,
    now,
    ...(opts.dryRun ? { dryRun: true } : {}),
    // Evidence filed under a company is memory for that company; everything else is unfiled. The
    // partition comes from the same switch the evidence tree came from, so a record cannot land in a
    // different company from the item that produced it.
    partitionFor: () => activeCompany() || 'unfiled',
  });

  // §4.5 — the people. Not conditional on a record being promoted: a Drive document and a mail
  // message promote nothing of their own and still corroborate a colleague into shared vocabulary.
  const today = new Date(now()).toISOString().slice(0, 10);
  const entitiesFile = entitiesFileFor(corpus);
  const doc = readEntitiesDoc(entitiesFile, today);
  const entityResult = promoteEntities(doc, entityCandidatesFromEvidence(zone), { apply: true, today });
  if (entityResult.changed && !opts.dryRun) {
    fs.mkdirSync(path.dirname(entitiesFile), { recursive: true });
    fs.writeFileSync(entitiesFile, serializeEntitiesDoc(entityResult.doc), { mode: 0o600 });
  }

  return {
    ran: true,
    corpus,
    memory: writer.corpusRoot && writer.corpusRoot.root ? writer.corpusRoot.root : corpus,
    events: result.promoted.length,
    entities: entityResult.promoted.filter((e) => e.applied !== false).length,
    entitiesHeld: entityResult.held.length,
    held: tally(result.skipped.map((sk) => sk.reason)),
    failed: result.failed,
  };
}

/** Group reasons so a hold is reported by CAUSE and count, never as a bare number. */
function tally(reasons) {
  const counts = new Map();
  for (const reason of reasons) counts.set(reason, (counts.get(reason) || 0) + 1);
  return [...counts.entries()].map(([reason, count]) => ({ reason, count }))
    .sort((a, b) => b.count - a.count || a.reason.localeCompare(b.reason));
}

/**
 * The lines `sync` prints for a promotion pass. NEVER-SILENT, the posture of every other line that
 * command emits: an absence is reported with its cause, and a failure is not allowed to look like a
 * success with a small number in it.
 * @param {Awaited<ReturnType<typeof runPromotion>>} p
 * @param {(label:string) => string} L
 * @returns {string[]}
 */
export function describePromotion(p, L) {
  if (!p.ran) return [`${L('promoted')}not run — ${p.reason}`];
  const held = p.held.reduce((n, h) => n + h.count, 0);
  const lines = [
    `${L('promoted')}${p.events} event${p.events === 1 ? '' : 's'} into memory, `
      + `${p.entities} ${p.entities === 1 ? 'person' : 'people'} learned, `
      + `${held} item${held === 1 ? '' : 's'} held`,
  ];
  for (const h of p.held) lines.push(`            held: ${h.count} × ${h.reason}`);
  if (p.entitiesHeld) {
    lines.push(`            held: ${p.entitiesHeld} name${p.entitiesHeld === 1 ? '' : 's'} below the corroboration threshold (seen once — not yet somebody you work with)`);
  }
  for (const f of p.failed) lines.push(`            FAILED: ${f.sourceItemId} — ${f.error}`);
  lines.push(`${L('memory')}${p.memory}`);
  return lines;
}

/** `corpusRoot()` is re-exported for the assertion that the derivation agrees with the real config. */
export { corpusRoot, corpusRootConfigured };
