import test from 'node:test';
import assert from 'node:assert/strict';
import { createRequire } from 'node:module';
import { createHash, generateKeyPairSync, sign } from 'node:crypto';
import { readFileSync, rmSync } from 'node:fs';
import { join } from 'node:path';
import { startMac } from '../dev/mac-server.mjs';
const require = createRequire(import.meta.url);
const { createScratch } = require('./storage.cjs');
const { createClient } = require('../core/client.js');
const { createPorts } = require('../platform/native.js');
const pause = ms => new Promise(resolve => setTimeout(resolve, ms));

test('actual mobile client pairs, signs, receives and resumes against the production Rust stack', { timeout: 360000 }, async t => {
  const cache = createScratch('mac-proof');
  let server, client;
  t.after(async () => { client?.close(); await server?.close(); rmSync(cache, { recursive: true, force: true }); });
  server = await startMac(cache);
  const { state } = server;
  const { privateKey, publicKey } = generateKeyPairSync('ec', { namedCurve: 'prime256v1' });
  const listeners = new Set(), streams = new Map(), events = [], requests = [];
  let disk;
  const local = url => {
    assert.equal(new URL(url).origin, state.origin);
    return `http://127.0.0.1:${state.port}${new URL(url).pathname}${new URL(url).search}`;
  };
  const emit = event => { events.push(event.kind); for (const fn of listeners) fn(event); };
  const call = async (method, args) => {
    switch (method) {
      case 'configure': assert.equal(args.origin, state.origin); return true;
      case 'load': return structuredClone(disk);
      case 'save': disk = structuredClone(args.value); return true;
      case 'recordings': return [];
      case 'updateInfo': return { version: '0.1.0', build: '2', osVersion: '16.7.16', appId: null, storefront: null, configured: false };
      case 'hash': return createHash('sha256').update(args.value).digest('hex');
      case 'publicKey': return publicKey.export({ format: 'jwk' });
      case 'sign': return sign('sha256', Buffer.from(args.input), { key: privateKey, dsaEncoding: 'ieee-p1363' }).toString('base64url');
      case 'request': {
        requests.push(args);
        const response = await fetch(local(args.url), { method: args.method, headers: args.headers, body: args.method === 'GET' ? undefined : args.body });
        return { status: response.status, headers: Object.fromEntries(response.headers), body: await response.text() };
      }
      case 'streamClose': streams.get(args.id)?.abort(); streams.delete(args.id); return true;
      case 'streamOpen': {
        const controller = new AbortController(); streams.set(args.id, controller);
        void (async () => {
          try {
            const response = await fetch(local(args.url), { signal: controller.signal });
            assert.equal(response.status, 200);
            emit({ kind: 'stream-open', id: args.id });
            for await (const chunk of response.body) emit({ kind: 'stream-data', id: args.id, data: Buffer.from(chunk).toString('base64') });
          } catch (error) { if (!controller.signal.aborted) { t.diagnostic(error.message); emit({ kind: 'stream-error', id: args.id, error: error.message }); } }
        })();
        return true;
      }
      default: throw Error(method);
    }
  };
  const ports = createPorts(call, fn => { listeners.add(fn); return () => listeners.delete(fn); });
  const wait = async predicate => {
    const deadline = Date.now() + 10000;
    while (!predicate() && Date.now() < deadline) await pause(25);
    assert(predicate(), JSON.stringify({ state: client.state(), events }));
  };
  assert.equal((await fetch(`http://127.0.0.1:${state.port}/api/messages`, { method: 'POST', body: '{}' })).status, 404);
  client = await createClient(ports);
  await client.dispatch({ type: 'pair', link: state.pairLink });
  assert.equal(client.state().words, state.words);
  await client.dispatch({ type: 'confirm-pair', matched: true });
  await wait(() => client.state().online);
  const message = 'Rust integration ' + crypto.randomUUID();
  await client.dispatch({ type: 'compose', text: message });
  await client.dispatch({ type: 'send' });
  const reply = () => client.state().messages.find(row => row.role === 'rich' && row.text === 'ack: ' + message && row.complete);
  await wait(reply);
  assert.equal(client.state().outbox.length, 0);
  const sent = requests.find(row => row.url.endsWith('/api/messages') && row.headers.Authorization);
  assert(sent);
  const challengeResponse = await fetch(`http://127.0.0.1:${state.port}/api/challenge`);
  const challenge = challengeResponse.headers.get('x-richos-challenge');
  const input = `${challenge}\nPOST\n/api/messages\n${createHash('sha256').update(sent.body).digest('hex')}`;
  const wrong = await call('sign', { input: input + 'wrong' });
  const signed = await call('sign', { input });
  const headers = signature => ({ 'Content-Type': 'application/json', Authorization: `RichOS-Device ${disk.api.deviceId}.${challenge}.${signature}` });
  assert.equal((await fetch(local(sent.url), { method: 'POST', body: sent.body, headers: headers(wrong) })).status, 404);
  const duplicate = await fetch(local(sent.url), { method: 'POST', body: sent.body, headers: headers(signed) });
  assert.equal(duplicate.status, 200); assert.equal((await duplicate.json()).duplicate, true);
  client.close(); client = await createClient(ports);
  assert(reply(), 'reply survives client process state restoration');
  const previous = events.filter(kind => kind === 'stream-open').length;
  await wait(() => client.state().online && events.filter(kind => kind === 'stream-open').length > previous);
  const second = message + ' after restart';
  await client.dispatch({ type: 'compose', text: second }); await client.dispatch({ type: 'send' });
  await wait(() => client.state().messages.some(row => row.role === 'rich' && row.text === 'ack: ' + second && row.complete));
  client.close(); await server.close();
  assert.deepEqual(await server.exited, [0, null]);
  const timeline = JSON.parse(readFileSync(join(cache, 'mac-timeline.json'), 'utf8'));
  assert.equal(timeline.items.filter(row => row.kind === 'user_message' && row.text === message).length, 1);
  assert(timeline.items.some(row => row.kind === 'rich_message' && row.text === 'ack: ' + second));
  await assert.rejects(fetch(`http://127.0.0.1:${state.port}/api/challenge`));
});
