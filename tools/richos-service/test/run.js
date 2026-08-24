#!/usr/bin/env node
/**
 * RichOS local service — pure-logic test harness (no ffmpeg, no whisper, no browser).
 *
 *   node test/run.js
 *
 * Everything that decides correctness or a reliability alarm lives in pure modules so it can be
 * tested here deterministically with a fake clock and temp dirs. Test names document the invariant.
 * The heavy end-to-end (real audio -> real transcript) lives in test/e2e.mjs.
 */

import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

import { upgradeRecord, CONTRACT_SCHEMA_VERSION, PIPELINE_STATUS, toAbsolute } from '../lib/contract.js';
import { reconcilePipeline, analyzeSession } from '../lib/reconcile.js';
import { mergeTranscript, captionSpeakerFor, renderMarkdown, verify, stamp, wordCount } from '../lib/merge.js';
import { correct } from '../lib/correct.js';
import { encodeMessage, FrameDecoder } from '../lib/stdio.js';
import { SessionSink } from '../lib/host-handlers.js';
import { appendLedger, alreadyLedgered } from '../lib/ledger.js';
import { parseChannels, parseVolume, SILENCE_MAX_DB } from '../lib/normalize.js';
import { parseWhisperJson } from '../lib/transcribe.js';

let passed = 0;
const failures = [];
function test(name, fn) {
  try {
    fn();
    passed += 1;
    console.log(`  ok  ${name}`);
  } catch (err) {
    failures.push({ name, err });
    console.log(`FAIL  ${name}\n      ${err.message}`);
  }
}
function group(t) {
  console.log(`\n${t}`);
}
function tmp() {
  return fs.mkdtempSync(path.join(os.tmpdir(), 'richos-svc-'));
}

const T0 = 1_700_000_000_000;

// ---------------------------------------------------------------------------------------
group('capture->pipeline contract (schemaVersion 2) — surface-independence, no field lost');

test('upgradeRecord lifts a v1 extension record to v2 without discarding any v1 field', () => {
  const v1 = {
    schemaVersion: 1,
    sessionId: 's1',
    status: 'closed',
    platform: { id: 'meet' },
    capture: { chunkMs: 3000, micEnabled: true },
    audio: { parts: [{ part: 0, bytes: 10 }], bytesTotal: 10 },
    captions: { count: 5 },
  };
  const v2 = upgradeRecord(v1);
  assert.equal(v2.schemaVersion, CONTRACT_SCHEMA_VERSION);
  assert.equal(v2.capture.chunkMs, 3000, 'existing capture fields survive');
  assert.equal(v2.capture.source, 'chrome-extension');
  assert.equal(v2.capture.channels.left, 'microphone (me)');
  assert.equal(v2.ownership.ownerSurface, 'chrome-extension');
  assert.equal(v2.pipeline.status, 'pending');
  assert.deepEqual(v2.pipeline.modelRuns, []);
});

test('upgradeRecord is idempotent and never overwrites an existing pipeline block', () => {
  const rec = upgradeRecord({ sessionId: 's', pipeline: { status: 'ready', modelRuns: [{ model: 'x' }] } });
  const again = upgradeRecord(rec);
  assert.equal(again.pipeline.status, 'ready');
  assert.equal(again.pipeline.modelRuns.length, 1);
});

test('toAbsolute anchors a relative offset onto session start (no timestamp, no merge)', () => {
  assert.equal(toAbsolute(T0, 5000), T0 + 5000);
  assert.equal(toAbsolute(0, 0), 0);
});

// ---------------------------------------------------------------------------------------
group('reconcile — the never-silent guard extends the extension logic verbatim');

function recordWith({ audioBytes = 0, parts = 0, captionCount = 0, status = 'closed', endedAt = T0 }) {
  return {
    status,
    endedAt,
    audio: { parts: Array.from({ length: parts }, (_, i) => ({ part: i, bytes: audioBytes })), bytesTotal: audioBytes },
    captions: { count: captionCount },
    health: { redSeconds: 0 },
  };
}

