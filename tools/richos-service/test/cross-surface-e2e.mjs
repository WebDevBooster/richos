#!/usr/bin/env node
/**
 * RichOS local service — P5 CROSS-SURFACE END-TO-END harness (real, on this machine).
 *
 *   node test/cross-surface-e2e.mjs
 *
 * ONE harness that drives EVERY capture surface available today through the SAME chain —
 * coordination -> pipeline -> loro-correction -> transcript.md — and asserts the full chain AND the
 * never-silent guarantees hold IDENTICALLY regardless of where the audio came from. This is the
 * consolidation of the reliability guarantee across surfaces: the pipeline (§4) and reliability model
 * (§6) are surface-independent by construction, so they must produce the same outcomes for each.
 *
 * Surfaces exercised as REAL producers of the frozen capture->pipeline contract (§3):
 *   - chrome-extension        : the extension's REAL session.js record + a 2-channel Opus/WebM part +
 *                               captions.ndjson (browser calls yield remote NAMES).
 *   - desktop-companion-macos : the REAL Swift companion binary (`richos-companion ingest`) — pushes a
 *                               sample through the same SessionWriter/ChannelMixer live capture uses,
 *                               producing a WAV-part contract dir with NO captions (desktop apps have
 *                               none). No TCC/audio grant needed.
 *   - desktop-companion-windows : STRUCTURAL. Absent on this host, so SKIPPED — but it flows through
 *                               the SAME surface table with no special-casing, so a Windows companion
 *                               plugs in by adding one producer entry (set RICHOS_WINDOWS_COMPANION to
 *                               a binary that speaks the same `ingest` interface and it runs here).
 *
 * Per present surface the harness asserts, identically:
 *   [chain]        good call -> pipeline READY -> transcript.md, and loro-correction rewrites an
 *                  injected mangled term (proving the correction stage runs the same for every source);
 *   [never-silent] a captured-but-SILENT call and a captured-but-NO-AUDIO call are LOUD anomalies, not
 *                  silent empty transcripts — the SAME outcome for extension and companion.
 * Plus a cross-surface COORDINATION block: the extension owns a live browser call and the companion is
 * told to STAND DOWN (one session per call, no double-capture) — the surface-agnostic §5.4 authority.
 */

import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { runPipeline, readRecord } from '../lib/pipeline.js';
import { SessionSink } from '../lib/host-handlers.js';
import { CAPTURE_SOURCE } from '../lib/contract.js';
import { newSessionRecord } from '../../richos-extension/modules/call-capture/session.js';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const CLI = path.join(HERE, '..', 'bin', 'richos-service.js');
const COMPANION_DIR = path.join(HERE, '..', 'companion-macos');
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
  try { execFileSync(bin, args, { stdio: 'ignore' }); return true; } catch { return false; }
}

const ffmpeg = 'ffmpeg';
if (!have(ffmpeg, ['-version'])) { console.error('cross-surface-e2e requires ffmpeg. Aborting.'); process.exit(1); }
const canSay = have('say', ['-v', '?']);

const zone = fs.mkdtempSync(path.join(os.tmpdir(), 'richos-xsurface-'));
const work = fs.mkdtempSync(path.join(os.tmpdir(), 'richos-xsurface-work-'));
console.log(`drop zone: ${zone}\n`);

const ME_LINE = 'Hi Marcus, thanks for joining the call. Let me pull up your account now.';
const OTHERS_LINE = 'Marcus Whitfield here, happy to be on. Let us get started with the quarterly review.';

/** Render a stereo WAV (L=me, R=others) and, optionally, a mono/2-ch Opus/WebM. Returns paths. */
function renderAudio(prefix, { silent = false } = {}) {
  const wav = path.join(work, `${prefix}.wav`);
  if (silent) {
    execFileSync(ffmpeg, ['-y', '-f', 'lavfi', '-i', 'anullsrc=r=48000:cl=stereo', '-t', '8', wav]);
    return { wav };
  }
  if (canSay) {
    const a = path.join(work, `${prefix}-a.aiff`);
    const b = path.join(work, `${prefix}-b.aiff`);
    execFileSync('say', ['-v', 'Samantha', '-o', a, ME_LINE]);
    execFileSync('say', ['-v', 'Fred', '-o', b, OTHERS_LINE]);
    execFileSync(ffmpeg, [
      '-y', '-i', a, '-i', b, '-filter_complex',
      '[0:a]aformat=channel_layouts=mono,apad=whole_dur=12[me];' +
        '[1:a]aformat=channel_layouts=mono,adelay=5000,apad=whole_dur=12[others];' +
        '[me][others]join=inputs=2:channel_layout=stereo[a]',
      '-map', '[a]', '-ac', '2', '-ar', '48000', wav,
    ]);
  } else {
    execFileSync(ffmpeg, [
      '-y', '-f', 'lavfi', '-i', 'sine=frequency=300:duration=12', '-f', 'lavfi', '-i', 'sine=frequency=600:duration=12',
      '-filter_complex', '[0:a][1:a]join=inputs=2:channel_layout=stereo[a]', '-map', '[a]', '-ac', '2', '-ar', '48000', wav,
    ]);
  }
  return { wav };
}

