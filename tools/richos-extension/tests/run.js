#!/usr/bin/env node
/**
 * RichOS extension — pure-logic test harness. No dependencies, no browser.
 *
 *   node tests/run.js
 *
 * Everything that decides whether the CEO is alarmed lives in pure modules precisely so it
 * can be tested here, deterministically, with a fake clock. Test names document the
 * invariant they protect.
 */

import assert from 'node:assert/strict';
import { detectPlatform, shouldAutoArm, isCallTab } from '../modules/call-capture/platforms.js';
import { newCaptureState, applyHeartbeat, evaluateHealth, badgeTextFor } from '../modules/call-capture/health.js';
import { THRESHOLDS, ACTIONS, CAPTURE_DEFAULTS } from '../modules/call-capture/constants.js';
import {
  stampFor,
  sessionDirName,
  newSessionRecord,
  verifySession,
  accrueHealth,
} from '../modules/call-capture/session.js';
import { safeName, dropPath } from '../core/output.js';
import { CORE_DEFAULTS } from '../core/constants.js';
import { CaptionAggregator } from '../modules/call-capture/captions/caption-dedup.js';
import { analyzeSession } from '../sync/reconcile.js';
import { extractCaptionRows } from '../modules/call-capture/captions/meet.js';

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

function group(title) {
  console.log(`\n${title}`);
}

const T0 = 1_700_000_000_000;

// ---------------------------------------------------------------------------------------
group('platform detection');

test('recognises a Google Meet meeting URL but not the Meet home page', () => {
  assert.equal(detectPlatform('https://meet.google.com/abc-defg-hij')?.id, 'meet');
  assert.equal(detectPlatform('https://meet.google.com/abc-defg-hij?hs=1')?.id, 'meet');
  assert.equal(detectPlatform('https://meet.google.com/'), null);
});

test('recognises the Zoom web client and extracts the meeting number', () => {
  const zoom = detectPlatform('https://us02web.zoom.us/wc/81234567890/join');
  assert.equal(zoom?.id, 'zoom-web');
  assert.equal(zoom?.slug, '81234567890');
});

test('recognises Teams web meetings and Whereby rooms', () => {
  assert.equal(detectPlatform('https://teams.microsoft.com/v2/?meetingjoin=true')?.id, 'teams-web');
  assert.equal(detectPlatform('https://teams.live.com/l/meetup-join/xyz')?.id, 'teams-web');
  assert.equal(detectPlatform('https://whereby.com/richos-room')?.id, 'whereby');
});

test('ignores non-call pages and malformed URLs', () => {
  assert.equal(detectPlatform('https://news.ycombinator.com/'), null);
  assert.equal(detectPlatform('not a url'), null);
  assert.equal(detectPlatform('chrome://extensions'), null);
});

test('Slack/Discord/Webex only count as calls once the tab is actually making sound', () => {
  const slackUrl = 'https://app.slack.com/client/T1/C1';
  assert.equal(detectPlatform(slackUrl)?.requiresAudible, true);
  assert.equal(isCallTab({ url: slackUrl, audible: false }), false);
  assert.equal(isCallTab({ url: slackUrl, audible: true }), true);
});

group('auto-arm decisions');

const armSettings = { ...CAPTURE_DEFAULTS };

test('a recognised call URL arms even before any audio (a silent lobby must not be missed)', () => {
  const decision = shouldAutoArm(
    { url: 'https://meet.google.com/abc-defg-hij', audible: false, openedAt: T0 - 5000 },
    armSettings,
    T0,
  );
  assert.equal(decision.arm, true);
  assert.equal(decision.reason, 'known-platform');
});

test('the arm delay is respected so a page that is merely loading is not armed', () => {
  const decision = shouldAutoArm(
    { url: 'https://meet.google.com/abc-defg-hij', audible: false, openedAt: T0 - 500 },
    armSettings,
    T0,
  );
  assert.equal(decision.arm, false);
  assert.equal(decision.reason, 'arm-delay');
});

test('manual mode never auto-arms', () => {
  const decision = shouldAutoArm(
    { url: 'https://meet.google.com/abc-defg-hij', audible: true, openedAt: T0 - 60000 },
    { ...armSettings, armMode: 'manual' },
    T0,
  );
  assert.equal(decision.arm, false);
});

test('unknown audible tabs arm only when the CEO opted in', () => {
  const tab = { url: 'https://example.com/webinar', audible: true, openedAt: T0 - 60000 };
  assert.equal(shouldAutoArm(tab, armSettings, T0).arm, false);
  assert.equal(shouldAutoArm(tab, { ...armSettings, armUnknownAudible: true }, T0).arm, true);
});