test('reconcilePipeline reuses analyzeSession — a captions-only session is still a flagged anomaly', () => {
  const r = reconcilePipeline({ record: recordWith({ captionCount: 20 }), audioBytesOnDisk: 0, hasTranscript: false, now: T0 });
  assert.equal(r.captionsOnly, true);
  assert.equal(r.complete, false);
  assert.ok(r.problems.some((p) => /NO audio/.test(p)));
  // parity: analyzeSession alone agrees
  assert.equal(analyzeSession({ record: recordWith({ captionCount: 20 }), audioBytesOnDisk: 0 }).captionsOnly, true);
});

test('a CLOSED session with audio but no transcript, past the SLA, is a LOUD transcript-overdue anomaly', () => {
  const rec = recordWith({ audioBytes: 2_000_000, parts: 1, endedAt: T0 });
  const r = reconcilePipeline({
    record: rec,
    audioBytesOnDisk: 2_000_000,
    hasTranscript: false,
    now: T0 + 20 * 60 * 1000, // 20 min later, SLA is 10
    slaMs: 10 * 60 * 1000,
  });
  assert.equal(r.transcriptOverdue, true);
  assert.equal(r.complete, false);
  assert.ok(r.problems.some((p) => /NO transcript\.md/.test(p)));
});

test('the same session WITH a transcript is complete and not overdue', () => {
  const rec = recordWith({ audioBytes: 2_000_000, parts: 1, endedAt: T0 });
  const r = reconcilePipeline({ record: rec, audioBytesOnDisk: 2_000_000, hasTranscript: true, now: T0 + 3600_000 });
  assert.equal(r.transcriptOverdue, false);
  assert.equal(r.complete, true, r.problems.join('; '));
});

test('within the SLA, a not-yet-transcribed closed session is NOT yet an overdue anomaly', () => {
  const rec = recordWith({ audioBytes: 2_000_000, parts: 1, endedAt: T0 });
  const r = reconcilePipeline({ record: rec, audioBytesOnDisk: 2_000_000, hasTranscript: false, now: T0 + 60_000, slaMs: 600_000 });
  assert.equal(r.transcriptOverdue, false);
});

// ---------------------------------------------------------------------------------------
group('merge — interleave by timestamp + fold in caption speaker labels');

const meSegs = [
  { startMs: 0, endMs: 2000, text: 'hi there', speaker: 'me' },
  { startMs: 6000, endMs: 8000, text: 'sounds good', speaker: 'me' },
];
const othersSegs = [{ startMs: 2500, endMs: 5500, text: 'hello, thanks for joining', speaker: 'others' }];
const captions = [{ speaker: 'Marcus Whitfield', text: 'hello, thanks for joining', firstT: T0 + 2400, t: T0 + 5600, revision: 3 }];

test('segments from both channels interleave into one time-ordered transcript', () => {
  const merged = mergeTranscript({ me: meSegs, others: othersSegs, captions: [], startedAt: T0 });
  assert.deepEqual(merged.segments.map((s) => s.startMs), [0, 2500, 6000]);
  assert.deepEqual(merged.segments.map((s) => s.speaker), ['me', 'others', 'me']);
});

test('a far-side segment is attributed to the caption speaker it overlaps in time', () => {
  const name = captionSpeakerFor(othersSegs[0], T0, captions);
  assert.equal(name, 'Marcus Whitfield');
  const merged = mergeTranscript({ me: meSegs, others: othersSegs, captions, startedAt: T0 });
  const other = merged.segments.find((s) => s.speaker === 'others');
  assert.equal(other.label, 'Marcus Whitfield', 'audio gives you-vs-them; captions add WHICH of them');
  assert.deepEqual(merged.segments.filter((s) => s.speaker === 'me').map((s) => s.label), ['Me', 'Me']);
});

test('with no overlapping caption, a far-side segment falls back to the generic "Them" label', () => {
  const merged = mergeTranscript({ me: meSegs, others: othersSegs, captions: [], startedAt: T0 });
  assert.equal(merged.segments.find((s) => s.speaker === 'others').label, 'Them');
});

test('an "unknown" caption speaker never wins attribution (fails soft to Them)', () => {
  const anon = [{ speaker: 'unknown', firstT: T0 + 2400, t: T0 + 5600 }];
  assert.equal(captionSpeakerFor(othersSegs[0], T0, anon), null);
});

