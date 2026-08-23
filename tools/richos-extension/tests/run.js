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
console.log(`\n${passed} passed, ${failures.length} failed`);
if (failures.length) {
  console.error('\nFAILURES:');
  for (const f of failures) console.error(`- ${f.name}: ${f.err.stack}`);
  process.exit(1);
}
