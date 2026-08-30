/**
 * STAGE A ONLY — the channel's density profile, free, no probe. What the budget looks like on real
 * material before any adjudication: every window, its detected speech, its emitted words, its rate.
 * usage: node profile.mjs <run> <channel> [--noguard]
 */
import fs from 'node:fs';
import { findSparseWindows, tileWindows, DEFAULT_SPARSITY_OPTS } from '/Users/alex/ab/richos-wt/norm-substitution-2026-08-30/tools/richos-service/lib/substitution-guard.js';
import { guardTranscription } from '/Users/alex/ab/richos-wt/norm-substitution-2026-08-30/tools/richos-service/lib/repetition-guard.js';
import { parseWhisperJson } from '/Users/alex/ab/richos-wt/norm-substitution-2026-08-30/tools/richos-service/lib/transcribe.js';
import { emittedWordTimes } from '/Users/alex/ab/richos-wt/norm-substitution-2026-08-30/tools/richos-service/lib/deletion-guard.js';

const SP = '/private/tmp/claude-501/-Users-alex-ab-femcboost/8a598936-e161-4b29-a91c-5a02800052aa/scratchpad/sub';
const [run, ch] = process.argv.slice(2);
const noGuard = process.argv.includes('--noguard');
const num = (n, d) => (process.env[n] != null && process.env[n] !== '' ? Number(process.env[n]) : d);
const o = {
  ...DEFAULT_SPARSITY_OPTS,
  floorWordsPerSec: num('FLOOR', DEFAULT_SPARSITY_OPTS.floorWordsPerSec),
  windowSpeechSec: num('WINDOW_SEC', DEFAULT_SPARSITY_OPTS.windowSpeechSec),
  maxWindowSec: num('MAX_WINDOW', DEFAULT_SPARSITY_OPTS.maxWindowSec),
  baselineFraction: num('BASELINE_FRACTION', DEFAULT_SPARSITY_OPTS.baselineFraction),
  minDeficitWords: num('MIN_DEFICIT', DEFAULT_SPARSITY_OPTS.minDeficitWords),
};
const raw = JSON.parse(fs.readFileSync(`${SP}/results/${run}/${ch}.json`, 'utf8'));
const parsed = parseWhisperJson(raw, ch);
const grid = JSON.parse(fs.readFileSync(`${SP}/results/bursts_${ch}.json`, 'utf8'));
let segments = parsed;
if (!noGuard) {
  const g = guardTranscription(
    { me: ch === 'me' ? parsed : [], others: ch === 'others' ? parsed : [] },
    { speechBursts: { me: ch === 'me' ? grid.speech : [], others: ch === 'others' ? grid.speech : [] } },
  );
  segments = ch === 'me' ? g.me : g.others;
}
const found = findSparseWindows(segments, grid.speech, { ...o, channel: ch });
const wins = tileWindows(grid.speech, 0, o);
const { times } = emittedWordTimes(segments);
const dens = wins.map((w) => {
  const n = times.filter((t) => t >= w.startMs - 250 && t <= w.endMs + 250).length;
  return { startMs: w.startMs, endMs: w.endMs, speechSec: +(w.speechMs / 1000).toFixed(2), words: n, d: +(n / (w.speechMs / 1000)).toFixed(3) };
});
const sorted = dens.map((x) => x.d).sort((a, b) => a - b);
const q = (p) => sorted[Math.min(sorted.length - 1, Math.floor(p * sorted.length))];
console.log(JSON.stringify({
  run, ch, guarded: !noGuard, segments: segments.length, emittedWords: times.length,
  windows: wins.length, analyzedSpeechSec: found.analyzedSpeechSec, burstSeconds: found.burstSeconds,
  medianDensity: found.medianDensity, thresholdWordsPerSec: found.thresholdWordsPerSec,
  baselineBelowFloor: found.baselineBelowFloor,
  p0: q(0), p01: q(0.01), p05: q(0.05), p10: q(0.10), p25: q(0.25), p50: q(0.5), p75: q(0.75), p95: q(0.95), p100: sorted[sorted.length - 1],
  candidates: found.candidates.length,
}, null, 1));
console.log('--- 15 thinnest windows ---');
for (const w of dens.slice().sort((a, b) => a.d - b.d).slice(0, 15)) {
  console.log(`  ${(w.startMs / 1000).toFixed(1)}..${(w.endMs / 1000).toFixed(1)} speech=${w.speechSec}s words=${w.words} d=${w.d}`);
}
console.log('--- candidates ---');
for (const c of found.candidates) {
  console.log(`  ${(c.startMs / 1000).toFixed(1)}..${(c.endMs / 1000).toFixed(1)} wall=${c.wallSec}s speech=${c.speechSec}s words=${c.emittedWords} d=${c.density} deficit=${c.deficitWords}`);
}
fs.writeFileSync(`${SP}/results/profile_${run}_${ch}${noGuard ? '_raw' : ''}.json`, JSON.stringify({ found: { ...found, candidates: found.candidates }, windows: dens }, null, 1));