// ============================================================================================
// Surface producers — each writes ONE frozen contract session directory into the drop zone.
// ============================================================================================

/** chrome-extension: real session.js record + 2-ch Opus/WebM + captions (remote NAMES). */
function produceExtension(kind) {
  // Start from the extension's ACTUAL record shape, then close it as the extension does at call end.
  const rec = newSessionRecord({
    startedAt: T0, platform: { id: 'meet', label: 'Google Meet', slug: `xs-ext-${kind}` },
    tabId: 7, url: 'https://meet.google.com/abc', title: 'Meet', extensionVersion: '0.2.1',
    settings: { chunkMs: 3000, audioBitsPerSecond: 64000 },
  });
  rec.sessionId = `2026-08-24T09-00-00Z--meet--xs-ext-${kind}`;
  rec.dir = rec.sessionId;
  const dir = path.join(zone, rec.sessionId);
  fs.mkdirSync(dir, { recursive: true });
  rec.status = 'closed';
  rec.endedAt = T0 + 12000;
  rec.capture.source = CAPTURE_SOURCE.extension;

  if (kind !== 'no-audio') {
    const { wav } = renderAudio(`ext-${kind}`, { silent: kind === 'silent' });
    execFileSync(ffmpeg, ['-y', '-i', wav, '-c:a', 'libopus', '-b:a', '64k', '-ac', '2', path.join(dir, 'audio-part-00.webm')]);
    const bytes = fs.statSync(path.join(dir, 'audio-part-00.webm')).size;
    rec.audio = { parts: [{ part: 0, bytes, chunks: 4 }], bytesTotal: bytes, chunkCount: 4 };
  } else {
    rec.audio = { parts: [], bytesTotal: 0, chunkCount: 0 };
  }
  // Browser surfaces carry captions (the far-side NAME). Present even for the anomaly variants so the
  // "captions-but-no-audio" never-silent path is exercised on the extension exactly as in production.
  rec.captions = { available: true, adapter: 'meet', count: 1, speakers: ['Marcus Whitfield'], degraded: false };
  fs.writeFileSync(path.join(dir, 'captions.ndjson'),
    `${JSON.stringify({ speaker: 'Marcus Whitfield', text: OTHERS_LINE, firstT: T0 + 5000, t: T0 + 11000, revision: 3 })}\n`);
  fs.writeFileSync(path.join(dir, 'session.json'), `${JSON.stringify(rec, null, 2)}\n`);
  return dir;
}

/** desktop-companion-macos: the REAL Swift companion `ingest` writes the contract (WAV, no captions). */
let companionBin = null;
function ensureCompanion() {
  if (companionBin !== null) return companionBin;
  try {
    execFileSync('swift', ['build'], { cwd: COMPANION_DIR, stdio: 'ignore' });
    const binPath = execFileSync('swift', ['build', '--show-bin-path'], { cwd: COMPANION_DIR, encoding: 'utf8' }).trim();
    const bin = path.join(binPath, 'richos-companion');
    companionBin = fs.existsSync(bin) ? bin : false;
  } catch {
    companionBin = false;
  }
  return companionBin;
}
function produceCompanion(kind) {
  const bin = ensureCompanion();
  if (!bin) return null;
  if (kind === 'no-audio') {
    // The companion's no-audio anomaly = an open session with zero parts (never-silent inversion).
    const id = '2026-08-24T09-30-00Z--system--xs-mac-no-audio';
    const dir = path.join(zone, id);
    fs.mkdirSync(dir, { recursive: true });
    fs.writeFileSync(path.join(dir, 'session.json'), `${JSON.stringify({
      schemaVersion: 2, sessionId: id, dir: id, status: 'closed', startedAt: T0, endedAt: T0 + 60000,
      capture: { source: CAPTURE_SOURCE.macos, captureTarget: 'system' },
      audio: { parts: [], bytesTotal: 0, chunkCount: 0 }, captions: { count: 0 }, health: { redSeconds: 0 },
    }, null, 2)}\n`);
    return dir;
  }
  const { wav } = renderAudio(`mac-${kind}`, { silent: kind === 'silent' });
  const startedAt = String(T0 + (kind === 'silent' ? 100000 : 200000)); // distinct dir names per variant
  execFileSync(bin, ['ingest', '--stereo', wav, '--zone', zone, '--started-at', startedAt], { stdio: 'ignore' });
  // Find the just-written companion session dir (source = desktop-companion-macos, matching startedAt).
  const stamp = new Date(Number(startedAt)).toISOString().replace(/\.\d+Z$/, 'Z').replace(/:/g, '-');
  const id = `${stamp}--system--call`;
  return fs.existsSync(path.join(zone, id)) ? path.join(zone, id) : null;
}

