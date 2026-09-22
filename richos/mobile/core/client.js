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
    node ? require('./links.js') : root.RichOSMobileLinks,
    node ? require('../../web/web-app/lib/connection.js') : root.RichOSConnection,
    node ? require('../../web/web-app/lib/voice.js') : root.RichOSVoice,
    node ? require('../../web/web-app/lib/notification-target.js') : root.RichOSNotificationTarget);
  if (node) module.exports = value;
  root.RichOSClient = value;
})(globalThis, function (Mobile, Api, Link, Fingerprint, Thread, Updates, Links, Connection, Voice, NotificationTarget) {
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
    const data = { voiceFiles: {}, outbox: [], confirmed: false, drafts: {}, cache: {}, accepted: [], ...saved, schema: 2 };
    data.cache = Object.assign(Object.create(null), data.cache);
    data.drafts = Object.assign(Object.create(null), data.drafts);
    data.session = { threads: [], selectedThreadId: null, draft: '', ...data.session, paired: !!data.confirmed, online: false };
    // Retain the paired Mac’s last advertised abilities for offline composition.
    // Its next hello replaces these; authentication and dispatch stay server-gated.
    data.api = { ...data.api, capabilities: data.confirmed && Array.isArray(data.api?.capabilities) ? data.api.capabilities : [] };
    data.push = { previews:true, enabled:false, hostId:null, registrationHash:null, pendingDisable:false, ...data.push };
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
    let playbackState = 'idle', playbackId = null, gesture;
    let beforeRecording = new Set();
    let pushState = 'off', pushBusy = false, pushAgain = false, pushError = null;
    let reconnectNotice=false, reconnectNoticeTimer=null;
    let hasConnected=false, connectionReason = 'connecting', lastConnectionProbe = -Infinity;
    let latestError = null, transientError = false, generation = 0, playbackGeneration = 0, retryTimer, negotiated = false, unsupported = null, paging = false;
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
      const recentVoice=Object.values(data.voiceFiles).filter(v=>v.sent && !recordings.some(r=>r.id===v.id));
      for(const old of recentVoice.slice(0,Math.max(0,recentVoice.length-100)))delete data.voiceFiles[old.id];
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
    const effectiveConnectionReason=()=>data.revoked?'revoked':unsupported?'incompatible':app.state().online?'connected':connectionReason;
    const state = () => copy({ ...app.state(), messages: thread().view(data.outbox.filter(x => x.threadId === data.session.selectedThreadId)).map(row => {
        const note = Object.values(data.voiceFiles).find(v => v.threadId === data.session.selectedThreadId && (v.clientId === row.clientId || v.messageId === row.id));
        return note ? {...row, voice: {seconds:note.seconds,fileId:recordings.some(r=>r.id===note.id)?note.id:null}} : row;
      }),
      connectionReason: effectiveConnectionReason(),
      connectionNoticeReason: effectiveConnectionReason()==='connected'?null:['connecting','reconnecting'].includes(effectiveConnectionReason())?(reconnectNotice?'reconnecting':null):effectiveConnectionReason(),
      notifications: {previews:data.push.previews,enabled:data.push.enabled,status:pushState,error:pushError},
      confirmed: data.confirmed, words, recording, recordings, playbackState, playbackId, voice: gesture?.snapshot() || {phase:"idle"},
      recoveredRecordings: recordings.filter(r => !data.voiceFiles[r.id]?.sent && !data.outbox.some(x=>x.fileId===r.id) && (!r.threadId || (r.threadId===data.session.selectedThreadId && r.origin===data.api.apiBase))), capabilities: data.api.capabilities || [], error: latestError,
      updates: updates.state(), unsupported, canVoice: data.confirmed && !unsupported && api?.offers('voice') === true, canText: data.confirmed && !unsupported && (!negotiated || api?.offers('text')),
      olderAvailable: !thread().atTheBeginning(), paging, focusMessage: data.focusMessage || null, migrationRequired: !data.confirmed });
    function emit() {
      if (!app) return;
      updates.setBusy(recording || data.outbox.some(x => x.state === 'sending'));
      for (const listener of listeners) listener(state());
    }
    function diagnoseConnection(mine) {
      if (!Connection.managed(data.api.apiBase) || now() - lastConnectionProbe < 60000) return;
      lastConnectionProbe = now();
      Promise.resolve(ports.connectionHealth?.() || {}).then(info => {
        if (closed || mine !== generation || app.state().online) return;
        const reason=Connection.classify(info);
        // A healthy relay does not prove that the Mac is asleep or broken.
        connectionReason = reason==='mac-unreachable'?'reconnecting':reason; emit();
      }).catch(() => {});
    }
    function failure(error) { transientError=error.retryable===true;latestError = error.message || String(error); emit(); }
    function closeStream() { clearTimer(reconnectNoticeTimer);reconnectNoticeTimer=null;reconnectNotice=false;generation++; link?.close(); link = null; }
    function gate(feature) {
      const policy = updates.state();
      if (policy.blocked || policy.features[feature] === false) throw Object.assign(Error(policy.message || 'This action is temporarily unavailable. Your work stays on this phone.'), { reason: 'policy', retryable: false });
      if (feature === 'voice' && (unsupported || !api?.offers('voice'))) throw Object.assign(Error('This Mac cannot accept voice yet. Your recording stays on this phone.'), {reason:'unsupported',retryable:false});
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
          if(transientError){latestError=null;transientError=false;}
          if (Array.isArray(frame.messages)) thread(id).merge(frame.messages);
          negotiated = true;
          unsupported = frame.protocol_version !== undefined && frame.protocol_version !== 1 ? 'Update this app or your Mac to use compatible RichOS versions.' : null;
          if (Array.isArray(frame.threads)) data.session.threads = frame.threads.filter(x => x && typeof x.id === 'string' && typeof x.title === 'string');
        }
        await reconcileVoice(id);
        void reconcileNotification().catch(failure);
        await persist(); await app.dispatch({ type: 'network', online: true }); emit();
        if (name==='hello' && (data.push.enabled || data.push.pendingDisable)) void syncNotifications();
      }).catch(failure);
    }
    async function configure() {
      await ports.native('configure', { origin: data.api.apiBase });
      api = Api.createApi({ state: data.api, origin: data.api.apiBase, nativeClient: true,
        isBodyReference: value => value && typeof value.recordingFile === 'string', voiceBody: id => ({recordingFile:id}),
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
      let firstOpen=true;
      link = Link.createLink({ refresh: () => api.refreshChallenge(),
        open: async handlers => {
          // Persisted credentials may have expired while iOS suspended us.
          // Refresh before the first stream instead of provoking a refused one.
          if(firstOpen){firstOpen=false;await api.refreshChallenge();}
          if(mine!==generation || closed || suspended)return null;
          const rows = thread(id).view([]);
          const incomplete = rows.filter(x => x.complete === false && Number.isSafeInteger(x.cursor)).map(x => Math.max(0, x.cursor - 1));
          const cursor = thread(id).latestCursor();
          // Replay the last observed row inclusively. An empty replay can wait
          // behind a proxy until the 15-second heartbeat; a real opening frame
          // makes acceptance immediate, including with existing Mac versions.
          // The shared thread model deduplicates replayed rows/delta indexes.
          return api.openEvents(id, cursor > 0 ? Math.min(cursor-1, ...incomplete) : null, handlers);
        },
        handlers: Object.fromEntries(['hello', 'message', 'delta', 'heartbeat', 'state'].map(name => [name, frame => receive(name, frame, mine, id)])),
        onState: status => {
          if (mine !== generation) return;
          if (status === 'open') {
            clearTimer(reconnectNoticeTimer);reconnectNoticeTimer=null;reconnectNotice=false;
            hasConnected=true;connectionReason='connected';
            if(transientError){latestError=null;transientError=false;}
          } else if(!['phone-offline','service-unavailable'].includes(connectionReason)) {
            connectionReason=status==='opening' && !hasConnected && connectionReason==='connecting'?'connecting':'reconnecting';
          }
          if(['connecting','reconnecting'].includes(connectionReason) && reconnectNoticeTimer===null && !reconnectNotice) {
            // Brief recovery is invisible. Transport/queue state remains honest;
            // only a persistent interruption earns a user-facing notice.
            reconnectNoticeTimer=setTimer(()=>{reconnectNoticeTimer=null;reconnectNotice=true;emit();},3000);
            reconnectNoticeTimer?.unref?.();
          }
          app.dispatch({ type:'network', online:status==='open' }).then(() => {
            if (status === 'away') diagnoseConnection(mine);
          }).catch(failure);
        },
        onFailure: error => {
          if (mine !== generation) return;
          if (error?.reason === 'revoked') {
            data.revoked = true; data.confirmed = false; data.session.paired = false; closeStream(); persist().catch(failure);
          }
          if (error && error.retryable!==true) failure(error);
        }, setTimeoutImpl: setTimer, clearTimeoutImpl: clearTimer });
      link.connect();
    }
    async function reconcileVoice(id) {
      // Match the authenticated projection to the receipt without keeping transcript
      // text in the Mac's replay table. Either ACK/projection arrival order works.
      for (const accepted of data.accepted) {
        const {item,answer}=accepted;
        if(item.threadId!==id || item.kind!=='voice' || !/^[a-f0-9]{64}$/.test(answer.text_sha256 || '')) continue;
        for (const row of thread(id).view([]).filter(row=>row.role==='ceo' && !row.confirmed)) {
          if(await ports.hash(row.text || '')===answer.text_sha256) {
            item.text=row.text; if(data.voiceFiles[item.fileId])data.voiceFiles[item.fileId].messageId=row.id; thread(id).confirm(item,answer);break;
          }
        }
      }
    }
    app = await Mobile.createApp({
      storage: { all: async () => copy(data.outbox),
        put: item => { const value = copy(item); return persist(items => items.filter(x => x.clientId !== value.clientId).concat(value)); },
        remove: id => persist(items => items.filter(x => x.clientId !== id)) },
      session: { read: async () => data.session, write: async value => { data.session = value; await persist(); } },
      transport: { sendVoice: async item => { gate('voice'); gate('recording'); gate('text');
        if (closed || suspended || !data.confirmed) throw Object.assign(Error('Connection paused'),{reason:'unreachable',retryable:true});
        return api.sendVoice(item);
      }, sendText: async item => { gate('text'); if (closed || suspended || !data.confirmed) throw Object.assign(Error('Connection paused'), { reason: 'unreachable', retryable: true }); try { return await api.sendText(item); } catch (error) { if (error.status === 426) { error.retryable = false; error.reason = 'unsupported'; } throw error; } } },
      clock: { now }, nextId: ports.nextId, deferDrain: true, onError: failure,
      onFlush: async result => {
        for (const { item, answer } of result.accepted || []) {
          if(item.kind==='voice' && data.voiceFiles[item.fileId])Object.assign(data.voiceFiles[item.fileId],{sent:true,messageId:answer.message_id});
          // PWA confirmation handles either arrival order: ACK before or after projection.
          if (Number.isSafeInteger(answer.cursor)) {
            thread(item.threadId).confirm(item, answer);
            data.accepted = data.accepted.filter(value => value.item.clientId !== item.clientId).concat({ item: copy(item), answer: copy(answer) });
          }
        }
        if (result.reason === 'revoked') { data.revoked = true; data.confirmed = false; data.session.paired = false; closeStream(); }
        for (const id of new Set((result.accepted || []).map(({item})=>item.threadId))) await reconcileVoice(id);
        await persist(); scheduleRetry();
        // Evict only acknowledged audio. Failed/queued/interrupted recordings remain protected.
        if ((result.accepted || []).some(({item})=>item.kind==='voice')) {
          const sent=Object.values(data.voiceFiles).filter(v=>v.sent && !data.outbox.some(x=>x.fileId===v.id)).map(v=>v.id);
          try {await ports.native('recordPrune',{sent});recordings=await ports.native('recordings',{});} catch { /* Retry housekeeping on a later acknowledgement. */ }
        }
      } });
    app.subscribe(() => { emit(); scheduleRetry(); });
    updates.subscribe(policy => {
      if (recording && (policy.blocked || policy.features.recording === false)) void (gesture?.snapshot().phase !== 'idle' ? gesture.interrupt() : dispatch({ type: 'record-stop' })).catch(failure);
      if (app) { emit(); scheduleRetry(); }
    });
    recordings = await ports.native('recordings', {});
    gesture = Voice.createGesture({now, changed: value => { recording = ['preparing','held','locked'].includes(value.phase); emit(); }, error: failure,
      start: async context => {
        beforeRecording = new Set(recordings.map(r=>r.id));
        playbackGeneration++; playbackState='idle';playbackId=null;
        await ports.native('recordStart', context);
      },
      cancel: async () => { await ports.native('recordCancel', {}); recordings = await ports.native('recordings', {}); },
      finish: async ({send,context}) => {
        await ports.native('recordStop', {}); recordings = await ports.native('recordings', {});
        const captured=recordings.find(r=>!beforeRecording.has(r.id));
        if (!captured) return;
        if (send) await submitVoice(captured,context);
        else latestError=captured.seconds>=30*60-1 ? 'Your 30-minute voice message is saved below. Send it, then start another.' : 'Recording interrupted. Your voice message is kept below.';
      }
    });
    async function submitVoice(saved,context={threadId:data.session.selectedThreadId,origin:data.api.apiBase}) {
      gate('voice');gate('recording');gate('text');
      if(context.origin!==data.api.apiBase || !data.confirmed) throw Error('This recording belongs to another pairing. It has been kept.');
      if(data.outbox.some(x=>x.fileId===saved.id)) throw Error('This voice message is already queued');
      const note=data.voiceFiles[saved.id] || {...saved,clientId:ports.nextId(),threadId:context.threadId};
      data.voiceFiles[saved.id]=note;await persist();
      await app.dispatch({type:'send-voice',recording:saved,threadId:note.threadId,clientId:note.clientId});
    }
    if (data.api.apiBase) {
      await configure();
      if (!data.confirmed && data.fingerprint) words = Fingerprint.phraseFromHex(data.fingerprint);
      connect();
    }
    void updates.start();
    async function syncNotifications(force=false) {
      if (pushBusy) {pushAgain=true;return;}
      if (closed || suspended || !data.confirmed || !app.state().online) return;
      if (!api?.offers('native-push')) {pushState='unsupported';emit();return;}
      pushBusy=true; const device=data.api.deviceId, origin=data.api.apiBase;
      try {
        await ports.native('pushPreview',{enabled:data.push.previews});
        const info=await ports.native('pushInfo',{});
        if(info.permission!=='allowed') data.push.enabled=false;
        pushState=info.permission==='denied' ? 'denied' : info.registrationFailed ? 'apple-unavailable' : 'registering';
        const registration=data.push.enabled && info.permission==='allowed' ? info.registration : null;
        if (data.push.enabled && info.permission==='allowed' && !registration) return;
        const hash=registration ? await ports.hash(JSON.stringify(registration)) : null;
        if (!force && hash && data.push.registrationHash===hash && !data.push.pendingDisable) {pushState='enabled';return;}
        if (!registration && !data.push.registrationHash && !data.push.pendingDisable) {if(info.permission!=='denied')pushState='off';return;}
        const answer=await api.registerNativePush(registration);
        if (closed || data.api.deviceId!==device || data.api.apiBase!==origin) return;
        if (!/^[a-f0-9]{32}$/.test(answer.host_id || '') || answer.registered!==!!registration) throw Error('Notification registration could not be confirmed. Retry notifications.');
        data.push.hostId=answer.host_id;data.push.registrationHash=hash;
        if (!!registration !== data.push.enabled) {pushAgain=true;await persist();return;}
        data.push.pendingDisable=false;
        pushState=registration?'enabled':info.permission==='denied'?'denied':'off';pushError=null;await persist();
      } catch(error) {pushState='service-unavailable';pushError=error.message || 'Notifications unavailable';}
      finally {pushBusy=false;emit();if(pushAgain){pushAgain=false;void syncNotifications();}}
    }
    async function openNotification(value) {
      if (!data.confirmed || !value || value.host!==data.push.hostId || !/^[a-f0-9]{64}$/.test(value.thread || '') || !/^[a-f0-9]{64}$/.test(value.event || '')) return;
      data.notificationTarget=value;await persist();void reconcileNotification().catch(failure);emit();
    }
    let resolvingNotification=false, notificationAgain=false;
    async function reconcileNotification() {
      const value=data.notificationTarget;
      if(!value || value.host!==data.push.hostId)return;
      for(const candidate of data.session.threads) {
        if(await ports.hash(candidate.id)!==value.thread)continue;
        if(data.session.selectedThreadId!==candidate.id) {
          await gesture.interrupt();data.drafts[data.session.selectedThreadId]=app.state().draft;
          await app.dispatch({type:'select-thread',threadId:candidate.id});
          await app.dispatch({type:'compose',text:data.drafts[candidate.id] || ''});
          data.focusMessage=null;connect();return;
        }
        if(resolvingNotification){notificationAgain=true;return;}
        resolvingNotification=true;
        try {
          const mine=generation;
          const row=await NotificationTarget.find({model:thread(candidate.id),matches:async row=>await ports.hash(row.id)===value.event,fetchPage:before=>api.backfill(candidate.id,before,50),isCurrent:()=>!closed && mine===generation && data.notificationTarget===value});
          if(row){data.focusMessage=row.id;delete data.notificationTarget;await persist();emit();}
        } finally {resolvingNotification=false;if(notificationAgain){notificationAgain=false;void reconcileNotification().catch(failure);}}
        return;
      }
    }
    function dispatch(action) {
      if (action.type.startsWith('voice-')) {
        latestError=null;transientError=false;
        try {
          if(action.type==='voice-press') {gate('recording');gate('voice');if(!data.confirmed)throw Error('Pair this phone before recording');return gesture.press({threadId:data.session.selectedThreadId,origin:data.api.apiBase});}
          if(action.type==='voice-move')return gesture.move(action.dx,action.dy);
          if(action.type==='voice-release')return gesture.release();
          if(action.type==='voice-lock'){gesture.lock();return Promise.resolve();}
          if(action.type==='voice-send')return gesture.send();
          if(action.type==='voice-cancel')return gesture.cancel();
          if(action.type==='voice-interrupt')return gesture.interrupt();
        } catch(error) {failure(error);return Promise.reject(error);}
      }
      const work = async () => {
        latestError = null;transientError=false;
        switch (action.type) {
          case 'notification-focused':
            if(data.focusMessage===action.id)data.focusMessage=null;break;
          case 'notifications-previews':
            await ports.native('pushPreview',{enabled:action.enabled===true});
            data.push.previews=action.enabled===true;await persist();void syncNotifications(true);break;
          case 'notifications-enable': {
            if (!data.confirmed) throw Error('Pair this phone before enabling notifications.');
            const info=await ports.native('pushRequest',{});
            data.push.enabled=info.permission==='allowed';pushState=info.permission==='denied'?'denied':'registering';
            await persist();void syncNotifications(true);break;
          }
          case 'notifications-disable':
            data.push.enabled=false;data.push.pendingDisable=true;pushState='disabling';await persist();void syncNotifications(true);break;
          case 'notifications-refresh': void syncNotifications(true);break;
          case 'notification-open': await openNotification(action.value);break;
          case 'pair': {
            if (data.confirmed || data.outbox.length) throw new Error('Existing pairing or queued messages must be resolved before pairing again');
            const { origin, code } = pairingLink(action.link);
            data.revoked = false; lastConnectionProbe = -Infinity;
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
            if (data.push.registrationHash || data.push.pendingDisable) {
              data.push.enabled=false;data.push.pendingDisable=true;await persist();await syncNotifications(true);
              if (data.push.pendingDisable) throw Error('Connect to your Mac and disable notifications before forgetting this pairing.');
            }
            data.push={enabled:false,previews:data.push.previews!==false,hostId:null,registrationHash:null,pendingDisable:false};pushState='off';
            closeStream(); data.confirmed = false; data.session.paired = false; data.api = {}; data.fingerprint = null; words = null;
            models.clear(); data.cache = {}; data.session.threads = []; data.session.selectedThreadId = null;
            await app.dispatch({ type: 'network', online: false }); break;
          case 'suspend':
            await gesture.interrupt();
            playbackGeneration++; playbackState='idle';
            suspended = true; updates.stop(); closeStream(); clearTimer(retryTimer);
            await app.dispatch({ type: 'network', online: false });
            if (recording) { await ports.native('recordStop', {}); recording = false; }
            recordings = await ports.native('recordings', {}); break;
          case 'resume': {
            const wasSuspended = suspended; suspended = false;
            if (updatePorts.clientInfo) updates.setClient(await updatePorts.clientInfo());
            void updates.start(); recordings = await ports.native('recordings', {}); if (wasSuspended) recording = false;
            if (!link) connect(); else link.wake(); if(data.push.enabled || data.push.pendingDisable) void syncNotifications(); break;
          }
          case 'network-recovered':
            lastConnectionProbe = -Infinity; void updates.refresh(true); link?.wake(); break;
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
              await gesture.interrupt();
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
            playbackGeneration++; playbackState='idle';
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
          case 'record-send': {
            gate('voice'); gate('recording'); gate('text');
            if (recording) throw Error('Stop recording before sending');
            const saved = recordings.find(r=>r.id===action.id);
            if (!saved || data.outbox.some(x=>x.fileId===action.id)) throw Error('Choose a saved recording that is not already queued');
            if (data.outbox.length>=100) throw Error('Resolve your unsent messages before sending more');
            await submitVoice(saved, {threadId:saved.threadId || data.session.selectedThreadId,origin:saved.origin || data.api.apiBase}); break;
          }
          case 'reply-play': {
            if (!data.confirmed || !app.state().online || !api.offers('audio') || recording) throw Error('Connect to your Mac and stop recording before playback');
            const id=data.session.selectedThreadId, mine=generation, playback=++playbackGeneration;
            playbackState='loading';playbackId=action.id;
            // Fetch outside the action queue. Late audio must not start in a different conversation.
            void api.fetchAudio(action.id,id).then(async audio=>{
              if (!closed && !suspended && generation===mine && playback===playbackGeneration && !recording) {
                await ports.native('replyPlay',{id:audio});
                if (playback===playbackGeneration) {playbackState='playing';emit();}
              } else if (playback===playbackGeneration) {playbackState='idle';emit();}
            }).catch(error=>{if (!closed && playback===playbackGeneration) {playbackState='idle';failure(error);}}); break;
          }
          case 'playback-ended': playbackState='idle';playbackId=null; break;
          case 'playback-stop': playbackGeneration++; playbackState='idle'; await ports.native('playbackStop',{}); break;
          case 'record-play': playbackGeneration++; await ports.native('recordPlay', { id: action.id });playbackState='playing';playbackId=action.id; break;
          case 'record-delete':
            if (recording) throw new Error('Stop recording before deleting a recording');
            if (data.outbox.some(x=>x.fileId===action.id)) throw Error('Resolve the queued voice message before deleting its recording');
            await ports.native('recordDelete', { id: action.id }); delete data.voiceFiles[action.id]; await persist(); recordings = await ports.native('recordings', {}); break;
          default:
            if (action.type === 'send') {
              delete data.notificationTarget;data.focusMessage=null;
              gate('text');
              if (data.outbox.length >= 100) throw Error('The phone has 100 unsent messages. Resolve them before sending more.');
              if (new TextEncoder().encode(JSON.stringify(app.state().draft)).length > 48000) throw new Error('Message is too long; shorten it before sending');
            }
            if (action.type === 'retry') gate('text');
            if (action.type === 'select-thread') {
              delete data.notificationTarget;data.focusMessage=null;
              await gesture.interrupt();
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
      settle: async () => { await events; await pending; await gesture.settle().catch(()=>{}); await app.settle(); await writes; } };
  }
  return { pairingLink, createClient };
});