// ---------------------------------------------------------------------------------------
group('health evaluation — the in-call guarantee');

/** @returns {import('../modules/call-capture/health.js').CaptureState} */
function healthyState(now = T0) {
  const state = newCaptureState({ sessionId: 's', startedAt: now - 60000, micEnabled: true });
  applyHeartbeat(state, {
    t: now,
    micRms: 0.02,
    tabRms: 0.03,
    recorderState: 'recording',
    chunkCount: 20,
    bytesTotal: 200000,
    lastChunkAt: now - 1000,
    micTrack: { readyState: 'live', muted: false },
    tabTrack: { readyState: 'live', muted: false },
  });
  return state;
}

test('a healthy session is green with no recovery actions', () => {
  const result = evaluateHealth(healthyState(), T0);
  assert.equal(result.level, 'green');
  assert.deepEqual(result.actions, []);
});

test('the first 20 seconds without a chunk are amber (warm-up), not a false alarm', () => {
  const state = newCaptureState({ sessionId: 's', startedAt: T0 - 5000 });
  applyHeartbeat(state, { t: T0, recorderState: 'recording', micRms: 0.01, tabRms: 0.01 });
  const result = evaluateHealth(state, T0);
  assert.equal(result.level, 'amber');
  assert.ok(result.reasons.some((r) => r.code === 'warming-up'));
});

test('armed but never received one byte of audio => RED plus a recorder restart', () => {
  const state = newCaptureState({ sessionId: 's', startedAt: T0 - (THRESHOLDS.warmupMs + 1000) });
  applyHeartbeat(state, { t: T0, recorderState: 'recording', micRms: 0.01, tabRms: 0.01 });
  const result = evaluateHealth(state, T0);
  assert.equal(result.level, 'red');
  assert.ok(result.reasons.some((r) => r.code === 'no-audio-ever'));
  assert.ok(result.actions.includes(ACTIONS.restartRecorder));
});

test('audio stops arriving => amber at 7s, red with a restart by 15s', () => {
  const amberState = healthyState();
  amberState.lastChunkAt = T0 - 8000;
  amberState.bytesGrewAt = T0 - 8000;
  amberState.lastHeartbeatAt = T0;
  assert.equal(evaluateHealth(amberState, T0).level, 'amber');

  const redState = healthyState();
  redState.lastChunkAt = T0 - 16000;
  redState.bytesGrewAt = T0 - 16000;
  redState.lastHeartbeatAt = T0;
  const red = evaluateHealth(redState, T0);
  assert.equal(red.level, 'red');
  assert.ok(red.reasons.some((r) => r.code === 'audio-stalled'));
  assert.ok(red.actions.includes(ACTIONS.restartRecorder));
});

test('chunks that keep arriving but never grow the file are caught (the nastiest silent failure)', () => {
  const state = healthyState();
  state.lastChunkAt = T0 - 1000;
  state.bytesGrewAt = T0 - 20000;
  const result = evaluateHealth(state, T0);
  assert.equal(result.level, 'red');
  assert.ok(result.reasons.some((r) => r.code === 'audio-not-growing'));
});

test('a silent recorder document is red and asks for a rebuild, and other signals are not guessed at', () => {
  const state = healthyState();
  state.lastHeartbeatAt = T0 - 20000;
  const result = evaluateHealth(state, T0);
  assert.equal(result.level, 'red');
  assert.deepEqual(result.actions, [ACTIONS.recreateOffscreen]);
  assert.equal(result.reasons.length, 1, 'stale signals must not be reported as if they were fresh');
});

test('an ended tab stream asks for re-attach; an ended mic stream asks for re-acquire', () => {
  const tabDead = healthyState();
  tabDead.tabTrack = { readyState: 'ended', muted: false };
  assert.ok(evaluateHealth(tabDead, T0).actions.includes(ACTIONS.reattachTab));

  const micDead = healthyState();
  micDead.micTrack = { readyState: 'ended', muted: false };
  assert.ok(evaluateHealth(micDead, T0).actions.includes(ACTIONS.reacquireMic));
});

test('exact digital silence on the microphone is red (device switched / muted at the OS)', () => {
  const state = healthyState();
  state.micNonZeroAt = T0 - (THRESHOLDS.digitalSilenceRedMs + 1000);
  const result = evaluateHealth(state, T0);
  assert.equal(result.level, 'red');
  assert.ok(result.reasons.some((r) => r.code === 'mic-digital-silence'));
  assert.ok(result.actions.includes(ACTIONS.reacquireMic));
});

