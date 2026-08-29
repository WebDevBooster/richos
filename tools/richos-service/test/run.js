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
import { correct, correctText, similarity, levenshtein, normalizeTerm } from '../lib/correct.js';
import { normalizeEntities, loadEntityMemory } from '../lib/entities.js';
import {
  learnTerm,
  learnFromEdits,
  extractTermCorrections,
  tokenReplaceHunks,
  looksLikeTerm,
  bumpVersion,
  serializeEntitiesDoc,
} from '../lib/capture.js';
import {
  CAPTURE_KIND,
  preferenceRank,
  scopesOverlap,
  decideClaim,
  findPromotable,
  buildPromotionOwnership,
  dedupeOverlapping,
  sessionDescriptor,
} from '../lib/coordination.js';
import { encodeMessage, FrameDecoder } from '../lib/stdio.js';
import { SessionSink } from '../lib/host-handlers.js';
import { appendLedger, alreadyLedgered } from '../lib/ledger.js';
import { parseChannels, parseVolume, parseSilenceLog, SILENCE_MAX_DB } from '../lib/normalize.js';
import { parseWhisperJson } from '../lib/transcribe.js';
import { resolveTier, MODEL_TIERS, DEFAULT_TIER, whisperArgs, MAX_CONTEXT_TOKENS } from '../lib/config.js';
import {
  guardChannel,
  guardChannelAll,
  guardInsertions,
  guardOverlapStutter,
  guardTranscription,
  guardWarnings,
  readEnumerationMarker,
  burstCapacity,
} from '../lib/repetition-guard.js';
import {
  TURBO_NUMERAL_INSERTION,
  Q5_SAME_AUDIO_CLEAN,
  GENUINE_SPOKEN_ENUMERATION,
  LARGE_V3_SLIDING_STUTTER,
  CLEAN_NO_BOUNDARY_OVERLAP,
} from './fixtures/captured-hallucinations.js';
import { diarizeOthers, readTurn, SPEAKER_TURN_MARKER } from '../lib/diarize.js';

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
group('loro entity memory loader — the correction stage input source (P4)');

test('normalizeEntities keeps valid rows, applies defaults, drops rows with no canonical', () => {
  const { entities, entitiesVersion } = normalizeEntities({
    version: 'v1',
    entities: [
      { canonical: 'Deepgram', type: 'product', mangled: ['deep graham'] },
      { canonical: '   ', type: 'product' }, // no real canonical -> dropped
      { type: 'person' }, // no canonical -> dropped
      { canonical: 'loro', caseSensitive: true, fuzzy: false },
    ],
  });
  assert.equal(entitiesVersion, 'v1');
  assert.equal(entities.length, 2);
  assert.equal(entities[0].fuzzy, true, 'fuzzy defaults true');
  assert.equal(entities[0].caseSensitive, false, 'caseSensitive defaults false');
  assert.equal(entities[1].caseSensitive, true);
  assert.equal(entities[1].fuzzy, false);
});

test('loadEntityMemory returns an EMPTY memory (never throws) when the file is missing', () => {
  const mem = loadEntityMemory('/nonexistent/loro/entities.json');
  assert.deepEqual(mem.entities, []);
  assert.equal(mem.entitiesVersion, null);
  assert.equal(mem.source, null);
});

test('the in-repo loro/entities.json, when present, loads and is well-formed', () => {
  const mem = loadEntityMemory(); if (mem.source === null) return; // repo default; absent in a clean clone (the missing-file contract is asserted above)
  assert.ok(typeof mem.entitiesVersion === 'string' && mem.entitiesVersion.length > 0);
  assert.ok(mem.entities.length >= 5, `expected several curated entities, got ${mem.entities.length}`);
  assert.ok(mem.entities.every((e) => typeof e.canonical === 'string' && e.canonical.length > 0));
});

// ---------------------------------------------------------------------------------------
group('loro-correction (P4 real corrector) — MEASURED precision/recall, no overcorrection');

const CORR_ENTITIES = normalizeEntities({
  version: 'corrtest-1',
  entities: [
    { canonical: 'Deepgram', type: 'product', mangled: ['deep graham'] },
    { canonical: 'whisper.cpp', type: 'product', mangled: ['whisper c p p'] },
    { canonical: 'RichOS', type: 'product', mangled: ['rich o s'] },
    { canonical: 'Rich Hanna', type: 'person', aliases: ['Rich'], mangled: ['rich hand'] },
    { canonical: 'loro', type: 'product', caseSensitive: true, aliases: ['Loro'], minScore: 0.8 }, // fuzzy target
    { canonical: 'Karpathy', type: 'person' }, // fuzzy target (no curated mangling)
  ],
}).entities;

// Planted manglings + the canonical each MUST become; `method` = the path that should catch it.
const PLANTED = [
  { text: 'I tested Deep Graham last week.', expect: 'Deepgram', method: 'curated' },
  { text: 'We built it on Whisper C P P.', expect: 'whisper.cpp', method: 'curated' },
  { text: 'The Rich O S dashboard shipped.', expect: 'RichOS', method: 'curated' },
  { text: 'Rich Hand owns the roadmap.', expect: 'Rich Hanna', method: 'curated' },
  { text: 'Our memory layer is called Lorow.', expect: 'loro', method: 'fuzzy' }, // NOT curated
  { text: 'The Karpathi wiki idea seeded it.', expect: 'Karpathy', method: 'fuzzy' }, // NOT curated
];
// Controls: ordinary text with words that superficially resemble entities — must NOT change.
const CONTROLS = [
  'Take a deep breath before the rich history lesson.',
  'The ground rules are simple.',
  'I had granola for breakfast.',
  'Rich, our CEO, will decide today.',
  'She went to the room to watch the team.',
];

test('recall = 1.0 — every planted mangling is corrected to its canonical', () => {
  let fixed = 0;
  for (const p of PLANTED) {
    const r = correctText(p.text, CORR_ENTITIES);
    const hit = r.corrections.find((c) => c.entity === p.expect);
    if (hit && r.text.includes(p.expect) && hit.method === p.method) fixed += 1;
    else console.log(`      recall miss: ${JSON.stringify(p.text)} -> ${JSON.stringify(r.text)}`);
  }
  const recall = fixed / PLANTED.length;
  console.log(`      recall = ${fixed}/${PLANTED.length} = ${recall.toFixed(3)}`);
  assert.equal(recall, 1, 'all planted manglings corrected by the expected path');
});

test('precision = 1.0 — zero false positives across planted + control text', () => {
  let tp = 0;
  let fp = 0;
  for (const p of PLANTED) {
    const r = correctText(p.text, CORR_ENTITIES);
    for (const c of r.corrections) {
      if (c.entity === p.expect) tp += 1;
      else fp += 1;
    }
  }
  for (const text of CONTROLS) {
    const r = correctText(text, CORR_ENTITIES);
    fp += r.corrections.length; // ANY correction on control text is a false positive
    assert.equal(r.text, text, `control text was overcorrected: ${JSON.stringify(text)} -> ${JSON.stringify(r.text)}`);
  }
  const precision = tp / (tp + fp || 1);
  console.log(`      precision = ${tp}/${tp + fp} = ${precision.toFixed(3)} (fp=${fp})`);
  assert.equal(fp, 0, 'no ordinary word was corrected into an entity');
  assert.equal(precision, 1);
});

test('correctText preserves surrounding punctuation on a fuzzy fix (Lorow. -> loro.)', () => {
  const r = correctText('Our layer is called Lorow.', CORR_ENTITIES);
  assert.equal(r.text, 'Our layer is called loro.');
});

