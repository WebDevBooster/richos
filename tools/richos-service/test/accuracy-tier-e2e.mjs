#!/usr/bin/env node
/**
 * RichOS local service — P5 accuracy-tier REAL end-to-end (ffmpeg + whisper.cpp on this machine).
 *
 *   node test/accuracy-tier-e2e.mjs
 *
 * Proves, on real audio through the real pipeline:
 *   1. the QUANTIZED tier runs end-to-end (a quantized .bin transcribes a call to transcript.md);
 *   2. the DEFAULT turbo tier stays clean (no repetition loops on a normal sample);
 *   3. the opt-in MAX tier (guarded large-v3) runs end-to-end IF the large-v3 model is installed —
 *      self-skips otherwise (the 2.9 GB model is not a standard install), with the guard's real
 *      before/after on the benchmark hallucination sample proven separately (see the P5 report).
 *
 * Model resolution honors RICHOS_MODEL_DIR / RICHOS_WHISPER_MODEL, so a tier whose model is absent is
 * reported as SKIP, never a hard failure.
 */

import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { execFileSync } from 'node:child_process';
import { runPipeline, readRecord } from '../lib/pipeline.js';
import { ffmpegBin, whisperBin, resolveModel, resolveTier } from '../lib/config.js';

const T0 = 1_700_000_000_000;
let failures = 0;
let skips = 0;
function check(name, ok, detail = '') {
  console.log(`${ok ? '  ok  ' : 'FAIL  '}${name}${detail ? ` — ${detail}` : ''}`);
  if (!ok) failures += 1;
}
function skip(name, why) {
  console.log(`  ~~  SKIP ${name} — ${why}`);
  skips += 1;
}
function have(bin, args) {
  try {
    execFileSync(bin, args, { stdio: 'ignore' });
    return true;
  } catch {
    return false;
  }
}
function tierModelPresent(tierName) {
  try {
    resolveModel(resolveTier(tierName).model);
    return true;
  } catch {
    return false;
  }
}

const ffmpeg = (() => { try { return ffmpegBin(); } catch { return null; } })();
const whisper = (() => { try { return whisperBin(); } catch { return null; } })();
if (!ffmpeg || !whisper) {
  console.error('accuracy-tier-e2e requires ffmpeg + whisper-cli; one is missing. Aborting.');
  process.exit(1);
}
const canSay = have('say', ['-v', '?']);

const zone = fs.mkdtempSync(path.join(os.tmpdir(), 'richos-tier-'));
const work = fs.mkdtempSync(path.join(os.tmpdir(), 'richos-tier-work-'));

/** Build a real 2-channel session dir (L=me, R=others) with a caption for the far side. */
function buildSession(id) {
  const dir = path.join(zone, id);
  fs.mkdirSync(dir, { recursive: true });
  const ME = 'Hi Marcus, thanks for joining. Let me pull up your account now.';
  const OTHERS = 'Marcus here, happy to be on. Let us get started with the quarterly review.';
  if (canSay) {
    const a = path.join(work, `${id}-a.aiff`);
    const b = path.join(work, `${id}-b.aiff`);
    execFileSync('say', ['-v', 'Samantha', '-o', a, ME]);
    execFileSync('say', ['-v', 'Fred', '-o', b, OTHERS]);
    execFileSync(ffmpeg, [
      '-y', '-i', a, '-i', b, '-filter_complex',
      '[0:a]aformat=channel_layouts=mono,apad=whole_dur=12[me];' +
        '[1:a]aformat=channel_layouts=mono,adelay=5000,apad=whole_dur=12[others];' +
        '[me][others]join=inputs=2:channel_layout=stereo[a]',
      '-map', '[a]', '-c:a', 'libopus', '-b:a', '64k', '-ac', '2', path.join(dir, 'audio-part-00.webm'),
    ]);
  } else {
    execFileSync(ffmpeg, [
      '-y', '-f', 'lavfi', '-i', 'sine=frequency=300:duration=12', '-f', 'lavfi', '-i', 'sine=frequency=600:duration=12',
      '-filter_complex', '[0:a][1:a]join=inputs=2:channel_layout=stereo[a]',
      '-map', '[a]', '-c:a', 'libopus', '-b:a', '64k', '-ac', '2', path.join(dir, 'audio-part-00.webm'),
    ]);
  }
  const bytes = fs.statSync(path.join(dir, 'audio-part-00.webm')).size;
  fs.writeFileSync(path.join(dir, 'session.json'), JSON.stringify({
    schemaVersion: 1, sessionId: id, dir: id, status: 'closed', startedAt: T0, endedAt: T0 + 12000,
    platform: { id: 'meet', label: 'Google Meet', slug: 'tier' },
    capture: { container: 'audio/webm;codecs=opus', channels: { left: 'microphone (me)', right: 'tab (everyone else)' } },
    audio: { parts: [{ part: 0, bytes }], bytesTotal: bytes, chunkCount: 1 },
    health: { redSeconds: 0, worstLevel: 'green' }, captions: { available: true, count: 1 },
  }, null, 2));
  fs.writeFileSync(path.join(dir, 'captions.ndjson'),
    `${JSON.stringify({ speaker: 'Marcus Whitfield', text: OTHERS, firstT: T0 + 5000, t: T0 + 11000, revision: 3 })}\n`);
  return dir;
}

