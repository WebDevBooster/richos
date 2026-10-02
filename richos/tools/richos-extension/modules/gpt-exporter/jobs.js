/** Durable export job and response cache. No recorder stores or session keys. */
const DB_NAME = 'richos-gpt-exporter';
let opening, current = null, queue = Promise.resolve();
function database() {
  if (!opening) opening = new Promise((resolve, reject) => {
    const request = indexedDB.open(DB_NAME, 1);
    request.onupgradeneeded = () => {
      request.result.createObjectStore('jobs');
      request.result.createObjectStore('cache');
    };
    request.onsuccess = () => resolve(request.result);
    request.onerror = () => { opening = null; reject(request.error); };
  });
  return opening;
}
async function transaction(store, mode, action) {
  const db = await database();
  return new Promise((resolve, reject) => {
    const tx = db.transaction(store, mode);
    const request = action(tx.objectStore(store));
    tx.oncomplete = () => resolve(request.result);
    tx.onerror = tx.onabort = () => reject(tx.error || request.error || new Error('Export checkpoint failed'));
  });
}
export async function getJob() {
  if (!current) current = await transaction('jobs', 'readonly', s => s.get('current')) || null;
  return current;
}
export function checkpoint(job = current) {
  if (!job) return Promise.resolve();
  const snapshot = structuredClone(job);
  const next = queue.catch(() => {}).then(() => transaction('jobs', 'readwrite', s => s.put(snapshot, 'current')));
  queue = next;
  return next;
}
export async function newJob(options, contextKey, tabId) {
  await transaction('cache', 'readwrite', s => s.clear());
  current = { id: crypto.randomUUID(), options, contextKey, tabId, startedAt: Date.now(),
    phase: 'starting', current: 0, total: 0, status: 'running', outputs: {}, nextRequestAt: 0 };
  await checkpoint();
  return current;
}
export async function cacheRequest(message, value) {
  if (current?.status !== 'running') return;
  await transaction('cache', 'readwrite', s => s.put(value, JSON.stringify(message)));
}
export async function cachedRequest(message) {
  if (current?.status !== 'running') return null;
  return transaction('cache', 'readonly', s => s.get(JSON.stringify(message)));
}
export async function waitPacing(ms, check) {
  if (current?.status === 'running') {
    current.nextRequestAt = Date.now() + ms;
    await checkpoint();
  }
  const until = Date.now() + ms;
  // Keep original pacing but respond promptly to cancellation.
  while (Date.now() < until) {
    check();
    await new Promise(resolve => setTimeout(resolve, Math.min(250, until - Date.now())));
  }
  check();
}
export async function resumePacing(check = () => {}) {
  const delay = Math.max(0, (current?.nextRequestAt || 0) - Date.now());
  if (delay) await waitPacing(delay, check);
}
export async function saveOutput(output, job = current) {
  if (!job) return;
  if (output) job.outputs[output.path] = output;
  await checkpoint(job);
}
export async function savedOutput(path) { return (await getJob())?.outputs?.[path]; }
export async function updateJob(patch) {
  const job = await getJob();
  if (job) { Object.assign(job, patch); await checkpoint(job); }
}
