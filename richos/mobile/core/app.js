// Shared mobile application actions. No DOM, simulator or fixture dependencies.
// The PWA's queue remains the single implementation of durability and retry policy.
(function (root, factory) {
  const queue = typeof module === 'object' ? require('../../web/web-app/lib/queue.js') : root.RichOSQueue;
  const api = factory(queue);
  if (typeof module === 'object') module.exports = api;
  root.RichOSMobile = api;
})(globalThis, function ({ createQueue }) {
  const copy = (value) => JSON.parse(JSON.stringify(value));
  async function createApp(ports) {
    const { storage, session, transport, clock, nextId } = ports;
    const listeners = new Set();
    let model = await session.read();
    let lastSend = null;
    const queue = createQueue({ storage, clock: clock.now,
      now: () => new Date(clock.now()).toISOString(), onChange: () => emit() });
    await queue.load();
    function state() {
      return copy({ ...model, outbox: queue.all(), dueInMs: queue.dueInMs(), lastSend });
    }
    function emit() { const value = state(); for (const fn of listeners) fn(value); return value; }
    let draining;
    function flush() {
      if (draining) return ports.deferDrain ? undefined : draining;
      draining = drain().finally(() => { draining = null; emit(); });
      if (ports.deferDrain) { draining.catch(error => ports.onError?.(error)); return; }
      return draining;
    }
    async function drain() {
      if (!model.online) return;
      lastSend = await queue.flush(transport);
      if (lastSend.reason === 'revoked') model.paired = false;
      await ports.onFlush?.(lastSend);
    }
    // Serialize user/CLI actions. Each send captures its selected thread before awaiting IO.
    let pending = Promise.resolve();
    function dispatch(action) {
      const run = async () => {
        if (!action || typeof action.type !== 'string') throw new Error('An action needs a type');
        switch (action.type) {
          case 'select-thread':
            if (!model.threads.some((t) => t.id === action.threadId)) throw new Error('Unknown conversation');
            model.selectedThreadId = action.threadId;
            break;
          case 'compose':
            if (typeof action.text !== 'string') throw new Error('Message must be text');
            model.draft = action.text;
            break;
          case 'send': {
            if (!model.paired) throw new Error('Pair this device before sending');
            const text = model.draft.trim();
            if (!text) throw new Error('Message is empty');
            await queue.enqueue({ clientId: nextId(), threadId: model.selectedThreadId, kind: 'text', text });
            model.draft = '';
            await session.write(model);
            await flush();
            break;
          }
          case 'send-voice': {
            if (!model.paired || !model.selectedThreadId) throw new Error('Pair this device before sending');
            if (!action.recording || typeof action.recording.id !== 'string') throw new Error('Choose a saved recording');
            await queue.enqueue({ clientId: action.clientId || nextId(), threadId: action.threadId || model.selectedThreadId, kind:'voice', fileId:action.recording.id,
              codec:'wav16k', sampleRate:16000, seconds:action.recording.seconds, text:'Voice message' });
            await flush(); break;
          }
          case 'network':
            if (typeof action.online !== 'boolean') throw new Error('online must be boolean');
            model.online = action.online;
            if (model.online && model.paired) await flush();
            break;
          case 'retry':
            if (!model.paired) throw new Error('Pairing has been revoked');
            queue.retryEverythingNow();
            await flush();
            break;
          case 'sync':
            if (model.paired) await flush();
            break;
          case 'discard':
            if (typeof action.clientId !== 'string') throw new Error('clientId is required');
            await queue.discard(action.clientId);
            break;
          default: throw new Error(`Unknown action: ${action.type}`);
        }
        await session.write(model);
        return emit();
      };
      const result = pending.then(run);
      pending = result.catch(() => {});
      return result;
    }
    return { state, dispatch, settle: async () => { await pending; await draining; }, subscribe(fn) { listeners.add(fn); fn(state()); return () => listeners.delete(fn); } };
  }
  return { createApp };
});
