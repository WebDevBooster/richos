/**
 * RichOS Workspace source — UNDO ONE SYNC RUN (`workspace repair --since … --until …`).
 *
 * ── WHY A COMMAND, AND NOT A ONE-OFF SCRIPT ─────────────────────────────────────────────────────
 * On 2026-09-17 two Google grants were stored under each other's names (`identity.js` has the whole
 * account, and the sync output that proves it). `connect` can no longer do that. But one crossed run
 * had already happened, and what it left behind is not a file to delete: it is ledger rows, evidence
 * revisions, delta cursors that now hold the OTHER account's position, and promotions computed from
 * evidence counted twice. Undoing that by hand means knowing every one of those stores and the exact
 * relationship between them, at a keyboard, on the CEO's real corpus, once. That is the shape of
 * thing that gets done wrong, so it is code with a dry run and a test instead.
 *
 * ── WHAT IT CHANGES, AND WHAT IT DELIBERATELY DOES NOT ──────────────────────────────────────────
 * CHANGES, and only inside the window:
 *   - ingest-ledger rows whose `observedAt` falls in [since, until];
 *   - the evidence revision each of those rows links to, and the item directory when it empties;
 *   - every delta cursor whose entry was written in the window — reset to null, so the next sync is
 *     a bounded FULL sync that the (now-repaired) ledger dedups against. `resetSyncState` does it,
 *     the same function the core calls on a 410, rather than a second spelling of the same idea.
 *
 * REPORTS AND NEVER TOUCHES:
 *   - promoted MEMORY records whose evidence is going away. They are loro records: create-only,
 *     write-locked, superseded rather than overwritten, and deciding that a record should stop
 *     existing is the CEO's call and the writer's job, not this command's. Repair names every one of
 *     them, with its ref and its file, and says so plainly in both modes.
 *   - `entities.json` rows whose §4.5 corroboration falls below the threshold once the removed
 *     evidence stops counting. The count is recomputed with `entityCandidatesFromEvidence` and
 *     `tallyCorroboration`/`DEFAULT_MIN_CORROBORATION` — the SAME reader and the SAME threshold the
 *     promotion pass uses, given an `exclude` predicate. A second implementation of "is this person
 *     corroborated" would answer a different question from the one promotion asked.
 *
 * ── THE WINDOW IS THE HANDLE, BECAUSE IT IS THE ONLY HONEST ONE ─────────────────────────────────
 * A ledger row records `sourceItemId`, `vendorEtag`, vendor, source, scope, trust, `observedAt` and
 * the evidence link. It does NOT record which account it came from — the account is hashed into the
 * adapter's `sourceInstanceId`, which is inside `sourceItemId`, and a run's rows are therefore
 * identifiable by WHEN they were written and by nothing cheaper. So the window is what the operator
 * gives, it comes from the run's own output, and `--dry-run` exists because a window is a claim about
 * a run and a wrong one is only discovered by reading what it would do.
 *
 * ── REFUSALS, NOT GUESSES ───────────────────────────────────────────────────────────────────────
 * Every evidence directory is resolved through `evidence.js:evidenceDir` — the same function that
 * WROTE it — and then its `item.json` is read back and its identity compared to the ledger row.
 * A revision whose stored identity does not match the row that claims it is NOT deleted: it is
 * reported, its row is kept, and the run still reports everything else. Nothing outside the zone is
 * ever touched, and that is asserted rather than assumed.
 */

import fs from 'node:fs';
import path from 'node:path';

import { workspaceLedgerPath, workspaceSyncStatePath, workspaceZone } from '../config.js';
import { writePrivateFile } from '../private-files.js';
import { appendJsonLine } from '../durable-jsonl.js';
import { evidenceDir } from './evidence.js';
import { loadSyncState, resetSyncState } from './sync-state.js';
import { entityCandidatesFromEvidence, readPromotionLedger, promotionLedgerPath } from './promotion.js';
import { tallyCorroboration, DEFAULT_MIN_CORROBORATION } from './entity-feed.js';

/** The append-only record of what a repair removed — the undo is itself auditable. */
export function repairLedgerPath(zone = workspaceZone()) {
  return path.join(zone, '_workspace_repairs.jsonl');
}

/**
 * Parse an ISO instant the operator typed. Refuses anything it cannot read, rather than silently
 * becoming `NaN` and matching either everything or nothing.
 * @param {string} value
 * @param {string} label
 * @returns {number}
 */