test('a caseSensitive entity is not title-cased and an already-correct alias is left alone', () => {
  const r = correctText('The Loro layer and loro memory are the same.', CORR_ENTITIES);
  assert.equal(r.text, 'The Loro layer and loro memory are the same.', 'Loro alias + lowercase loro untouched');
  assert.equal(r.corrections.length, 0);
});

test('correct() over segments: applied=true, corrections carry segmentIndex, version recorded', () => {
  const segs = [
    { startMs: 0, endMs: 2000, text: 'Hi, this is Deep Graham speaking.', speaker: 'others', label: 'Them' },
    { startMs: 2000, endMs: 4000, text: 'We run on Whisper C P P.', speaker: 'me', label: 'Me' },
  ];
  const out = correct(segs, { entities: CORR_ENTITIES, entitiesVersion: 'corrtest-1' });
  assert.equal(out.applied, true);
  assert.equal(out.entitiesVersion, 'corrtest-1');
  assert.equal(out.segments[0].text, 'Hi, this is Deepgram speaking.');
  assert.equal(out.segments[1].text, 'We run on whisper.cpp.');
  assert.deepEqual(out.corrections.map((c) => c.segmentIndex).sort(), [0, 1]);
});

test('applied=true even with zero corrections (the corrector RAN; count says nothing changed)', () => {
  const segs = [{ startMs: 0, endMs: 1000, text: 'Nothing to fix here at all.', speaker: 'me', label: 'Me' }];
  const out = correct(segs, { entities: CORR_ENTITIES, entitiesVersion: 'corrtest-1' });
  assert.equal(out.applied, true);
  assert.equal(out.corrections.length, 0);
  assert.equal(out.segments[0].text, 'Nothing to fix here at all.');
});

test('similarity + levenshtein are sane (fuzzy metric guardrails)', () => {
  assert.equal(levenshtein('loro', 'loro'), 0);
  assert.equal(levenshtein('lorow', 'loro'), 1);
  assert.ok(similarity('deepgramm', 'deepgram') > 0.85);
  assert.ok(similarity('deep breath', 'deepgram') < 0.7, 'an ordinary phrase is far from the canonical');
  assert.equal(normalizeTerm('Rich O.S.!'), 'rich o s');
});

// ---------------------------------------------------------------------------------------
group('correction flywheel — EXPLICIT intake (learnTerm): dedup, no-clobber, versioned');

function baseDoc() {
  return {
    schemaVersion: 1,
    version: '2026-08-24',
    entities: [
      { canonical: 'Deepgram', type: 'product', aliases: [], mangled: ['deep graham'] },
      { canonical: 'loro', type: 'product', caseSensitive: true, aliases: ['Loro'], mangled: ['lorro'], fuzzy: true, minScore: 0.8 },
    ],
  };
}

test('learnTerm adds a NEW entity and bumps the version', () => {
  const before = baseDoc();
  const res = learnTerm(before, { canonical: 'Segment Anything', mangled: 'segment any thing', type: 'product' }, { today: '2026-08-25' });
  assert.equal(res.changed, true);
  assert.equal(res.created, true);
  assert.equal(res.doc.entities.length, 3);
  const e = res.doc.entities.find((x) => x.canonical === 'Segment Anything');
  assert.deepEqual(e.mangled, ['segment any thing']);
  assert.equal(e.type, 'product');
  assert.equal(res.doc.version, '2026-08-25', 'cross-day bump = the new date');
  assert.equal(before.entities.length, 2, 'input doc not mutated');
});

test('learnTerm MERGES a new mangling into an existing entity without clobbering curated data', () => {
  const before = baseDoc();
  const res = learnTerm(before, { canonical: 'Deepgram', mangled: 'deep gramme', type: 'company' });
  assert.equal(res.created, false);
  const e = res.doc.entities.find((x) => x.canonical === 'Deepgram');
  assert.deepEqual(e.mangled, ['deep graham', 'deep gramme'], 'existing mangling preserved, new one appended');
  assert.equal(e.type, 'product', 'curated type NOT clobbered by the supplied one');
  assert.equal(before.entities[0].mangled.length, 1, 'input doc not mutated');
});

test('learnTerm dedups a mangling it already has (no change, no version bump)', () => {
  const before = baseDoc();
  const res = learnTerm(before, { canonical: 'Deepgram', mangled: 'Deep Graham' }); // same after normalize
  assert.equal(res.changed, false);
  assert.equal(res.added.mangled.length, 0);
  assert.equal(res.doc.version, '2026-08-24', 'no bump when nothing changed');
});

test('learnTerm drops a mangling that normalizes to the canonical (correct.js would skip it anyway)', () => {
  const res = learnTerm(baseDoc(), { canonical: 'Deepgram', mangled: 'DEEPGRAM' }); // casing-only
  const e = res.doc.entities.find((x) => x.canonical === 'Deepgram');
  assert.deepEqual(e.mangled, ['deep graham'], 'a casing-only mangling is not stored (curated one kept)');
  assert.equal(res.changed, false, 'nothing learnable -> no change');
});

test('learnTerm refuses to steal a mangling already owned by a different canonical (conflict, precision)', () => {
  const before = baseDoc();
  const res = learnTerm(before, { canonical: 'Deepgraham Corp', mangled: 'deep graham' });
  assert.equal(res.conflicts.length, 1);
  const e = res.doc.entities.find((x) => x.canonical === 'Deepgraham Corp');
  assert.deepEqual(e.mangled, [], 'the conflicting mangling was skipped');
  // The original owner keeps it.
  assert.ok(res.doc.entities.find((x) => x.canonical === 'Deepgram').mangled.includes('deep graham'));
});

test('learnTerm matches an entity by an existing alias, adds a new alias, dedups aliases', () => {
  const res = learnTerm(baseDoc(), { canonical: 'Loro', aliases: ['Lauro', 'Loro'] }); // 'Loro' is an existing alias of 'loro'
  const e = res.doc.entities.find((x) => x.canonical === 'loro');
  assert.equal(res.created, false, 'matched the existing entity via its alias');
  assert.deepEqual(e.aliases, ['Loro', 'Lauro'], 'new alias added once; existing (dedup) kept');
});

test('bumpVersion increments an intra-day revision counter monotonically', () => {
  assert.equal(bumpVersion('2026-08-24', '2026-08-24'), '2026-08-24.1');
  assert.equal(bumpVersion('2026-08-24.1', '2026-08-24'), '2026-08-24.2');
  assert.equal(bumpVersion('2026-08-24', '2026-08-25'), '2026-08-25');
  assert.equal(bumpVersion('', '2026-08-25'), '2026-08-25');
});

test('serializeEntitiesDoc round-trips to valid JSON in the curated inline-array style', () => {
  const doc = baseDoc();
  const out = serializeEntitiesDoc(doc);
  assert.deepEqual(JSON.parse(out), doc, 'parses back to an identical object');
  assert.ok(out.includes('"mangled": ["deep graham"]'), 'string arrays stay inline (minimal git diff)');
  assert.ok(out.endsWith('}\n'), 'trailing newline');
});

// ---------------------------------------------------------------------------------------
group('correction flywheel — TRANSCRIPT-EDIT diff intake: PRECISION over recall');

