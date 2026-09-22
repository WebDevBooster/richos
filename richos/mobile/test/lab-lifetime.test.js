const test = require('node:test');
const assert = require('node:assert/strict');

for (const manual of [false, true]) {
  test(`Mac lab ${manual ? 'manual session waits for explicit stop' : 'automated session remains bounded'}`, async t => {
    const { waitForMac } = await import('../dev/mac-server.mjs');
    t.mock.timers.enable({ apis: ['setTimeout'] });
    const signalsBefore = process.listenerCount('SIGTERM');
    let closed = 0;
    const server = { exited: new Promise(() => {}), close: async () => { closed++; } };
    const running = waitForMac(server, { manual });
    t.mock.timers.tick(24 * 60 * 60 * 1000);
    await Promise.resolve(); await Promise.resolve();
    if (manual) {
      assert.equal(closed, 0, 'A full day must not terminate manual testing');
      process.emit('SIGTERM');
    }
    await running;
    assert.equal(closed, 1);
    assert.equal(process.listenerCount('SIGTERM'), signalsBefore);
  });
}

test('unexpected manual backend exit remains an error and closes owned resources', async () => {
  const { waitForMac } = await import('../dev/mac-server.mjs');
  let closed = 0;
  await assert.rejects(waitForMac({ state: { log: 'owned-log' }, exited: Promise.resolve(), close: async () => { closed++; } }, { manual: true }), /exited unexpectedly/);
  assert.equal(closed, 1);
});
