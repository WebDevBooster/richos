/**
 * THE WIRING PROOF AND THE COST MEASUREMENT: the real pipeline, end to end, over the real
 * 92-minute two-channel recording, with no test double anywhere.
 *
 * Builds a session directory to the capture contract whose single audio part is the STEREO join of
 * both channels — the shape the extension actually writes — and runs runPipeline(): ffmpeg
 * normalize + channelsplit, whisper decode, repetition guard, deletion detector (3.7), WORD-DENSITY
 * INSTRUMENT (3.8), merge, verify, emit. Then reads what the product itself wrote.
 *
 * The cost share is taken from the product's OWN record (pipeline.substitutionGuard.elapsedMs and
 * pipeline.deletionGuard.elapsedMs) against the same run's wall clock — never from a stopwatch
 * around a harness.
 *
 * usage: node pipeline-e2e.mjs <tag>
 */
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { execFileSync } from 'node:child_process';
import { runPipeline, readRecord } from '/Users/alex/ab/richos-wt/norm-substitution-2026-08-30/tools/richos-service/lib/pipeline.js';

const SP = '/private/tmp/claude-501/-Users-alex-ab-femcboost/8a598936-e161-4b29-a91c-5a02800052aa/scratchpad/sub';
const tag = process.argv[2] || 'e2e';
const zone = fs.mkdtempSync(path.join(os.tmpdir(), 'richos-sub-e2e-'));
const sessionId = `2026-08-30T09-00-00Z--local--${tag}`;
const dir = path.join(zone, sessionId);
fs.mkdirSync(dir, { recursive: true });
const part = path.join(dir, 'audio-part-0.wav');
execFileSync('ffmpeg', [
  '-y', '-v', 'error', '-i', `${SP}/audio/me.wav`, '-i', `${SP}/audio/others.wav`,
  '-filter_complex', '[0:a][1:a]join=inputs=2:channel_layout=stereo[a]', '-map', '[a]',
  '-c:a', 'pcm_s16le', '-ar', '16000', part,
]);
fs.writeFileSync(path.join(dir, 'session.json'), `${JSON.stringify({
  schemaVersion: 1, sessionId, dir: sessionId, status: 'closed',
  startedAt: 1_756_537_200_000, endedAt: 1_756_542_737_000,
  capture: { source: 'local-file', channels: { left: 'microphone (me)', right: 'tab (everyone else)' } },
  audio: { parts: ['audio-part-0.wav'], bytesTotal: fs.statSync(part).size },
}, null, 2)}\n`);

const t0 = Date.now();
const res = runPipeline(dir, { zone });
const wallMs = Date.now() - t0;
const rec = readRecord(dir);
const ver = JSON.parse(fs.readFileSync(path.join(dir, 'verification.json'), 'utf8'));
const d = rec.pipeline.deletionGuard;
const s = rec.pipeline.substitutionGuard;
const summary = {
  tag, status: res.status, wallSeconds: +(wallMs / 1000).toFixed(1),
  deletionGuard: { elapsedMs: d.elapsedMs, shareOfRun: +((d.elapsedMs / wallMs) * 100).toFixed(1), candidates: d.candidates, probed: d.probed, deletedSpans: d.deletedSpans, deletedSeconds: d.deletedSeconds },
  substitutionGuard: {
    elapsedMs: s.elapsedMs, shareOfRun: +((s.elapsedMs / wallMs) * 100).toFixed(1),
    windows: s.windows, candidates: s.candidates, probed: s.probed,
    sparseSpans: s.sparseSpans, sparseSeconds: s.sparseSeconds,
    channelsBelowFloor: s.channelsBelowFloor, coverageUnit: s.coverageUnit,
    byChannel: s.byChannel,
  },
  warnings: ver.warnings.length,
  probeClipsLeftBehind: fs.existsSync(path.join(dir, '_deletion-probe')),
  sessionDir: dir,
};
fs.writeFileSync(`${SP}/results/e2e_${tag}.json`, JSON.stringify(summary, null, 1));
console.log(JSON.stringify(summary, null, 1));
console.log('--- warnings, recovered text withheld ---');
for (const w of ver.warnings) console.log('  - ' + w.replace(/"[^"]*"/g, '"<withheld>"'));
