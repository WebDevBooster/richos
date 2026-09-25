import test from 'node:test';
import assert from 'node:assert/strict';
import { allowanceSeconds, configuration, prebuilt, verifyPushEnvironment } from './physical-device.mjs';

test('only verify may reuse an earlier build, and only when asked', () => {
  assert.equal(prebuilt({ RICHOS_PHYSICAL_PREBUILT: '1' }, 'verify'), true);
  assert.equal(prebuilt({ RICHOS_PHYSICAL_PREBUILT: '1' }, 'build'), false);
  assert.equal(prebuilt({}, 'verify'), false);
  assert.equal(prebuilt({ RICHOS_PHYSICAL_PREBUILT: 'yes' }, 'verify'), false);
});

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

test('a walker script is one named selection with a bounded time allowance', () => {
  assert.equal(configuration(env, 'verify', 'script').test, 'testScript');
  assert.equal(allowanceSeconds({}), 240);
  assert.equal(allowanceSeconds({ allowanceSeconds: '900' }), 900);
  for (const bad of ['59', '1801', '12.5', 'forever']) assert.throws(() => allowanceSeconds({ allowanceSeconds: bad }), /60 to 1800/);
});
