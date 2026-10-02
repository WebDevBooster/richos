import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { DB, KEYS } from '../core/constants.js';
import { CAPTURE_DEFAULTS } from '../modules/call-capture/constants.js';
let now = 1700000000000;
Date.now = () => now;
const store = {};
const calls = [];
const rows = new Map();
let invoked = true;
const settings = { ...CAPTURE_DEFAULTS, armMode: 'manual', captureCaptions: false };
globalThis.chrome = {
  runtime: { getManifest: () => ({ version: '0.3.0' }) },
  tabCapture: { async getMediaStreamId() { if (!invoked) throw new Error('needs invocation'); return 'valid'; } },
  tabs: { async get(id) { return { id, url: 'https://app.zoom.us/wc/12345678901/start', audible: true }; }, async query() { return []; } },
  storage: { local: { async get(key) { return structuredClone({ [key]: store[key] }); }, async set(value) { Object.assign(store, structuredClone(value)); }, async remove(key) { delete store[key]; } } },
};
globalThis.__controllerDependencies = {
  getModuleSettings: async module => module === 'core' ? { dropFolder: 'capture' } : settings,
  ensureOffscreen: async () => {}, closeOffscreen: async () => {}, offscreenExists: async () => true,
  async callOffscreen(message) {
    calls.push(message);
    if (message.type === 'cc:start') return { ok: true, hasMic: true, hasTab: true };
    if (message.type === 'cc:stop') return { ok: true };
    if (message.type === 'cc:assemble') return { ok: true, parts: [] };
    if (message.type === 'cc:health-jsonl') return { ok: true, text: '', count: 0 };
    return { ok: true };
  },
  writeText: async () => ({ ok: true }), writeUrl: async () => ({ ok: true }), setDownloadUi: async () => {},
  raiseAlert: async () => true, setHealth: async () => {}, resetAlertThrottle: async () => {}, notifyRoutine: async () => {}, resolveAlerts: async () => {},
  async put(storeName, record) { rows.set(`${storeName}:${record.sessionId}`, structuredClone(record)); },
  async get(storeName, id) { return rows.get(`${storeName}:${id}`); }, async getAll() { return []; }, async deleteBySession() {},
};
let source = await readFile(new URL('../modules/call-capture/controller.js', import.meta.url), 'utf8');
for (const dependency of ['settings.js','offscreen-host.js','output.js','alerts.js','idb.js']) {
  source = source.replace(new RegExp("import \\{([^}]+)\\} from '../../core/" + dependency.replace('.', '\\.') + "';"), (match, names) => {
    if (dependency === 'output.js') names = names.replace('dropPath,', '');
    return `const {${names}} = globalThis.__controllerDependencies;` + (dependency === 'output.js' ? "\nconst dropPath = (...parts) => parts.join('/');" : '');
  });
}
for (const match of source.matchAll(/from '([^']+)'/g)) {
  source = source.replace(match[1], new URL(match[1], new URL('../modules/call-capture/controller.js', import.meta.url)).href);
}
const controller = await import('data:text/javascript;base64,' + Buffer.from(source).toString('base64'));
try {
  assert.equal((await controller.armTab(8, 'shortcut')).ok, true);
  invoked = false;
  now += 40000;
  await controller.callCaptureModule.onMessage({ type: 'cc:heartbeat', sessionId: store[KEYS.activeSession].record.sessionId,
    t: now, recorderState: 'recording', ctxState: 'running', chunkCount: 10, bytesTotal: 90000, lastChunkAt: now,
    micTrack: { readyState: 'live' }, tabTrack: { readyState: 'ended' }, micRms: .02, tabRms: .02 });
  let status = await controller.callCaptureModule.getStatus();
  assert.equal(status.awaitingTabAudio, true, 'lost tab must expose an invocation recovery path');
  assert.equal(status.mode, 'mic+captions', 'full mode must never conceal a lost tab');
  assert.equal(calls.filter(c => c.type === 'cc:reattach-tab').length, 0, 'refused mint must not detach a stream');
  invoked = true;
  const recovered = await controller.armTab(8, 'shortcut');
  assert.equal(recovered.upgraded, true, 'the real shortcut must restore a lost tab in an existing session');
  status = await controller.callCaptureModule.getStatus();
  assert.equal(status.awaitingTabAudio, false);
  assert.equal(status.micOnlyFailover, false);
  assert.equal(status.mode, 'full');
  assert.equal(calls.filter(c => c.type === 'cc:reattach-tab').length, 1);
  console.log('PASS production controller truthful failover and invocation recovery');
} finally { await controller.finalize('test-cleanup'); }
