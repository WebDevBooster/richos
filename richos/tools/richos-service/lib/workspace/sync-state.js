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
import path from 'node:path';
import { workspaceSyncStatePath } from '../config.js';

function keyOf(vendor, source) {
  return `${vendor}:${source}`;
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
export function getSyncState(vendor, source, file = workspaceSyncStatePath()) {
  const map = loadSyncState(file);
  const entry = map[keyOf(vendor, source)];
  return entry && entry.cursor !== undefined ? entry.cursor : null;
}

/** Persist the opaque cursor an adapter returned. */
export function setSyncState(vendor, source, cursor, file = workspaceSyncStatePath()) {
  const map = loadSyncState(file);
  map[keyOf(vendor, source)] = { cursor, updatedAt: Date.now() };
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, `${JSON.stringify(map, null, 2)}\n`);
  return map[keyOf(vendor, source)];
}

/** Reset a cursor after a token-loss signal (§4.3) — the next poll does a bounded full sync. */
export function resetSyncState(vendor, source, file = workspaceSyncStatePath()) {
  const map = loadSyncState(file);
  map[keyOf(vendor, source)] = { cursor: null, resetAt: Date.now() };
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, `${JSON.stringify(map, null, 2)}\n`);
  return null;
}
