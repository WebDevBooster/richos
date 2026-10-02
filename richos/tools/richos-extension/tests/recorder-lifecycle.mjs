/** Regression: exercise the production recorder with delayed final chunks and failed devices. */
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { DB } from '../core/constants.js';

const rows = [];
globalThis.__recorderStore = {
  async put(store, row) { await new Promise(r => setTimeout(r, 5)); if (store === DB.stores.chunks) rows.push(row); },
  async putAll() {}, async get() {}, async getAll() { return rows; }, async deleteBySession() {},
};
const stream = label => ({ getAudioTracks() { return this.getTracks(); }, getTracks() { return [this.track]; },
  track: { label, readyState: 'live', enabled: true, muted: false, stop() { this.readyState = 'ended'; }, addEventListener() {}, getSettings() { return {}; } } });
let failAcquire = false;
Object.defineProperty(globalThis, 'navigator', { configurable: true, value: { mediaDevices: {
  async getUserMedia(options) { if (failAcquire) throw new Error('device unavailable'); return stream(options.audio.mandatory ? 'tab' : 'mic'); }
} } });
globalThis.chrome = { runtime: { async sendMessage() {}, getURL: x => x } };
globalThis.IDBKeyRange = { only: x => x };
class Node { connect() {} disconnect() {} }
globalThis.AudioContext = class {
  state = 'running'; destination = new Node(); sampleRate = 48000;
  audioWorklet = { async addModule() { throw new Error('use analyser fallback'); } };
  createChannelMerger() { return new Node(); } createMediaStreamDestination() { return { stream: stream('dest') }; }
  createGain() { return Object.assign(new Node(), { gain: { value: 0 } }); }
  createMediaStreamSource() { return new Node(); }
  createAnalyser() { return Object.assign(new Node(), { fftSize: 2048, getFloatTimeDomainData(a) { a.fill(0.1); } }); }
  async close() { this.state = 'closed'; } async resume() { this.state = 'running'; }
};
const recorders = [];
let releaseFinal;
globalThis.MediaRecorder = class {
  static isTypeSupported() { return true; }
  state = 'inactive'; listeners = new Map();
  constructor() { recorders.push(this); this.id = recorders.length - 1; }
  addEventListener(event, fn) { this.listeners.set(event, fn); }
  removeEventListener(event) { this.listeners.delete(event); }
  emit(text, pending = false) {
    this.ondataavailable({ data: { size: text.length, async arrayBuffer() {
      if (pending) await new Promise(resolve => { releaseFinal = resolve; });
      return new TextEncoder().encode(text).buffer;
    } } });
  }
  start() { this.state = 'recording'; this.emit(`HEADER${this.id}`); }
  stop() { this.state = 'inactive'; this.emit(`TAIL${this.id}`, this.id === 0); this.listeners.get('stop')?.(); }
};
let source = await readFile(new URL('../modules/call-capture/recorder.js', import.meta.url), 'utf8');
source = source.replace("import { put, putAll, get, getAll, deleteBySession } from '../../core/idb.js';", 'const {put,putAll,get,getAll,deleteBySession} = globalThis.__recorderStore;');
for (const relative of ['../../core/constants.js', '../../core/zip.js', './constants.js']) {
  source = source.replaceAll(relative, new URL(relative, new URL('../modules/call-capture/recorder.js', import.meta.url)).href);
}
const recorder = await import('data:text/javascript;base64,' + Buffer.from(source).toString('base64'));
const started = await recorder.start({ sessionId: 'race', streamId: 'valid', settings: {} });
assert.equal(started.ok, true);
const rotation = recorder.restartRecorder();
await new Promise(r => setTimeout(r, 20));
assert.equal(recorders.length, 1, 'rotation must wait for final chunk durability before creating the next recorder');
releaseFinal();
await rotation;
assert.deepEqual(rows.map(r => [r.part, new TextDecoder().decode(r.data)]), [[0,'HEADER0'],[0,'TAIL0']], 'old tail must stay in old part');
const before = recorder.status();
const refused = await recorder.reattachTab({ streamId: null });
assert.equal(refused.ok, false);
assert.equal(recorder.status().tabTrack.readyState, 'live', 'missing invocation must preserve the live tab');
assert.equal(recorder.status().micOnlyFailover, false);
failAcquire = true;
await recorder.reattachTab({ streamId: 'expired' });
await recorder.reacquireMic();
assert.equal(recorder.status().tabTrack.readyState, 'live', 'failed replacement must preserve tab');
assert.equal(recorder.status().micTrack.readyState, 'live', 'failed replacement must preserve mic');
assert.equal(recorder.status().part, before.part, 'device replacement failures must not rotate recorder');
failAcquire = false;
await recorder.reattachTab({ streamId: 'new' });
assert.equal(recorder.status().part, before.part, 'stable audio destination needs no rotation for a source replacement');
const stopped = await recorder.stop();
assert.equal(stopped.chunkCount, 4, 'stop must await every committed chunk');
assert.deepEqual(rows.map(r => [r.part, r.seq]), [[0,0],[0,1],[1,2],[1,3]]);
const resumed = await recorder.start({ sessionId: 'race', streamId: 'valid', settings: {} });
assert.equal(resumed.ok, true);
assert.equal(recorder.status().part, 2, 'recreated offscreen recorder must not overwrite old part or sequence');
await recorder.stop();
assert.equal(new Set(rows.map(r => r.seq)).size, rows.length);
console.log('PASS production recorder delayed durability, replacement preservation and restart continuity');