test('tokenReplaceHunks expands a name fix to the full proper-noun span and ignores pure insertions', () => {
  // "Hand"->"Hanna" absorbs the adjacent unchanged term token "Rich" so the mangling is the WHOLE
  // name (safe), never the dangerous lone word "Hand".
  assert.deepEqual(
    tokenReplaceHunks('we run on Rich Hand today'.split(' '), 'we run on Rich Hanna today'.split(' ')),
    [{ from: 'Rich Hand', to: 'Rich Hanna' }],
  );
  // a pure insertion (no removed counterpart) yields no replace hunk
  assert.deepEqual(tokenReplaceHunks('we shipped it'.split(' '), 'we finally shipped it'.split(' ')), []);
});

test('looksLikeTerm accepts proper nouns / dotted terms and rejects ordinary words', () => {
  assert.equal(looksLikeTerm('Deepgram'), true);
  assert.equal(looksLikeTerm('Rich Hanna'), true);
  assert.equal(looksLikeTerm('whisper.cpp'), true);
  assert.equal(looksLikeTerm('RichOS'), true);
  assert.equal(looksLikeTerm('great'), false);
  assert.equal(looksLikeTerm('shall'), false);
  assert.equal(looksLikeTerm('the'), false);
});

// A realistic edited transcript: the CEO fixed ONE name and ONE ordinary word.
const BASELINE_TRANSCRIPT = [
  '# Transcript — call',
  '',
  '- **Session:** `s-1`',
  '',
  '---',
  '',
  '**[00:02] Them:** So Rich Hand walked us through the deep graham setup.',
  '',
  '**[00:15] Me:** Right, the plan is solid and we ship Monday.',
  '',
].join('\n');

const EDITED_TRANSCRIPT = [
  '# Transcript — call',
  '',
  '- **Session:** `s-1`',
  '',
  '---',
  '',
  '**[00:02] Them:** So Rich Hanna walked us through the Deepgram setup.',
  '',
  '**[00:15] Me:** Right, the plan is great and we ship Monday.', // ordinary word edit: solid -> great
  '',
].join('\n');

test('extractTermCorrections proposes the NAME + TERM fixes and NOT the ordinary word edit (precision)', () => {
  const { proposals, rejected } = extractTermCorrections(BASELINE_TRANSCRIPT, EDITED_TRANSCRIPT);
  const pairs = proposals.map((p) => `${p.from}=>${p.to}`).sort();
  assert.deepEqual(pairs, ['Rich Hand=>Rich Hanna', 'deep graham=>Deepgram']);
  // the ordinary-word edit must be rejected, not proposed (false-positive guard)
  assert.ok(!pairs.some((p) => p.includes('great')), 'solid->great was NOT learned');
  assert.ok(rejected.some((r) => r.to === 'great'), 'solid->great is explicitly recorded as rejected');
});

test('extractTermCorrections rejects a wholesale rewrite even when the new side is a proper noun', () => {
  const base = '**[00:01] Them:** um yeah exactly.';
  const edited = '**[00:01] Them:** Marcus Whitfield yeah exactly.'; // "um" -> a full name = a rewrite, not a mangling
  const { proposals } = extractTermCorrections(base, edited);
  assert.equal(proposals.length, 0, 'low edit-similarity rejects the rewrite');
});

test('learnFromEdits is PROPOSE-ONLY by default (doc untouched) and applies with apply=true', () => {
  const before = baseDoc();
  const dry = learnFromEdits(before, BASELINE_TRANSCRIPT, EDITED_TRANSCRIPT);
  assert.equal(dry.applied, false);
  assert.equal(dry.doc, before, 'default run does not touch the doc');
  assert.equal(dry.proposals.length, 2);

  const wet = learnFromEdits(before, BASELINE_TRANSCRIPT, EDITED_TRANSCRIPT, { apply: true, today: '2026-08-25' });
  assert.equal(wet.applied, true);
  const dg = wet.doc.entities.find((x) => x.canonical === 'Deepgram');
  assert.ok(dg.mangled.includes('deep graham'), 'existing curated mangling kept');
  const rh = wet.doc.entities.find((x) => x.canonical === 'Rich Hanna');
  assert.ok(rh && rh.mangled.includes('rich hand'), 'new person entity created from the edit');
  assert.equal(wet.doc.version, '2026-08-25');
});

// ---------------------------------------------------------------------------------------
group('correction flywheel — CLOSED LOOP: capture -> entities.json -> a later transcript is corrected');

test('a captured term fixes a subsequent transcript that mangles it (end-to-end through correct())', () => {
  // 1. A brand-new term the corrector does NOT yet know.
  const doc0 = baseDoc();
  const pre = correct(
    [{ startMs: 0, endMs: 1000, text: 'We evaluated Segment Any Thing for masks.', speaker: 'me', label: 'Me' }],
    normalizeEntities(doc0),
  );
  assert.equal(pre.segments[0].text, 'We evaluated Segment Any Thing for masks.', 'unknown term is NOT corrected pre-capture');

  // 2. Capture the correction (explicit intake).
  const { doc: doc1 } = learnTerm(doc0, { canonical: 'Segment Anything', mangled: 'segment any thing', type: 'product' });

  // 3. The SAME mangling now gets fixed — the loop is closed, and entitiesVersion advanced.
  const post = correct(
    [{ startMs: 0, endMs: 1000, text: 'We evaluated Segment Any Thing for masks.', speaker: 'me', label: 'Me' }],
    normalizeEntities(doc1),
  );
  assert.equal(post.segments[0].text, 'We evaluated Segment Anything for masks.', 'captured term now corrected');
  assert.notEqual(post.entitiesVersion, pre.entitiesVersion, 'entitiesVersion bumped by the capture');
});

// ---------------------------------------------------------------------------------------
group('coordination (P4) — one session per call, no double-capture, browser-crash failover');

const T = 2_000_000_000_000;
function liveExt({ id = 'ext-1', hb = T, hint = 'Google Chrome' } = {}) {
  return { sessionId: id, surface: 'chrome-extension', captureKind: CAPTURE_KIND.browserTab, processHint: hint, status: 'open', lastHeartbeat: hb };
}

test('preferenceRank: browser-tab (richest) > process > system (coverage net)', () => {
  assert.ok(preferenceRank(CAPTURE_KIND.browserTab) > preferenceRank(CAPTURE_KIND.process));
  assert.ok(preferenceRank(CAPTURE_KIND.process) > preferenceRank(CAPTURE_KIND.system));
});

test('scopesOverlap: all-system captures everything; a per-app scope only overlaps the same app', () => {
  assert.equal(scopesOverlap({ kind: CAPTURE_KIND.system }, { kind: CAPTURE_KIND.browserTab }), true);
  assert.equal(scopesOverlap({ kind: CAPTURE_KIND.system }, { kind: CAPTURE_KIND.process, processHint: 'zoom.us' }), true);
  assert.equal(scopesOverlap({ kind: CAPTURE_KIND.browserTab, processHint: 'Chrome' }, { kind: CAPTURE_KIND.process, processHint: 'zoom.us' }), false);
  assert.equal(scopesOverlap({ kind: CAPTURE_KIND.process, processHint: 'zoom.us' }, { kind: CAPTURE_KIND.process, processHint: 'zoom.us' }), true);
});

test('THE HANDSHAKE: a companion stands down while the extension owns the browser call (no double)', () => {
  const decision = decideClaim(
    { surface: 'desktop-companion-macos', sessionId: 'mac-1', captureKind: CAPTURE_KIND.system },
    [liveExt()],
    { now: T + 1000 },
  );
  assert.equal(decision.decision, 'stand-down');
  assert.equal(decision.conflictSessionId, 'ext-1');
  assert.equal(decision.excludeProcessHint, 'Google Chrome', 'hands back the browser process to exclude');
});

