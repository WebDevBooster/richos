/**
 * RichOS local service — the ingest ledger (collector-path parity discipline).
 *
 * One append-only JSONL line per transcribed session in the drop zone: what was captured ==
 * what was transcribed == what landed. Idempotent by sessionId + modelRun index: re-running the
 * pipeline (or a retranscribe) never double-ingests; it appends a NEW run row for the same session,
 * so the ledger is the durable record of every transcription and re-transcription.
 */

import fs from 'node:fs';
import { ingestLedgerPath } from './config.js';

/**
 * @param {string} sessionId
 * @param {number} runIndex the index into pipeline.modelRuns this line records
 * @param {string} [zone]
 * @returns {boolean} true if a line for this (sessionId, runIndex) already exists
 */
export function alreadyLedgered(sessionId, runIndex, zone) {
  const file = ingestLedgerPath(zone);
  if (!fs.existsSync(file)) return false;
  const lines = fs.readFileSync(file, 'utf8').split(/\r?\n/).filter(Boolean);
  return lines.some((l) => {
    try {
      const row = JSON.parse(l);
      return row.sessionId === sessionId && row.runIndex === runIndex;
    } catch {
      return false;
    }
  });
}

/**
 * Append one ingest line, unless an identical (sessionId, runIndex) line already exists.
 * @param {Record<string, any>} entry
 * @param {string} [zone]
 * @returns {{appended: boolean, path: string}}
 */
export function appendLedger(entry, zone) {
  const file = ingestLedgerPath(zone);
  if (alreadyLedgered(entry.sessionId, entry.runIndex, zone)) return { appended: false, path: file };
  fs.appendFileSync(file, `${JSON.stringify(entry)}\n`);
  return { appended: true, path: file };
}
