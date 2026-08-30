/**
 * Score the PRODUCT'S OWN word-density instrument on real audio — imported, never reimplemented.
 *
 * Reproduces the pipeline's composition exactly: whisper JSON -> the product's parseWhisperJson ->
 * the product's repetition guard (stage 3.5, so the segments judged are the ones that SHIP) ->
 * guardSubstitution() with a probe built from the product's own cutSpan / measureSpanVolume /
 * transcribeClips.
 *
 * usage: node score.mjs <run-tag> <channel> [--noguard] [--model=<id>]
 * env: FLOOR, BASELINE_FRACTION, WINDOW_SEC, MAX_WINDOW, RECOVERY, MIN_EXTRA, MIN_DEFICIT, TAG
 */
import fs from 'node:fs';
import path from 'node:path';
import { guardSubstitution, DEFAULT_SPARSITY_OPTS } from '/Users/alex/ab/richos-wt/norm-substitution-2026-08-30/tools/richos-service/lib/substitution-guard.js';
import { guardTranscription } from '/Users/alex/ab/richos-wt/norm-substitution-2026-08-30/tools/richos-service/lib/repetition-guard.js';
import { cutSpan, measureSpanVolume, measureVolume } from '/Users/alex/ab/richos-wt/norm-substitution-2026-08-30/tools/richos-service/lib/normalize.js';
import { transcribeClips, parseWhisperJson } from '/Users/alex/ab/richos-wt/norm-substitution-2026-08-30/tools/richos-service/lib/transcribe.js';

const SP = '/private/tmp/claude-501/-Users-alex-ab-femcboost/8a598936-e161-4b29-a91c-5a02800052aa/scratchpad/sub';
const [run, ch] = process.argv.slice(2);
const noGuard = process.argv.includes('--noguard');
const modelArg = (process.argv.find((a) => a.startsWith('--model=')) || '').split('=')[1];
const model = modelArg || (run.startsWith('q5') ? 'large-v3-turbo-q5_0' : 'large-v3-turbo');
const num = (name, dflt) => (process.env[name] != null && process.env[name] !== '' ? Number(process.env[name]) : dflt);
const opts = {
  floorWordsPerSec: num('FLOOR', DEFAULT_SPARSITY_OPTS.floorWordsPerSec),
  baselineFraction: num('BASELINE_FRACTION', DEFAULT_SPARSITY_OPTS.baselineFraction),
  windowSpeechSec: num('WINDOW_SEC', DEFAULT_SPARSITY_OPTS.windowSpeechSec),
  maxWindowSec: num('MAX_WINDOW', DEFAULT_SPARSITY_OPTS.maxWindowSec),
  recoveryRatio: num('RECOVERY', DEFAULT_SPARSITY_OPTS.recoveryRatio),
  minRecoveredExtra: num('MIN_EXTRA', DEFAULT_SPARSITY_OPTS.minRecoveredExtra),
  minDeficitWords: num('MIN_DEFICIT', DEFAULT_SPARSITY_OPTS.minDeficitWords),
  maxProbes: num('MAX_PROBES', DEFAULT_SPARSITY_OPTS.maxProbes),
};
const tag = process.env.TAG || `${run}_${ch}${noGuard ? '_raw' : ''}`;

const raw = JSON.parse(fs.readFileSync(`${SP}/results/${run}/${ch}.json`, 'utf8'));
const parsed = parseWhisperJson(raw, ch);
const grid = JSON.parse(fs.readFileSync(`${SP}/results/bursts_${ch}.json`, 'utf8'));
const wav = `${SP}/audio/${ch}.wav`;
const peak = measureVolume(wav).maxDb;

// Stage 3.5, exactly as the pipeline runs it: the instrument judges the SHIPPING timeline.
let segments = parsed;
let guardReport = null;
if (!noGuard) {
  const guarded = guardTranscription(
    { me: ch === 'me' ? parsed : [], others: ch === 'others' ? parsed : [] },
    { speechBursts: { me: ch === 'me' ? grid.speech : [], others: ch === 'others' ? grid.speech : [] } },
  );
  segments = ch === 'me' ? guarded.me : guarded.others;
  guardReport = { removed: guarded.report.removed, classes: guarded.report.classes };
}

