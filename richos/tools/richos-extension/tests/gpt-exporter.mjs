import assert from 'node:assert/strict';
import { test } from 'node:test';
import { setTimeout as delay } from 'node:timers/promises';
import { readFile } from 'node:fs/promises';
import vm from 'node:vm';
import { isChatGPTPage } from '../modules/gpt-exporter/sites.js';
import { validateMigration, validateDownloadPath } from '../modules/gpt-exporter/migration.js';
import { shouldAutoArm, isExcludedCapturePage } from '../modules/call-capture/platforms.js';

// Small transactional fixture; the browser suite separately exercises actual IndexedDB.
const stores = new Map();
globalThis.indexedDB = { open() {
  const request = {};
  const db = {
    createObjectStore(name) { stores.set(name, new Map()); },
    transaction(name) {
      const tx = { objectStore() { return {
        get(key) { return operation(() => structuredClone(stores.get(name).get(key))); },
        put(value, key) { return operation(() => { stores.get(name).set(key, structuredClone(value)); return key; }); },
        clear() { return operation(() => stores.get(name).clear()); }
      }; } };
      function operation(fn) { const r = {}; queueMicrotask(() => { r.result = fn(); tx.oncomplete?.(); }); return r; }
      return tx;
    }
  };
  queueMicrotask(() => { request.result = db; request.onupgradeneeded?.(); request.onsuccess?.(); });
  return request;
} };
const storage = { 'richos.settings': { callCapture: { enabled: true }, core: { notifyOnFailure: true } } };
const downloads = [], listeners = [], generated = [], requests = [];
let recording = true, offscreen = false, closeCount = 0, allowed = true, account = 'test-user:personal', count = 1;
const conversations = Array.from({ length: 4 }, (_, i) => ({
  id: `1234567${i}-1234-5678-9abc-def012345678`, conversation_id: `1234567${i}-1234-5678-9abc-def012345678`,
  title: `Test ${i}`, create_time: 1700000000, update_time: 1700000100, mapping: {}
}));
const tab = { id: 7, active: true, lastAccessed: 1, url: `https://chatgpt.com/c/${conversations[0].id}` };
globalThis.chrome = {
  permissions: { async contains() { return allowed; } },
  storage: { local: { async get(key) { return { [key]: structuredClone(storage[key]) }; }, async set(data) { Object.assign(storage, structuredClone(data)); } } },
  runtime: { id: 'test', getURL: path => `chrome-extension://test/${path}`, async getPlatformInfo() { return {}; }, async getContexts() { return offscreen ? [{}] : []; }, async sendMessage(message) {
    if (message.type === 'core:resource-status') return { ok: true, busy: recording };
    if (message.action?.startsWith('create-')) { generated.push(message); return { success: true, url: `blob:${generated.length}` }; }
    return { ok: true, success: true };
  } },
  offscreen: { async createDocument() { offscreen = true; }, async closeDocument() { offscreen = false; closeCount++; } },
  scripting: { async executeScript() {} },
  tabs: { async query() { return [tab]; }, async get() { return tab; }, async sendMessage(id, message) {
    assert.equal(message.module, 'gptExporter');
    requests.push(message);
    if (message.action === 'ping') return { hasToken: true, contextKey: account };
    if (message.action === 'getProjectsList') return { items: [] };
    if (message.action === 'getConversationsList') return { items: message.offset === 0 ? conversations.slice(0, count) : [] };
    if (message.action === 'getConversation') return structuredClone(conversations.find(c => c.id === message.id));
    throw new Error('Unexpected request');
  } },
  downloads: { onChanged: { addListener(fn) { listeners.push(fn); } }, async download(options) {
    const item = { id: downloads.length + 1, state: 'in_progress', exists: true, options };
    downloads.push(item); return item.id;
  }, async search({ id }) { return downloads.filter(x => x.id === id); }, async cancel(id) { finish(id, 'interrupted', 'USER_CANCELED'); } }
};
function finish(id, state, error) {
  Object.assign(downloads[id - 1], { state, error });
  listeners.forEach(fn => fn({ id, state: { current: state }, error: { current: error } }));
}
const { gptExporterModule: module } = await import('../modules/gpt-exporter/controller.js');
const { getJob } = await import('../modules/gpt-exporter/jobs.js');
const { acquireOffscreen, closeOffscreen } = await import('../core/offscreen-host.js');
const sender = { id: 'test', url: 'chrome-extension://test/popup/popup.html' };
const send = msg => module.onMessage(msg, sender);
async function until(fn, timeout = 2000) {
  const end = Date.now() + timeout;
  while (!fn()) { if (Date.now() > end) throw new Error('Fixture timed out'); await delay(10); }
}
const history = () => Object.keys(storage['richos.gptExporter.history']?.exportedConversations || {});
const start = (action, formats = { markdown: true }, limit = 1) => send({ action, formats, limit });