test('a suspended audio graph is red — it would record perfect silence while looking healthy', () => {
  const state = healthyState();
  state.ctxState = 'suspended';
  const result = evaluateHealth(state, T0);
  assert.equal(result.level, 'red');
  assert.ok(result.reasons.some((r) => r.code === 'audio-graph-not-running'));
  assert.ok(result.actions.includes(ACTIONS.restartRecorder));
});

test('nobody talking is amber, never red, and never triggers recovery', () => {
  const state = healthyState();
  state.micSpeechAt = T0 - (THRESHOLDS.quietAmberMs + 5000);
  state.tabSpeechAt = T0 - (THRESHOLDS.quietAmberMs + 5000);
  const result = evaluateHealth(state, T0);
  assert.equal(result.level, 'amber');
  assert.ok(result.reasons.some((r) => r.code === 'no-speech'));
  assert.deepEqual(result.actions, []);
});

test('microphone-only failover stays visibly degraded for the whole call', () => {
  const state = healthyState();
  state.micOnlyFailover = true;
  const result = evaluateHealth(state, T0);
  assert.equal(result.level, 'amber');
  assert.ok(result.reasons.some((r) => r.code === 'mic-only-failover'));
});

test('applyHeartbeat only advances the growth clock when bytes actually increased', () => {
  const state = newCaptureState({ sessionId: 's', startedAt: T0 });
  applyHeartbeat(state, { t: T0 + 1000, bytesTotal: 100 });
  assert.equal(state.bytesGrewAt, T0 + 1000);
  applyHeartbeat(state, { t: T0 + 2000, bytesTotal: 100 });
  assert.equal(state.bytesGrewAt, T0 + 1000);
});

test('badge text is short enough for the action badge', () => {
  for (const level of ['green', 'amber', 'red', 'idle']) {
    assert.ok(badgeTextFor(level).length <= 4);
  }
});

// ---------------------------------------------------------------------------------------
group('session records — a lost call is present on disk, not absent');

test('session directory names are portable (no colons) and carry time, platform and slug', () => {
  const dir = sessionDirName({ startedAt: T0, platformId: 'meet', slug: 'abc-defg-hij' });
  assert.ok(!dir.includes(':'), 'colons are illegal in Windows filenames');
  assert.match(dir, /^\d{4}-\d{2}-\d{2}T\d{2}-\d{2}-\d{2}Z--meet--abc-defg-hij$/);
  assert.equal(stampFor(T0).includes(':'), false);
});

test('a session record is born OPEN so a call that captured nothing is a loud anomaly', () => {
  const record = newSessionRecord({
    startedAt: T0,
    platform: { id: 'meet', label: 'Google Meet', slug: 'abc-defg-hij' },
    tabId: 7,
    url: 'https://meet.google.com/abc-defg-hij',
    extensionVersion: '0.1.0',
    settings: CAPTURE_DEFAULTS,
  });
  assert.equal(record.status, 'open');
  assert.equal(record.audio.parts.length, 0);
  assert.equal(record.capture.channels.left, 'microphone (me)');
  const verdict = verifySession({ ...record, endedAt: T0 + 60000 });
  assert.equal(verdict.ok, false);
  assert.ok(verdict.problems.some((p) => /no audio parts/.test(p)));
  assert.ok(verdict.problems.some((p) => /never closed/.test(p)));
});

test('a session that recorded real audio and closed cleanly verifies OK', () => {
  const record = newSessionRecord({
    startedAt: T0,
    platform: { id: 'meet', label: 'Google Meet', slug: 'abc-defg-hij' },
    tabId: 7,
    extensionVersion: '0.1.0',
    settings: CAPTURE_DEFAULTS,
  });
  record.status = 'closed';
  record.endedAt = T0 + 1800000;
  record.audio = { parts: [{ part: 0, bytes: 21000000, chunks: 600 }], bytesTotal: 21000000, chunkCount: 600 };
  const verdict = verifySession(record);
  assert.equal(verdict.ok, true, verdict.problems.join('; '));
  assert.equal(verdict.durationSeconds, 1800);
});

