(async () => {
  const $ = id => document.getElementById(id);
  const listeners = new Set();
  globalThis.RichOSNativeEvent = event => { for (const fn of listeners) fn(event); };
  const call = (method, args = {}) => window.webkit.messageHandlers.richos.postMessage({ method, args });
  const ports = RichOSNative.createPorts(call, fn => { listeners.add(fn); return () => listeners.delete(fn); });
  const app = await RichOSClient.createClient(ports);
  async function perform(action) { try { await app.dispatch(action); } catch (error) { $('error').textContent = error.message; } }
  globalThis.RichOSClientInspect?.(app);
  app.subscribe(state => {
    $('connection').textContent = state.confirmed ? state.online ? 'Connected to your Mac' : 'Mac is offline · messages stay on this phone' : 'Pairing required';
    $('pairing').hidden = state.confirmed;
    $('fingerprint').hidden = !state.words;
    $('words').textContent = state.words || '';
    $('thread').replaceChildren(...state.threads.map(t => { const e = document.createElement('option'); e.value = t.id; e.textContent = t.title; return e; }));
    $('thread').value = state.selectedThreadId;
    if ($('message').value !== state.draft) $('message').value = state.draft;
    $('send').disabled = !state.confirmed;
    $('history').replaceChildren(...state.messages.map(m => { const e = document.createElement('li'); e.textContent = `${m.role === 'ceo' ? 'You' : 'Rich'}: ${m.text}`; return e; }));
    $('outbox').replaceChildren(...state.outbox.map(m => { const e = document.createElement('li'); e.textContent = `${m.text} · ${m.state}`; return e; }));
    $('record-start').disabled = state.recording; $('record-stop').disabled = !state.recording; $('record-cancel').disabled = !state.recording;
    $('record-status').textContent = state.recording ? 'Recording…' : 'Recordings stay on this phone. Sending voice is not available in this build.';
    $('recordings').replaceChildren(...state.recordings.map(r => {
      const e = document.createElement('li'); e.textContent = `${Math.round(r.seconds)} seconds · saved on this phone `;
      const b = document.createElement('button'); b.textContent = 'Delete recording'; b.onclick = () => perform({ type: 'record-delete', id: r.id }); e.append(b); return e;
    }));
    $('error').textContent = state.error || '';
  });
  $('pair-form').onsubmit = event => { event.preventDefault(); perform({ type: 'pair', link: $('pair-link').value }); };
  $('confirm').onclick = () => perform({ type: 'confirm-pair', matched: true });
  $('reject').onclick = () => perform({ type: 'confirm-pair', matched: false });
  $('composer').onsubmit = event => { event.preventDefault(); perform({ type: 'send' }); };
  $('message').oninput = () => perform({ type: 'compose', text: $('message').value });
  $('thread').onchange = () => perform({ type: 'select-thread', threadId: $('thread').value });
  $('retry').onclick = () => perform({ type: 'retry' });
  for (const type of ['record-start', 'record-stop', 'record-cancel']) $(type).onclick = () => perform({ type });
  listeners.add(event => {
    if (event.kind === 'record-finished') perform({ type: 'record-refresh' });
    if (event.kind === 'background') perform({ type: 'suspend' });
    if (event.kind === 'foreground') perform({ type: 'resume' });
  });
})().catch(error => { document.getElementById('error').textContent = error.message; });