test('a companion OWNS a desktop-app call the extension is not capturing (no browser session live)', () => {
  const decision = decideClaim(
    { surface: 'desktop-companion-macos', sessionId: 'mac-2', captureKind: CAPTURE_KIND.process, processHint: 'zoom.us' },
    [liveExt()], // extension owns a browser tab — different app, no overlap
    { now: T + 1000 },
  );
  assert.equal(decision.decision, 'own');
});

test('a STALE extension session is not a live conflict — the companion may own', () => {
  const decision = decideClaim(
    { surface: 'desktop-companion-macos', sessionId: 'mac-3', captureKind: CAPTURE_KIND.system },
    [liveExt({ hb: T })],
    { now: T + 60000 }, // 60 s later: the extension session is stale
  );
  assert.equal(decision.decision, 'own');
});

test('the richer surface wins if it arrives late: extension supersedes a live all-system companion', () => {
  const liveMac = { sessionId: 'mac-4', surface: 'desktop-companion-macos', captureKind: CAPTURE_KIND.system, status: 'open', lastHeartbeat: T };
  const decision = decideClaim(
    { surface: 'chrome-extension', sessionId: 'ext-late', captureKind: CAPTURE_KIND.browserTab, processHint: 'Chrome' },
    [liveMac],
    { now: T + 1000 },
  );
  assert.equal(decision.decision, 'own');
  assert.deepEqual(decision.supersede, ['mac-4']);
});

test('FAILOVER: an interrupted browser call (crash) is promotable; a fresh one is not', () => {
  const now = T + 5000;
  const sessions = [
    { sessionId: 'ext-dead', surface: 'chrome-extension', captureKind: CAPTURE_KIND.browserTab, processHint: 'Chrome', status: 'interrupted', lastHeartbeat: T, hasTranscript: false },
    { sessionId: 'ext-live', surface: 'chrome-extension', captureKind: CAPTURE_KIND.browserTab, status: 'open', lastHeartbeat: now, hasTranscript: false },
  ];
  const promotable = findPromotable(sessions, { now });
  assert.equal(promotable.length, 1);
  assert.equal(promotable[0].sessionId, 'ext-dead');
  const ownership = buildPromotionOwnership({ deadSessionId: 'ext-dead', surface: 'desktop-companion-macos', processHint: 'Chrome' });
  assert.equal(ownership.supersedes, 'ext-dead');
  assert.equal(ownership.ownerSurface, 'desktop-companion-macos');
});

test('FAILOVER: a stale-open owner past the promote threshold is promotable; already-superseded is not', () => {
  const now = T + 20000;
  const sessions = [
    { sessionId: 'ext-hung', surface: 'chrome-extension', captureKind: CAPTURE_KIND.browserTab, status: 'open', lastHeartbeat: T, hasTranscript: false },
    { sessionId: 'ext-taken', surface: 'chrome-extension', captureKind: CAPTURE_KIND.browserTab, status: 'interrupted', lastHeartbeat: T, hasTranscript: false, supersededBy: 'mac-x' },
  ];
  const promotable = findPromotable(sessions, { now, promoteAfterMs: 12000 });
  assert.deepEqual(promotable.map((p) => p.sessionId), ['ext-hung']);
});

test('pipeline dedup backstop: two overlapping sessions keep the richer (captions) one', () => {
  const { keep, shadow } = dedupeOverlapping(
    [
      { sessionId: 'ext-rich', captureKind: CAPTURE_KIND.browserTab, captionCount: 12, startedAt: T, endedAt: T + 600000 },
      { sessionId: 'mac-plain', captureKind: CAPTURE_KIND.system, captionCount: 0, startedAt: T + 1000, endedAt: T + 600000 },
    ],
    { minOverlapMs: 30000 },
  );
  assert.deepEqual(keep, ['ext-rich']);
  assert.equal(shadow.length, 1);
  assert.equal(shadow[0].sessionId, 'mac-plain');
  assert.equal(shadow[0].preferredSessionId, 'ext-rich');
});

