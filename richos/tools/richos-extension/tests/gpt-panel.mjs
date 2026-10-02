import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import vm from 'node:vm';
const root = new URL('../modules/gpt-exporter/', import.meta.url);
const html = await readFile(new URL('panel.html', root), 'utf8');
const source = await readFile(new URL('panel.js', root), 'utf8');
const elements = new Map(), messages = [], timers = [], listeners = [];
function element() {
  const classes = new Set();
  return { value: '', checked: false, disabled: true, hidden: false, style: {}, children: [], handlers: {}, textContent: '',
    classList: { add: x => classes.add(x), remove: (...x) => x.forEach(y => classes.delete(y)), contains: x => classes.has(x) },
    appendChild(child) { this.children.push(child); }, addEventListener(type, fn) { this.handlers[type] = fn; }, querySelector() { return this; },
    get firstChild() { return this.children[0]; }, remove() {}, click() {} };
}
for (const match of html.matchAll(/id="([^"]+)"/g)) elements.set(match[1], element());
elements.get('formatMarkdown').checked = true;
let initialize, jobRunning = true;
const chrome = {
  permissions: { async contains() { return true; }, async request() { return true; } },
  runtime: { lastError: null, getURL: p => 'chrome-extension://test/'+p,
    onMessage: { addListener: fn => listeners.push(fn) },
    sendMessage(message, callback) {
      messages.push(message);
      let response;
      if (message.type === 'core:get-settings') response = { settings: { gptExporter: { downloadFolder: '中文', exportLimit: 7, includeAboveBranchedFrom: false } } };
      else if (message.type === 'core:update-settings') response = { ok: true };
      else if (message.action === 'checkConnection') response = { connected: true };
      else if (message.action === 'getCurrentConversationTarget') response = { available: true, conversationId: 'test' };
      else if (message.action === 'getStats') response = { totalExported: 2, lastSyncTime: null };
      else if (message.action === 'getExportState') response = { isRunning: jobRunning, state: { phase: 'saving', current: 0, total: 1 }, job: { status: jobRunning ? 'running' : 'complete' } };
      else response = { totalExported: 1, success: true };
      if (callback) { queueMicrotask(() => callback(response)); return; }
      return Promise.resolve(response);
    }
  }, windows: { create() {} }
};
const context = vm.createContext({ chrome, document: { getElementById: id => elements.get(id), createElement: element, addEventListener(type, fn) { if (type === 'DOMContentLoaded') initialize = fn; } },
  window: { innerWidth: 420, close() {} }, console: { log() {}, error() {} }, Date, URL, Blob, setTimeout() {}, setInterval(fn) { timers.push(fn); }, alert() {}, confirm() { return true; } });
vm.runInContext(source, context);
await initialize();
assert.equal(elements.get('downloadFolder').value, '中文');
assert.equal(elements.get('exportLimit').value, 7);
assert.equal(elements.get('includeAboveBranchedFrom').checked, false);
assert.equal(elements.get('btnExportAll').disabled, true, 'reopened panel must show existing export');
assert.equal(elements.get('progressText').textContent, 'Saving export... waiting for Chrome to finish');
jobRunning = false;
await vm.runInContext('checkExportState()', context);
assert.equal(elements.get('btnExportAll').disabled, false, 'completed job must re-enable reopened controls');
await elements.get('btnExportCurrent').handlers.click();
const start = messages.find(m => m.action === 'exportCurrentConversation');
assert.equal(start.module, 'gptExporter'); assert.equal(start.target, 'sw');
assert.equal(start.downloadFolder, '中文'); assert.equal(start.limit, 7);
assert.equal(start.formats.markdown, true); assert.equal(start.formats.json, false);
assert.equal(start.formats.includeAboveBranchedFrom, false);
listeners[0]({ module: 'callCapture', type: 'gpt:progress', phase: 'saving' });
assert.ok(elements.get('progressText').textContent.includes('Exported 1'));
listeners[0]({ module: 'gptExporter', type: 'gpt:progress', phase: 'saving', current: 0, total: 1 });
assert.equal(elements.get('progressText').textContent, 'Saving export... waiting for Chrome to finish');
assert.ok(html.includes('btnResume') && html.includes('historyFile') && html.includes('btnEnableAccess'));
const css = await readFile(new URL('popup.css', root), 'utf8');
assert.ok(css.includes('.hidden') && css.includes('.progress-fill'), 'panel ships its own style classes');
console.log('PASS exporter controls, namespaced settings/messages, saving status and popup reopening');
