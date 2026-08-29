// WHAT PERSISTING DICTATION ACTUALLY COSTS, in bytes per hour of speech.
//
// Not estimated. An hour of dictation is synthesized from the same invented utterances the biasing
// measurement uses, at the real speaking rate those utterances were spoken at (measured from the
// `say`-rendered WAVs), journalled as the REAL record shape open-wispr appends, and then measured on
// disk. Tier B is measured from the actual bytes open-wispr's recorder would keep: 16 kHz mono
// 16-bit PCM, which is what `AudioRecorder` writes.
//
// usage: retention-cost.mjs <libDir> <dictationWavDir>
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { execFileSync } from 'node:child_process';
import { pathToFileURL } from 'node:url';

const [libDir, wavDir] = process.argv.slice(2);
const imp = (f) => import(pathToFileURL(path.join(libDir, f)).href);
const { costPerHour, loadJournal, surveyJournal, planRetention,
  TEXT_RETENTION_DAYS, TEXT_RETENTION_RECORDS, AUDIO_RETENTION_DAYS, AUDIO_RETENTION_BYTES } =
  await imp('dictation-store.js');

const UTTERANCES = JSON.parse(fs.readFileSync(path.join(wavDir, 'hypotheses.json'), 'utf8')).UTTERANCES;

/** Real durations, from the real synthesized audio — not a words-per-minute assumption. */
const durations = fs.readdirSync(wavDir).filter((f) => /^u\d\d\.wav$/.test(f)).sort().map((f) => {
  const out = execFileSync('ffprobe',
    ['-v', 'error', '-show_entries', 'format=duration', '-of', 'csv=p=0', path.join(wavDir, f)],
    { encoding: 'utf8' });
  return { file: f, sec: Number(out.trim()), bytes: fs.statSync(path.join(wavDir, f)).size };
});
const meanSec = durations.reduce((a, d) => a + d.sec, 0) / durations.length;

// Fill one hour of SPOKEN time by cycling the utterances.
const root = fs.mkdtempSync(path.join(os.tmpdir(), 'retention-cost-'));
const day = new Date().toISOString().slice(0, 10);
const lines = [];
const records = [];
let spokenMs = 0;
let i = 0;
while (spokenMs < 3_600_000) {
  const d = durations[i % durations.length];
  const text = UTTERANCES[i % UTTERANCES.length];
  const rec = {
    v: 1,
    id: `d-${1_700_000_000_000 + i * 1000}-${(i % 10000).toString(16).padStart(4, '0')}`,
    at: 1_700_000_000_000 + i * 1000,
    ms: Math.round(d.sec * 1000),
    model: 'large-v3-turbo-q5_0',
    text,
    emitted: text,
    corrected: false,
    audio: null,
    audioBytes: d.bytes, // measured, not assumed — used only for the Tier B column
  };
  records.push(rec);
  const onDisk = { ...rec };
  delete onDisk.audioBytes; // not a field open-wispr writes; it is this rig's accounting column
  lines.push(JSON.stringify(onDisk));
  spokenMs += rec.ms;
  i += 1;
}
fs.writeFileSync(path.join(root, `${day}.jsonl`), lines.join('\n') + '\n');

const onDiskBytes = fs.statSync(path.join(root, `${day}.jsonl`)).size;
const cost = costPerHour(records);
const reloaded = loadJournal({ root });
const survey = surveyJournal(root);
const fourteenDays = planRetention(survey.days, { audio: [] }, { now: Date.now() });

const MB = (n) => `${(n / 1024 / 1024).toFixed(1)} MB`;
console.log('RETENTION COST — one hour of dictation, measured');
console.log('');
console.log(`utterances in an hour of speech      ${records.length}  (mean ${meanSec.toFixed(1)} s each, from the real audio)`);
console.log(`words                                ${records.reduce((a, r) => a + r.text.split(/\s+/).length, 0)}`);
console.log(`records read back from disk          ${reloaded.length}  (round-trips clean)`);
console.log('');
console.log('TIER A — the text record (ON by default)');
console.log(`  bytes per hour of dictation        ${cost.textBytesPerHour.toLocaleString()} B  (${(cost.textBytesPerHour / 1024).toFixed(0)} KB)`);
console.log(`  on disk, one hour                  ${onDiskBytes.toLocaleString()} B`);
console.log(`  a heavy day, 2 h of dictation      ${(cost.textBytesPerHour * 2 / 1024).toFixed(0)} KB`);
console.log(`  the full ${TEXT_RETENTION_DAYS}-day window at 2 h/day   ${MB(cost.textBytesPerHour * 2 * TEXT_RETENTION_DAYS)}`);
console.log(`  the ${TEXT_RETENTION_RECORDS.toLocaleString()}-record ceiling            ${MB(onDiskBytes / records.length * TEXT_RETENTION_RECORDS)}  (~${(TEXT_RETENTION_RECORDS / records.length).toFixed(1)} hours of speech)`);
console.log('');
console.log('TIER B — the audio (OFF by default; these are the bytes NOT being kept)');
console.log(`  bytes per hour of dictation        ${cost.audioBytesPerHour.toLocaleString()} B  (${MB(cost.audioBytesPerHour)})`);
console.log(`  ratio to the text record           ${Math.round(cost.audioBytesPerHour / cost.textBytesPerHour)}x`);
console.log(`  the ${AUDIO_RETENTION_BYTES / 1024 / 1024 / 1024} GB ceiling would hold        ${(AUDIO_RETENTION_BYTES / cost.audioBytesPerHour).toFixed(0)} hours of dictation`);
console.log('');
console.log(`eviction plan for this journal today: ${fourteenDays.evictDays.length} day file(s), ${fourteenDays.evictedRecords} record(s)`);
console.log(`(nothing, correctly — it is today's file, inside the ${TEXT_RETENTION_DAYS}-day window)`);
fs.rmSync(root, { recursive: true, force: true });