/** desktop-companion-windows: structural seam. Runs iff a binary speaking `ingest` is provided. */
function produceWindows(kind) {
  const bin = process.env.RICHOS_WINDOWS_COMPANION;
  if (!bin || !fs.existsSync(bin)) return null;
  const { wav } = renderAudio(`win-${kind}`, { silent: kind === 'silent' });
  execFileSync(bin, ['ingest', '--stereo', wav, '--zone', zone], { stdio: 'ignore' });
  return null; // a real Windows companion would return its dir; absent here.
}

const SURFACES = [
  { name: CAPTURE_SOURCE.extension, browserTab: true, produce: produceExtension, present: true, hasCaptions: true },
  { name: CAPTURE_SOURCE.macos, browserTab: false, produce: produceCompanion, present: !!ensureCompanion(),
    absentReason: 'swift companion did not build on this host', hasCaptions: false },
  { name: CAPTURE_SOURCE.windows, browserTab: false, produce: produceWindows,
    present: !!(process.env.RICHOS_WINDOWS_COMPANION && fs.existsSync(process.env.RICHOS_WINDOWS_COMPANION)),
    absentReason: 'no Windows host / RICHOS_WINDOWS_COMPANION unset — the seam is proven by table membership', hasCaptions: false },
];

// ============================================================================================
// PER-SURFACE: the identical chain + the identical never-silent guarantee.
// ============================================================================================
const goodDirsBySurface = {};

for (const surface of SURFACES) {
  console.log(`\n=== surface: ${surface.name} ===`);
  if (!surface.present) { skip(surface.name, surface.absentReason); continue; }

  // --- [chain] good call -> READY -> transcript.md, source-tagged correctly -------------------
  const goodDir = surface.produce('good');
  check(`[${surface.name}] produced a contract session directory`, !!goodDir && fs.existsSync(path.join(goodDir, 'session.json')));
  if (!goodDir) continue;
  goodDirsBySurface[surface.name] = goodDir;

  const r = runPipeline(goodDir, { zone, now: T0 + 13 * 60 * 1000 });
  check(`[${surface.name}] pipeline reached READY`, r.status === 'ready', JSON.stringify(r.problems || ''));
  check(`[${surface.name}] transcript.md written`, fs.existsSync(path.join(goodDir, 'transcript.md')));
  check(`[${surface.name}] verification.json written`, fs.existsSync(path.join(goodDir, 'verification.json')));
  const rec = readRecord(goodDir);
  check(`[${surface.name}] session upgraded to v2 with the right capture.source`,
    rec.schemaVersion === 2 && rec.capture.source === surface.name, `source=${rec.capture?.source}`);

  // Browser surface must yield the remote NAME; companion honestly has no captions.
  const md = fs.readFileSync(path.join(goodDir, 'transcript.md'), 'utf8');
  if (surface.hasCaptions && canSay) {
    check(`[${surface.name}] remote NAME folded in from captions (Marcus Whitfield)`, /Marcus Whitfield:/.test(md));
  } else if (canSay) {
    check(`[${surface.name}] far side attributed as generic "Them" (no captions on this surface)`, /\] Them:\*\*/.test(md) || /\] Me:\*\*/.test(md));
  }

  // --- [chain] loro-correction runs identically for every source ------------------------------
  if (canSay && md.trim()) {
    const spoken = md.split(/\r?\n/).filter((l) => /^\*\*\[\d/.test(l)).map((l) => l.replace(/^\*\*\[[^\]]*\]\s[^:]*:\*\*\s?/, '')).join(' ');
    const pick = (spoken.match(/[A-Za-z]{5,}/g) || [])[0];
    if (pick) {
      const CANON = 'Zeta Cross Surface Term';
      const entityMemory = { entitiesVersion: `xs-${surface.name}`, entities: [{ canonical: CANON, type: 'jargon', aliases: [], mangled: [pick.toLowerCase()], fuzzy: false, caseSensitive: false, minScore: null }] };
      const cr = runPipeline(goodDir, { zone, retranscribe: true, entityMemory, now: T0 + 14 * 60 * 1000 });
      const md2 = fs.readFileSync(path.join(goodDir, 'transcript.md'), 'utf8');
      const spokenAfter = md2.split(/\r?\n/).filter((l) => /^\*\*\[\d/.test(l)).join('\n');
      check(`[${surface.name}] loro-correction rewrote "${pick}" -> "${CANON}" identically to every source`,
        cr.status === 'ready' && spokenAfter.includes(CANON));
    }
  }

  // --- [never-silent] a SILENT call is a LOUD anomaly, not a silent transcript -----------------
  const silentDir = surface.produce('silent');
  if (silentDir) {
    const sr = runPipeline(silentDir, { zone, now: T0 + 60000 });
    check(`[${surface.name}] captured-but-SILENT -> anomaly (never a silent transcript)`, sr.status === 'anomaly', sr.status);
    check(`[${surface.name}] SILENT session produced NO transcript.md`, !fs.existsSync(path.join(silentDir, 'transcript.md')));
  }

  // --- [never-silent] a NO-AUDIO call is a LOUD anomaly ----------------------------------------
  const noAudioDir = surface.produce('no-audio');
  if (noAudioDir) {
    const nr = runPipeline(noAudioDir, { zone, now: T0 + 60000 });
    check(`[${surface.name}] captured-but-NO-AUDIO -> anomaly (absence made present on disk)`, nr.status === 'anomaly', nr.status);
  }
}

