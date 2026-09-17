/**
 * RichOS Workspace source — the LAST-RUN record (operational state, next to the sync cursors).
 *
 * `workspace status` has to answer "what happened last time it ran?". It could infer that from the
 * cursor file's timestamp, and that answer would be wrong in the two cases that matter: a poll that
 * observed nothing does not move the cursor, and a poll that failed on auth never reaches it. So the
 * outcome is RECORDED by the run that produced it, and status reports the record.
 *
 * What goes in: counts, the auth state, whether a resync happened, and an error message if the poll
 * threw. What never goes in: an item, a title, an attendee, a URL, a cursor or a token. This file is
 * a tally, not a second evidence store — the evidence zone (§4.2) is the only place item data lives.
 *
 * A run can also be UNAVAILABLE rather than failed or successful — a stated condition about the
 * account itself (e.g. a Google account with no Gmail mailbox), not a fault in RichOS and not a
 * transient error. `run.unavailable` is recorded as its own outcome (`ok: true, unavailable: true`),
 * distinct from `ok: false` (a real failure) precisely so `status` and a caller reading the record can
 * tell "this source cannot run against this account" apart from "the last attempt threw."
 */

import fs from 'node:fs';
import { workspaceRunStatePath } from '../config.js';
import { writePrivateFile } from '../private-files.js';

function keyOf(vendor, source, instance) {
  return JSON.stringify([vendor, source, instance || null]);
}

/** Load the whole map. Missing/corrupt → empty, the same way the sync store degrades. */
export function loadRunState(file = workspaceRunStatePath()) {
  try {
    const raw = JSON.parse(fs.readFileSync(file, 'utf8'));
    return raw && typeof raw === 'object' ? raw : {};
  } catch {
    return {};
  }
}

/** The last recorded outcome for one source instance, or null. */
export function getRunState(vendor, source, instance, file = workspaceRunStatePath()) {
  const map = loadRunState(file);
  return map[keyOf(vendor, source, instance)] || null;
}

/**
 * Record one pass. Takes the summary `ingestOnce` returns (or an error, or an `unavailable` reason)
 * and keeps only the tally.
 * @param {{vendor:string, source:string, instance:string, at:number,
 *   summary?:object, error?:string, unavailable?:string}} run
 */
export function recordRun(run, file = workspaceRunStatePath()) {
  const map = loadRunState(file);
  const s = run.summary || {};
  const key = keyOf(run.vendor, run.source, run.instance);
  map[key] = run.unavailable
    // A stated condition about the account, not a failure: `ok: true` on purpose (nothing here is
    // broken), `unavailable: true` so a reader can tell it apart from an ordinary successful poll.
    ? { at: run.at, ok: true, unavailable: true, reason: String(run.unavailable) }
    : run.error
      ? { at: run.at, ok: false, error: String(run.error) }
      : {
        at: run.at,
        ok: true,
        polled: Boolean(s.polled),
        observed: s.observed || 0,
        ingested: s.ingested || 0,
        deduped: s.deduped || 0,
        quarantined: s.quarantined || 0,
        resynced: Boolean(s.resynced),
        healthState: s.health && s.health.state ? s.health.state : 'unknown',
      };
  writePrivateFile(file, `${JSON.stringify(map, null, 2)}\n`);
  return map[key];
}

/** Human-readable one-liner for `status`. */
export function describeRun(run) {
  if (!run) return 'never run';
  const when = new Date(run.at).toISOString();
  if (run.unavailable) return `${when} — unavailable — ${run.reason}`;
  if (!run.ok) return `FAILED at ${when} — ${run.error}`;
  if (!run.polled) return `${when} — did not poll (auth needed re-consent)`;
  return `${when} — observed ${run.observed}, ingested ${run.ingested}, deduped ${run.deduped}`
    + (run.quarantined ? `, quarantined ${run.quarantined}` : '')
    + (run.resynced ? ' (full resync)' : '');
}
