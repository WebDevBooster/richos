/** Own only export workers and export URLs. Never touch recorder streams or core URLs. */
const urls = new Set(), workers = new Set();
export function busy() { return urls.size > 0 || workers.size > 0; }
export function handleExportFile(message) {
  if (message.module !== 'gptExporter') return undefined;
  if (message.action === 'revoke-blob-url') {
    if (urls.delete(message.url)) URL.revokeObjectURL(message.url);
    return Promise.resolve({ success: true });
  }
  if (!['create-blob-url', 'create-zip-blob-url'].includes(message.action)) return undefined;
  return new Promise(resolve => {
    const worker = new Worker(new URL('./packaging-worker.js', import.meta.url));
    workers.add(worker);
    const finish = result => {
      clearTimeout(timer); workers.delete(worker); worker.terminate(); resolve(result);
    };
    const timer = setTimeout(() => finish({ success: false, error: 'Export packaging timed out; recording continues' }), 120000);
    worker.onerror = () => finish({ success: false, error: 'Export packaging worker failed' });
    worker.onmessage = ({ data }) => {
      if (data.error) return finish({ success: false, error: data.error });
      const url = URL.createObjectURL(data.blob);
      urls.add(url); finish({ success: true, url });
    };
    worker.postMessage(message);
  });
}
