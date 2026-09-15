/**
 * RichOS local service — the dictation journal on disk, and its RETENTION POSTURE.
 *
 * open-wispr transcribes, pastes into whatever field has focus, and forgets: the text lives only in
 * memory for the menu-bar "copy last transcription" item, and `maxRecordings` defaults to 0 so the
 * audio goes to a temp file that is deleted the moment transcription returns. With nothing stored
 * there is nothing to compare a correction against, which is why the correction flywheel does not
 * turn today. This module is the "heard" side made durable — and bounded.
 *
 * ============================================================================================
 * RETENTION POSTURE — stated deliberately, because persisting dictation is not a free choice
 * ============================================================================================
 *
 * Persisting what the CEO dictates creates a store of everything he has ever said to his machine.
 * That is a strictly more sensitive artifact than a call transcript, because it includes the
 * messages he chose NOT to send. So the posture is written down here, next to the code that
 * enforces it, and it reuses the SHAPE AND THE NUMBERS the techy-mode journal already committed to
 * (`docs/plans/richos-techy-mode-2026-08-26.md` §2.4) rather than inventing a third thing to reason
 * about:
 *
 *   TIER A — the text record. A rolling window: 14 days OR 5,000 records, whichever binds first,
 *   evicted oldest-day-file-first (an `unlink`, by construction). 14 days is the techy-mode Tier B
 *   window, unchanged. It is FAR longer than a correction actually needs — the CEO fixes a dictated
 *   name while it is still on screen, in seconds — and the surplus exists only so a correction made
 *   after a weekend still finds its "heard" side.
 *
 *   TIER B — the audio. OFF BY DEFAULT, which is upstream open-wispr's own default and the right
 *   one: THE FLYWHEEL DOES NOT NEED IT. A correction is text against text; audio buys re-decoding
 *   with a better model later, which nothing in this loop asks for. When switched on it is a rolling
 *   window of 14 days OR 2 GB, whichever binds first — the techy-mode Tier B numbers exactly.
 *
 *   AN EVICTED RECORD DEGRADES HONESTLY, NEVER SILENTLY. A text record whose audio has been evicted
 *   still reads; its `audio` pointer resolves to null and the reason is reported. A day file that
 *   has aged out is gone, and `retentionReport()` says how many records went with it.
 *
 * WHY TIER A IS BOUNDED HERE AND UNBOUNDED IN THE TECHY-MODE JOURNAL. There, Tier A is never evicted
 * because retroactivity has to be a guarantee. Here, the record's only job is to be the other half of
 * a correction, and that job expires. A permanent archive of the CEO's speech would be a larger
 * privacy cost than the loop it serves is worth, so the loop gets exactly the window it needs.
 *
 * CLASSIFICATION: `ceo-private`, always, by construction — this is his speech. It lives under
 * open-wispr's own config directory on his machine, never in this repository, and nothing here
 * makes a network call of any kind.
 */

import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import { expand } from './config.js';

/** Tier A: how many days of dictation TEXT are kept. */
export const TEXT_RETENTION_DAYS = Number(process.env.RICHOS_DICTATION_TEXT_DAYS) || 14;

/** Tier A: hard ceiling on records, whichever binds first with the day window. */
export const TEXT_RETENTION_RECORDS = Number(process.env.RICHOS_DICTATION_TEXT_RECORDS) || 5000;

/** Tier B: how many days of dictation AUDIO are kept, when audio retention is switched on at all. */
export const AUDIO_RETENTION_DAYS = Number(process.env.RICHOS_DICTATION_AUDIO_DAYS) || 14;

/** Tier B: byte ceiling on retained audio, whichever binds first with the day window. */
export const AUDIO_RETENTION_BYTES = Number(process.env.RICHOS_DICTATION_AUDIO_BYTES) || 2 * 1024 * 1024 * 1024;

const DAY_MS = 24 * 60 * 60 * 1000;

/**
 * The journal root. open-wispr's own config directory, because open-wispr is the thing that writes
 * it — a separate application with its own settings file, its own launcher and its own permission
 * grants (`wiki/getting-text-into-richos.md`). This service only READS it.
 */
export function journalRoot() {
  if (process.env.RICHOS_DICTATION_JOURNAL) return expand(process.env.RICHOS_DICTATION_JOURNAL);
  return path.join(os.homedir(), '.config', 'open-wispr', 'dictation-journal');
}

/** Where the ask ledger lives: declines, permanent suppressions, and reconciled entry ids. */
export function ledgerPath(root = journalRoot()) {
  return path.join(root, '_asks.json');
}

/** The Tier B audio directory, when audio retention is on. */
export function audioRoot(root = journalRoot()) {
  return path.join(root, 'audio');
}

/** `YYYY-MM-DD` for a timestamp, in UTC — the day-file key, and therefore the eviction unit. */
export function dayKey(ms) {
  return new Date(ms).toISOString().slice(0, 10);
}

