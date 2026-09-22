(async () => {
  const $ = id => document.getElementById(id), listeners = new Set();
  globalThis.RichOSNativeEvent = event => { for (const fn of listeners) fn(event); };
  const call = (method, args = {}) => window.webkit.messageHandlers.richos.postMessage({ method, args });
  const ports = RichOSNative.createPorts(call, fn => { listeners.add(fn); return () => listeners.delete(fn); });
  const fixture = globalThis.RichOSUpdateFixture ? await RichOSUpdateFixture.wrap(ports) : null;
  const app = await RichOSClient.createClient(fixture?.ports || ports);
  async function perform(action) { try { return await app.dispatch(action); } catch (error) { $('error').textContent = error.message; $('dialog-error').textContent = error.message; } }
  globalThis.RichOSClientInspect?.(app, fixture);
  let historyKey, selected, current, composing = 0;
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
    $('pairing').hidden = state.confirmed; document.body.classList.toggle('is-paired',state.confirmed); document.querySelector('.pair-intro').hidden=!!state.words; $('fingerprint').hidden = !state.words; $('words').textContent = state.words || '';
    const options = JSON.stringify(state.threads);
    if ($('thread').dataset.options !== options) {
      $('thread').replaceChildren(...state.threads.map(t => { const e = document.createElement('option'); e.value = t.id; e.textContent = t.title; return e; })); $('thread').dataset.options = options;
    }
    $('thread').value = state.selectedThreadId; $('thread').hidden = state.threads.length < 2;
    if (!composing && $('message').value !== state.draft) $('message').value = state.draft;
    $('send').disabled = !state.canText || state.updates.blocked || !state.updates.features.text;
    $('retry').hidden = !state.outbox.length; $('retry').disabled = $('send').disabled;
    $('compatibility').textContent = state.unsupported || ((!state.updates.features.text || !state.updates.features.recording) ? state.updates.message : '');
    const key = JSON.stringify([state.messages, state.capabilities, state.playbackState,state.playbackId]);
    if (key !== historyKey || selected !== state.selectedThreadId) {
      const area = $('conversation'), follow = area.scrollHeight - area.scrollTop - area.clientHeight < 80 || selected !== state.selectedThreadId;
      const oldHeight = area.scrollHeight, oldTop = area.scrollTop;
      $('history').replaceChildren(...state.messages.map(m => {
        const e = document.createElement('li'); e.dataset.messageId = m.id; e.className = `msg msg-${m.role === 'ceo' ? 'mine' : 'rich'}`;
        const label = document.createElement('span'); label.className = 'visually-hidden'; label.textContent = m.role === 'ceo' ? 'You: ' : 'Rich: ';
        if(m.voice) {
          const voice=document.createElement('div');voice.className='voice-message';
          const seconds=Math.round(m.voice.seconds || 0), duration=`${Math.floor(seconds/60)}:${String(seconds%60).padStart(2,'0')}`;
          const label=document.createElement('span');label.textContent=`Voice message · ${duration}`;voice.append(label);
          if(m.voice.fileId){const play=document.createElement('button');const active=state.playbackId===m.voice.fileId && state.playbackState==='playing';play.textContent=active?'Stop':'Play';play.setAttribute('aria-label',active?'Stop voice message':'Play voice message');play.onclick=()=>perform(active?{type:'playback-stop'}:{type:'record-play',id:m.voice.fileId});voice.prepend(play);}
          e.append(voice);
        }
        const body = document.createElement('p'); body.className = 'msg-text'; textWithLinks(body, m.text); e.append(label);if(!m.voice || m.text!=='Voice message')e.append(body);
        if (m.pending) {
          const status = document.createElement('p'); status.className = 'msg-meta'; status.textContent = m.sendState === 'blocked' ? 'Not sent · needs attention' : m.sendState === 'sending' ? 'Sending…' : state.online ? 'Waiting to send' : 'Queued · waiting for connection'; e.append(status);
          const discard = document.createElement('button'); discard.textContent = 'Discard unsent message'; discard.onclick = () => perform({ type: 'discard', clientId: m.clientId }); e.append(discard);
        } else if (m.complete === false) { const status = document.createElement('span'); status.className = 'msg-meta'; status.textContent = 'Rich is replying…'; e.append(status); }
        if (m.role==='rich' && m.complete!==false && state.capabilities.includes('audio')) {
          const play=document.createElement('button');const active=state.playbackId===m.id && state.playbackState!=='idle';
          play.className='reply-audio';play.textContent=active?(state.playbackState==='loading'?'Cancel audio':'Stop playback'):'Play reply';
          play.onclick=()=>perform(active?{type:'playback-stop'}:{type:'reply-play',id:m.id});e.append(play);
        }
        return e;
      }));
      if (follow) area.scrollTop = area.scrollHeight;
      else if (state.paging) area.scrollTop = oldTop + area.scrollHeight - oldHeight;
      else area.scrollTop=oldTop;
      $('latest').hidden=follow;
      if (state.focusMessage) [...$('history').children].find(row => row.dataset.messageId === state.focusMessage)?.scrollIntoView({ block: 'center' });
      historyKey = key; selected = state.selectedThreadId;
    }
    $('empty').hidden = !!state.messages.length;
    $('older').hidden = !state.confirmed || !state.olderAvailable || !state.messages.length; $('older').disabled = state.paging || !state.online;
    const phase=state.voice.phase, active=phase!=='idle', locked=phase==='locked';
    document.body.dataset.voice=phase;
    $('record-start').disabled = !state.canVoice || state.updates.blocked || !state.updates.features.recording;
    $('record-start').hidden=locked || phase==='finishing' || (!active && !!state.draft.trim());
    $('send').hidden=active || !state.draft.trim();
    $('message').hidden=active; $('message').disabled=!state.confirmed;
    $('voice-controls').hidden=!active;
    $('voice-cancel').hidden=!locked; $('voice-send').hidden=!locked; $('voice-lock').hidden=phase!=='held';
    $('voice-hint').textContent=phase==='preparing'?'Opening microphone…':phase==='finishing'?'Saving your message…':locked?'Recording · hands free':'← Slide to cancel';
    $('record-status').textContent=phase==='held'?'Release to send · slide up to lock':locked?'Keep talking. Send when you’re finished.':'';
    const recordingsKey=JSON.stringify([state.recoveredRecordings,state.outbox,state.playbackId,state.playbackState]);
    $('recovered').hidden=!state.recoveredRecordings.length;
    if($('recordings').dataset.value!==recordingsKey) {
      $('recordings').replaceChildren(...state.recoveredRecordings.map(r=>{
        const e=document.createElement('li');e.textContent=`${Math.round(r.seconds)} seconds `;
        for(const [label,type] of [['Play','record-play'],['Send','record-send'],['Discard','record-delete']]) {
          const button=document.createElement('button');button.textContent=label;button.setAttribute('aria-label',`${label} unsent recording`);
          button.onclick=()=>perform({type,id:r.id});if(type==='record-send')button.disabled=!state.canVoice;e.append(button);
        }return e;
      }));$('recordings').dataset.value=recordingsKey;
    }
    $('playback-status').textContent=state.playbackState==='playing'?'Playing reply…':state.playbackState==='loading'?'Preparing reply audio…':'';
    const notifications=state.notifications;
    const notificationText={off:'Reply notifications are off.',enabled:'Reply notifications are on.',registering:'Registering with Apple and your Mac…',denied:'Notifications are denied. Enable them in iPhone Settings.',unsupported:'Update your Mac to enable native reply notifications.',disabling:'Disabling notifications when your Mac is reachable…','apple-unavailable':'Apple registration is unavailable. Retry notifications.','service-unavailable':'The notification service is unavailable. Retry notifications; your conversation still works.'};
    $('notification-status').textContent=notificationText[notifications.status] || 'Reply notifications are off.';
    $('notifications-enable').hidden=notifications.enabled;
    $('notifications-disable').hidden=!notifications.enabled;
    $('notifications-enable').disabled=!state.confirmed;
    $('notifications-refresh').hidden=!['apple-unavailable','service-unavailable','unsupported'].includes(notifications.status);
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
  $('conversation').onscroll=()=>{$('latest').hidden=$('conversation').scrollHeight-$('conversation').scrollTop-$('conversation').clientHeight<80;};
  $('latest').onclick=()=>{$('conversation').scrollTop=$('conversation').scrollHeight;};
  $('pair-form').onsubmit = event => { event.preventDefault(); perform({ type: 'pair', link: $('pair-link').value }); };
  $('scan').onclick = async () => { const result = await perform({ type: 'scan-pair' }); if (result?.pairingLink) { $('pair-link').value = result.pairingLink; await perform({type:'pair',link:result.pairingLink}); } };
  $('confirm').onclick = () => perform({ type: 'confirm-pair', matched: true }); $('reject').onclick = () => perform({ type: 'confirm-pair', matched: false });
  $('composer').onsubmit = event => { event.preventDefault(); perform({ type: 'send' }); };
  $('message').oninput = () => {
    $('message').style.height='auto'; $('message').style.height=Math.min(140,$('message').scrollHeight)+'px';
    composing++;
    void perform({ type: 'compose', text: $('message').value }).finally(() => { composing--; });
  };
  $('thread').onchange = () => perform({ type: 'select-thread', threadId: $('thread').value });
  $('retry').onclick = () => perform({ type: 'retry' }); $('older').onclick = () => perform({ type: 'older' });
  let pointer=null, startX=0, startY=0;
  const mic=$('record-start');
  mic.oncontextmenu=event=>event.preventDefault();
  mic.onpointerdown=event=>{if(pointer!==null || event.button!==0)return;event.preventDefault();pointer=event.pointerId;startX=event.clientX;startY=event.clientY;mic.setPointerCapture(pointer);void perform({type:'voice-press'});};
  mic.onpointermove=event=>{if(event.pointerId===pointer)void perform({type:'voice-move',dx:event.clientX-startX,dy:event.clientY-startY});};
  mic.onpointerup=event=>{if(event.pointerId!==pointer)return;pointer=null;void perform({type:'voice-release'});};
  mic.onpointercancel=()=>{pointer=null;if(current?.voice.phase!=='locked')void perform({type:'voice-interrupt'});};
  mic.onlostpointercapture=()=>{if(pointer!==null){pointer=null;if(current?.voice.phase!=='locked')void perform({type:'voice-interrupt'});}};
  mic.onclick=event=>{if(event.detail===0)void perform({type:'voice-press'}).then(()=>perform({type:'voice-lock'}));};
  $('voice-send').onclick=()=>perform({type:'voice-send'});$('voice-cancel').onclick=()=>perform({type:'voice-cancel'});$('voice-lock').onclick=()=>perform({type:'voice-lock'});
  setInterval(()=>{const start=current?.voice.startedAt;const seconds=start?Math.max(0,Math.floor((Date.now()-start)/1000)):0;const value=`${Math.floor(seconds/60)}:${String(seconds%60).padStart(2,'0')}`;if($('voice-timer').textContent!==value)$('voice-timer').textContent=value;},250);
  $('settings-open').onclick=()=>$('settings').showModal();$('settings-close').onclick=()=>$('settings').close();
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
    if (event.kind === 'record-finished') {void perform({type:'voice-interrupt'}).then(()=>perform({type:'record-refresh'}));}
    if (event.kind === 'background') perform({ type: 'suspend' });
    if (event.kind === 'foreground') perform({ type: 'resume' });
    if (event.kind === 'network-recovered') perform({ type: 'network-recovered' });
  });
})().catch(error => { document.getElementById('error').textContent = error.message; });
