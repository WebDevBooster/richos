// Phone session actions. Native services are injected; the PWA owns protocol and retry rules.
(function (root, factory) {
  const node = typeof module === 'object';
  const value = factory(node ? require('./app.js') : root.RichOSMobile,
    node ? require('../../web/web-app/lib/api.js') : root.RichOSApi,
    node ? require('../../web/web-app/lib/link.js') : root.RichOSLink,
    node ? require('../../web/web-app/lib/fingerprint.js') : root.RichOSFingerprint);
  if (node) module.exports = value;
  root.RichOSClient = value;
})(globalThis, function (Mobile, Api, Link, Fingerprint) {
  function pairingLink(value) {
    if (typeof value !== 'string' || /[\s\\]/.test(value)) throw new Error('Paste the complete HTTPS pairing link from your Mac');
    const url = new URL(value);
    if (url.protocol !== 'https:' || url.username || url.password || url.pathname !== '/' || url.search) throw new Error('Pairing requires an HTTPS origin');
    const params = new URLSearchParams(url.hash.slice(1));
    if ([...params.keys()].some(k => k !== 'pair') || params.getAll('pair').length !== 1 || !params.get('pair')) throw new Error('The link needs one pairing code');
    return { origin: url.origin, code: params.get('pair') };
  }
  async function createClient(ports) {
    const saved = await ports.load() || {};
    const data = { outbox: [], messages: [], cursor: 0, confirmed: false, ...saved };
    data.session = { threads: [], selectedThreadId: null, draft: '', ...data.session, paired: !!data.confirmed, online: false };
    data.api = { ...data.api, capabilities: [] };
    let api, link, app, recording = false, recordings = [], words = null, closed = false;
    let latestError = null;
    const listeners = new Set();
    const persist = () => ports.save(JSON.parse(JSON.stringify(data)));
    const state = () => JSON.parse(JSON.stringify({ ...app.state(), messages: data.messages, confirmed: data.confirmed, words,
      recording, recordings, capabilities: data.api.capabilities || [], error: latestError }));
    function emit() { if (app) for (const listener of listeners) listener(state()); }
    function failure(error) { latestError = error.message || String(error); emit(); }
    function closeStream() { if (link) link.close(); link = null; }
    let events = Promise.resolve();
    function receive(name, frame) {
      events = events.then(async () => {
        if (closed) return;
        if (name === 'message') {
          if (!frame || typeof frame.id !== 'string' || typeof frame.text !== 'string') return;
          const rows = data.messages.filter(x => x.id !== frame.id);
          rows.push({ id: frame.id, text: frame.text.slice(0, 64000), role: frame.role, cursor: frame.cursor, complete: frame.complete !== false });
          data.messages = rows.slice(-100);
          if (Number.isSafeInteger(frame.cursor)) data.cursor = Math.max(data.cursor, frame.cursor);
          await persist();
        }
        if (name === 'state' && frame?.complete === true) {
          const row = data.messages.find(x => x.id === frame.message_id);
          if (row) { row.complete = true; await persist(); }
        }
        if (name === 'delta' && frame && typeof frame.message_id === 'string' && typeof frame.text === 'string') {
          const row = data.messages.find(x => x.id === frame.message_id);
          if (row) { row.text = (row.text + frame.text).slice(0, 64000); await persist(); }
        }
        if (name === 'hello' && Array.isArray(frame.threads)) {
          data.session.threads = frame.threads.filter(x => x && typeof x.id === 'string' && typeof x.title === 'string');
        }
        await app.dispatch({ type: 'network', online: true });
        emit();
      }).catch(failure);
    }
    async function configure() {
      await ports.native('configure', { origin: data.api.apiBase });
      api = Api.createApi({ state: data.api, origin: data.api.apiBase,
        signer: { sign: input => ports.native('sign', { input }), sha256Hex: value => ports.hash(value) },
        fetchImpl: ports.fetch, eventSourceImpl: ports.EventSource,
        onState: () => { persist().catch(failure); emit(); } });
    }
    function connect() {
      closeStream();
      if (!data.confirmed || closed) return;
      link = Link.createLink({ refresh: () => api.refreshChallenge(),
        open: handlers => {
          const incomplete = data.messages.filter(x => x.complete === false && Number.isSafeInteger(x.cursor)).map(x => Math.max(0, x.cursor - 1));
          return api.openEvents(data.session.selectedThreadId, Math.min(data.cursor, ...incomplete), handlers);
        },
        handlers: Object.fromEntries(['hello', 'message', 'delta', 'heartbeat', 'state'].map(name => [name, frame => receive(name, frame)])),
        // A quiet resumed stream may send no frame until its next heartbeat.
        onState: status => { app.dispatch({ type: 'network', online: status === 'open' }).catch(failure); },
        onFailure: error => {
          if (error?.reason === 'revoked') {
            data.confirmed = false; data.session.paired = false; closeStream(); persist().catch(failure);
          }
          if (error) failure(error);
        } });
      link.connect();
    }
    app = await Mobile.createApp({
      storage: { all: async () => data.outbox,
        put: async item => { data.outbox = data.outbox.filter(x => x.clientId !== item.clientId).concat(item); await persist(); },
        remove: async id => { data.outbox = data.outbox.filter(x => x.clientId !== id); await persist(); } },
      session: { read: async () => data.session, write: async value => { data.session = value; await persist(); } },
      transport: { sendText: item => api.sendText(item) }, clock: { now: ports.now || Date.now }, nextId: ports.nextId });
    app.subscribe(emit);
    recordings = await ports.native('recordings', {});
    if (data.api.apiBase) {
      await configure();
      if (!data.confirmed && data.fingerprint) words = Fingerprint.phraseFromHex(data.fingerprint);
      connect();
    }
    let pending = Promise.resolve();
    function dispatch(action) {
      const work = async () => {
        latestError = null;
        switch (action.type) {
          case 'pair': {
            if (data.confirmed || data.outbox.length) throw new Error('Existing pairing or queued messages must be resolved before pairing again');
            const { origin, code } = pairingLink(action.link);
            closeStream();
            data.api = { apiBase: origin, deviceId: null, challenge: null, capabilities: [] };
            await configure();
            const key = await ports.native('publicKey', {});
            const result = await api.pair(code, key, 'iPhone');
            if (typeof result.device_id !== 'string' || !/^[a-f0-9]{64}$/i.test(result.ca_fingerprint_sha256 || '') || !Array.isArray(result.threads)) throw new Error('Invalid pairing response');
            data.session.threads = result.threads;
            data.session.selectedThreadId = result.threads[0]?.id || null;
            data.fingerprint = result.ca_fingerprint_sha256;
            words = Fingerprint.phraseFromHex(data.fingerprint);
            await persist();
            break;
          }
          case 'confirm-pair':
            if (!words || !api) throw new Error('No pairing to confirm');
            await api.confirmFingerprint(action.matched === true);
            if (!action.matched) {
              data.api = {}; data.fingerprint = null; words = null; await persist(); break;
            }
            data.confirmed = true; data.session.paired = true; words = null;
            await persist(); connect(); break;
          case 'suspend':
            closeStream(); await app.dispatch({ type: 'network', online: false });
            if (recording) { await ports.native('recordStop', {}); recording = false; }
            recordings = await ports.native('recordings', {}); break;
          case 'resume':
            recordings = await ports.native('recordings', {}); recording = false;
            if (!link) connect(); else link.wake(); break;
          case 'record-start':
            if (recording) throw new Error('Already recording');
            await ports.native('recordStart', {}); recording = true; break;
          case 'record-stop':
            if (!recording) throw new Error('No recording is active');
            await ports.native('recordStop', {}); recording = false;
            recordings = await ports.native('recordings', {}); break;
          case 'record-cancel':
            await ports.native('recordCancel', {}); recording = false;
            recordings = await ports.native('recordings', {}); break;
          case 'record-refresh':
            recording = false; recordings = await ports.native('recordings', {}); break;
          case 'record-delete':
            if (recording) throw new Error('Stop recording before deleting a recording');
            await ports.native('recordDelete', { id: action.id }); recordings = await ports.native('recordings', {}); break;
          default:
            if (action.type === 'send' && new TextEncoder().encode(JSON.stringify(app.state().draft)).length > 48000) throw new Error('Message is too long; shorten it before sending');
            await app.dispatch(action);
            if (action.type === 'select-thread') { data.cursor = 0; data.messages = []; await persist(); connect(); }
        }
        emit(); return state();
      };
      const result = pending.then(work); pending = result.catch(failure); return result;
    }
    return { state, dispatch, subscribe(fn) { listeners.add(fn); fn(state()); return () => listeners.delete(fn); },
      close() { closed = true; closeStream(); }, settle: () => events };
  }
  return { pairingLink, createClient };
});