export function parseInstant(value, label) {
  const ms = Date.parse(String(value || ''));
  if (!Number.isFinite(ms)) {
    throw new Error(`--${label} is not a time RichOS can read: "${value}". Use an ISO instant, e.g. 2026-09-17T07:32:00Z`);
  }
  return ms;
}

/** `observedAt` is epoch milliseconds (`source-item.js`), but a hand-written row may hold an ISO string. */
function instantOf(value) {
  if (typeof value === 'number' && Number.isFinite(value)) return value;
  const parsed = Date.parse(String(value || ''));
  return Number.isFinite(parsed) ? parsed : null;
}

function readJson(file) {
  try {
    return JSON.parse(fs.readFileSync(file, 'utf8'));
  } catch {
    return null;
  }
}

/** Every line of a JSONL file, with the raw text kept so a rewrite preserves what it did not touch. */
function readLines(file) {
  let text;
  try {
    text = fs.readFileSync(file, 'utf8');
  } catch {
    return [];
  }
  return text.split(/\r?\n/).filter((l) => l.trim()).map((raw) => {
    let row = null;
    try {
      row = JSON.parse(raw);
    } catch {
      row = null; // a damaged line is DATA, not an error: it is kept verbatim and never matched
    }
    return { raw, row };
  });
}

/** True when `dir` is inside `zone`. The boundary every deletion is checked against. */
function insideZone(dir, zone) {
  const rel = path.relative(path.resolve(zone), path.resolve(dir));
  return Boolean(rel) && !rel.startsWith('..') && !path.isAbsolute(rel);
}

/**
 * PLAN a repair. Reads; changes nothing, ever — `applyRepair` performs exactly what this returned.
 *
 * @param {{zone?:string, since:number, until?:number, now?:() => number}} opts
 * @returns {Object} the plan (see the module header for what is a change and what is a report)
 */
export function planRepair(opts) {
  const zone = opts.zone || workspaceZone();
  const since = opts.since;
  const until = opts.until ?? (opts.now ? opts.now() : Date.now());
  if (!Number.isFinite(since) || !Number.isFinite(until)) throw new Error('repair needs a finite --since and --until');
  if (until < since) throw new Error('--until is before --since, so the window is empty');

  const ledgerFile = workspaceLedgerPath(zone);
  const lines = readLines(ledgerFile);

  const removing = [];
  const keeping = [];
  const refusals = [];

  for (const line of lines) {
    const at = line.row ? instantOf(line.row.observedAt) : null;
    if (!line.row || at === null || at < since || at > until) {
      keeping.push(line);
      continue;
    }
    const resolved = resolveEvidence(line.row, zone);
    if (resolved.refusal) {
      refusals.push({ sourceItemId: line.row.sourceItemId, dir: resolved.dir, reason: resolved.refusal });
      keeping.push(line); // a row whose evidence could not be confirmed keeps its row
      continue;
    }
    removing.push({ line, row: line.row, observedAt: at, evidence: resolved });
  }

  // The evidence directories, deduplicated: two ledger rows never share a revision, but a damaged
  // ledger could claim so, and deleting one path twice must not be a second, failing delete.
  const evidenceDirs = [...new Map(removing
    .filter((r) => r.evidence.exists)
    .map((r) => [r.evidence.dir, { dir: r.evidence.dir, sourceItemId: r.row.sourceItemId, vendor: r.row.vendor, source: r.row.source }]))
    .values()];
  const removedDirs = new Set(evidenceDirs.map((e) => e.dir));

  // ── cursors written in the window ──────────────────────────────────────────────────────────────
  const syncFile = workspaceSyncStatePath(zone);
  const syncMap = loadSyncState(syncFile);
  const cursors = [];
  for (const [key, entry] of Object.entries(syncMap)) {
    const at = instantOf(entry && (entry.updatedAt ?? entry.resetAt));
    if (at === null || at < since || at > until) continue;
    const parsed = parseCursorKey(key);
    cursors.push({
      key,
      vendor: parsed.vendor,
      source: parsed.source,
      instance: parsed.instance,
      updatedAt: at,
      // WHAT the cursor is, never the cursor itself: Calendar's is a MAP of per-calendar sync tokens
      // and the rest are opaque strings. A token is a credential-shaped thing and this file prints
      // none of them — what the operator needs is which calendars a reset covers, and that is the
      // map's KEYS.
      shape: describeCursor(entry && entry.cursor),
    });
  }

  // ── promoted records whose evidence is going away ──────────────────────────────────────────────
  const promotions = readPromotionLedger(zone);
  const survivingRevisions = survivingBySourceItem(zone, removedDirs);
  const orphanedRecords = [];
  for (const rem of removing) {
    const entry = promotions.get(rem.row.sourceItemId);
    if (!entry) continue;
    if ((survivingRevisions.get(rem.row.sourceItemId) || 0) > 0) continue; // another revision still cites it
    if (orphanedRecords.some((o) => o.ref === entry.ref)) continue;
    orphanedRecords.push({
      sourceItemId: rem.row.sourceItemId,
      ref: entry.ref,
      promotedAt: entry.promotedAt || null,
      vendorEtag: entry.vendorEtag || '',
    });
  }

  // ── §4.5 corroboration, recomputed with promotion's OWN reader and threshold ───────────────────
  const before = tallyCorroboration(entityCandidatesFromEvidence(zone));
  const after = tallyCorroboration(entityCandidatesFromEvidence(zone, { exclude: (dir) => removedDirs.has(dir) }));
  const threshold = DEFAULT_MIN_CORROBORATION;
  const entitiesFalling = [];
  for (const [key, { candidate, count }] of before.entries()) {
    if (count < threshold) continue; // it was never promoted on this evidence
    const now = after.has(key) ? after.get(key).count : 0;
    if (now >= threshold) continue;
    entitiesFalling.push({ key, canonical: candidate.canonical, before: count, after: now, threshold });
  }
  entitiesFalling.sort((a, b) => a.canonical.localeCompare(b.canonical));

  return {
    zone,
    since,
    until,
    ledger: {
      file: ledgerFile,
      total: lines.length,
      removing: removing.map((r) => ({ ...r.row, observedAt: r.observedAt, evidenceDir: r.evidence.dir, evidenceExists: r.evidence.exists })),
      keeping: keeping.length,
    },
    evidence: { dirs: evidenceDirs, missing: removing.filter((r) => !r.evidence.exists).map((r) => r.evidence.dir) },
    cursors: { file: syncFile, resetting: cursors },
    promotions: { file: promotionLedgerPath(zone), orphaned: orphanedRecords, total: promotions.size },
    entities: { threshold, falling: entitiesFalling },
    refusals,
    // Carried for `applyRepair` so apply performs exactly what was planned, rather than re-deriving
    // it from a zone that a second process may have changed in between.
    _lines: lines,
    _removeRaw: new Set(removing.map((r) => r.line.raw)),
  };
}