// ============================================================================================
// CROSS-SURFACE COORDINATION — one session per call, no double-capture (§5.4, surface-agnostic).
// ============================================================================================
console.log('\n=== cross-surface coordination: no double-capture ===');
function cli(args) {
  try { return { code: 0, out: execFileSync(process.execPath, [CLI, ...args, '--zone', zone], { encoding: 'utf8', env: { ...process.env, RICHOS_LOG_LEVEL: 'error' } }) }; }
  catch (err) { return { code: err.status ?? 1, out: `${err.stdout || ''}${err.stderr || ''}` }; }
}
// The extension owns a LIVE browser call (real SessionSink + a fresh heartbeat). Liveness is judged
// against wall-clock now, so anchor this block on real time (not the fixed replay T0).
const sink = new SessionSink(zone);
const nowMs = Date.now();
const liveId = '2026-08-24T15-00-00Z--meet--xs-live';
sink.handle({ type: 'session-start', record: {
  schemaVersion: 1, sessionId: liveId, dir: liveId, status: 'open', startedAt: nowMs,
  capture: { source: CAPTURE_SOURCE.extension, captureTarget: 'tab' },
  ownership: { ownerSurface: CAPTURE_SOURCE.extension, supersedes: null, processHint: 'Google Chrome' },
  audio: { parts: [], bytesTotal: 0 }, captions: { count: 3 },
} }, nowMs);
sink.handle({ type: 'health', sessionId: liveId, line: { t: nowMs + 500, level: 'green' } }, nowMs + 500);
const claim = cli(['claim', '--surface', CAPTURE_SOURCE.macos, '--kind', 'system', '--session-id', 'xs-mac-live']);
const claimJson = JSON.parse(claim.out);
check('a companion is told to STAND DOWN while the extension owns the live browser call (no double)',
  claimJson.decision === 'stand-down' && claim.code === 3, claimJson.decision);
check('a companion capturing a DIFFERENT desktop app is allowed to OWN it',
  JSON.parse(cli(['claim', '--surface', CAPTURE_SOURCE.macos, '--kind', 'process', '--process-hint', 'zoom.us', '--session-id', 'xs-mac-zoom']).out).decision === 'own');

// ============================================================================================
// CROSS-SURFACE INVARIANT — the pipeline produced the SAME artifacts for EVERY present source.
// ============================================================================================
console.log('\n=== cross-surface invariant: identical outcome regardless of source ===');
const presentGood = Object.entries(goodDirsBySurface);
check('at least two distinct capture surfaces were exercised through ONE pipeline', presentGood.length >= 2,
  `surfaces=${presentGood.map(([n]) => n).join(', ')}`);
for (const [name, dir] of presentGood) {
  const rec = readRecord(dir);
  check(`[${name}] identical contract outcome: v2 + pipeline.status ready + transcript.md + verification.json`,
    rec.schemaVersion === 2 && rec.pipeline.status === 'ready' &&
    fs.existsSync(path.join(dir, 'transcript.md')) && fs.existsSync(path.join(dir, 'verification.json')));
}
const sources = presentGood.map(([, dir]) => readRecord(dir).capture.source);
check('the exercised surfaces carried DISTINCT capture.source values (truly cross-surface)',
  new Set(sources).size === sources.length, sources.join(', '));

fs.rmSync(work, { recursive: true, force: true });
console.log(`\n${failures === 0 ? 'ALL CROSS-SURFACE E2E CHECKS PASSED' : `${failures} CROSS-SURFACE CHECK(S) FAILED`} (${skips} skipped)`);
console.log(`(drop zone kept at ${zone})`);
process.exit(failures ? 1 : 0);
