/**
 * RichOS Workspace source — the ingest ledger (the system architecture §4.2).
 *
 * REUSES THE `lib/ledger.js` PATTERN VERBATIM, keyed by (sourceItemId, vendorEtag) instead of the
 * transcription ledger's (sessionId, runIndex). One append-only JSONL line per observed item version:
 * what was observed == what was governed == what synthesis saw. Idempotent by construction:
 *   - re-polling an UNCHANGED item (same id + same etag) → no-op, never double-ingested.
 *   - a CHANGED item (same id, NEW etag) → a NEW ledger line (a new evidence version), so a full
 *     resync after a lost sync token (§4.3, Google 410) never double-lands.
 */

import fs from 'node:fs';
import path from 'node:path';
import { workspaceLedgerPath } from '../config.js';

/**
 * @param {string} sourceItemId
 * @param {string} vendorEtag
 * @param {string} [zone]
 * @returns {boolean} true if a line for this (sourceItemId, vendorEtag) already exists
 */
export function alreadyIngested(sourceItemId, vendorEtag, zone) {
  const file = workspaceLedgerPath(zone);
  if (!fs.existsSync(file)) return false;
  const lines = fs.readFileSync(file, 'utf8').split(/\r?\n/).filter(Boolean);
  return lines.some((l) => {
    try {
      const row = JSON.parse(l);
      return row.sourceItemId === sourceItemId && row.vendorEtag === vendorEtag;
    } catch {
      return false;
    }
  });
}

/**
 * Append one ingest line, unless an identical (sourceItemId, vendorEtag) line already exists.
 * @param {Record<string, any>} entry must carry sourceItemId + vendorEtag
 * @param {string} [zone]
 * @returns {{appended: boolean, path: string}}
 */
export function appendIngest(entry, zone) {
  const file = workspaceLedgerPath(zone);
  if (alreadyIngested(entry.sourceItemId, entry.vendorEtag, zone)) return { appended: false, path: file };
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.appendFileSync(file, `${JSON.stringify(entry)}\n`);
  return { appended: true, path: file };
}