/**
 * PERFORM a plan. Does exactly what `planRepair` returned and nothing else.
 * @param {Object} plan
 * @param {{now?:() => number}} [opts]
 */
export function applyRepair(plan, opts = {}) {
  const now = opts.now ? opts.now() : Date.now();
  const zone = plan.zone;
  const done = { evidenceRemoved: [], rowsRemoved: 0, cursorsReset: [], errors: [] };

  // 1. EVIDENCE FIRST. A removed ledger row with its evidence still on disk is a revision that will
  //    never be re-ingested and never be explainable; the reverse — evidence gone, row still there —
  //    is repaired by running this again.
  for (const entry of plan.evidence.dirs) {
    if (!insideZone(entry.dir, zone)) {
      done.errors.push({ dir: entry.dir, error: 'storage boundary: outside the evidence zone — not touched' });
      continue;
    }
    try {
      fs.rmSync(entry.dir, { recursive: true, force: true });
      pruneEmptyParent(path.dirname(entry.dir), zone);
      done.evidenceRemoved.push(entry.dir);
    } catch (err) {
      done.errors.push({ dir: entry.dir, error: String(err.message || err) });
    }
  }

  // 2. THE LEDGER, rewritten from the lines the plan kept — including any line it could not parse,
  //    verbatim. An append-only log is rewritten here and only here, which is why the removed rows
  //    are written to the repair ledger below before anything else can lose them.
  if (plan._removeRaw.size) {
    const kept = plan._lines.filter((l) => !plan._removeRaw.has(l.raw)).map((l) => l.raw);
    writePrivateFile(plan.ledger.file, kept.length ? `${kept.join('\n')}\n` : '');
    done.rowsRemoved = plan._removeRaw.size;
  }

  // 3. CURSORS. Through `resetSyncState`, so a repaired cursor is indistinguishable from one the core
  //    itself reset after a 410 — the next poll is a bounded full sync, deduped by the ledger.
  for (const c of plan.cursors.resetting) {
    resetSyncState(c.vendor, c.source, plan.cursors.file, c.instance);
    done.cursorsReset.push(c.key);
  }

  // 4. THE AUDIT ROW. What was removed, in full, so the repair can be read back afterwards and so a
  //    row deleted by mistake is still recoverable from a file rather than from a memory of a
  //    terminal window.
  appendJsonLine(repairLedgerPath(zone), {
    repairedAt: now,
    since: plan.since,
    until: plan.until,
    rows: plan.ledger.removing,
    evidenceRemoved: done.evidenceRemoved,
    cursorsReset: done.cursorsReset,
    orphanedRecords: plan.promotions.orphaned,
    entitiesBelowThreshold: plan.entities.falling,
    errors: done.errors,
  });

  return done;
}