console.log('=== P5 accuracy-tier e2e (real ffmpeg + whisper) ===\n');

// ---- 1) QUANTIZED tier end-to-end ------------------------------------------------------------
if (tierModelPresent('quantized')) {
  console.log('--- quantized tier (real) ---');
  const dir = buildSession('2026-08-24T12-00-00Z--meet--quantized');
  const r = runPipeline(dir, { zone, tier: 'quantized', now: T0 + 13 * 60 * 1000 });
  check('quantized tier reached READY', r.status === 'ready', JSON.stringify(r.problems || ''));
  check('quantized tier wrote transcript.md', fs.existsSync(path.join(dir, 'transcript.md')));
  const rec = readRecord(dir);
  check('session.json records tier=quantized + the quantized model', rec.pipeline.tier === 'quantized' && /q\d/.test(rec.pipeline.model),
    `tier=${rec.pipeline.tier} model=${rec.pipeline.model}`);
  check('quantized run recorded a repetitionGuard block', !!rec.pipeline.repetitionGuard);
  if (canSay) check('quantized transcript has real words', rec.pipeline.modelRuns[0].words > 4, `words=${rec.pipeline.modelRuns[0].words}`);
} else {
  skip('quantized tier', 'no quantized model installed (build one with `whisper-quantize <turbo.bin> <out> q5_0`)');
}

// ---- 2) DEFAULT turbo tier stays clean -------------------------------------------------------
if (tierModelPresent('turbo')) {
  console.log('\n--- default turbo tier (real) ---');
  const dir = buildSession('2026-08-24T12-10-00Z--meet--turbo');
  const r = runPipeline(dir, { zone, now: T0 + 13 * 60 * 1000 });
  check('default (turbo) tier reached READY', r.status === 'ready', JSON.stringify(r.problems || ''));
  const rec = readRecord(dir);
  check('default tier is turbo', rec.pipeline.tier === 'turbo' && rec.pipeline.model === 'large-v3-turbo');
  check('turbo produced NO repetition loop on a normal sample', rec.pipeline.repetitionGuard.detected === false,
    `removed=${rec.pipeline.repetitionGuard.removedSegments}`);
} else {
  skip('turbo tier', 'turbo model not installed');
}

// ---- 3) MAX (guarded large-v3) tier, if the model is installed -------------------------------
if (tierModelPresent('max')) {
  console.log('\n--- max tier: guarded large-v3 (real) ---');
  const dir = buildSession('2026-08-24T12-20-00Z--meet--max');
  const r = runPipeline(dir, { zone, tier: 'max', now: T0 + 13 * 60 * 1000 });
  check('max tier reached READY', r.status === 'ready', JSON.stringify(r.problems || ''));
  const rec = readRecord(dir);
  check('max tier is full large-v3 with guard decode params recorded', rec.pipeline.tier === 'max' &&
    rec.pipeline.model === 'large-v3' && Array.isArray(rec.pipeline.decodeArgs) && rec.pipeline.decodeArgs.includes('-mc'),
    `decode=${JSON.stringify(rec.pipeline.decodeArgs)}`);
} else {
  skip('max tier (guarded large-v3)', 'large-v3 model not in a standard model dir — guard proven on the benchmark sample separately (see P5 report). Set RICHOS_MODEL_DIR to run it here.');
}

fs.rmSync(work, { recursive: true, force: true });
console.log(`\n${failures === 0 ? 'ALL ACCURACY-TIER E2E CHECKS PASSED' : `${failures} CHECK(S) FAILED`} (${skips} skipped)`);
console.log(`(artifacts at ${zone})`);
process.exit(failures ? 1 : 0);
