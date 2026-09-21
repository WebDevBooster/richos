// Rendering and input only. All behavior goes through core.dispatch.
globalThis.RichOSView = (() => {
  let current;
  let unsubscribe;
  const $ = (id) => document.getElementById(id);
  async function perform(action) {
    try { $('error').textContent = ''; await current.dispatch(action); }
    catch (error) { $('error').textContent = error.message; }
  }
  function render(state) {
    $('connection').textContent = !state.paired ? 'Pairing required' : state.online ? 'Online' : 'Offline · messages stay on this phone';
    const select = $('thread');
    select.replaceChildren(...state.threads.map((thread) => {
      const option = document.createElement('option'); option.value = thread.id; option.textContent = thread.title; return option;
    }));
    select.value = state.selectedThreadId;
    if ($('message').value !== state.draft) $('message').value = state.draft;
    $('send').disabled = !state.paired;
    $('retry').disabled = !state.paired || !state.online || !state.outbox.length;
    $('empty').hidden = state.outbox.length !== 0;
    $('outbox').replaceChildren(...state.outbox.map((item) => {
      const row = document.createElement('li');
      row.textContent = item.text;
      const status = document.createElement('small');
      status.textContent = `${item.state} · ${item.threadId}${item.lastReason ? ` · ${item.lastReason}` : ''}`;
      row.append(status); return row;
    }));
  }
  $('message').addEventListener('input', () => perform({ type: 'compose', text: $('message').value }));
  $('thread').addEventListener('change', () => perform({ type: 'select-thread', threadId: $('thread').value }));
  $('composer').addEventListener('submit', (event) => { event.preventDefault(); perform({ type: 'send' }); });
  $('retry').addEventListener('click', () => perform({ type: 'retry' }));
  return { attach(app) { if (unsubscribe) unsubscribe(); current = app; unsubscribe = app.subscribe(render); } };
})();
