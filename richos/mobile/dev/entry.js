// Compiled into the simulator Debug bundle only.
(async () => {
  const key = 'richos.mobile.development.v1';
  const saved = localStorage.getItem(key);
  const runtime = await RichOSFixtures.createRuntime({ initial: saved ? JSON.parse(saved) : undefined,
    save: async (value) => localStorage.setItem(key, JSON.stringify(value)), onApp: RichOSView.attach });
  let tail = Promise.resolve();
  globalThis.RichOSDev = { execute(request) {
    const result = tail.then(() => runtime.execute(request));
    tail = result.catch(() => {});
    return result;
  } };
  document.documentElement.dataset.ready = 'true';
})().catch((error) => { document.getElementById('error').textContent = error.message; });
