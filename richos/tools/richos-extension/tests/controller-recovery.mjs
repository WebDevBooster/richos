import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { DB, KEYS } from '../core/constants.js';
import { CAPTURE_DEFAULTS } from '../modules/call-capture/constants.js';
let now = 1700000000000;
Date.now = () => now;
globalThis.IDBKeyRange = { only: value => value };
const store = {};
const calls = [];
const rows = new Map();
let invoked = true;
let downloads = 0;
let cancelExport = true;
let orphanIDs = [];
const settings = { ...CAPTURE_DEFAULTS, armMode: 'manual', captureCaptions: false };
globalThis.chrome = {
  runtime: { id: 'extension', getManifest: () => ({ version: '0.3.0' }) },
  tabCapture: { async getMediaStreamId() { if (!invoked) throw new Error('needs invocation'); return 'valid'; } },
  tabs: { async get(id) { return { id, url: 'https://app.zoom.us/wc/12345678901/start', audible: true }; }, async query() { return []; } },
  storage: { session: { async get(key) { return structuredClone({ [key]: store[key] }); }, async set(value) { Object.assign(store, structuredClone(value)); } }, local: { async get(key) { return structuredClone({ [key]: store[key] }); }, async set(value) { Object.assign(store, structuredClone(value)); }, async remove(key) { delete store[key]; } } },
};
globalThis.__controllerDependencies = {
  getModuleSettings: async module => module === 'core' ? { dropFolder: 'capture' } : settings,
  ensureOffscreen: async () => {}, closeOffscreen: async () => {}, offscreenExists: async () => true,
  async callOffscreen(message) {
    calls.push(message);
    if (message.type === 'cc:orphans') return {ok:true,sessionIds:orphanIDs};
    if (message.type === 'cc:start') return { ok: true, hasMic: true, hasTab: true };
    if (message.type === 'cc:stop') return { ok: true };
    if (message.type === 'cc:archive') return { ok: true, url: 'blob:archive' };
    if (message.type === 'cc:assemble') return { ok: true, parts: [] };
    if (message.type === 'cc:health-jsonl') return { ok: true, text: '', count: 0 };
    return { ok: true };
  },
  writeText: async () => { downloads++; return { ok: true }; }, writeUrl: async (file, url, options) => {
    downloads++; assert.ok(file.endsWith('.zip')); assert.equal(options.userInitiated, true);
    return cancelExport ? { ok: false, error: 'USER_CANCELED' } : { ok: true };
  }, setDownloadUi: async () => {},
  raiseAlert: async () => true, setHealth: async () => {}, resetAlertThrottle: async () => {}, notifyRoutine: async () => {}, resolveAlerts: async () => {},
  async put(storeName, record) { rows.set(`${storeName}:${record.sessionId}`, structuredClone(record)); },
  async get(storeName, id) { return rows.get(`${storeName}:${id}`); }, async getAll(storeName) { return storeName === DB.stores.chunks ? [{ part: 0, seq: 0, bytes: 10000, data: new Uint8Array(10000).buffer }] : []; }, async deleteBySession() {},
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
  assert.equal(downloads, 0, 'startup checkpoint must not create a download');
  assert.equal([...rows.values()][0].status, 'open', 'call existence must be durable before audio starts');
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
  assert.equal(downloads, 0, 'watchdog failure checkpoints must not create downloads');
  const closed = await controller.finalize('test-complete');
  assert.equal(closed.exportPending, true);
  assert.equal(closed.verdict.ok, false);
  assert.ok(closed.verdict.problems.some(p => p.includes('EBML header')), 'corrupt orphan or native parts must not be labelled usable');
  assert.equal(downloads, 0, 'automatic close must not create downloads');
  assert.equal((await controller.callCaptureModule.getStatus()).pendingExports.length, 1);
  const sessionId = closed.sessionId;
  const firstExport = await controller.callCaptureModule.onMessage({ type: 'cc:export-session', sessionId });
  assert.equal(firstExport.ok, false);
  assert.equal((await controller.callCaptureModule.getStatus()).pendingExports.length, 1, 'cancelled export must remain recoverable');
  cancelExport = false;
  assert.equal((await controller.callCaptureModule.onMessage({ type: 'cc:export-session', sessionId })).ok, true);
  assert.equal((await controller.callCaptureModule.getStatus()).pendingExports.length, 0);
  assert.equal(downloads, 2, 'each explicit export produces exactly one download');
  now += 1000;
  await controller.armTab(8, 'shortcut');
  assert.equal((await controller.callCaptureModule.onMessage({type:'cc:platform-ended'}, {id:'extension',url:'https://app.zoom.us/wc/99999999999/join',tab:{id:8,url:'https://app.zoom.us/wc/12345678901/start'}})).ignored,true);
  assert.equal((await controller.callCaptureModule.getStatus()).active,true);
  const ended = await controller.callCaptureModule.onMessage({type:'cc:platform-ended'}, {id:'extension',url:'https://app.zoom.us/wc/12345678901/start',tab:{id:8,url:'https://app.zoom.us/wc/12345678901/start'}});
  assert.equal(ended.exportPending,true);
  assert.equal((await controller.callCaptureModule.getStatus()).active,false);
  assert.equal((await controller.armTab(8,'auto')).error,'this Zoom meeting has ended');
  const saved = {...rows.get(`${DB.stores.sessions}:${ended.sessionId}`),status:'closed',transport:'native',exportPending:false,verification:{ok:true,problems:[]}};
  rows.set(`${DB.stores.sessions}:${saved.sessionId}`,structuredClone(saved));
  orphanIDs=[saved.sessionId];
  await controller.__testHooks.recoverAfterRestart();
  assert.deepEqual(rows.get(`${DB.stores.sessions}:${saved.sessionId}`),saved,'diagnostic native copies must preserve the completed save and verdict');
  const exportedCopy={...saved,transport:'browser',exportedAt:now,verification:{ok:false,problems:['flagged but explicitly exported']}};
  rows.set(`${DB.stores.sessions}:${saved.sessionId}`,structuredClone(exportedCopy));
  await controller.__testHooks.recoverAfterRestart();
  assert.deepEqual(rows.get(`${DB.stores.sessions}:${saved.sessionId}`),exportedCopy,'successful explicit exports must not be repeated just because diagnostic rows remain');
  console.log('PASS production controller invocation recovery, durable fallback and cancelled export retry');
} finally { await controller.finalize('test-cleanup'); }
