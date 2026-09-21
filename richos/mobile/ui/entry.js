// Release shell: no fixture loader, fake connection or command bridge.
// Real pairing/transport adapters are Part 1 work. Do not imply that a Mac is connected.
(async () => {
  const key = 'richos.mobile.outbox.v1';
  let records = JSON.parse(localStorage.getItem(key) || '[]');
  const persist = () => localStorage.setItem(key, JSON.stringify(records));
  const app = await RichOSMobile.createApp({
    storage: { all: async () => records,
      put: async (item) => { records = records.filter((i) => i.clientId !== item.clientId); records.push(item); persist(); },
      remove: async (id) => { records = records.filter((i) => i.clientId !== id); persist(); } },
    session: { read: async () => ({ threads: [{ id: 'general', title: 'General' }], selectedThreadId: 'general', draft: '', paired: false, online: false }), write: async () => {} },
    clock: { now: () => Date.now() }, nextId: () => crypto.randomUUID(),
    transport: { sendText: async () => { throw new Error('Transport is not configured'); } }
  });
  RichOSView.attach(app);
})().catch((error) => { document.getElementById('error').textContent = error.message; });