test('any second spent red is remembered in the session record', () => {
  const record = newSessionRecord({
    startedAt: T0,
    platform: { id: 'meet', label: 'Google Meet', slug: 'x' },
    tabId: 1,
    extensionVersion: '0.1.0',
    settings: CAPTURE_DEFAULTS,
  });
  accrueHealth(record, { level: 'green' });
  accrueHealth(record, { level: 'red' });
  accrueHealth(record, { level: 'amber' });
  assert.equal(record.health.redSeconds, 1);
  assert.equal(record.health.worstLevel, 'red');
  record.status = 'closed';
  record.endedAt = T0 + 600000;
  record.audio = { parts: [{ part: 0, bytes: 5000000, chunks: 100 }], bytesTotal: 5000000, chunkCount: 100 };
  assert.equal(verifySession(record).ok, false, 'a red second must make the session suspect');
});

group('drop-zone paths');

test('path components are made safe for every OS Chrome runs on', () => {
  assert.equal(safeName('2026-08-23T14:05:02Z'), '2026-08-23T14-05-02Z');
  assert.equal(safeName('../../etc/passwd'), 'etc-passwd');
  assert.equal(safeName('a b'), 'a_b');
  assert.equal(safeName(''), 'unnamed');
});

test('drop paths stay relative and keep their directory structure', () => {
  const path = dropPath('richos-capture', '2026-08-23T14-05-02Z--meet--abc', 'session.json');
  assert.equal(path, 'richos-capture/2026-08-23T14-05-02Z--meet--abc/session.json');
  assert.ok(!path.startsWith('/'));
  assert.ok(!path.includes('..'));
});

group('privacy + noise defaults (the CEO\'s stated posture)');

test('routine notifications and the participant disclosure are OFF by default; failure alerts are ON', () => {
  assert.equal(CORE_DEFAULTS.notifyOnStartStop, false);
  assert.equal(CAPTURE_DEFAULTS.disclosureBanner, false);
  assert.equal(CORE_DEFAULTS.notifyOnFailure, true);
  assert.equal(CORE_DEFAULTS.alertSound, false, 'a chime would be picked up by an open microphone');
});

test('capture defaults bias towards never missing a call', () => {
  assert.equal(CAPTURE_DEFAULTS.enabled, true);
  assert.equal(CAPTURE_DEFAULTS.armMode, 'auto');
  assert.equal(CAPTURE_DEFAULTS.captureMic, true);
  assert.ok(CAPTURE_DEFAULTS.chunkMs <= 5000, 'a crash must never cost more than a few seconds');
});

// ---------------------------------------------------------------------------------------
group('captions — the secondary channel dedups, and the COUNT is the collector path');

test('a caption row emits once on appearance and once per meaningful change; no-ops are dropped', () => {
  const agg = new CaptionAggregator();
  assert.equal(agg.observe({ key: 'r1', speaker: 'Ada', text: 'hello', t: T0 }).length, 1);
  // Identical re-report of the same line (Meet does this constantly) → nothing.
  assert.equal(agg.observe({ key: 'r1', speaker: 'Ada', text: 'hello', t: T0 + 100 }).length, 0);
  // The line grows → a new revision.
  const grown = agg.observe({ key: 'r1', speaker: 'Ada', text: 'hello there', t: T0 + 200 });
  assert.equal(grown.length, 1);
  assert.equal(grown[0].revision, 2);
  assert.equal(grown[0].firstT, T0, 'firstT is preserved across revisions');
});

test('the caption count equals exactly the number of events emitted (no second heuristic)', () => {
  const agg = new CaptionAggregator();
  let emitted = 0;
  const feed = [
    { key: 'r1', speaker: 'Ada', text: 'a' },
    { key: 'r1', speaker: 'Ada', text: 'a' }, // no-op
    { key: 'r1', speaker: 'Ada', text: 'ab' }, // revision
    { key: 'r2', speaker: 'Bob', text: 'hi' }, // new row
    { key: 'r2', speaker: 'Bob', text: '' }, // empty → dropped
  ];
  for (const raw of feed) emitted += agg.observe({ ...raw, t: T0 }).length;
  assert.equal(emitted, 3);
  assert.equal(agg.count, 3, 'aggregator.count must match what was actually emitted');
  assert.deepEqual(agg.speakerList(), ['Ada', 'Bob']);
});

test('blank / keyless observations never produce a caption', () => {
  const agg = new CaptionAggregator();
  assert.equal(agg.observe({ key: 'r1', speaker: 'Ada', text: '   ', t: T0 }).length, 0);
  assert.equal(agg.observe({ speaker: 'Ada', text: 'orphan', t: T0 }).length, 0);
  assert.equal(agg.count, 0);
});

