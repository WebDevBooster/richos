import test from 'node:test';
import assert from 'node:assert/strict';
import { configuration, verifyPushEnvironment } from './physical-device.mjs';

const env = { RICHOS_IOS_DEVICE: '00000000-0000000000000000', RICHOS_APPLE_TEAM: 'ABCDEFGHIJ' };
test('physical checks require a named device, team and single supported selection', () => {
  assert.throws(() => configuration({}, 'verify', 'recording'), /physical UDID/);
  assert.throws(() => configuration({ ...env, RICHOS_APPLE_TEAM: '' }, 'verify', 'recording'), /signing team/);
  assert.throws(() => configuration(env, 'verify', 'all'), /one named/);
  assert.throws(() => configuration(env, 'erase', 'recording'), /device build/);
  assert.equal(configuration(env, 'verify', 'recording').test, 'testActualMicrophonePreservesUnsentAudioAfterHomeAndTermination');
});

test('APNs registration must match actual signing regardless of Release optimization', () => {
  assert.throws(() => verifyPushEnvironment('production', 'development'), /must match/);
  assert.throws(() => verifyPushEnvironment(undefined, 'development'), /must match/);
  assert.doesNotThrow(() => verifyPushEnvironment('development', 'development'));
  assert.doesNotThrow(() => verifyPushEnvironment('production', 'production'));
});