/**
 * Parse one JSONL day file into records, dropping malformed lines rather than throwing. A corrupt
 * line must never make a correction impossible; it is one lost dictation, not a broken loop.
 * @returns {object[]}
 */
export function parseJournalFile(text) {
  const out = [];
  for (const line of String(text || '').split('\n')) {
    const t = line.trim();
    if (!t) continue;
    try {
      const r = JSON.parse(t);
      if (r && typeof r.id === 'string' && typeof r.text === 'string' && Number.isFinite(Number(r.at))) {
        out.push({ ...r, at: Number(r.at) });
      }
    } catch { /* one bad line, not a broken journal */ }
  }
  return out;
}

/** All day files present, oldest first. */
export function dayFiles(root = journalRoot()) {
  try {
    return fs.readdirSync(root)
      .filter((f) => /^\d{4}-\d{2}-\d{2}\.jsonl$/.test(f))
      .sort()
      .map((f) => ({ day: f.slice(0, 10), file: path.join(root, f) }));
  } catch {
    return [];
  }
}

/**
 * Load the journal, newest last, optionally bounded to a recent window (which is all the ask path
 * ever needs — `matchHeard` will not claim an entry older than its window anyway).
 * A missing journal is NOT an error: it yields an empty list, exactly as a missing entities file
 * yields an empty vocabulary. The flywheel degrades to "nothing to learn from", never to a crash.
 * @param {{root?:string, sinceMs?:number}} [opts]
 * @returns {object[]}
 */
export function loadJournal(opts = {}) {
  const root = opts.root || journalRoot();
  const since = opts.sinceMs ?? null;
  const records = [];
  for (const { file } of dayFiles(root)) {
    let text;
    try { text = fs.readFileSync(file, 'utf8'); } catch { continue; }
    for (const r of parseJournalFile(text)) {
      if (since != null && r.at < since) continue;
      records.push(r);
    }
  }
  records.sort((a, b) => a.at - b.at);
  return records;
}

/** Read the ask ledger. Missing => the empty ledger (nothing declined, nothing suppressed). */
export function loadLedger(root = journalRoot()) {
  try {
    const raw = JSON.parse(fs.readFileSync(ledgerPath(root), 'utf8'));
    return {
      suppressed: Array.isArray(raw?.suppressed) ? raw.suppressed.filter((s) => typeof s === 'string') : [],
      declined: raw?.declined && typeof raw.declined === 'object' ? { ...raw.declined } : {},
      reconciled: Array.isArray(raw?.reconciled) ? raw.reconciled.filter((s) => typeof s === 'string') : [],
    };
  } catch {
    return { suppressed: [], declined: {}, reconciled: [] };
  }
}

/** Write the ask ledger. The suppression list is stored SORTED so it stays readable by a human. */
export function saveLedger(ledger, root = journalRoot()) {
  fs.mkdirSync(root, { recursive: true });
  const doc = {
    note: 'RichOS dictation correction flywheel — the CEO\'s answers to "Add X to your vocabulary?". '
      + 'suppressed = never ask again; declined = declined N times, still asked on the next repeat.',
    suppressed: [...new Set(ledger.suppressed || [])].sort(),
    declined: ledger.declined || {},
    reconciled: [...new Set(ledger.reconciled || [])].slice(-2000),
  };
  fs.writeFileSync(ledgerPath(root), `${JSON.stringify(doc, null, 2)}\n`);
  return doc;
}

/**
 * Mark journal entries whose asks have been answered, so one dictation yields one ask round and a
 * re-run of the review does not re-prompt for the same sentence. Kept in the LEDGER rather than
 * rewritten into the journal, so the journal stays strictly append-only (open-wispr appends; this
 * service never rewrites what open-wispr wrote).
 */
export function markReconciled(ledger, id) {
  const reconciled = [...new Set([...(ledger.reconciled || []), id])];
  return { ...ledger, reconciled };
}

/** Apply the ledger's reconciled set to journal records, as the `consumed` flag `matchHeard` reads. */
export function withConsumed(records, ledger) {
  const done = new Set(ledger?.reconciled || []);
  return records.map((r) => (done.has(r.id) ? { ...r, consumed: true } : r));
}

// ---------------------------------------------------------------------------------------------------
// Retention — the policy above, executed
// ---------------------------------------------------------------------------------------------------

/**
 * Decide what the retention policy evicts, WITHOUT touching disk. Pure, so the policy is testable
 * with literal inputs and so `retentionReport()` can show the CEO what a sweep WOULD do before it
 * does it.
 *
 * Day files, not records, are the eviction unit for Tier A — the record cap is honoured by dropping
 * whole oldest day files until the count fits, which is the same `unlink`-only discipline the
 * techy-mode policy chose and it is what keeps eviction from being a rewrite of the CEO's speech.
 *
 * @param {{day:string, records:number, bytes:number}[]} days oldest first
 * @param {{audio:{id:string, at:number, bytes:number}[]}} [tierB]
 * @param {{now?:number, textDays?:number, textRecords?:number, audioDays?:number, audioBytes?:number}} [opts]
 */