test('sessionDescriptor maps a companion record to a system-scope descriptor with its heartbeat', () => {
  const rec = {
    sessionId: 'mac-9', status: 'open', startedAt: T,
    capture: { source: 'desktop-companion-macos', captureTarget: 'system' },
    ownership: { ownerSurface: 'desktop-companion-macos', processHint: null },
  };
  const d = sessionDescriptor(rec, { lastHeartbeat: T + 3000, hasTranscript: false });
  assert.equal(d.captureKind, CAPTURE_KIND.system);
  assert.equal(d.surface, 'desktop-companion-macos');
  assert.equal(d.lastHeartbeat, T + 3000);
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
group('P5 model tiering — turbo default, guarded large-v3 opt-in, quantized/low-resource fallback');

test('the default tier is turbo (the benchmarked reliable model) when nothing is specified', () => {
  const t = resolveTier(null);
  assert.equal(t.name, DEFAULT_TIER);
  assert.equal(t.model, 'large-v3-turbo');
  assert.deepEqual(t.decodeArgs, []); // turbo needs no repetition-guard decode params
});

test('the "max" opt-in tier is full large-v3 and carries NO private decode params', () => {
  const t = resolveTier('max');
  assert.equal(t.model, 'large-v3');
  assert.ok(t.repetitionGuard === true);
  // -mc 0 used to live here and ONLY here, which is how the two shipping tiers ended up decoding
  // with full context carry-over and destroying up to 44.1% of a 92-minute channel (2026-08-29).
  // It is now a pipeline-wide invariant in whisperArgs, so this tier needs nothing of its own.
  assert.deepEqual(t.decodeArgs, []);
});

test('EVERY tier decodes with no previous-text conditioning — the loop fix cannot be tier-local', () => {
  // The invariant the old per-tier decodeArg failed to hold. It is asserted for every tier that
  // exists, not just the one that happened to carry the flag.
  for (const name of [...Object.keys(MODEL_TIERS), 'large-v3', 'large-v3-turbo', 'some-future-model']) {
    const t = resolveTier(name);
    const args = whisperArgs({ extraArgs: t.decodeArgs });
    const i = args.lastIndexOf('-mc');
    assert.ok(i >= 0, `${name}: -mc must be emitted`);
    assert.equal(args[i + 1], '0', `${name}: decode context must be 0, got ${args[i + 1]}`);
  }
});

test('a raw --model large-v3 is gated by the pipeline-wide cap, not by a per-model special case', () => {
  const t = resolveTier('large-v3');
  assert.equal(t.model, 'large-v3');
  const args = whisperArgs({ extraArgs: t.decodeArgs });
  assert.equal(args[args.lastIndexOf('-mc') + 1], '0', 'bare large-v3 must not run with context carry-over');
});

test('MAX_CONTEXT_TOKENS is overridable per call and by env, so an operator is never trapped', () => {
  assert.equal(whisperArgs({ maxContext: -1 })[whisperArgs({ maxContext: -1 }).lastIndexOf('-mc') + 1], '-1');
  const prev = process.env.RICHOS_WHISPER_MAX_CONTEXT;
  process.env.RICHOS_WHISPER_MAX_CONTEXT = '16';
  try {
    const a = whisperArgs();
    assert.equal(a[a.lastIndexOf('-mc') + 1], '16');
  } finally {
    if (prev === undefined) delete process.env.RICHOS_WHISPER_MAX_CONTEXT;
    else process.env.RICHOS_WHISPER_MAX_CONTEXT = prev;
  }
});

test('a tier decodeArg still wins over the default (emitted after, whisper-cli takes the last)', () => {
  const args = whisperArgs({ extraArgs: ['-mc', '224'] });
  assert.equal(args.lastIndexOf('-mc'), args.length - 2);
  assert.equal(args[args.length - 1], '224');
});

test('a raw --model large-v3-turbo stays clean (no guard decode params forced on the safe model)', () => {
  const t = resolveTier('large-v3-turbo');
  assert.deepEqual(t.decodeArgs, []);
});

test('low-resource + quantized tiers select smaller/quantized models for weak hosts', () => {
  assert.equal(MODEL_TIERS['low-resource'].model, 'small.en');
  assert.ok(/q\d/.test(MODEL_TIERS.quantized.model), 'quantized tier names a quantized .bin');
  assert.equal(resolveTier('quantized').model, 'large-v3-turbo-q5_0');
});

// ---------------------------------------------------------------------------------------
group('P5 repetition guard — the model-agnostic post-decode hallucination net');

// A fixture built from the REAL captured large-v3 hallucination (benchmark §4.2): the line looped 4x.
const LOOP_LINE = "I'll flag your account for the large V3 turbo batch tier, and it'll apply to you as well.";
const largeV3Hallucination = [
  { startMs: 0, endMs: 3000, text: 'Then turbo should serve you well.', speaker: 'others' },
  { startMs: 3000, endMs: 6000, text: LOOP_LINE, speaker: 'others' },
  { startMs: 6000, endMs: 9000, text: LOOP_LINE, speaker: 'others' },
  { startMs: 9000, endMs: 12000, text: LOOP_LINE, speaker: 'others' },
  { startMs: 12000, endMs: 15000, text: LOOP_LINE, speaker: 'others' },
  { startMs: 15000, endMs: 18000, text: 'apply starting with tonight\'s run.', speaker: 'others' },
];

test('the guard collapses the real large-v3 4x repetition loop to a single line', () => {
  const r = guardChannel(largeV3Hallucination);
  const loopCount = r.segments.filter((s) => s.text === LOOP_LINE).length;
  assert.equal(loopCount, 1, 'the 4 looped copies collapse to exactly one');
  assert.equal(r.removed, 3, 'three duplicate segments removed');
  assert.equal(r.loops.length, 1);
  assert.equal(r.loops[0].count, 4);
});

test('the collapsed loop keeps timing honest (first kept, end extended over the whole run)', () => {
  const r = guardChannel(largeV3Hallucination);
  const kept = r.segments.find((s) => s.text === LOOP_LINE);
  assert.equal(kept.startMs, 3000);
  assert.equal(kept.endMs, 15000, 'the kept segment spans the full looped interval (4 copies, last ends 15000)');
});

test('the guard preserves the surrounding legitimate speech byte-for-byte', () => {
  const r = guardChannel(largeV3Hallucination);
  assert.equal(r.segments[0].text, 'Then turbo should serve you well.');
  assert.equal(r.segments[r.segments.length - 1].text, "apply starting with tonight's run.");
});

test('the guard does NOT collapse short legitimate backchannels ("Yeah." "Yeah.")', () => {
  const back = [
    { startMs: 0, endMs: 500, text: 'Yeah.', speaker: 'me' },
    { startMs: 800, endMs: 1300, text: 'Yeah.', speaker: 'me' },
    { startMs: 2000, endMs: 2500, text: 'Yeah.', speaker: 'me' },
  ];
  const r = guardChannel(back);
  assert.equal(r.removed, 0, 'three short backchannels are legitimate, not a loop');
});

// ---------------------------------------------------------------------------------------
// THE PHYSICAL VETO. Fixtures are the REAL 2026-08-29 92-minute artifacts, not invented shapes:
// the retake is what large-v3-turbo actually emitted at 5502-5536 s on the `others` channel, and
// the bursts are what ffmpeg silencedetect actually measured on that same audio.
const RETAKE_LINE = 'Because before you commit to a rollout, you need to agree the metrics.';
const REAL_RETAKE_X3 = [
  { startMs: 5502400, endMs: 5509500, text: RETAKE_LINE, speaker: 'others' },
  { startMs: 5512300, endMs: 5517100, text: 'because before you commit to a rollout you need to agree the metrics', speaker: 'others' },
  { startMs: 5523300, endMs: 5536300, text: 'because before you commit to a rollout you need to agree the metrics', speaker: 'others' },
];
// Three separate bursts, each verified in the brief to independently decode to the whole sentence.
const REAL_RETAKE_BURSTS = [
  { startMs: 5502498, endMs: 5507510 },
  { startMs: 5512384, endMs: 5517062 },
  { startMs: 5523479, endMs: 5528128 },
];

test('the guard DELETES two genuine deliveries of a real 3x human retake when it is text-only', () => {
  // This is the defect, pinned. minRun:3 vs a human who delivers the same line three times running.
  const r = guardChannel(REAL_RETAKE_X3);
  assert.equal(r.removed, 2, 'text alone cannot tell this from a decoder loop — and it does not');
  assert.equal(r.loops.length, 1);
});

test('the physical veto PRESERVES that retake: three bursts, three deliveries, nothing removed', () => {
  const r = guardChannel(REAL_RETAKE_X3, { speechBursts: REAL_RETAKE_BURSTS });
  assert.equal(r.removed, 0, 'the audio holds a qualifying burst per repetition, so it is speech');
  assert.equal(r.loops.length, 0);
  assert.equal(r.segments.length, 3, 'all three genuine deliveries survive');
  assert.equal(r.preserved.length, 1);
  assert.equal(r.preserved[0].burstCapacity, 3);
});

test('the veto still collapses a fabrication over digital silence (no bursts, no capacity)', () => {
  // turbo emitted "Thank you." x7 at 4885-4915 s over a window measuring -51.3 dBFS. There is no
  // burst there at all, so capacity is 0 and the collapse stands.
  const line = 'Thank you very much indeed.';
  const overSilence = [0, 1, 2, 3, 4, 5, 6].map((i) => ({
    startMs: 4885200 + i * 4000, endMs: 4889200 + i * 4000, text: line, speaker: 'me',
  }));
  const r = guardChannel(overSilence, { speechBursts: [] });
  assert.equal(r.segments.filter((s) => s.text === line).length, 1, 'a loop over silence still collapses');
  assert.equal(r.removed, 6);
});

test('the veto collapses PARTIALLY when the audio holds some deliveries but not all', () => {
  // 5 emitted copies over 2 qualifying bursts -> keep 2, drop 3. Neither "delete it all" nor
  // "keep it all" is right when the audio says the truth is in between.
  const line = 'and the week later you get an update that sounds reassuring but changes nothing';
  const segs = [0, 1, 2, 3, 4].map((i) => ({
    startMs: 2142400 + i * 9600, endMs: 2152000 + i * 9600, text: line, speaker: 'others',
  }));
  const bursts = [{ startMs: 2142400, endMs: 2160000 }, { startMs: 2170000, endMs: 2190400 }];
  const r = guardChannel(segs, { speechBursts: bursts });
  assert.equal(r.segments.filter((s) => s.text === line).length, 2);
  assert.equal(r.removed, 3);
  assert.equal(r.loops[0].kept, 2);
  assert.equal(r.loops[0].burstCapacity, 2);
});

test('the veto is inert on short phrases, where a burst ceiling carries no signal', () => {
  // "Okay." fits in any burst; using capacity there would veto every short collapse. Documented
  // residual: a short genuine repetition can still be collapsed.
  const segs = [0, 1, 2, 3, 4, 5].map((i) => ({ startMs: i * 4000, endMs: i * 4000 + 3000, text: 'Okay.', speaker: 'me' }));
  const bursts = segs.map((s) => ({ startMs: s.startMs, endMs: s.endMs }));
  const withProbe = guardChannel(segs, { speechBursts: bursts });
  const without = guardChannel(segs);
  assert.equal(withProbe.removed, without.removed, 'short runs keep the old text-only behaviour');
});

test('the veto can only REFUSE a collapse, never cause one (strictly more conservative)', () => {
  // Burst capacity is a ceiling, not proof of delivery, so adding the probe must never remove more.
  for (const fixture of [largeV3Hallucination, REAL_RETAKE_X3]) {
    for (const bursts of [[], REAL_RETAKE_BURSTS, [{ startMs: 0, endMs: 60000 }]]) {
      const withProbe = guardChannel(fixture, { speechBursts: bursts });
      const without = guardChannel(fixture);
      assert.ok(withProbe.removed <= without.removed,
        `probe removed ${withProbe.removed} > text-only ${without.removed}`);
    }
  }
});

test('guardTranscription routes each channel its OWN bursts (never the other channel\'s)', () => {
  const r = guardTranscription(
    { me: largeV3Hallucination.map((s) => ({ ...s, speaker: 'me' })), others: REAL_RETAKE_X3 },
    { speechBursts: { me: [], others: REAL_RETAKE_BURSTS } },
  );
  assert.equal(r.others.length, 3, 'the retake survives on `others` (its own bursts back it)');
  assert.equal(r.me.filter((s) => s.text === LOOP_LINE).length, 1, 'the loop still collapses on `me`');
  assert.equal(r.report.classes.preservedByAudio, 1);
});

test('parseSilenceLog turns silencedetect output into speech bursts (the complement)', () => {
  const log = [
    '  Duration: 00:00:30.00, start: 0.000000, bitrate: 256 kb/s',
    '[silencedetect @ 0x1] silence_start: 5',
    '[silencedetect @ 0x1] silence_end: 10 | silence_duration: 5',
    '[silencedetect @ 0x1] silence_start: 20',
  ].join('\n');
  const r = parseSilenceLog(log);
  assert.equal(r.durationSec, 30);
  assert.deepEqual(r.speech, [{ startMs: 0, endMs: 5000 }, { startMs: 10000, endMs: 20000 }]);
  // a trailing silence_start with no silence_end runs to the end of the file, not to infinity
  assert.deepEqual(r.silence[r.silence.length - 1], { startMs: 20000, endMs: 30000 });
});

test('burstCapacity counts only bursts long enough to hold the phrase, clipped to the span', () => {
  const bursts = [{ startMs: 0, endMs: 5000 }, { startMs: 6000, endMs: 6500 }, { startMs: 8000, endMs: 13000 }];
  assert.equal(burstCapacity(bursts, 0, 20000, 3, 1), 2, '0.5 s burst cannot hold a 3 s phrase');
  assert.equal(burstCapacity(bursts, 0, 20000, 10, 1), 0, 'nothing holds a 10 s phrase');
  assert.equal(burstCapacity(bursts, 0, 5000, 3, 1), 1, 'bursts outside the span do not count');
  assert.equal(burstCapacity(null, 0, 20000, 1, 1), 0, 'no probe means no capacity, never a veto');
});

test('the guard does not touch a clean transcript (zero false positives on turbo output)', () => {
  const clean = [
    { startMs: 0, endMs: 2000, text: 'Hi Marcus, thanks for joining.', speaker: 'me' },
    { startMs: 2000, endMs: 5000, text: 'Happy to be on. Let us get started.', speaker: 'others' },
  ];
  const r = guardTranscription({ me: [clean[0]], others: [clean[1]] });
  assert.equal(r.report.removed, 0);
  assert.equal(r.report.detected, false);
});

test('guardTranscription reports per-channel loop findings for verification.json', () => {
  const r = guardTranscription({ me: [], others: largeV3Hallucination });
  assert.equal(r.report.detected, true);
  assert.equal(r.report.removed, 3);
  assert.equal(r.report.byChannel.others.loops, 1);
  assert.equal(r.report.loops[0].channel, 'others');
});

// ---------------------------------------------------------------------------------------
group('P5 hallucination guard, class 2 — PERSISTENT INSERTION (the real large-v3-turbo artifact)');

// Every fixture in this group is verbatim captured whisper.cpp output; see
// test/fixtures/captured-hallucinations.js for the sha256 of each source JSON.
const flat = (segs) => segs.map((s) => s.text).join('');

test('readEnumerationMarker reads a bare segment-initial ordinal and leaves real numbers alone', () => {
  assert.equal(readEnumerationMarker(' 12. Two small things.').value, 12);
  assert.equal(readEnumerationMarker(' 3) The runbook now links the dashboard.').value, 3);
  assert.equal(readEnumerationMarker(' 3.0.2 shipped last week.'), null, 'a version number is not a marker');
  assert.equal(readEnumerationMarker(' 9 cents. That tier starts at 25,000.'), null, 'no separator, no marker');
  assert.equal(readEnumerationMarker(' 21%. Yes.'), null, 'a percentage is not a marker');
  assert.equal(readEnumerationMarker(' 2.7.4'), null);
});

test('the guard DETECTS the real 59-marker turbo fabrication the 2026-08-26 benchmark found blind', () => {
  const r = guardInsertions(TURBO_NUMERAL_INSERTION);
  assert.equal(r.insertions.length, 1, 'the fabricated span is reported as one finding');
  assert.equal(r.stats.markerSegments, 59, '59 of 88 segments carry a leading ordinal (brief §6.3)');
  assert.equal(r.stats.channelSegments, 88);
  assert.ok(r.stats.spanDensity > 0.9, `markers dominate their own span (${r.stats.spanDensity})`);
  assert.equal(r.stats.maxRepeat, 13, 'the fabricated ordinal stalls on "12." for 13 consecutive segments');
  assert.equal(r.insertions[0].startMs, 171500);
  assert.equal(r.insertions[0].endMs, 615140);
});

test('the fabricated span is bounded by the FIRST well-formedness break, so the real "1." "3." list survives', () => {
  const r = guardInsertions(TURBO_NUMERAL_INSERTION);
  const f = r.insertions[0];
  assert.deepEqual(f.genuinePrefix, ['1.', '3.'], 'the speaker really did enumerate two items here');
  assert.equal(f.count, 57, '57 of the 59 markers are judged fabricated, not all 59');
  assert.equal(f.firstIndex, 20, 'the fabrication is dated from the first stall, not from the first marker');
});

test('detection NEVER rewrites the transcript — not one character of the 88 segments moves', () => {
  const r = guardInsertions(TURBO_NUMERAL_INSERTION);
  assert.equal(flat(r.segments), flat(TURBO_NUMERAL_INSERTION));
  assert.equal(r.stripped, 0);
});

// This test exists to DOCUMENT why the remedy is detect-only, not to endorse the opt-in.
test('opting into stripping would delete a real word: the speaker\'s "Zero." at 205.3 s', () => {
  const before = TURBO_NUMERAL_INSERTION.find((s) => s.startMs === 205260);
  assert.ok(before.text.startsWith(' 0. We ran a full checksum comparison'), 'the captured segment');
  const r = guardInsertions(TURBO_NUMERAL_INSERTION, { stripInsertions: true });
  assert.equal(r.stripped, 57);
  const after = r.segments.find((s) => s.startMs === 205260);
  assert.ok(!/\b0\b/.test(after.text.slice(0, 6)), 'the marker is gone');
  // The reference says: "Any data loss?" / "Zero. We ran a full checksum comparison..."
  assert.ok(after.text.trim().startsWith('We ran a full checksum'), 'and so is the answer the speaker gave');
});

test('POSITIVE CONTROL for the negatives below: the same detector fires on the artifact', () => {
  assert.equal(guardInsertions(TURBO_NUMERAL_INSERTION).insertions.length, 1);
});

test('SILENT on real speech carrying the same surface feature — a genuinely spoken "1. 2. 3." list', () => {
  // large-v3-turbo on the CLEAN sample B: " 3. We added a synthetic canary job…" is a legitimate
  // segment-initial ordinal, byte-identical in surface form to the fabricated ones.
  assert.ok(
    GENUINE_SPOKEN_ENUMERATION.some((s) => /^\s*3\.\s/.test(s.text)),
    'the control really does contain the surface feature',
  );
  const r = guardInsertions(GENUINE_SPOKEN_ENUMERATION);
  assert.equal(r.insertions.length, 0);
  assert.equal(flat(r.segments), flat(GENUINE_SPOKEN_ENUMERATION));
});

test('SILENT on the q5_0 transcript of the identical audio that produced the artifact', () => {
  const r = guardInsertions(Q5_SAME_AUDIO_CLEAN);
  assert.equal(r.insertions.length, 0);
  assert.equal(r.stats.markerSegments, 0);
});

test('SILENT on a long, well-formed spoken enumeration — counting up, each number used once', () => {
  // CONSTRUCTED control (no captured instance exists): a person reading a 12-item numbered agenda,
  // 100% marker density. Well-formed, so the guard must not touch it however dense it gets.
  const agenda = Array.from({ length: 12 }, (_, i) => ({
    startMs: i * 5000,
    endMs: i * 5000 + 4000,
    text: ` ${i + 1}. Agenda item number ${i + 1}, which we should cover today.`,
    speaker: 'me',
  }));
  const r = guardInsertions(agenda);
  assert.equal(r.stats.markerSegments, 12);
  assert.equal(r.stats.spanDensity, 1, 'maximum possible density');
  assert.equal(r.insertions.length, 0, 'density alone never fires — well-formedness is the discriminator');
});

test('SILENT on a spoken enumeration with ONE hiccup (a speaker repeating or going back a number)', () => {
  // CONSTRUCTED control: real speakers do lose their place once. One violation is not a fabrication.
  const list = [1, 2, 3, 3, 4, 5, 6, 7, 8, 9].map((v, i) => ({
    startMs: i * 5000,
    endMs: i * 5000 + 4000,
    text: ` ${v}. The next thing on the list that I wanted to raise with you.`,
    speaker: 'me',
  }));
  const r = guardInsertions(list);
  assert.equal(r.stats.violations, 1);
  assert.equal(r.insertions.length, 0, 'one stall is a person, thirteen is a decoder');
});

test('a segment that is ONLY a numeral is a person counting, never a prefix insertion', () => {
  const counting = Array.from({ length: 10 }, (_, i) => ({
    startMs: i * 2000,
    endMs: i * 2000 + 1500,
    text: ` ${(i % 3) + 1}.`,
    speaker: 'me',
  }));
  const r = guardInsertions(counting);
  assert.equal(r.stats.markerSegments, 0, 'nothing was prefixed ONTO anything');
  assert.equal(r.insertions.length, 0);
});

// ---------------------------------------------------------------------------------------
group('P5 hallucination guard, class 3 — SLIDING-OVERLAP STUTTER (the real large-v3 artifact)');

test('the guard DETECTS the real large-v3 sliding stutter the loop detector could only see 6 of', () => {
  const r = guardOverlapStutter(LARGE_V3_SLIDING_STUTTER);
  assert.ok(r.stutters.length >= 1, 'the stutter is reported');
  const chain = r.stutters[0];
  assert.ok(chain.links >= 30, `a long chain of overlapping boundaries, not one restart (${chain.links})`);
  assert.ok(chain.maxOverlapWords >= 7, 'whole phrases re-emitted, not a shared article');
  assert.equal(chain.kind, 'sliding-overlap');
});

test('the de-overlap is CONTENT-PRESERVING — every distinct word survives, just once', () => {
  const r = guardOverlapStutter(LARGE_V3_SLIDING_STUTTER);
  const words = (segs) =>
    segs
      .map((s) => s.text.toLowerCase())
      .join(' ')
      .match(/[a-z0-9']+/g) || [];
  const before = new Set(words(LARGE_V3_SLIDING_STUTTER));
  const after = new Set(words(r.segments));
  const lost = [...before].filter((w) => !after.has(w));
  assert.deepEqual(lost, [], 'no word present in the artifact is missing from the repair');
  assert.ok(words(r.segments).length < words(LARGE_V3_SLIDING_STUTTER).length * 0.65, 'the doubling is gone');
});

test('the repaired stream reads once, not two or three times (the captured phrase, verbatim)', () => {
  const r = guardOverlapStutter(LARGE_V3_SLIDING_STUTTER);
  const raw = flat(LARGE_V3_SLIDING_STUTTER);
  const fixed = flat(r.segments);
  const phrase = 'the cloud vendors sell as a premium';
  const count = (h, n) => h.split(n).length - 1;
  assert.equal(count(raw, phrase), 3, 'the artifact emits it three times');
  assert.equal(count(fixed, phrase), 1, 'the repair emits it once');
});

test('dropping a re-emitted segment folds its time into the kept one (timing/coverage stay honest)', () => {
  const r = guardOverlapStutter(LARGE_V3_SLIDING_STUTTER);
  const inSpan = (segs) => Math.max(...segs.map((s) => s.endMs)) - Math.min(...segs.map((s) => s.startMs));
  assert.equal(inSpan(r.segments), inSpan(LARGE_V3_SLIDING_STUTTER), 'the channel still spans the same audio');
});

test('SILENT on real clean speech — 18 captured clean transcripts share ZERO boundary words', () => {
  const r = guardOverlapStutter(CLEAN_NO_BOUNDARY_OVERLAP);
  assert.equal(r.stutters.length, 0);
  assert.equal(r.removed, 0);
  assert.equal(flat(r.segments), flat(CLEAN_NO_BOUNDARY_OVERLAP));
});

test('SILENT on a speaker genuinely repeating a phrase across ONE segment boundary', () => {
  // CONSTRUCTED control (the captured corpus contains no such case): a real restart is one link.
  const restart = [
    { startMs: 0, endMs: 3000, text: ' so what I would suggest is we push the migration', speaker: 'me' },
    { startMs: 3000, endMs: 6000, text: ' we push the migration to the following Tuesday', speaker: 'me' },
    { startMs: 6000, endMs: 9000, text: ' and tell procurement on the Monday.', speaker: 'me' },
  ];
  const r = guardOverlapStutter(restart);
  assert.equal(r.stutters.length, 0, 'one overlapping boundary is a person, not a decoder');
  assert.equal(flat(r.segments), flat(restart));
});

test('SILENT at two consecutive overlapping boundaries — the chain floor is three', () => {
  // CONSTRUCTED control: the deliberate precision/recall line. A 2-link stutter goes undetected;
  // that is a stated blind spot, chosen over risking a real speaker's repeated phrase.
  const two = [
    { startMs: 0, endMs: 3000, text: ' I said we would send the deck on Thursday', speaker: 'me' },
    { startMs: 3000, endMs: 6000, text: ' send the deck on Thursday and the tier table', speaker: 'me' },
    { startMs: 6000, endMs: 9000, text: ' and the tier table with it', speaker: 'me' },
  ];
  const r = guardOverlapStutter(two);
  assert.equal(r.stutters.length, 0);
  assert.equal(flat(r.segments), flat(two));
});

test('collapseStutter:false keeps detection while leaving the text untouched', () => {
  const r = guardOverlapStutter(LARGE_V3_SLIDING_STUTTER, { collapseStutter: false });
  assert.ok(r.stutters.length >= 1);
  assert.equal(r.removed, 0);
  assert.equal(flat(r.segments), flat(LARGE_V3_SLIDING_STUTTER));
});

// ---------------------------------------------------------------------------------------
group('P5 hallucination guard — all three classes through the one pipeline seam');

test('guardTranscription reports the insertion class from the real turbo artifact', () => {
  const r = guardTranscription({ me: [], others: TURBO_NUMERAL_INSERTION });
  assert.equal(r.report.detected, true);
  assert.equal(r.report.classes.insertion, 1);
  assert.equal(r.report.classes.repetition, 0);
  assert.equal(r.report.classes.overlapStutter, 0);
  assert.equal(r.report.byChannel.others.insertions, 1);
  assert.equal(r.report.insertions[0].channel, 'others');
  assert.equal(r.report.removed, 0, 'the insertion class removes nothing');
});

test('guardTranscription reports the stutter class from the real large-v3 artifact', () => {
  const r = guardTranscription({ me: LARGE_V3_SLIDING_STUTTER, others: [] });
  assert.equal(r.report.detected, true);
  assert.ok(r.report.classes.overlapStutter >= 1);
  assert.ok(r.report.removed > 0);
  assert.equal(r.report.stutters[0].channel, 'me');
});

test('the loop class still reports exactly as before (no regression in class 1)', () => {
  const r = guardTranscription({ me: [], others: largeV3Hallucination });
  assert.equal(r.report.classes.repetition, 1);
  assert.equal(r.report.removed, 3);
  assert.equal(r.report.loops[0].count, 4);
});

test('all three real captured CLEAN channels stay untouched and undetected', () => {
  for (const [name, fixture] of [
    ['q5 on the noisy sample', Q5_SAME_AUDIO_CLEAN],
    ['turbo on the clean sample, genuine enumeration', GENUINE_SPOKEN_ENUMERATION],
    ['turbo, mid-call', CLEAN_NO_BOUNDARY_OVERLAP],
  ]) {
    const r = guardTranscription({ me: [], others: fixture });
    assert.equal(r.report.detected, false, `${name} must not trip any class`);
    assert.equal(r.report.removed, 0, name);
    assert.equal(flat(r.others), flat(fixture), `${name} is byte-identical after the guard`);
  }
});

test('a DETECTED-BUT-UNREPAIRED class becomes a plain-English verification warning (never silent)', () => {
  const r = guardTranscription({ me: [], others: TURBO_NUMERAL_INSERTION });
  const w = guardWarnings(r.report);
  assert.equal(w.length, 1);
  assert.ok(/STILL IN the transcript/.test(w[0]), 'it says the fabricated text was NOT removed');
  assert.ok(/re-transcribe/.test(w[0]), 'and names the remedy');
  assert.ok(/57 fabricated/.test(w[0]) && /"others" channel/.test(w[0]));
});

test('a REPAIRED class produces no warning — the transcript no longer contains it', () => {
  const loop = guardTranscription({ me: [], others: largeV3Hallucination });
  assert.deepEqual(guardWarnings(loop.report), []);
  const stutter = guardTranscription({ me: LARGE_V3_SLIDING_STUTTER, others: [] });
  assert.deepEqual(guardWarnings(stutter.report), []);
});

test('guardChannelAll runs loops before insertions before overlap so classes cannot mask each other', () => {
  const r = guardChannelAll(TURBO_NUMERAL_INSERTION);
  assert.equal(r.insertions.length, 1);
  assert.equal(r.loops.length, 0);
  assert.equal(r.stutters.length, 0, 'a leading marker must not be mistaken for a boundary overlap');
});

// ---------------------------------------------------------------------------------------
group('P5 diarization seam — honest scope (default off; opt-in tinydiarize turn segmentation)');

test('default method "none" is identity — one "Them", no wrong speaker counts', () => {
  const segs = [
    { startMs: 0, endMs: 2000, text: 'first remote line', speaker: 'others' },
    { startMs: 2000, endMs: 4000, text: 'second remote line', speaker: 'others' },
  ];
  const d = diarizeOthers(segs);
  assert.equal(d.method, 'none');
  assert.equal(d.speakerCount, 1);
  assert.ok(d.segments.every((s) => s.diarizedLabel === undefined), 'no per-turn labels when off');
});

test('readTurn strips the whisper.cpp tinydiarize marker and flags the turn', () => {
  const r = readTurn({ text: `okay let me hand over ${SPEAKER_TURN_MARKER}`, speaker: 'others' });
  assert.equal(r.turned, true);
  assert.ok(!r.text.includes('[SPEAKER'), 'the marker is stripped from the rendered text');
  assert.equal(r.text, 'okay let me hand over');
});

test('tinydiarize-turns splits the RIGHT channel at native turn markers into sequential remotes', () => {
  const segs = [
    { startMs: 0, endMs: 2000, text: `Alice speaking here ${SPEAKER_TURN_MARKER}`, speaker: 'others' },
    { startMs: 2000, endMs: 4000, text: 'now Bob replies', speaker: 'others', speakerTurn: true },
    { startMs: 4000, endMs: 6000, text: 'and a third voice', speaker: 'others' },
  ];
  const d = diarizeOthers(segs, { method: 'tinydiarize-turns' });
  assert.equal(d.method, 'tinydiarize-turns');
  assert.equal(d.identityStable, false, 'turn segmentation is honestly not stable identity');
  assert.equal(d.segments[0].diarizedLabel, 'Remote 1');
  assert.equal(d.segments[1].diarizedLabel, 'Remote 2');
  assert.equal(d.segments[2].diarizedLabel, 'Remote 3');
  assert.equal(d.turns, 3);
});

test('a caption NAME still wins over a diarized turn label in the merge', () => {
  const others = diarizeOthers(
    [{ startMs: 2500, endMs: 5500, text: 'hello, thanks for joining', speaker: 'others' }],
    { method: 'tinydiarize-turns' },
  ).segments;
  const merged = mergeTranscript({ me: [], others, captions, startedAt: T0 });
  assert.ok(merged.speakers.includes('Marcus Whitfield'), 'the real caption name beats "Remote 1"');
  assert.ok(!merged.speakers.includes('Remote 1'));
});

test('with no caption, the diarized turn label fills the gap (better than generic "Them")', () => {
  const others = diarizeOthers(
    [{ startMs: 0, endMs: 2000, text: 'unnamed remote speaker', speaker: 'others' }],
    { method: 'tinydiarize-turns' },
  ).segments;
  const merged = mergeTranscript({ me: [], others, captions: [], startedAt: T0 });
  assert.ok(merged.speakers.includes('Remote 1'));
});

// ---------------------------------------------------------------------------------------
console.log(`\n${passed} passed, ${failures.length} failed`);
if (failures.length) {
  console.error('\nFAILURES:');
  for (const f of failures) console.error(`- ${f.name}: ${f.err.stack}`);
  process.exit(1);
}
