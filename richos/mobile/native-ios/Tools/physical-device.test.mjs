import test from 'node:test';
import assert from 'node:assert/strict';
import { configuration } from './physical-device.mjs';

const env = { RICHOS_IOS_DEVICE: '00000000-0000000000000000', RICHOS_APPLE_TEAM: 'ABCDEFGHIJ' };
test('physical checks require a named device, team and single supported selection', () => {
  assert.throws(() => configuration({}, 'verify', 'recording'), /physical UDID/);
  assert.throws(() => configuration({ ...env, RICHOS_APPLE_TEAM: '' }, 'verify', 'recording'), /signing team/);
  assert.throws(() => configuration(env, 'verify', 'all'), /one named/);
  assert.throws(() => configuration(env, 'erase', 'recording'), /device build/);
  assert.equal(configuration(env, 'verify', 'recording').test, 'testActualMicrophonePreservesUnsentAudioAfterHomeAndTermination');
});
