import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { sessionZip } from '../core/zip.js';
import { writeUrl } from '../core/output.js';
import { NativeHostClient } from '../core/native-host-client.js';
const archive = sessionZip([{ name: 'call/session.json', data: '{"closed":true}' }, { name: 'call/audio-part-00.webm', data: new Uint8Array([0x1a,0x45,0xdf,0xa3,0,255]) }, { name: 'call/captions.ndjson', data: 'héllo' }]);
const independent = spawnSync('python3', ['-c', `import sys,io,zipfile,json
z=zipfile.ZipFile(io.BytesIO(sys.stdin.buffer.read()))
assert z.testzip() is None
assert z.namelist()==['call/session.json','call/audio-part-00.webm','call/captions.ndjson']
assert json.loads(z.read('call/session.json'))['closed'] is True
assert z.read('call/audio-part-00.webm')==bytes([26,69,223,163,0,255])
assert z.read('call/captions.ndjson').decode()=='héllo'
`], { input: Buffer.from(await archive.arrayBuffer()), encoding: 'utf8' });
assert.equal(independent.status, 0, independent.stderr);
assert.throws(() => sessionZip([{ name: '../escape', data: '' }]));
assert.throws(() => sessionZip([{ name: 'a', data: '' }, { name: 'a', data: '' }]));
let downloads = 0, revoked = 0;
globalThis.chrome = { runtime: { async getContexts() { return [{}]; }, async sendMessage() { revoked++; return { ok: true }; } }, downloads: {
  async download() { downloads++; return 1; }, onChanged: { addListener() {}, removeListener() {} }, search(query, callback) { callback([{ state: 'complete' }]); }
} };
assert.equal((await writeUrl('automatic.json', 'blob:blocked')).ok, false);
assert.equal(downloads, 0, 'automated output must never create a Chrome save picker');
assert.equal((await writeUrl('explicit.zip', 'blob:export', { userInitiated: true })).ok, true);
assert.equal(downloads, 1);
assert.equal(revoked, 2);
const listeners = {};
let rejectChunk = false;
const port = { onMessage: { addListener(fn) { listeners.message = fn; } }, onDisconnect: { addListener(fn) { listeners.disconnect = fn; } },
  postMessage(message) { queueMicrotask(() => {
    if (message.type === 'hello') listeners.message({ type: 'ready' });
    else if (message.type === 'audio-chunk') listeners.message(rejectChunk ? { type: 'error', error: 'disk full' } : { type: 'chunk-ack', sessionId: message.sessionId, part: message.part });
  }); }, disconnect() { listeners.disconnect(); } };
chrome.runtime.connectNative = () => port;
const host = new NativeHostClient();
assert.equal(await host.connect(), true);
assert.equal(await host.sendChunk('call', 0, 'YWJj'), true);
rejectChunk = true;
assert.equal(await host.sendChunk('call', 0, 'YWJj'), false, 'host disk failure must fail durable acknowledgment');
assert.equal(host.available, false);
console.log('PASS independent ZIP decoding, explicit download boundary and durable native acknowledgments');
