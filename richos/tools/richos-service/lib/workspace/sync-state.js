/**
 * RichOS Workspace source — the delta/sync-token store (the system architecture §4.3).
 *
 * Incremental sync is POLLING with opaque delta tokens, NEVER webhooks (§1: a webhook needs a public
 * HTTPS endpoint = a RichOS server, which violates the privacy invariant). The core persists whatever
 * opaque cursor an adapter returns from `listChanges` and hands it back next poll — it never branches on
 * vendor and never re-pulls the world.
 *
 * A lost/expired token (Google 410 Gone / Graph resync) is recorded as a reset so the next poll does a
 * bounded full sync, deduped by the ingest ledger so nothing double-lands.
 */

import fs from 'node:fs';
import { workspaceSyncStatePath } from '../config.js';
import { writePrivateFile } from '../private-files.js';

function keyOf(vendor, source, instance) {
  return instance ? JSON.stringify([vendor, source, instance]) : `${vendor}:${source}`;
}

/** Load the whole sync-state map. Missing/corrupt file → empty (a first run does a full sync). */
export function loadSyncState(file = workspaceSyncStatePath()) {
  try {
    const raw = JSON.parse(fs.readFileSync(file, 'utf8'));
    return raw && typeof raw === 'object' ? raw : {};
  } catch {
    return {};
  }
}

/**
 * The opaque cursor for one (vendor, source), or null for a first run / after a reset.
 * @returns {any|null}
 */
export function getSyncState(vendor, source, file = workspaceSyncStatePath(), instance = null) {
  const map = loadSyncState(file);
  const entry = map[keyOf(vendor, source, instance)];
  return entry && entry.cursor !== undefined ? entry.cursor : null;
}

/** Persist the opaque cursor an adapter returned. */
export function setSyncState(vendor, source, cursor, file = workspaceSyncStatePath(), instance = null) {
  const map = loadSyncState(file);
  map[keyOf(vendor, source, instance)] = { cursor, updatedAt: Date.now() };
  writePrivateFile(file, `${JSON.stringify(map, null, 2)}\n`);
  return map[keyOf(vendor, source, instance)];
}

/** Reset a cursor after a token-loss signal (§4.3) — the next poll does a bounded full sync. */
export function resetSyncState(vendor, source, file = workspaceSyncStatePath(), instance = null) {
  const map = loadSyncState(file);
  map[keyOf(vendor, source, instance)] = { cursor: null, resetAt: Date.now() };
  writePrivateFile(file, `${JSON.stringify(map, null, 2)}\n`);
  return null;
}

/**
 * Drop the cursors belonging to a set of source instances, and NOTHING else.
 *
 * `disconnect --forget-cursors` used to delete the whole file, which was exactly right while one
 * account existed and is data loss the moment two do: the account still connected would silently
 * re-pull its world on its next poll. The file is removed only when the last entry leaves it, so
 * "no cursors at all" still looks on disk the way it always did.
 *
 * @param {string[]} instances  `sourceInstanceId`s, produced by the same adapters a sync polls with
 * @returns {number} how many entries were dropped
 */
export function forgetInstances(instances, file = workspaceSyncStatePath()) {
  const want = new Set(instances.filter(Boolean));
  if (!want.size) return 0;
  const map = loadSyncState(file);
  let dropped = 0;
  for (const key of Object.keys(map)) {
    if (!key.startsWith('[')) continue; // a legacy `vendor:source` key belongs to no account
    let parsed;
    try {
      parsed = JSON.parse(key);
    } catch {
      continue;
    }
    if (Array.isArray(parsed) && want.has(parsed[2])) {
      delete map[key];
      dropped += 1;
    }
  }
  if (!dropped) return 0;
  if (Object.keys(map).length) writePrivateFile(file, `${JSON.stringify(map, null, 2)}\n`);
  else fs.rmSync(file, { force: true });
  return dropped;
}

/** Old cursors have no account/resource owner. Retain their history and force a scoped full sync. */
export function retireUnscopedCursor(vendor, source, file = workspaceSyncStatePath()) {
  const map = loadSyncState(file);
  const legacy = map[keyOf(vendor, source)];
  if (!legacy || legacy.retiredAt) return false;
  map[keyOf(vendor, source)] = { ...legacy, cursor: null, retiredCursor: legacy.cursor ?? null,
    retiredAt: Date.now(), reason: 'legacy cursor has no source instance; scoped full sync required' };
  writePrivateFile(file, `${JSON.stringify(map, null, 2)}\n`);
  return true;
}