export function planRetention(days, tierB = { audio: [] }, opts = {}) {
  const now = opts.now ?? Date.now();
  const textDays = opts.textDays ?? TEXT_RETENTION_DAYS;
  const textRecords = opts.textRecords ?? TEXT_RETENTION_RECORDS;
  const audioDays = opts.audioDays ?? AUDIO_RETENTION_DAYS;
  const audioBytes = opts.audioBytes ?? AUDIO_RETENTION_BYTES;

  const cutoff = now - textDays * DAY_MS;
  const evictDays = [];
  const keepDays = [];
  for (const d of days) {
    // A day file is aged out when the END of that UTC day is older than the window.
    const dayEnd = Date.parse(`${d.day}T23:59:59.999Z`);
    if (Number.isFinite(dayEnd) && dayEnd < cutoff) evictDays.push({ ...d, why: `older than ${textDays} days` });
    else keepDays.push(d);
  }
  let kept = keepDays.reduce((a, d) => a + d.records, 0);
  while (kept > textRecords && keepDays.length) {
    const d = keepDays.shift();
    evictDays.push({ ...d, why: `over the ${textRecords}-record ceiling` });
    kept -= d.records;
  }

  const audioCutoff = now - audioDays * DAY_MS;
  const audio = [...(tierB.audio || [])].sort((a, b) => a.at - b.at);
  const evictAudio = [];
  const keepAudio = [];
  for (const a of audio) {
    if (a.at < audioCutoff) evictAudio.push({ ...a, why: `older than ${audioDays} days` });
    else keepAudio.push(a);
  }
  let bytes = keepAudio.reduce((s, a) => s + a.bytes, 0);
  while (bytes > audioBytes && keepAudio.length) {
    const a = keepAudio.shift();
    evictAudio.push({ ...a, why: `over the ${audioBytes}-byte ceiling` });
    bytes -= a.bytes;
  }

  return {
    evictDays,
    keepDays,
    evictAudio,
    keepAudio,
    keptRecords: kept,
    keptAudioBytes: bytes,
    evictedRecords: evictDays.reduce((a, d) => a + d.records, 0),
    evictedAudioBytes: evictAudio.reduce((a, x) => a + x.bytes, 0),
  };
}

/** Measure the journal on disk into the shape `planRetention` consumes. */
export function surveyJournal(root = journalRoot()) {
  const days = [];
  for (const { day, file } of dayFiles(root)) {
    let bytes = 0;
    let records = 0;
    try {
      bytes = fs.statSync(file).size;
      records = parseJournalFile(fs.readFileSync(file, 'utf8')).length;
    } catch { /* unreadable day file counts as empty rather than fatal */ }
    days.push({ day, file, records, bytes });
  }
  const audio = [];
  const aRoot = audioRoot(root);
  try {
    for (const f of fs.readdirSync(aRoot)) {
      const p = path.join(aRoot, f);
      try {
        const st = fs.statSync(p);
        if (st.isFile()) audio.push({ id: f, at: st.mtimeMs, bytes: st.size, file: p });
      } catch { /* raced away */ }
    }
  } catch { /* no audio dir — Tier B is off, which is the default */ }
  return { root, days, audio };
}

/**
 * Run the retention sweep. `dryRun` (the default) reports without deleting, because the first thing
 * anyone should be able to do with a policy that erases the CEO's speech is READ IT.
 */
export function sweepRetention(opts = {}) {
  const root = opts.root || journalRoot();
  const survey = surveyJournal(root);
  const plan = planRetention(survey.days, { audio: survey.audio }, opts);
  if (opts.dryRun !== false) return { root, dryRun: true, ...plan };
  for (const d of plan.evictDays) { try { fs.unlinkSync(d.file); } catch { /* already gone */ } }
  for (const a of plan.evictAudio) { try { fs.unlinkSync(a.file); } catch { /* already gone */ } }
  return { root, dryRun: false, ...plan };
}

/**
 * What one hour of dictation costs on disk, from real measured records rather than an estimate.
 * `bytesPerHour` is the number the retention posture has to justify, so it is computed, not guessed.
 * @param {object[]} records
 * @returns {{records:number, spokenMs:number, textBytes:number, audioBytes:number,
 *            textBytesPerHour:number, audioBytesPerHour:number}}
 */
export function costPerHour(records) {
  const rows = Array.isArray(records) ? records : [];
  let spokenMs = 0;
  let textBytes = 0;
  let audioBytes = 0;
  for (const r of rows) {
    spokenMs += Number(r.ms || 0);
    textBytes += Buffer.byteLength(`${JSON.stringify(r)}\n`, 'utf8');
    audioBytes += Number(r.audioBytes || 0);
  }
  const hours = spokenMs / 3_600_000;
  return {
    records: rows.length,
    spokenMs,
    textBytes,
    audioBytes,
    textBytesPerHour: hours > 0 ? Math.round(textBytes / hours) : 0,
    audioBytesPerHour: hours > 0 ? Math.round(audioBytes / hours) : 0,
  };
}
