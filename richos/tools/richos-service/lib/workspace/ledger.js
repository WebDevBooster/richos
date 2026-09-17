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
import { appendJsonLine } from '../durable-jsonl.js';
import { workspaceLedgerPath } from '../config.js';

/**
 * Every `identityKey` this zone has ever ingested → the ITEM that holds it, and whether that item is
 * still live at the source.
 *
 * WHY THE LEDGER AND NOT THE ADAPTER. The adapter already merges copies of one meeting seen on two
 * calendars, and it does it with a `seen` set that lives for exactly one poll (`google-calendar.js`,
 * `microsoft-calendar.js`). That is the whole of the merge, and it is why a copy shared onto a second
 * calendar a month after the original lands a SECOND time: the two copies were never in one poll, so
 * nothing remembered. This is that same memory, made durable, in the store that already answers
 * "have I ingested this before" for every other reason.
 *
 * WHY `withdrawn` IS PART OF THE ANSWER. Suppressing a copy because of a twin is only right while the
 * twin exists. If the copy that landed is called off at the source and the other one is not, the CEO
 * still has that meeting — and memory that reported it as called off would be wrong in the direction
 * that matters. The latest row for an item is its current state, so the index reports it and the core
 * lets the survivor in.
 *
 * Rows written before this field existed carry no `identityKey` and simply do not appear here, so an
 * existing zone loses nothing and gains the protection from its next new observation onward.
 *
 * @param {string} [zone]
 * @returns {Map<string,{sourceItemId:string, withdrawn:boolean}>}
 */
export function identityIndex(zone) {
  const file = workspaceLedgerPath(zone);
  const owner = new Map(); // identityKey -> the first sourceItemId that claimed it
  const state = new Map(); // sourceItemId -> withdrawn, from its LATEST row
  let text;
  try {
    text = fs.readFileSync(file, 'utf8');
  } catch {
    return new Map();
  }
  for (const line of text.split(/\r?\n/)) {
    const trimmed = line.trim();
    if (!trimmed) continue;
    let row;
    try {
      row = JSON.parse(trimmed);
    } catch {
      continue; // a damaged line must not stop an ingest; it is an append-only log, not truth
    }
    if (!row || !row.sourceItemId) continue;
    state.set(row.sourceItemId, row.withdrawn === true);
    if (row.identityKey && !owner.has(row.identityKey)) owner.set(row.identityKey, row.sourceItemId);
  }
  const index = new Map();
  for (const [key, sourceItemId] of owner) {
    index.set(key, { sourceItemId, withdrawn: state.get(sourceItemId) === true });
  }
  return index;
}

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
  appendJsonLine(file, entry);
  return { appended: true, path: file };
}