/**
 * The lines both modes print. `dry` changes the verbs and nothing about the content: a dry run that
 * described less than the apply would be a rehearsal of a different command.
 * @param {Object} plan
 * @param {(label:string) => string} L
 * @param {{dryRun:boolean, done?:Object}} opts
 */
export function describeRepair(plan, L, opts) {
  const dry = opts.dryRun;
  const would = dry ? 'would ' : '';
  const lines = [];
  lines.push(`${L('zone')}${plan.zone}`);
  lines.push(`${L('window')}${new Date(plan.since).toISOString()}  ..  ${new Date(plan.until).toISOString()}`);
  lines.push('');

  lines.push(`${L('ledger')}${would}remove ${plan.ledger.removing.length} of ${plan.ledger.total} row${plan.ledger.total === 1 ? '' : 's'} — ${plan.ledger.file}`);
  for (const row of plan.ledger.removing) {
    lines.push(`            ${new Date(row.observedAt).toISOString()}  ${row.vendor}:${row.source}  ${row.sourceItemId}`);
  }

  lines.push(`${L('evidence')}${would}delete ${plan.evidence.dirs.length} revision director${plan.evidence.dirs.length === 1 ? 'y' : 'ies'}`);
  for (const e of plan.evidence.dirs) lines.push(`            ${e.dir}`);
  for (const missing of plan.evidence.missing) lines.push(`            already gone: ${missing}`);

  lines.push(`${L('cursors')}${would}reset ${plan.cursors.resetting.length} — the next sync is a bounded full sync, deduped by the ledger`);
  for (const c of plan.cursors.resetting) {
    lines.push(`            ${c.vendor}:${c.source}  instance ${c.instance || '(none)'}  written ${new Date(c.updatedAt).toISOString()}  ${c.shape}`);
  }

  // NOT CHANGED, and said in both modes so nobody has to infer it from an absence. The tense follows
  // the mode: a dry run describes a consequence that has not happened yet, and an apply describes one
  // that just did. Reporting either in the other's words is how a rehearsal gets mistaken for a run.
  const left = dry ? 'would be left' : 'are now left';
  lines.push(`${L('memory')}${plan.promotions.orphaned.length} promoted record${plan.promotions.orphaned.length === 1 ? '' : 's'} ${left} citing evidence that is gone — NOT removed by repair`);
  for (const o of plan.promotions.orphaned) {
    lines.push(`            ${o.ref}   (from ${o.sourceItemId})`);
  }
  if (plan.promotions.orphaned.length) {
    lines.push('            A loro record is create-only and superseded rather than deleted, so whether these');
    lines.push('            stop existing is a decision for the CEO and a write for the loro writer, not this command.');
  }

  lines.push(`${L('people')}${plan.entities.falling.length} name${plan.entities.falling.length === 1 ? '' : 's'} ${dry ? 'would fall' : 'now fall'} below the corroboration threshold (${plan.entities.threshold}) without this evidence — NOT removed by repair`);
  for (const e of plan.entities.falling) {
    lines.push(`            ${e.canonical}: ${e.before} → ${e.after}`);
  }

  for (const r of plan.refusals) {
    lines.push(`${L('REFUSED')}${r.sourceItemId} — ${r.reason}`);
    lines.push(`            ${r.dir}`);
    lines.push('            its ledger row was KEPT, because a row whose evidence cannot be confirmed is not this run\'s.');
  }

  if (opts.done) {
    lines.push('');
    lines.push(`${L('removed')}${opts.done.rowsRemoved} ledger row${opts.done.rowsRemoved === 1 ? '' : 's'}, ${opts.done.evidenceRemoved.length} revision director${opts.done.evidenceRemoved.length === 1 ? 'y' : 'ies'}, ${opts.done.cursorsReset.length} cursor${opts.done.cursorsReset.length === 1 ? '' : 's'} reset`);
    lines.push(`${L('audit')}${repairLedgerPath(plan.zone)}`);
    for (const e of opts.done.errors) lines.push(`${L('FAILED')}${e.dir} — ${e.error}`);
  } else if (dry) {
    lines.push('');
    lines.push('(dry run — nothing was changed. Re-run with --apply.)');
  }
  return lines;
}

