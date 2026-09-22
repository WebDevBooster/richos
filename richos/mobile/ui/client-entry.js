(async () => {
  const $ = id => document.getElementById(id), listeners = new Set();
  globalThis.RichOSNativeEvent = event => { for (const fn of listeners) fn(event); };
  const call = (method, args = {}) => window.webkit.messageHandlers.richos.postMessage({ method, args });
  const ports = RichOSNative.createPorts(call, fn => { listeners.add(fn); return () => listeners.delete(fn); });
  const fixture = globalThis.RichOSUpdateFixture ? await RichOSUpdateFixture.wrap(ports) : null;
  const app = await RichOSClient.createClient(fixture?.ports || ports);
  async function perform(action) { try { return await app.dispatch(action); } catch (error) { $('error').textContent = error.message; $('dialog-error').textContent = error.message; } }
  globalThis.RichOSClientInspect?.(app, fixture);
  let historyKey, selected, recordingCount = 0, current, composing = 0;
  function textWithLinks(element, text) {
    // No Markdown HTML enters the privileged view. External HTTPS links open outside it.
    for (const part of (text || '').split(/(https:\/\/[^\s<>]+)/g)) {
      if (part.startsWith('https://')) {
        const link = document.createElement('a'); link.textContent = part; link.href = part;
        link.onclick = event => { event.preventDefault(); perform({ type: 'open-link', url: part }); }; element.append(link);
      } else element.append(document.createTextNode(part));
    }
  }
  app.subscribe(state => {
    current = state;
    $('connection').textContent = state.confirmed || state.connectionReason === 'revoked' ? globalThis.RichOSConnection.sentence(state.connectionReason) : 'Pairing required';
    $('pairing').hidden = state.confirmed; $('fingerprint').hidden = !state.words; $('words').textContent = state.words || '';
    const options = JSON.stringify(state.threads);
    if ($('thread').dataset.options !== options) {
      $('thread').replaceChildren(...state.threads.map(t => { const e = document.createElement('option'); e.value = t.id; e.textContent = t.title; return e; })); $('thread').dataset.options = options;
    }
    $('thread').value = state.selectedThreadId; $('thread').hidden = state.threads.length < 2;
    if (!composing && $('message').value !== state.draft) $('message').value = state.draft;
    $('send').disabled = !state.canText || state.updates.blocked || !state.updates.features.text;
    $('retry').hidden = !state.outbox.length; $('retry').disabled = $('send').disabled;
    $('compatibility').textContent = state.unsupported || ((!state.updates.features.text || !state.updates.features.recording) ? state.updates.message : '');
    const key = JSON.stringify([state.messages, state.capabilities]);
    if (key !== historyKey || selected !== state.selectedThreadId) {
      const area = $('conversation'), follow = area.scrollHeight - area.scrollTop - area.clientHeight < 80 || selected !== state.selectedThreadId;
      const oldHeight = area.scrollHeight, oldTop = area.scrollTop;
      $('history').replaceChildren(...state.messages.map(m => {
        const e = document.createElement('li'); e.dataset.messageId = m.id; e.className = `msg msg-${m.role === 'ceo' ? 'mine' : 'rich'}`;
        const label = document.createElement('span'); label.className = 'visually-hidden'; label.textContent = m.role === 'ceo' ? 'You: ' : 'Rich: ';
        const body = document.createElement('p'); body.className = 'msg-text'; textWithLinks(body, m.text); e.append(label, body);
        if (m.pending) {
          const status = document.createElement('p'); status.className = 'msg-meta'; status.textContent = m.sendState === 'blocked' ? 'Not sent · needs attention' : 'Waiting to send'; e.append(status);
          const discard = document.createElement('button'); discard.textContent = 'Discard unsent message'; discard.onclick = () => perform({ type: 'discard', clientId: m.clientId }); e.append(discard);
        } else if (m.complete === false) { const status = document.createElement('span'); status.className = 'msg-meta'; status.textContent = 'Rich is replying…'; e.append(status); }
        if (m.role==='rich' && m.complete!==false && state.capabilities.includes('audio')) {
          const play=document.createElement('button');play.textContent='Play reply';play.onclick=()=>perform({type:'reply-play',id:m.id});e.append(play);
          const stop=document.createElement('button');stop.textContent='Stop playback';stop.onclick=()=>perform({type:'playback-stop'});e.append(stop);
        }
        return e;
      }));
      if (follow) area.scrollTop = area.scrollHeight;
      else if (state.paging) area.scrollTop = oldTop + area.scrollHeight - oldHeight;
      if (state.focusMessage) [...$('history').children].find(row => row.dataset.messageId === state.focusMessage)?.scrollIntoView({ block: 'center' });
      historyKey = key; selected = state.selectedThreadId;
    }
    $('empty').hidden = !!state.messages.length;
    $('older').hidden = !state.confirmed || !state.olderAvailable; $('older').disabled = state.paging || !state.online;
    $('record-start').disabled = state.recording || state.updates.blocked || !state.updates.features.recording;
    $('record-stop').hidden = !state.recording; $('record-cancel').hidden = !state.recording;
    $('record-status').textContent = state.recording ? 'Recording…' : state.confirmed && !state.canVoice ? 'Voice sending is not available on this Mac yet. Saved recordings stay on this phone.' : 'Stop to review your recording, then choose Send recording. Cancel never sends.';
    if (state.recordings.length > recordingCount) $('saved-recordings').open = true;
    recordingCount = state.recordings.length;
    const recordingsKey = JSON.stringify([state.recordings,state.canVoice,state.outbox,state.updates.blocked,state.updates.features]);
    if ($('recordings').dataset.value !== recordingsKey) {
      $('recordings').replaceChildren(...state.recordings.map(r => {
        const e = document.createElement('li'); e.textContent = `${Math.round(r.seconds)} seconds · saved on this phone `;
        for (const [title, type] of [['Play recording', 'record-play'], ['Send recording', 'record-send'], ['Delete recording', 'record-delete']]) {
          const button = document.createElement('button'); button.textContent = title; button.onclick = () => perform({ type, id: r.id });
          const queued=state.outbox.some(x=>x.fileId===r.id);
          if (type==='record-send') button.disabled=!state.canVoice || queued || state.updates.blocked || !state.updates.features.recording || !state.updates.features.text;
          if (type==='record-delete') button.disabled=queued; e.append(button);
        } return e;
      })); $('recordings').dataset.value = recordingsKey;
    }
    $('playback-status').textContent=state.playbackState==='playing'?'Playing reply…':state.playbackState==='loading'?'Preparing reply audio…':'';
    const notifications=state.notifications;
    const notificationText={off:'Reply notifications are off.',enabled:'Reply notifications are on.',registering:'Registering with Apple and your Mac…',denied:'Notifications are denied. Enable them in iPhone Settings.',unsupported:'Update your Mac to enable native reply notifications.',disabling:'Disabling notifications when your Mac is reachable…','apple-unavailable':'Apple registration is unavailable. Retry notifications.','service-unavailable':'The notification service is unavailable. Retry notifications; your conversation still works.'};
    $('notification-status').textContent=notificationText[notifications.status] || 'Reply notifications are off.';
    $('notifications-enable').hidden=notifications.enabled;
    $('notifications-disable').hidden=!notifications.enabled;
    $('notifications-enable').disabled=!state.confirmed;
    $('error').textContent = state.error || '';
    const update = state.updates, modal = update.mode === 'dialog' || update.mode === 'blocking';
    $('update-banner').hidden = update.mode !== 'banner';
    for (const prefix of ['banner', 'dialog']) {
      $(prefix + '-title').textContent = update.title || 'Update RichOS'; $(prefix + '-message').textContent = update.message || '';
      $(prefix + '-dismiss').hidden = !update.dismissible;
    }
    if (modal && !$('update-dialog').open) $('update-dialog').showModal();
    if (!modal && $('update-dialog').open) $('update-dialog').close();
    $('update-status').textContent = !update.configured ? 'App Store updates are not configured for this development build.' : update.error || (update.expired ? 'The last update notice expired. Checking again keeps this app usable.' : update.mode === 'none' ? 'No verified update is currently being shown.' : 'A verified update is available.');
  });
  $('pair-form').onsubmit = event => { event.preventDefault(); perform({ type: 'pair', link: $('pair-link').value }); };
  $('scan').onclick = async () => { const result = await perform({ type: 'scan-pair' }); if (result?.pairingLink) { $('pair-link').value = result.pairingLink; $('pair-link').focus(); } };
  $('confirm').onclick = () => perform({ type: 'confirm-pair', matched: true }); $('reject').onclick = () => perform({ type: 'confirm-pair', matched: false });
  $('composer').onsubmit = event => { event.preventDefault(); perform({ type: 'send' }); };
  $('message').oninput = () => {
    composing++;
    void perform({ type: 'compose', text: $('message').value }).finally(() => { composing--; });
  };
  $('thread').onchange = () => perform({ type: 'select-thread', threadId: $('thread').value });
  $('retry').onclick = () => perform({ type: 'retry' }); $('older').onclick = () => perform({ type: 'older' });
  for (const type of ['record-start', 'record-stop', 'record-cancel']) $(type).onclick = () => perform({ type });
  for (const type of ['notifications-enable','notifications-disable','notifications-refresh']) $(type).onclick=()=>perform({type});
  $('permissions').onclick = () => perform({ type: 'settings' }); $('support').onclick = $('dialog-support').onclick = () => perform({ type: 'support' });
  $('check-update').onclick = $('dialog-check').onclick = () => perform({ type: 'update-check' });
  for (const prefix of ['banner', 'dialog']) {
    $(prefix + '-update').onclick = () => perform({ type: 'update-open' }); $(prefix + '-dismiss').onclick = () => perform({ type: 'update-dismiss' });
  }
  $('update-dialog').oncancel = event => { event.preventDefault(); if (current.updates.dismissible) perform({ type: 'update-dismiss' }); };
  $('forget').onclick = () => $('forget-dialog').showModal(); $('forget-cancel').onclick = () => $('forget-dialog').close();
  $('forget-confirm').onclick = async () => { $('forget-dialog').close(); await perform({ type: 'forget-pair', confirm: true }); };
  async function incoming() { const url = await call('incomingLink', {}); if (url) await perform({ type: 'navigate', url }); }
  async function notification() { const value=await call('pushIncoming',{}); if(value) await perform({type:'notification-open',value}); }
  await incoming();
  await notification();
  listeners.add(event => {
    if (event.kind === 'playback-ended') perform({type:'playback-ended'});
    if (event.kind === 'push-open') void notification();
    if (event.kind === 'push-changed') perform({type:'notifications-refresh'});
    if (event.kind === 'incoming-link') void incoming();
    if (event.kind === 'record-finished') perform({ type: 'record-refresh' });
    if (event.kind === 'background') perform({ type: 'suspend' });
    if (event.kind === 'foreground') perform({ type: 'resume' });
    if (event.kind === 'network-recovered') perform({ type: 'network-recovered' });
  });
})().catch(error => { document.getElementById('error').textContent = error.message; });