test('a missing speaker label degrades to "unknown", never crashes the row', () => {
  const agg = new CaptionAggregator();
  const [event] = agg.observe({ key: 'r1', speaker: '', text: 'anonymous line', t: T0 });
  assert.equal(event.speaker, 'unknown');
});

group('captions-only reconciliation — a call with captions but no audio is a FLAGGED anomaly');

/** @returns {any} */
function recordWith({ audioBytes = 0, parts = 0, captionCount = 0, status = 'closed', degraded = false }) {
  return {
    status,
    audio: { parts: Array.from({ length: parts }, (_, i) => ({ part: i, bytes: audioBytes })), bytesTotal: audioBytes },
    captions: { count: captionCount, degraded },
    health: { redSeconds: 0 },
  };
}

test('verifySession flags captions-present + audio-absent as a specific anomaly', () => {
  const record = newSessionRecord({
    startedAt: T0,
    platform: { id: 'meet', label: 'Google Meet', slug: 'x' },
    tabId: 1,
    extensionVersion: '0.2.0',
    settings: CAPTURE_DEFAULTS,
  });
  record.status = 'closed';
  record.endedAt = T0 + 600000;
  record.captions.count = 42;
  const verdict = verifySession(record);
  assert.equal(verdict.ok, false);
  assert.ok(verdict.problems.some((p) => /captions were captured .* but NO audio/.test(p)), verdict.problems.join('; '));
});

test('the sync reconciler refuses to treat a captions-only session as complete', () => {
  const result = analyzeSession({ record: recordWith({ captionCount: 30 }), audioBytesOnDisk: 0 });
  assert.equal(result.captionsOnly, true);
  assert.equal(result.complete, false);
  assert.ok(result.problems.some((p) => /NO audio/.test(p)));
});

test('the sync reconciler passes a clean audio session (with or without captions)', () => {
  const ok = analyzeSession({ record: recordWith({ audioBytes: 21000000, parts: 1, captionCount: 120 }), audioBytesOnDisk: 21000000 });
  assert.equal(ok.captionsOnly, false);
  assert.equal(ok.complete, true, ok.problems.join('; '));
});

test('degraded captions on an otherwise-complete audio session are noted, not a blocking loss', () => {
  const result = analyzeSession({
    record: recordWith({ audioBytes: 21000000, parts: 1, captionCount: 5, degraded: true }),
    audioBytesOnDisk: 21000000,
  });
  assert.equal(result.captionsOnly, false);
  assert.ok(result.problems.some((p) => /degraded/.test(p)));
});

test('an unreadable session.json is still an anomaly (never silently skipped)', () => {
  const result = analyzeSession({ record: null });
  assert.equal(result.complete, false);
  assert.ok(result.problems.some((p) => /no readable session\.json/.test(p)));
});

group('Meet caption extraction — BOTH renderers (classic markup + server-driven), deterministic');

// A tiny DOM shim: enough of querySelector/querySelectorAll/children/textContent to exercise
// extractCaptionRows against known markup shapes, with no browser. It supports exactly the
// selector forms the adapter uses: `.class` and `[attr]`.
function el(tag, opts = {}) {
  const cls = new Set(opts.cls || []);
  const attrs = opts.attrs || {};
  const children = opts.children || [];
  const ownText = opts.text ?? null;
  const node = {
    tagName: String(tag).toUpperCase(),
    children,
    _cls: cls,
    _attrs: attrs,
    get textContent() {
      if (ownText != null) return ownText;
      return children.map((c) => c.textContent).join('\n');
    },
    matchesToken(sel) {
      if (sel[0] === '.') return cls.has(sel.slice(1));
      if (sel[0] === '[') return Object.prototype.hasOwnProperty.call(attrs, sel.slice(1, -1));
      return false;
    },
    querySelector(sel) {
      return descendants(node).find((n) => n.matchesToken(sel)) || null;
    },
    querySelectorAll(sel) {
      return descendants(node).filter((n) => n.matchesToken(sel));
    },
  };
  return node;
}
function descendants(node) {
  const out = [];
  for (const child of node.children || []) {
    out.push(child, ...descendants(child));
  }
  return out;
}

