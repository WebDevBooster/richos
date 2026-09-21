// Phone actions run unchanged from the CLI and the native UI. The PWA owns protocol,
// conversation ordering and queue retry rules; this module owns their native lifecycle.
(function (root, factory) {
  const node = typeof module === 'object';
  const value = factory(node ? require('./app.js') : root.RichOSMobile,
    node ? require('../../web/web-app/lib/api.js') : root.RichOSApi,
    node ? require('../../web/web-app/lib/link.js') : root.RichOSLink,
    node ? require('../../web/web-app/lib/fingerprint.js') : root.RichOSFingerprint,
    node ? require('../../web/web-app/lib/thread.js') : root.RichOSThread,
    node ? require('./updates.js') : root.RichOSUpdates,
    node ? require('./links.js') : root.RichOSMobileLinks);
  if (node) module.exports = value;
  root.RichOSClient = value;
})(globalThis, function (Mobile, Api, Link, Fingerprint, Thread, Updates, Links) {
  const copy = value => JSON.parse(JSON.stringify(value));
  function pairingLink(value) {
    if (typeof value !== 'string' || value.length > 4096 || /[\s\\]/.test(value)) throw new Error('Paste the complete HTTPS pairing link from your Mac');
    const url = new URL(value);
    if (url.protocol !== 'https:' || url.username || url.password || url.pathname !== '/' || url.search) throw new Error('Pairing requires an HTTPS origin');
    const params = new URLSearchParams(url.hash.slice(1));
    if ([...params.keys()].some(k => k !== 'pair') || params.getAll('pair').length !== 1 || !params.get('pair')) throw new Error('The link needs one pairing code');
    return { origin: url.origin, code: params.get('pair') };
  }
  async function createClient(ports) {
    const saved = await ports.load() || {};
    if (saved.schema !== undefined && saved.schema !== 2) throw Error('This saved session needs a newer RichOS app. Your data has been retained.');
    if (saved.outbox !== undefined && !Array.isArray(saved.outbox)) throw Error('The saved outbox could not be read. Your data has been retained.');
    const data = { outbox: [], confirmed: false, drafts: {}, cache: {}, accepted: [], ...saved, schema: 2 };
    data.cache = Object.assign(Object.create(null), data.cache);
    data.drafts = Object.assign(Object.create(null), data.drafts);
    data.session = { threads: [], selectedThreadId: null, draft: '', ...data.session, paired: !!data.confirmed, online: false };
    data.api = { ...data.api, capabilities: [] };
    // One-time migration of the pilot's single-conversation cache. Never discard unsent work.
    if (Array.isArray(data.messages) && data.session.selectedThreadId && !data.cache[data.session.selectedThreadId]) data.cache[data.session.selectedThreadId] = data.messages;
    delete data.messages; delete data.cursor;
    const models = new Map();
    function thread(id = data.session.selectedThreadId) {
      if (!models.has(id)) {
        const rows = data.cache[id] || [], model = Thread.createThread();
        // Reconcile cached intake rows before projected rows, including older pilot caches.
        model.merge(rows.filter(row => row.id?.startsWith('intake_'))).merge(rows.filter(row => !row.id?.startsWith('intake_')));
        for (const { item, answer } of data.accepted) if (item.threadId === id) model.confirm(item, answer);
        models.set(id, model);
      }
      return models.get(id);
    }
    const now = ports.now || Date.now, setTimer = ports.setTimeout || setTimeout, clearTimer = ports.clearTimeout || clearTimeout;
    let api, link, app, recording = false, recordings = [], words = null, closed = false, suspended = false;
    let latestError = null, generation = 0, retryTimer, negotiated = false, unsupported = null, paging = false;
    let writes = Promise.resolve(), events = Promise.resolve(), pending = Promise.resolve();
    const listeners = new Set();
    function persist(outboxChange) {
      if (closed) return Promise.resolve();
      // Only the replaceable ledger view is bounded. Drafts and the outbox are never evicted.
      for (const [id, model] of models) {
        const rows = model.view([]), stillPending = new Set(rows.filter(row => row.confirmed).map(row => row.clientId));
        data.cache[id] = rows.filter(row => !row.confirmed).slice(-100);
        data.accepted = data.accepted.filter(({ item }) => item.threadId !== id || stillPending.has(item.clientId));
      }
      while (JSON.stringify(data.accepted).length > 300000) data.accepted.shift();
      while (JSON.stringify(data.cache).length > 1_000_000) {
        const key = Object.keys(data.cache).find(k => data.cache[k].length);
        if (!key) break; data.cache[key].shift();
      }
      const result = writes.then(async () => {
        if (closed) return;
        const snapshot = copy(data);
        if (outboxChange) snapshot.outbox = outboxChange(copy(data.outbox));
        await ports.save(snapshot);
        if (outboxChange) data.outbox = snapshot.outbox;
      });
      writes = result.catch(() => {}); return result;
    }
    const updatePorts = ports.updates ? await ports.updates() : {};
    const updates = await Updates.createController({ ...updatePorts, now, setTimeout: setTimer, clearTimeout: clearTimer,
      client: updatePorts.client || { version: '0.0.0', build: '1', osVersion: '16.7', appId: null, storefront: null },
      load: async () => data.updates, save: async value => { data.updates = value; await persist(); } });
    const state = () => copy({ ...app.state(), messages: thread().view(data.outbox.filter(x => x.threadId === data.session.selectedThreadId)),
      confirmed: data.confirmed, words, recording, recordings, capabilities: data.api.capabilities || [], error: latestError,
      updates: updates.state(), unsupported, canText: data.confirmed && !unsupported && (!negotiated || api?.offers('text')),
      olderAvailable: !thread().atTheBeginning(), paging, focusMessage: data.focusMessage || null, migrationRequired: !data.confirmed });
    function emit() {
      if (!app) return;
      updates.setBusy(recording || data.outbox.some(x => x.state === 'sending'));
      for (const listener of listeners) listener(state());
    }
    function failure(error) { latestError = error.message || String(error); emit(); }
    function closeStream() { generation++; link?.close(); link = null; }
    function gate(feature) {
      const policy = updates.state();
      if (policy.blocked || policy.features[feature] === false) throw Object.assign(Error(policy.message || 'This action is temporarily unavailable. Your work stays on this phone.'), { reason: 'policy', retryable: false });
      if (feature === 'text' && (unsupported || (negotiated && !api?.offers('text')))) throw Object.assign(Error(unsupported || 'This Mac does not support text messages.'), { reason: 'unsupported', retryable: false });
    }
    function scheduleRetry() {
      clearTimer(retryTimer);
      const current = app.state();
      if (closed || suspended || !data.confirmed || !current.online || !data.outbox.some(x => x.state === 'waiting')) return;
      try { gate('text'); } catch { return; }
      const delay = current.dueInMs;
      if (delay !== null && delay !== undefined) {
        retryTimer = setTimer(() => { void app.dispatch({ type: 'sync' }).catch(failure); }, Math.max(25, delay));
        retryTimer?.unref?.();
      }
    }
    function receive(name, frame, mine, id) {
      events = events.then(async () => {
        if (closed || mine !== generation) return;
        if (name === 'message' && frame && typeof frame.id === 'string' && typeof frame.text === 'string' && Number.isSafeInteger(frame.cursor)) thread(id).merge({ ...frame, text: frame.text.slice(0, 64000), complete: frame.complete !== false });
        if (name === 'state') thread(id).applyState(frame);
        if (name === 'delta') thread(id).applyDelta(frame);
        if (name === 'hello') {
          if (Array.isArray(frame.messages)) thread(id).merge(frame.messages);
          negotiated = true;
          unsupported = frame.protocol_version !== undefined && frame.protocol_version !== 1 ? 'Update this app or your Mac to use compatible RichOS versions.' : null;
          if (Array.isArray(frame.threads)) data.session.threads = frame.threads.filter(x => x && typeof x.id === 'string' && typeof x.title === 'string');
        }
        await persist(); await app.dispatch({ type: 'network', online: true }); emit();
      }).catch(failure);
    }
    async function configure() {
      await ports.native('configure', { origin: data.api.apiBase });
      api = Api.createApi({ state: data.api, origin: data.api.apiBase,
        signer: { sign: input => ports.native('sign', { input }), sha256Hex: value => ports.hash(value) },
        fetchImpl: async (...args) => {
          const response = await ports.fetch(...args);
          if (response.status === 426) { unsupported = 'This Mac requires a newer RichOS app. Your queued messages have been retained.'; emit(); }
          return response;
        }, eventSourceImpl: ports.EventSource,
        onState: () => { persist().catch(failure); emit(); } });
    }
    function connect() {
      closeStream();
      if (!data.confirmed || closed || suspended) return;
      const mine = generation, id = data.session.selectedThreadId;
      link = Link.createLink({ refresh: () => api.refreshChallenge(),
        open: handlers => {
          const rows = thread(id).view([]);
          const incomplete = rows.filter(x => x.complete === false && Number.isSafeInteger(x.cursor)).map(x => Math.max(0, x.cursor - 1));
          const cursor = thread(id).latestCursor();
          return api.openEvents(id, cursor > 0 ? Math.min(cursor, ...incomplete) : null, handlers);
        },
        handlers: Object.fromEntries(['hello', 'message', 'delta', 'heartbeat', 'state'].map(name => [name, frame => receive(name, frame, mine, id)])),
        onState: status => { if (mine === generation) app.dispatch({ type: 'network', online: status === 'open' }).catch(failure); },
        onFailure: error => {
          if (mine !== generation) return;
          if (error?.reason === 'revoked') {
            data.confirmed = false; data.session.paired = false; closeStream(); persist().catch(failure);
          }
          if (error) failure(error);
        }, setTimeoutImpl: setTimer, clearTimeoutImpl: clearTimer });
      link.connect();
    }
    app = await Mobile.createApp({
      storage: { all: async () => copy(data.outbox),
        put: item => { const value = copy(item); return persist(items => items.filter(x => x.clientId !== value.clientId).concat(value)); },
        remove: id => persist(items => items.filter(x => x.clientId !== id)) },
      session: { read: async () => data.session, write: async value => { data.session = value; await persist(); } },
      transport: { sendText: async item => { gate('text'); if (closed || suspended || !data.confirmed) throw Object.assign(Error('Connection paused'), { reason: 'unreachable', retryable: true }); try { return await api.sendText(item); } catch (error) { if (error.status === 426) { error.retryable = false; error.reason = 'unsupported'; } throw error; } } },
      clock: { now }, nextId: ports.nextId, deferDrain: true, onError: failure,
      onFlush: async result => {
        for (const { item, answer } of result.accepted || []) {
          // PWA confirmation handles either arrival order: ACK before or after projection.
          if (Number.isSafeInteger(answer.cursor)) {
            thread(item.threadId).confirm(item, answer);
            data.accepted = data.accepted.filter(value => value.item.clientId !== item.clientId).concat({ item: copy(item), answer: copy(answer) });
          }
        }
        if (result.reason === 'revoked') { data.confirmed = false; data.session.paired = false; closeStream(); }
        await persist(); scheduleRetry();
      } });
    app.subscribe(() => { emit(); scheduleRetry(); });
    updates.subscribe(policy => {
      if (recording && (policy.blocked || policy.features.recording === false)) void dispatch({ type: 'record-stop' }).catch(failure);
      if (app) { emit(); scheduleRetry(); }
    });
    recordings = await ports.native('recordings', {});
    if (data.api.apiBase) {
      await configure();
      if (!data.confirmed && data.fingerprint) words = Fingerprint.phraseFromHex(data.fingerprint);
      connect();
    }
    void updates.start();
    function dispatch(action) {
      const work = async () => {
        latestError = null;
        switch (action.type) {
          case 'pair': {
            if (data.confirmed || data.outbox.length) throw new Error('Existing pairing or queued messages must be resolved before pairing again');
            const { origin, code } = pairingLink(action.link);
            closeStream(); negotiated = false; unsupported = null;
            data.api = { apiBase: origin, deviceId: null, challenge: null, capabilities: [] };
            await configure();
            const result = await api.pair(code, await ports.native('publicKey', {}), 'iPhone');
            if (typeof result.device_id !== 'string' || Fingerprint.bytesFromHex(result.ca_fingerprint_sha256).length !== 32 || !Array.isArray(result.threads)) throw new Error('Invalid pairing response');
            data.session.threads = result.threads;
            data.session.selectedThreadId = result.threads[0]?.id || null;
            data.fingerprint = result.ca_fingerprint_sha256;
            words = Fingerprint.phraseFromHex(data.fingerprint); await persist(); break;
          }
          case 'confirm-pair':
            if (!words || !api) throw new Error('No pairing to confirm');
            await api.confirmFingerprint(action.matched === true);
            if (!action.matched) { data.api = {}; data.fingerprint = null; words = null; await persist(); break; }
            data.confirmed = true; data.session.paired = true; words = null;
            await persist(); connect(); break;
          case 'forget-pair':
            if (action.confirm !== true) throw Error('Confirm forgetting this pairing on the phone. Revoke it on your Mac too.');
            if (data.outbox.length || Object.values(data.drafts).some(Boolean) || data.session.draft) throw Error('Copy or resolve your unsent messages and drafts before changing Macs.');
            closeStream(); data.confirmed = false; data.session.paired = false; data.api = {}; data.fingerprint = null; words = null;
            models.clear(); data.cache = {}; data.session.threads = []; data.session.selectedThreadId = null;
            await app.dispatch({ type: 'network', online: false }); break;
          case 'suspend':
            suspended = true; updates.stop(); closeStream(); clearTimer(retryTimer);
            await app.dispatch({ type: 'network', online: false });
            if (recording) { await ports.native('recordStop', {}); recording = false; }
            recordings = await ports.native('recordings', {}); break;
          case 'resume': {
            const wasSuspended = suspended; suspended = false;
            if (updatePorts.clientInfo) updates.setClient(await updatePorts.clientInfo());
            void updates.start(); recordings = await ports.native('recordings', {}); if (wasSuspended) recording = false;
            if (!link) connect(); else link.wake(); break;
          }
          case 'network-recovered': void updates.refresh(true); link?.wake(); break;
          case 'update-check': await updates.refresh(true); break;
          case 'update-dismiss': await updates.dismiss(); break;
          case 'update-open':
            if (!updates.state().storeURL) throw Error('No compatible App Store update has been verified for this phone.');
            try { await ports.native('openStore', {}); Promise.resolve(updatePorts.metric?.('store-opened', updates.state().policyRevision)).catch(() => {}); }
            catch (error) { Promise.resolve(updatePorts.metric?.('store-failed', updates.state().policyRevision)).catch(() => {}); throw error; } break;
          case 'support': await ports.native('openSupport', {}); break;
          case 'settings': await ports.native('openSettings', {}); break;
          case 'scan-pair': {
            const link = await ports.native('scanPair', {}); pairingLink(link); return { pairingLink: link };
          }
          case 'navigate': {
            const target = Links.destination(action.url, updatePorts.client?.universalHosts || []);
            if (target.threadId) {
              data.drafts[data.session.selectedThreadId] = app.state().draft;
              await app.dispatch({ type: 'select-thread', threadId: target.threadId });
              await app.dispatch({ type: 'compose', text: data.drafts[target.threadId] || '' });
              data.focusMessage = target.messageId; connect();
            } break;
          }
          case 'open-link': {
            const url = new URL(action.url);
            if (url.protocol !== 'https:' || url.username || url.password || /[\s\\]/.test(action.url)) throw Error('Only HTTPS links can be opened.');
            await ports.native('openLink', { url: url.href }); break;
          }
          case 'older': {
            if (paging || !data.confirmed || !app.state().online) break;
            const id = data.session.selectedThreadId, mine = generation; paging = true; emit();
            // Paging is independent of the action queue so typing and lifecycle remain responsive.
            void api.backfill(id, thread(id).oldestCursor(), 50).then(async page => {
              if (!closed && mine === generation) { thread(id).prependOlder(page); await persist(); }
            }).catch(failure).finally(() => { paging = false; emit(); }); break;
          }
          case 'record-start':
            gate('recording'); if (recording) throw new Error('Already recording');
            await ports.native('recordStart', {}); recording = true;
            // A policy can change while the native permission prompt is open.
            try { gate('recording'); } catch (error) { await ports.native('recordStop', {}); recording = false; recordings = await ports.native('recordings', {}); throw error; }
            break;
          case 'record-stop':
            if (recording) await ports.native('recordStop', {});
            recording = false; recordings = await ports.native('recordings', {}); break;
          case 'record-cancel':
            await ports.native('recordCancel', {}); recording = false; recordings = await ports.native('recordings', {}); break;
          case 'record-refresh': recording = false; recordings = await ports.native('recordings', {}); break;
          case 'record-play': await ports.native('recordPlay', { id: action.id }); break;
          case 'record-delete':
            if (recording) throw new Error('Stop recording before deleting a recording');
            await ports.native('recordDelete', { id: action.id }); recordings = await ports.native('recordings', {}); break;
          default:
            if (action.type === 'send') {
              gate('text');
              if (data.outbox.length >= 100) throw Error('The phone has 100 unsent messages. Resolve them before sending more.');
              if (new TextEncoder().encode(JSON.stringify(app.state().draft)).length > 48000) throw new Error('Message is too long; shorten it before sending');
            }
            if (action.type === 'retry') gate('text');
            if (action.type === 'select-thread') {
              data.drafts[data.session.selectedThreadId] = app.state().draft;
              await app.dispatch(action);
              await app.dispatch({ type: 'compose', text: data.drafts[action.threadId] || '' });
              await app.dispatch({ type: 'network', online: false }); connect();
            } else {
              await app.dispatch(action);
              if (['compose', 'send'].includes(action.type)) { data.drafts[data.session.selectedThreadId] = app.state().draft; await persist(); }
            }
        }
        emit(); return state();
      };
      const result = pending.then(work); pending = result.catch(failure); return result;
    }
    return { state, dispatch, subscribe(fn) { listeners.add(fn); fn(state()); return () => listeners.delete(fn); },
      close() { closed = true; updates.stop(); clearTimer(retryTimer); closeStream(); },
      settle: async () => { await events; await pending; await app.settle(); await writes; } };
  }
  return { pairingLink, createClient };
});