// -------------------------------------------------------------------------------------------------

/**
 * Where a ledger row's evidence is, resolved through the SAME function that wrote it, and confirmed
 * by reading the stored item back. Collector-path parity: a second way of computing an evidence path
 * is a second way of deleting the wrong directory.
 */
function resolveEvidence(row, zone) {
  const item = {
    sourceItemId: row.sourceItemId,
    vendor: row.vendor,
    source: row.source,
    provenance: { vendorEtag: row.vendorEtag },
  };
  let dir;
  try {
    dir = evidenceDir(item, zone);
  } catch (err) {
    return { dir: null, exists: false, refusal: `its evidence path could not be resolved — ${String(err.message || err)}` };
  }
  if (!insideZone(dir, zone)) return { dir, exists: false, refusal: 'its evidence path resolves outside the evidence zone' };
  const itemFile = path.join(dir, 'item.json');
  if (!fs.existsSync(itemFile)) {
    // Not a refusal: a row whose evidence is already gone still has to lose its row, or the next
    // sync will dedup against a revision that does not exist and never re-ingest it.
    return { dir, exists: false, refusal: null };
  }
  const stored = readJson(itemFile);
  if (!stored) return { dir, exists: true, refusal: 'its item.json could not be read, so the revision was not confirmed' };
  const sameItem = stored.sourceItemId === row.sourceItemId
    && stored.vendor === row.vendor && stored.source === row.source
    && (stored.provenance && stored.provenance.vendorEtag) === row.vendorEtag;
  if (!sameItem) return { dir, exists: true, refusal: 'the revision on disk is not the one this row claims' };
  return { dir, exists: true, refusal: null };
}

/** How many revisions of each `sourceItemId` survive the removal — promotion cites the item, not the path. */
function survivingBySourceItem(zone, removedDirs) {
  const counts = new Map();
  const roots = listDirs(zone);
  for (const vendor of roots) {
    for (const source of listDirs(path.join(zone, vendor))) {
      for (const id of listDirs(path.join(zone, vendor, source))) {
        for (const rev of listDirs(path.join(zone, vendor, source, id))) {
          const dir = path.join(zone, vendor, source, id, rev);
          if (removedDirs.has(dir)) continue;
          const stored = readJson(path.join(dir, 'item.json'));
          if (!stored || !stored.sourceItemId) continue;
          counts.set(stored.sourceItemId, (counts.get(stored.sourceItemId) || 0) + 1);
        }
      }
    }
  }
  return counts;
}

function listDirs(dir) {
  try {
    return fs.readdirSync(dir, { withFileTypes: true })
      .filter((e) => e.isDirectory() && !e.name.startsWith('.') && !e.name.startsWith('_'))
      .map((e) => e.name)
      .sort();
  } catch {
    return [];
  }
}

/** `["google","calendar","<instance>"]` or the legacy `vendor:source`, which belongs to no account. */
function parseCursorKey(key) {
  if (key.startsWith('[')) {
    try {
      const parsed = JSON.parse(key);
      if (Array.isArray(parsed)) return { vendor: parsed[0], source: parsed[1], instance: parsed[2] || null };
    } catch { /* fall through to the legacy shape */ }
  }
  const [vendor, source] = key.split(':');
  return { vendor, source, instance: null };
}

/**
 * What a cursor IS, never what it says. Calendar's cursor is a map keyed by calendar id, and those
 * keys are exactly what an operator needs to see: "per calendar" is visible here or nowhere.
 */
function describeCursor(cursor) {
  if (cursor === null || cursor === undefined) return 'no cursor (already a full sync)';
  if (typeof cursor === 'object') {
    const keys = Object.keys(cursor);
    return `a cursor per calendar: ${keys.length} — ${keys.join(', ')}`;
  }
  return 'one delta token';
}

/** Remove an item directory that just lost its last revision. Never climbs past the zone. */
function pruneEmptyParent(dir, zone) {
  if (!insideZone(dir, zone)) return;
  try {
    if (fs.readdirSync(dir).length === 0) fs.rmdirSync(dir);
  } catch { /* a parent that will not empty is not a failure of the removal that already happened */ }
}