test('classic Meet caption markup (obfuscated classes) extracts speaker + text per row', () => {
  const region = el('div', {
    cls: ['a4cQT'],
    children: [
      el('div', {
        cls: ['nMcdL'],
        children: [el('span', { cls: ['KcIKyf'], text: 'Ada Lovelace' }), el('span', { cls: ['bh44bd'], text: 'the analytical engine' })],
      }),
      el('div', {
        cls: ['nMcdL'],
        children: [el('span', { cls: ['KcIKyf'], text: 'Charles Babbage' }), el('span', { cls: ['bh44bd'], text: 'quite so' })],
      }),
    ],
  });
  const rows = extractCaptionRows(region);
  assert.equal(rows.length, 2);
  assert.deepEqual(rows.map((r) => r.speaker), ['Ada Lovelace', 'Charles Babbage']);
  assert.equal(rows[0].text, 'the analytical engine');
});

test('server-driven (SDUI) caption markup extracts the same shape via data-attribute anchors', () => {
  const region = el('div', {
    attrs: { 'data-richos-caption-region': '' },
    children: [
      el('div', {
        attrs: { 'data-richos-caption-row': '' },
        children: [
          el('div', { attrs: { 'data-richos-caption-speaker': '' }, text: 'Grace Hopper' }),
          el('div', { attrs: { 'data-richos-caption-text': '' }, text: 'a nanosecond is about a foot' }),
        ],
      }),
    ],
  });
  const rows = extractCaptionRows(region);
  assert.equal(rows.length, 1);
  assert.equal(rows[0].speaker, 'Grace Hopper');
  assert.equal(rows[0].text, 'a nanosecond is about a foot');
});

test('structural fallback: an unrecognised row still yields text (name inferred from the first line)', () => {
  // No known speaker/text classes at all — the adapter must still recover the caption rather
  // than degrade to zero (fail soft), losing only precise attribution.
  const region = el('div', {
    attrs: { 'data-richos-caption-region': '' },
    children: [el('div', { attrs: { 'data-richos-caption-row': '' }, text: 'Mystery Speaker\nhello from an unknown layout' })],
  });
  const rows = extractCaptionRows(region);
  assert.equal(rows.length, 1);
  assert.equal(rows[0].speaker, 'Mystery Speaker');
  assert.equal(rows[0].text, 'hello from an unknown layout');
});

test('empty caption rows are dropped by extraction', () => {
  const region = el('div', {
    attrs: { 'data-richos-caption-region': '' },
    children: [el('div', { attrs: { 'data-richos-caption-row': '' }, children: [el('div', { attrs: { 'data-richos-caption-text': '' }, text: '   ' })] })],
  });
  assert.equal(extractCaptionRows(region).length, 0);
});

group('hybrid capture — mic + captions run while tab audio is awaited');

test('awaiting-tab-audio is amber (partial capture), never red, and never a recovery action', () => {
  const state = healthyState();
  state.awaitingTabAudio = true;
  state.tabEnabled = false; // tab audio is not part of the session yet
  const result = evaluateHealth(state, T0);
  assert.equal(result.level, 'amber');
  assert.ok(result.reasons.some((r) => r.code === 'awaiting-tab-audio'));
  assert.deepEqual(result.actions, [], 'the controller drives the ARM prompt; health asks for no recovery');
});

test('with tab audio disabled, a missing tab channel does not raise a tab-silence red', () => {
  const state = healthyState();
  state.awaitingTabAudio = true;
  state.tabEnabled = false;
  state.tabNonZeroAt = T0 - 60000; // long silent, but tab is not expected
  const result = evaluateHealth(state, T0);
  assert.ok(!result.reasons.some((r) => r.code === 'tab-digital-silence'));
});

test('the session record carries a caption block and a capture mode from birth', () => {
  const record = newSessionRecord({
    startedAt: T0,
    platform: { id: 'meet', label: 'Google Meet', slug: 'x' },
    tabId: 1,
    extensionVersion: '0.2.0',
    settings: CAPTURE_DEFAULTS,
  });
  assert.equal(record.captions.available, false);
  assert.equal(record.captions.count, 0);
  assert.deepEqual(record.captions.speakers, []);
  assert.equal(record.captions.degraded, false);
  assert.equal(record.mode, 'full');
});

test('hybrid auto-start is ON by default and captions collection is ON by default', () => {
  assert.equal(CAPTURE_DEFAULTS.autoStartMicCaptions, true);
  assert.equal(CAPTURE_DEFAULTS.captureCaptions, true);
});

// ---------------------------------------------------------------------------------------
console.log(`\n${passed} passed, ${failures.length} failed`);
if (failures.length) {
  console.error('\nFAILURES:');
  for (const f of failures) console.error(`- ${f.name}: ${f.err.stack}`);
  process.exit(1);
}