const probeDir = `${SP}/clips/${tag}`;
fs.rmSync(probeDir, { recursive: true, force: true });
fs.mkdirSync(probeDir, { recursive: true });
let cutMs = 0;
let decodeMs = 0;
let clips = 0;
// Probe results are CACHED to disk keyed by span, so the adjudication rule can be swept over the
// same real decodes without re-running whisper for every sweep step.
const cachePath = `${SP}/results/probecache_${run}_${ch}${noGuard ? '_raw' : ''}.json`;
const cache = fs.existsSync(cachePath) ? JSON.parse(fs.readFileSync(cachePath, 'utf8')) : {};
const probe = (spans, channel) => {
  const key = (s) => `${s.startMs}-${s.endMs}`;
  if (spans.every((s) => cache[key(s)])) return spans.map((s) => cache[key(s)]);
  const t0 = Date.now();
  const tight = [];
  const wide = [];
  const levels = [];
  spans.forEach((s, i) => {
    tight.push(cutSpan(wav, s, path.join(probeDir, `${channel}-${i}-t.wav`), { padSec: DEFAULT_SPARSITY_OPTS.probePadSec }));
    wide.push(cutSpan(wav, s, path.join(probeDir, `${channel}-${i}-w.wav`), { padSec: DEFAULT_SPARSITY_OPTS.probeWidePadSec }));
    levels.push(measureSpanVolume(wav, s));
  });
  cutMs += Date.now() - t0;
  const t1 = Date.now();
  const texts = transcribeClips([...tight, ...wide], { model });
  decodeMs += Date.now() - t1;
  clips += tight.length + wide.length;
  const finite = (x) => (Number.isFinite(x) ? x : null);
  const res = spans.map((s, i) => ({
    tight: texts[i] || '', wide: texts[spans.length + i] || '',
    maxDb: finite(levels[i].maxDb), meanDb: finite(levels[i].meanDb),
  }));
  spans.forEach((s, i) => { cache[key(s)] = res[i]; });
  fs.writeFileSync(cachePath, JSON.stringify(cache, null, 1));
  return res;
};

const t0 = Date.now();
const { report } = guardSubstitution(
  { me: ch === 'me' ? segments : [], others: ch === 'others' ? segments : [] },
  {
    speechBursts: { me: ch === 'me' ? grid.speech : [], others: ch === 'others' ? grid.speech : [] },
    peaks: { me: peak, others: peak },
    probe,
    ...opts,
  },
);
const totalMs = Date.now() - t0;
const out = {
  tag, run, channel: ch, model, guarded: !noGuard, guardReport, opts,
  peakDb: peak, segments: segments.length,
  bursts: grid.bursts, burstSeconds: grid.speechSeconds,
  windows: report.windows, candidates: report.candidates, probed: report.probed, clips,
  sparseSpans: report.sparseSpans, sparseSeconds: report.sparseSeconds,
  rejectedSpans: report.rejected.length, unprobedSpans: report.unprobedSpans,
  channelsBelowFloor: report.channelsBelowFloor,
  byChannel: report.byChannel[ch],
  cutMs, decodeMs, totalMs,
  report,
};
fs.writeFileSync(`${SP}/results/score_${tag}.json`, JSON.stringify(out, null, 1));
const { report: _r, ...head } = out;
console.log(JSON.stringify(head, null, 1));
console.log('--- findings ---');
for (const f of report.findings) {
  console.log(`  ${(f.startMs / 1000).toFixed(1)}..${(f.endMs / 1000).toFixed(1)} speech=${f.speechSec}s words=${f.emittedWords} d=${f.density} probe=${f.probeWords} max=${f.maxDb}`);
}
console.log('--- rejected ---');
for (const r of report.rejected) {
  console.log(`  ${(r.startMs / 1000).toFixed(1)} speech=${r.speechSec}s words=${r.emittedWords} d=${r.density} probe=${r.probeWords} [${r.verdict}] ${r.reason.slice(0, 70)}`);
}
