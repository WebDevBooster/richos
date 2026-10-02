import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import vm from 'node:vm';
const source = await readFile(new URL('../popup/popup.js', import.meta.url), 'utf8');
const html = await readFile(new URL('../popup/popup.html', import.meta.url), 'utf8');
const elements = new Map();
function element() { return { children: [], listeners: {}, hidden: false, append(child) { this.children.push(child); }, replaceChildren() { this.children = []; }, addEventListener(type, handler) { this.listeners[type] = handler; } }; }
for (const match of html.matchAll(/id="([^"]+)"/g)) elements.set(match[1], element());
let status = { active: false, recent: [], pendingExports: [{ sessionId: 'call', startedAt: 1700000000000, bytes: 10000 }] };
const messages = [];
const context = vm.createContext({ document: { getElementById: id => elements.get(id), createElement: element }, Date, console,
  setInterval() {}, chrome: { runtime: { async sendMessage(message) { messages.push(message); return message.type === 'core:get-status' ? { modules: { callCapture: status } } : { ok: true }; }, openOptionsPage() {} } } });
vm.runInContext(source, context);
await new Promise(r => setImmediate(r));
assert.equal(elements.get('exports').children.length, 2, 'pending session must expose explicit export');
const button = elements.get('exports').children[1];
assert.ok(button.textContent.startsWith('Export '));
await button.listeners.click();
assert.equal(messages.filter(m => m.type === 'cc:export-session').length, 1);
assert.equal(messages.find(m => m.type === 'cc:export-session').sessionId, 'call');
status = { ...status, active: true, mode: 'full', transport: 'browser', startedAt: Date.now(), bytesTotal: 10000, chunkCount: 2 };
await vm.runInContext('refresh()', context);
assert.equal(elements.get('exports').children.length, 0, 'export must not be offered during a call');
assert.ok(elements.get('hint').textContent.includes('retained in this browser'));
console.log('PASS popup explicit export, selected session and in-call export suppression');
