// Development-only deterministic adapters and scenarios. Never bundled in Release.
(function (root, factory) {
  const core = typeof module === 'object' ? require('../core/app.js') : root.RichOSMobile;
  const api = factory(core);
  if (typeof module === 'object') module.exports = api;
  root.RichOSFixtures = api;
})(globalThis, function ({ createApp }) {
  const copy = (v) => JSON.parse(JSON.stringify(v));
  const modes = ['accept', 'unreachable', 'lose-ack', 'revoked'];
  function fixture(name = 'offline') {
    if (!['offline', 'online', 'queued', 'interrupted', 'revoked'].includes(name)) throw new Error(`Unknown fixture: ${name}`);
    const doc = { version: 1, now: 1700000000000, sequence: 0, mode: name === 'revoked' ? 'revoked' : 'accept',
      session: { threads: [{ id: 'general', title: 'General' }, { id: 'planning', title: 'Planning' }],
        selectedThreadId: 'general', draft: '', online: name !== 'offline', paired: true },
      items: [], receipts: [], calls: [] };
    if (['queued', 'interrupted'].includes(name)) {
      doc.sequence = 1;
      doc.items.push({ clientId: 'mobile-1', threadId: 'general', kind: 'text', text: 'Saved before restart',
        state: name === 'interrupted' ? 'sending' : 'waiting', attempts: name === 'interrupted' ? 1 : 0,
        queuedAt: new Date(doc.now).toISOString(), lastReason: null });
      if (name === 'interrupted') doc.receipts.push({ clientId: 'mobile-1', threadId: 'general', text: 'Saved before restart' });
    }
    return doc;
  }
  async function createRuntime({ initial, save = async () => {}, onApp = () => {} } = {}) {
    let doc = copy(initial || fixture());
    let app;
    async function persist() { await save(copy(doc)); }
    async function open() {
      app = await createApp({
        storage: {
          all: async () => copy(doc.items),
          put: async (item) => { doc.items = doc.items.filter((i) => i.clientId !== item.clientId); doc.items.push(copy(item)); await persist(); },
          remove: async (id) => { doc.items = doc.items.filter((i) => i.clientId !== id); await persist(); }
        },
        session: { read: async () => copy(doc.session), write: async (value) => { doc.session = copy(value); await persist(); } },
        clock: { now: () => doc.now },
        nextId: () => `mobile-${++doc.sequence}`,
        transport: {
          async sendText(item) {
            doc.calls.push(item.clientId);
            const error = (reason, retryable) => Object.assign(new Error(reason), { reason, retryable });
            if (doc.mode === 'revoked') throw error('revoked', false);
            if (doc.mode === 'unreachable') throw error('unreachable', true);
            const duplicate = doc.receipts.some((r) => r.clientId === item.clientId);
            if (!duplicate) doc.receipts.push({ clientId: item.clientId, threadId: item.threadId, text: item.text });
            await persist();
            if (doc.mode === 'lose-ack') { doc.mode = 'accept'; await persist(); throw error('unreachable', true); }
            return { message_id: `intake_${item.clientId}`, duplicate, cursor: doc.receipts.length };
          }
        }
      });
      onApp(app);
    }
    await open();
    const state = () => ({ ...app.state(), environment: { now: doc.now, mode: doc.mode, receipts: copy(doc.receipts), calls: copy(doc.calls) } });
    async function command(request) {
      switch (request.command) {
        case 'state': break;
        case 'action': await app.dispatch(request.action); break;
        case 'fixture': doc = fixture(request.name); await persist(); await open(); break;
        case 'reset': doc = fixture(); await persist(); await open(); break;
        case 'restart': await open(); break;
        case 'transport':
          if (!modes.includes(request.mode)) throw new Error('Unknown transport mode');
          doc.mode = request.mode; break;
        case 'advance':
          if (!Number.isSafeInteger(request.ms) || request.ms < 0) throw new Error('ms must be a nonnegative integer');
          doc.now += request.ms; await app.dispatch({ type: 'sync' }); break;
        default: throw new Error(`Unknown command: ${request.command}`);
      }
      await persist();
      return state();
    }
    function check(condition, message) { if (!condition) throw new Error(`Scenario failed: ${message}`); }
    async function scenario(name) {
      const trace = [];
      async function step(request) { const value = await command(request); trace.push({ request, state: value }); return value; }
      if (name === 'offline-reconnect') {
        await step({ command: 'fixture', name: 'offline' });
        await step({ command: 'action', action: { type: 'select-thread', threadId: 'planning' } });
        await step({ command: 'action', action: { type: 'compose', text: 'A message queued offline' } });
        let s = await step({ command: 'action', action: { type: 'send' } });
        check(s.outbox.length === 1 && s.environment.calls.length === 0, 'offline send must persist without IO');
        await step({ command: 'restart' });
        await step({ command: 'transport', mode: 'lose-ack' });
        s = await step({ command: 'action', action: { type: 'network', online: true } });
        check(s.outbox.length === 1 && s.environment.receipts.length === 1 && s.dueInMs === 1000, 'lost acknowledgement must retain message and schedule retry');
        await step({ command: 'restart' });
        s = await step({ command: 'advance', ms: 999 });
        check(s.environment.calls.length === 1, 'retry must respect backoff');
        s = await step({ command: 'advance', ms: 1 });
        check(s.outbox.length === 0 && s.environment.calls.length === 2 && s.environment.receipts.length === 1, 'retry must deduplicate');
        check(s.environment.receipts[0].threadId === 'planning' && s.lastSend.duplicates === 1, 'selected thread and acknowledgement preserved');
      } else if (name === 'revoked') {
        await step({ command: 'fixture', name: 'revoked' });
        await step({ command: 'action', action: { type: 'compose', text: 'Do not retry a revoked device' } });
        let s = await step({ command: 'action', action: { type: 'send' } });
        check(!s.paired && s.outbox[0].state === 'blocked', 'revocation must stop delivery');
        s = await step({ command: 'advance', ms: 60000 });
        check(s.environment.calls.length === 1, 'revocation must not loop');
      } else if (name === 'interrupted') {
        let s = await step({ command: 'fixture', name: 'interrupted' });
        check(s.outbox[0].state === 'waiting' && s.outbox[0].resumedAfterInterruptedSend, 'interrupted send must recover');
        s = await step({ command: 'action', action: { type: 'sync' } });
        check(s.outbox.length === 0 && s.environment.receipts.length === 1 && s.lastSend.duplicates === 1, 'interrupted delivery must deduplicate');
      } else throw new Error(`Unknown scenario: ${name}`);
      return { name, trace, state: state() };
    }
    return { state, export: () => copy(doc), app: () => app, async execute(request) {
      if (request.command === 'scenario') return scenario(request.name);
      return { state: await command(request) };
    } };
  }
  return { createRuntime, fixture };
});
