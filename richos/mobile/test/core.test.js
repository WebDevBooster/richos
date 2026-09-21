const test = require('node:test');
const assert = require('node:assert/strict');
const { readFileSync } = require('node:fs');
const { join } = require('node:path');
const vm = require('node:vm');
const { createRuntime } = require('../dev/runtime');
const { createApp } = require('../core/app');

test('offline delivery, lost ACK and restart retain the same message and selected thread', async () => {
  const runtime = await createRuntime();
  const { state } = await runtime.execute({ command: 'scenario', name: 'offline-reconnect' });
  assert.deepEqual(state.environment.calls, ['mobile-1', 'mobile-1']);
  assert.equal(state.environment.receipts[0].threadId, 'planning');
});

test('revocation prevents later sends and automatic retries', async () => {
  const runtime = await createRuntime();
  await runtime.execute({ command: 'scenario', name: 'revoked' });
  await assert.rejects(runtime.execute({ command: 'action', action: { type: 'send' } }), /Pair/);
  assert.equal(runtime.state().environment.calls.length, 1);
});

test('interrupted send is replayed safely after a fresh runtime reads persisted state', async () => {
  const runtime = await createRuntime();
  await runtime.execute({ command: 'fixture', name: 'interrupted' });
  const restored = await createRuntime({ initial: runtime.export() });
  await restored.execute({ command: 'action', action: { type: 'sync' } });
  assert.equal(restored.state().outbox.length, 0);
  assert.equal(restored.state().environment.receipts.length, 1);
  assert.equal(restored.state().lastSend.duplicates, 1);
});

test('invalid actions fail without poisoning the next action', async () => {
  const runtime = await createRuntime();
  await assert.rejects(runtime.execute({ command: 'action', action: { type: 'select-thread', threadId: 'missing' } }), /Unknown conversation/);
  await assert.rejects(runtime.execute({ command: 'advance', ms: -1 }), /nonnegative/);
  await assert.rejects(runtime.execute({ command: 'action', action: { type: 'erase-everything' } }), /Unknown action/);
  await runtime.execute({ command: 'action', action: { type: 'compose', text: 'Still works' } });
  assert.equal(runtime.state().draft, 'Still works');
});

test('failed durable storage retains the draft and never calls the transport', async () => {
  let sends = 0;
  const model = { threads: [{ id: 't', title: 'Thread' }], selectedThreadId: 't', draft: 'Keep my message', online: true, paired: true };
  const app = await createApp({ storage: { all: async () => [], put: async () => { throw new Error('Disk unavailable'); } },
    session: { read: async () => model, write: async () => {} }, clock: { now: () => 0 }, nextId: () => 'one',
    transport: { sendText: async () => { sends++; } } });
  await assert.rejects(app.dispatch({ type: 'send' }), /Disk unavailable/);
  assert.equal(app.state().draft, 'Keep my message');
  assert.equal(sends, 0);
});

test('serialized actions retain each send target and external state cannot mutate the core', async () => {
  const runtime = await createRuntime();
  const app = runtime.app();
  await Promise.all([
    app.dispatch({ type: 'compose', text: 'First' }), app.dispatch({ type: 'send' }),
    app.dispatch({ type: 'select-thread', threadId: 'planning' }),
    app.dispatch({ type: 'compose', text: 'Second' }), app.dispatch({ type: 'send' })
  ]);
  const state = app.state();
  assert.deepEqual(state.outbox.map((i) => [i.text, i.threadId]), [['First', 'general'], ['Second', 'planning']]);
  state.outbox[0].text = 'Tampered';
  assert.equal(app.state().outbox[0].text, 'First');
});

test('browser scripts and CommonJS execute identical actions and expose identical semantic state', async () => {
  const context = vm.createContext({});
  for (const path of ['../../web/web-app/lib/queue.js', '../core/app.js', '../dev/runtime.js']) {
    vm.runInContext(readFileSync(join(__dirname, path), 'utf8'), context, { filename: path });
  }
  for (const name of ['offline-reconnect', 'revoked', 'interrupted']) {
    const node = await (await createRuntime()).execute({ command: 'scenario', name });
    const browser = await (await context.RichOSFixtures.createRuntime()).execute({ command: 'scenario', name });
    assert.deepEqual(JSON.parse(JSON.stringify(browser)), node);
  }
});