test('website boundaries exclude ChatGPT from every capture mode', () => {
  assert.equal(isChatGPTPage('https://chatgpt.com/c/test'), true);
  for (const url of ['http://chatgpt.com/', 'https://chatgpt.com.evil.test/', 'https://zoom.us/wc/123456789']) assert.equal(isChatGPTPage(url), false);
  for (const url of ['https://chatgpt.com/', 'https://chat.openai.com/']) {
    assert.ok(isExcludedCapturePage(url));
    assert.equal(shouldAutoArm({ url, audible: true, openedAt: 1 }, { armMode: 'auto', armUnknownAudible: true, armDelayMs: 0 }, 100).arm, false);
  }
});
for (const action of ['exportCurrentConversation', 'exportAll', 'exportNewUpdated']) {
  test(`${action} waits for completion, retains retry and cannot close recording`, { timeout: 10000 }, async () => {
    storage['richos.gptExporter.history'] = { exportedConversations: {}, lastSyncTime: null };
    const firstId = downloads.length + 1;
    const running = start(action);
    await until(() => downloads.length === firstId);
    assert.deepEqual(history(), []);
    assert.equal((await module.getStatus()).isRunning, true);
    assert.match((await start(action)).error, /already running/);
    finish(firstId, 'interrupted', 'FILE_FAILED');
    assert.match((await running).error, /FILE_FAILED/);
    assert.deepEqual(history(), []);
    assert.equal(closeCount, 0);
    const beforeRequests = requests.filter(x => x.action !== 'ping').length;
    const resumed = send({ action: 'resumeExport' });
    await until(() => downloads.length === firstId + 1);
    assert.equal(requests.filter(x => x.action !== 'ping').length, beforeRequests, 'resume reuses fetched output');
    finish(firstId + 1, 'complete');
    assert.equal((await resumed).totalExported, 1);
    assert.deepEqual(history(), [conversations[0].id]);
    assert.equal((await getJob()).status, 'complete');
    assert.equal(closeCount, 0, 'export completion must not close an active recorder');
  });
}
test('partial multi-format save resumes only its unfinished file', { timeout: 10000 }, async () => {
  storage['richos.gptExporter.history'] = { exportedConversations: {}, lastSyncTime: null };
  const id = downloads.length + 1;
  const result = start('exportCurrentConversation', { markdown: true, json: true });
  await until(() => downloads.length === id); finish(id, 'complete');
  await until(() => downloads.length === id + 1); finish(id + 1, 'interrupted', 'FILE_NO_SPACE');
  assert.match((await result).error, /FILE_NO_SPACE/); assert.deepEqual(history(), []);
  const retry = send({ action: 'resumeExport' });
  await until(() => downloads.length === id + 2);
  assert.equal(downloads[id + 1].options.filename, downloads[id].options.filename);
  finish(id + 2, 'complete'); assert.equal((await retry).totalExported, 1);
  assert.deepEqual(history(), [conversations[0].id]);
});
test('ZIP completion acknowledges every conversation only after save', { timeout: 30000 }, async () => {
  storage['richos.gptExporter.history'] = { exportedConversations: {}, lastSyncTime: null };
  count = 4;
  const id = downloads.length + 1;
  const result = start('exportAll', { markdown: true }, 4);
  await until(() => downloads.length === id, 20000);
  assert.ok(downloads[id - 1].options.filename.endsWith('.zip'));
  assert.deepEqual(history(), []); finish(id, 'complete');
  assert.equal((await result).totalExported, 4); assert.equal(history().length, 4); count = 1;
});
test('cancel and forced recorder recovery leave an export resumable', { timeout: 10000 }, async () => {
  const id = downloads.length + 1;
  const result = start('exportCurrentConversation');
  await until(() => downloads.length === id);
  await send({ action: 'cancelExport' });
  assert.match((await result).error, /USER_CANCELED/);
  assert.equal((await getJob()).status, 'interrupted');
  const next = send({ action: 'resumeExport' });
  await until(() => downloads.length === id + 1);
  await closeOffscreen({ force: true });
  assert.match((await next).error, /USER_CANCELED/);
  assert.equal((await getJob()).status, 'interrupted');
});
test('resume rejects changed account and page without mutating recording settings', async () => {
  account = 'other-user:personal';
  assert.match((await send({ action: 'resumeExport' })).error, /account or workspace changed/);
  account = 'test-user:personal';
  tab.url = 'https://chatgpt.com.evil.test/';
  assert.match((await send({ action: 'resumeExport' })).error, /left chatgpt.com/);
  tab.url = `https://chatgpt.com/c/${conversations[0].id}`;
  assert.deepEqual(storage['richos.settings'].callCapture, { enabled: true });
});
test('permission denial and page-origin messages cannot start exports', async () => {
  allowed = false;
  assert.match((await start('exportAll')).error, /Enable ChatGPT access/);
  allowed = true;
  assert.match((await module.onMessage({ action: 'exportAll' }, { id: 'test', url: 'https://chatgpt.com/', tab })).error, /RichOS Helper/);
});
test('explicit migration preserves call settings and rejects malicious paths/history', async () => {
  const data = { gpt_exporter_settings: { downloadFolder: 'Tëster/中文', exportLimit: 5 },
    gpt_exporter_sync_data: { exportedConversations: { [conversations[0].id]: { exportedAt: '2026-10-02T12:00:00Z', updateTime: '2026-10-01T12:00:00Z' } }, lastSyncTime: null } };
  assert.equal((await send({ action: 'importMigration', data })).success, true);
  assert.equal(storage['richos.settings'].gptExporter.downloadFolder, 'Tëster/中文');
  assert.deepEqual(storage['richos.settings'].callCapture, { enabled: true });
  assert.deepEqual((await send({ action: 'exportMigration' })).data.history, storage['richos.gptExporter.history']);
  for (const path of ['../x', '/x', 'C:/x', 'a/../x', 'a\\x', 'x\0y']) assert.throws(() => validateDownloadPath(path));
  assert.equal(validateDownloadPath('Tëster/中文 [ok].md'), 'Tëster/中文 [ok].md');
  assert.throws(() => validateMigration({ history: { exportedConversations: JSON.parse('{"__proto__":{}}') } }));
});
test('shared document leases survive routine closure and forced recovery notifies its owner', async () => {
  recording = false;
  let reset = false;
  const release = await acquireOffscreen('gptExporter', () => { reset = true; });
  assert.equal(await closeOffscreen(), false);
  assert.equal(reset, false);
  await closeOffscreen({ force: true }); assert.equal(reset, true);
  await release();
});
test('content bridge installs once, runs only on ChatGPT and ignores other modules', async () => {
  const source = await readFile(new URL('../modules/gpt-exporter/content.js', import.meta.url), 'utf8');
  const handlers = [], calls = [];
  const context = vm.createContext({ location: { origin: 'https://chatgpt.com' }, window: { location: { href: 'https://chatgpt.com/' } },
    document: { cookie: '', querySelectorAll: () => [] }, console, AbortController, setTimeout, clearTimeout,
    chrome: { runtime: { onMessage: { addListener: fn => handlers.push(fn) } } },
    fetch: async url => { calls.push(url); return { ok: true, json: async () => ({ accessToken: 'synthetic-token', user: { id: 'synthetic-user' } }) }; }
  });
  vm.runInContext(source, context); vm.runInContext(source, context);
  assert.equal(handlers.length, 1);
  assert.equal(handlers[0]({ module: 'callCapture', action: 'ping' }, {}, () => {}), false);
  let ping;
  handlers[0]({ module: 'gptExporter', action: 'ping' }, {}, response => { ping = response; });
  await until(() => ping); assert.equal(ping.contextKey, 'synthetic-user:personal');
  let denied;
  handlers[0]({ module: 'gptExporter', action: 'getConversation', contextKey: 'different:personal', id: 'test' }, {}, response => { denied = response; });
  await until(() => denied); assert.match(denied.error, /account or workspace changed/); assert.equal(calls.length, 1);
  const other = vm.createContext({ location: { origin: 'https://meet.google.com' } });
  vm.runInContext(source, other); assert.equal(other.__richosGptExporterBridge, undefined);
});

test('core registry routes exporter separately and retains an active call warning', async () => {
  const registry = await import('../core/registry.js');
  registry.registerModule({ id: 'callCapture', defaults: { enabled: true }, getStatus: async () => ({ active: true, level: 'red', reasons: [{ code: 'disk-write-failed' }] }) });
  registry.registerModule(module);
  const status = await registry.routeMessage({ type: 'core:get-status' }, sender);
  assert.equal(status.modules.callCapture.level, 'red');
  assert.ok(status.modules.gptExporter);
  assert.equal((await registry.routeMessage({ module: 'gptExporter', action: 'getStats' }, sender)).totalExported, history().length);
  const before = structuredClone(storage['richos.settings'].callCapture);
  await registry.routeMessage({ type: 'core:update-settings', moduleId: 'gptExporter', patch: { exportLimit: 9 } }, sender);
  assert.deepEqual(storage['richos.settings'].callCapture, before);
  assert.equal((await registry.routeMessage({ type: 'core:get-status' }, sender)).modules.callCapture.level, 'red');
});