test('renderMarkdown produces speaker-attributed, timestamped lines with a provenance header', () => {
  const rec = upgradeRecord({
    sessionId: 's', startedAt: T0, endedAt: T0 + 600000,
    platform: { label: 'Google Meet' }, captions: { count: 1 },
  });
  rec.pipeline.model = 'large-v3-turbo';
  const merged = mergeTranscript({ me: meSegs, others: othersSegs, captions, startedAt: T0 });
  const md = renderMarkdown(merged, rec);
  assert.match(md, /# Transcript — Google Meet/);
  assert.match(md, /\*\*\[00:00\] Me:\*\* hi there/);
  assert.match(md, /\*\*\[00:02\] Marcus Whitfield:\*\* hello, thanks for joining/);
  assert.match(md, /Model:.*large-v3-turbo/);
});

test('stamp formats mm:ss and h:mm:ss; wordCount handles blanks', () => {
  assert.equal(stamp(0), '00:00');
  assert.equal(stamp(65000), '01:05');
  assert.equal(stamp(3_661_000), '1:01:01');
  assert.equal(wordCount('  '), 0);
  assert.equal(wordCount('one two three'), 3);
});

// ---------------------------------------------------------------------------------------
group('verification — coverage, caption<->ASR agreement, dead intervals as measured numbers');

test('verify computes coverage, per-channel words, and caption agreement', () => {
  const rec = { startedAt: T0, endedAt: T0 + 8000, pipeline: { model: 'large-v3-turbo' } };
  const merged = mergeTranscript({ me: meSegs, others: othersSegs, captions, startedAt: T0 });
  const v = verify(merged, { me: meSegs, others: othersSegs }, captions, rec);
  assert.equal(v.channels.meSegments, 2);
  assert.equal(v.channels.othersSegments, 1);
  assert.ok(v.channels.totalWords > 0);
  assert.equal(v.captions.count, 1);
  assert.equal(v.captions.matchedToSegments, 1, 'the caption overlaps the far-side segment');
  assert.equal(v.captions.agreementRatio, 1);
  assert.ok(v.coverage.ratio > 0 && v.coverage.ratio <= 1);
});

test('verify flags a long silent tail as a dead interval', () => {
  const rec = { startedAt: T0, endedAt: T0 + 300000 }; // 5 min session, speech only in first 8s
  const merged = mergeTranscript({ me: meSegs, others: othersSegs, captions: [], startedAt: T0 });
  const v = verify(merged, { me: meSegs, others: othersSegs }, [], rec);
  assert.ok(v.deadIntervalCount >= 1, 'a 5-minute session with 8s of speech has dead air');
});

// ---------------------------------------------------------------------------------------
group('loro-correction seam — P1 identity pass, P4-shaped contract');

test('correct() is a pass-through in P1: same text, zero corrections, applied=false', () => {
  const segs = meSegs.map((s) => ({ ...s, label: 'Me' }));
  const out = correct(segs, {});
  assert.equal(out.applied, false);
  assert.equal(out.corrections.length, 0);
  assert.deepEqual(out.segments.map((s) => s.text), segs.map((s) => s.text));
});

test('correct() returns the exact shape P4 will fill: {segments, corrections[], applied, entitiesVersion}', () => {
  const out = correct([], { entitiesVersion: 'v0' });
  assert.ok(Array.isArray(out.segments) && Array.isArray(out.corrections));
  assert.equal(out.entitiesVersion, 'v0');
  assert.equal(typeof out.applied, 'boolean');
});

test('correct() does not mutate the caller\'s segments (defensive copy)', () => {
  const segs = [{ startMs: 0, endMs: 1, text: 'x', speaker: 'me', label: 'Me' }];
  const out = correct(segs, {});
  out.segments[0].text = 'mutated';
  assert.equal(segs[0].text, 'x');
});

// ---------------------------------------------------------------------------------------
group('native-messaging stdio framing — round-trips length-prefixed JSON');

test('encodeMessage + FrameDecoder round-trip a message', () => {
  const dec = new FrameDecoder();
  const out = dec.push(encodeMessage({ type: 'hello', v: 1 }));
  assert.equal(out.length, 1);
  assert.deepEqual(out[0], { type: 'hello', v: 1 });
});

test('the decoder reassembles a message split across chunk boundaries', () => {
  const dec = new FrameDecoder();
  const frame = encodeMessage({ type: 'audio-chunk', part: 0, dataB64: 'AAAA' });
  assert.deepEqual(dec.push(frame.subarray(0, 3)), []); // header incomplete
  assert.deepEqual(dec.push(frame.subarray(3, 10)), []); // body incomplete
  const done = dec.push(frame.subarray(10));
  assert.equal(done.length, 1);
  assert.equal(done[0].type, 'audio-chunk');
});

test('two concatenated frames decode as two messages in one push', () => {
  const dec = new FrameDecoder();
  const buf = Buffer.concat([encodeMessage({ a: 1 }), encodeMessage({ b: 2 })]);
  const out = dec.push(buf);
  assert.equal(out.length, 2);
  assert.deepEqual(out.map((m) => Object.keys(m)[0]), ['a', 'b']);
});

// ---------------------------------------------------------------------------------------
group('native host handlers (SessionSink) — writes the SAME contract dir as the sync helper');

test('session-start creates the contract dir with an OPEN, v2 session.json', () => {
  const zone = tmp();
  const sink = new SessionSink(zone);
  const resp = sink.handle({ type: 'session-start', record: { sessionId: 'sX', platform: { id: 'meet' } } }, T0);
  assert.equal(resp.type, 'started');
  const rec = JSON.parse(fs.readFileSync(path.join(zone, 'sX', 'session.json'), 'utf8'));
  assert.equal(rec.status, 'open');
  assert.equal(rec.schemaVersion, CONTRACT_SCHEMA_VERSION);
  assert.equal(rec.capture.source, 'chrome-extension');
  fs.rmSync(zone, { recursive: true, force: true });
});

test('audio-chunk / health / caption append the right files; session-close finalizes + triggers the pipeline', () => {
  const zone = tmp();
  const sink = new SessionSink(zone);
  sink.handle({ type: 'session-start', record: { sessionId: 'sY' } }, T0);
  sink.handle({ type: 'audio-chunk', sessionId: 'sY', part: 0, dataB64: Buffer.from('opusbytes').toString('base64') }, T0 + 1000);
  sink.handle({ type: 'health', sessionId: 'sY', line: { t: T0 + 1000, level: 'green' } }, T0 + 1000);
  sink.handle({ type: 'caption', sessionId: 'sY', line: { speaker: 'Ada', text: 'hi', t: T0 + 1200 } }, T0 + 1200);
  const close = sink.handle({ type: 'session-close', sessionId: 'sY', record: { audio: { parts: [{ part: 0 }], bytesTotal: 9 } } }, T0 + 5000);
  assert.equal(close.type, 'closed');
  assert.equal(close._trigger, 'sY', 'close hands the session to the pipeline');
  const dir = path.join(zone, 'sY');
  assert.equal(fs.readFileSync(path.join(dir, 'audio-part-00.webm'), 'utf8'), 'opusbytes');
  assert.equal(fs.readFileSync(path.join(dir, 'health.ndjson'), 'utf8').trim().length > 0, true);
  assert.equal(fs.readFileSync(path.join(dir, 'captions.ndjson'), 'utf8').trim().length > 0, true);
  const rec = JSON.parse(fs.readFileSync(path.join(dir, 'session.json'), 'utf8'));
  assert.equal(rec.status, 'closed');
  assert.equal(rec.endedAt, T0 + 5000);
  fs.rmSync(zone, { recursive: true, force: true });
});

test('the watchdog alarms on a stale heartbeat (browser stopped talking mid-call)', () => {
  const zone = tmp();
  const sink = new SessionSink(zone);
  sink.handle({ type: 'session-start', record: { sessionId: 'sZ' } }, T0);
  assert.deepEqual(sink.checkWatchdog(T0 + 5000), [], 'fresh heartbeat: no alarm');
  const alarms = sink.checkWatchdog(T0 + 20000);
  assert.equal(alarms.length, 1);
  assert.equal(alarms[0].sessionId, 'sZ');
  fs.rmSync(zone, { recursive: true, force: true });
});

test('on pipe EOF an open session is finalized INTERRUPTED — a lost call is present on disk', () => {
  const zone = tmp();
  const sink = new SessionSink(zone);
  sink.handle({ type: 'session-start', record: { sessionId: 'sEOF' } }, T0);
  const finalized = sink.finalizeOnEof(T0 + 9000);
  assert.deepEqual(finalized, ['sEOF']);
  const rec = JSON.parse(fs.readFileSync(path.join(zone, 'sEOF', 'session.json'), 'utf8'));
  assert.equal(rec.status, 'interrupted');
  assert.ok(rec.notes.some((n) => /interrupted by the native host/.test(n)));
  fs.rmSync(zone, { recursive: true, force: true });
});

// ---------------------------------------------------------------------------------------
group('ingest ledger — collector-path parity, idempotent by (sessionId, runIndex)');

test('appendLedger writes once and dedups an identical (sessionId, runIndex)', () => {
  const zone = tmp();
  const first = appendLedger({ sessionId: 's', runIndex: 0, model: 'large-v3-turbo', words: 100 }, zone);
  assert.equal(first.appended, true);
  assert.equal(alreadyLedgered('s', 0, zone), true);
  const dup = appendLedger({ sessionId: 's', runIndex: 0, model: 'large-v3-turbo', words: 100 }, zone);
  assert.equal(dup.appended, false, 're-running the pipeline never double-ingests');
  const second = appendLedger({ sessionId: 's', runIndex: 1, model: 'large-v3', words: 105 }, zone);
  assert.equal(second.appended, true, 'a re-transcription appends a NEW run row for the same session');
  fs.rmSync(zone, { recursive: true, force: true });
});

// ---------------------------------------------------------------------------------------
group('parsers — ffmpeg channel probe + whisper JSON');

test('parseChannels reads mono/stereo/N-channel from ffmpeg stderr', () => {
  assert.equal(parseChannels('Stream #0:0: Audio: opus, 48000 Hz, stereo, fltp'), 2);
  assert.equal(parseChannels('Stream #0:0: Audio: pcm_s16le, 16000 Hz, mono, s16'), 1);
  assert.equal(parseChannels('Stream #0:0: Audio: aac, 44100 Hz, 6 channels, fltp'), 6);
  assert.equal(parseChannels('no audio here'), 0);
});

test('parseVolume reads mean/max dBFS and treats -inf as digital silence', () => {
  const real = parseVolume('[Parsed_volumedetect_0] mean_volume: -23.4 dB\n[Parsed_volumedetect_0] max_volume: -3.1 dB');
  assert.equal(real.meanDb, -23.4);
  assert.equal(real.maxDb, -3.1);
  const silent = parseVolume('[Parsed_volumedetect_0] mean_volume: -inf dB\n[Parsed_volumedetect_0] max_volume: -inf dB');
  assert.equal(silent.maxDb, -Infinity);
  assert.ok(silent.maxDb <= SILENCE_MAX_DB, 'a -inf channel is below the silence floor');
  assert.ok(real.maxDb > SILENCE_MAX_DB, 'a -3 dB channel is well above the silence floor');
});

test('parseWhisperJson normalizes segments and drops empties', () => {
  const json = {
    transcription: [
      { offsets: { from: 0, to: 2000 }, text: ' Hello there.' },
      { offsets: { from: 2000, to: 2500 }, text: '   ' },
      { offsets: { from: 2500, to: 4000 }, text: 'General Kenobi' },
    ],
  };
  const segs = parseWhisperJson(json, 'others');
  assert.equal(segs.length, 2);
  assert.deepEqual(segs[0], { startMs: 0, endMs: 2000, text: 'Hello there.', speaker: 'others' });
  assert.equal(segs[1].text, 'General Kenobi');
});

// ---------------------------------------------------------------------------------------
console.log(`\n${passed} passed, ${failures.length} failed`);
if (failures.length) {
  console.error('\nFAILURES:');
  for (const f of failures) console.error(`- ${f.name}: ${f.err.stack}`);
  process.exit(1);
}
