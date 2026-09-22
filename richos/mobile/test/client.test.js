const test = require('node:test');
const assert = require('node:assert/strict');
const { createClient, pairingLink } = require('../core/client.js');
const { sseParser } = require('../platform/native.js');
const { harness } = require('../dev/client-runtime.js');
const turn = () => new Promise(resolve => setImmediate(resolve));
async function pair(client) { await client.dispatch({ type: 'pair', link: 'https://mac.example/#pair=secret' }); await client.dispatch({ type: 'confirm-pair', matched: true }); await turn(); }

test('pairing accepts only a code-bearing HTTPS origin', () => {
  assert.deepEqual(pairingLink('https://mac.example:8443/#pair=a%2Bb'), { origin: 'https://mac.example:8443', code: 'a+b' });
  for (const link of ['http://mac/#pair=x','https://u:p@mac/#pair=x','https://mac/path#pair=x','https://mac/?q=x#pair=x','https://mac/#pair=x&pair=y','https://mac/#pair=x&other=y','https://mac/',' https://mac/#pair=x']) assert.throws(() => pairingLink(link));
});
test('pair confirmation gates sends; shared API signs and shared queue drains after a stream frame', async t => {
  const h = harness(), app = await createClient(h.ports); t.after(() => app.close());
  await app.dispatch({ type: 'pair', link: 'https://mac.example/#pair=secret' });
  await app.dispatch({ type: 'compose', text: 'hello' });
  await assert.rejects(app.dispatch({ type: 'send' }), /Pair/);
  await app.dispatch({ type: 'confirm-pair', matched: true }); await turn();
  assert.equal(h.origin(), 'https://mac.example');
  await app.dispatch({ type: 'send' }); assert.equal(app.state().outbox.length, 1);
  h.opened[0].event('hello', { challenge: 'fresh', capabilities: ['text'] }); await app.settle();
  assert.equal(app.state().outbox.length, 0);
  const sent = h.requests.find(x => x.url.endsWith('/api/messages'));
  assert.equal(JSON.parse(sent.body).text, 'hello'); assert.match(sent.headers.Authorization, /^RichOS-Device phone\./);
  assert(h.signed.some(x => x.includes('\nPOST\n/api/messages\n')));
});
test('suspend closes the sole stream; relaunch retains paired outbox and resume cursor', async t => {
  const h = harness(); let app = await createClient(h.ports); t.after(() => app.close()); await pair(app);
  h.opened[0].event('message', { id: 'reply', role: 'rich', text: 'answer', cursor: 7 }); await app.settle();
  await app.dispatch({ type: 'suspend' }); assert(h.opened[0].closed);
  await app.dispatch({ type: 'compose', text: 'offline' }); await app.dispatch({ type: 'send' });
  app.close(); app = await createClient(h.ports); await turn();
  assert.equal(app.state().outbox.length, 1); assert.equal(app.state().messages[0].text, 'answer');
  assert.match(h.opened.at(-1).url, /since=7/);
  await app.dispatch({ type: 'resume' }); await turn();
  assert.equal(h.opened.filter(x => !x.closed).length, 1);
});
test('recording files stay behind native ports; interruption retains a file and cancellation does not', async t => {
  const h = harness(), app = await createClient(h.ports); t.after(() => app.close());
  await app.dispatch({ type: 'record-start' }); assert(app.state().recording);
  await app.dispatch({ type: 'suspend' }); assert.equal(app.state().recordings.length, 1);
  await app.dispatch({ type: 'record-start' }); await app.dispatch({ type: 'record-cancel' });
  assert.equal(app.state().recordings.length, 1); assert.equal(app.state().outbox.length, 0);
  assert.equal(h.requests.length, 0);
  await app.dispatch({ type: 'record-delete', id: 'recording-1' }); assert.equal(app.state().recordings.length, 0);
});
test('recording denial leaves the session idle and a subsequent action remains usable', async t => {
  const h = harness(), native = h.ports.native;
  h.ports.native = (method, args) => method === 'recordStart' ? Promise.reject(Error('Microphone denied')) : native(method, args);
  const app = await createClient(h.ports); t.after(() => app.close());
  await assert.rejects(app.dispatch({ type: 'record-start' }), /denied/); assert.equal(app.state().recording, false);
  await app.dispatch({ type: 'compose', text: 'still usable' }); assert.equal(app.state().draft, 'still usable');
});
test('SSE parser retains fragmented frames and bounds unterminated and multiline data', () => {
  const seen = [], parse = sseParser((...value) => seen.push(value));
  parse('event: mess'); parse('age\r\ndata: {"text":"hi"}\r\n'); assert.equal(seen.length, 0); parse('\r\n');
  assert.deepEqual(seen, [['message', '{"text":"hi"}']]);
  assert.throws(() => parse('x'.repeat(262145)), /limit/);
  const second = sseParser(() => {}); assert.throws(() => { for (let n=0;n<300;n++) second('data: '+ 'x'.repeat(1000) +'\n'); }, /limit/);
});

test('CLI scenarios use the same client actions and preserve the delivery and recording invariants', async () => {
  const { scenario } = require('../dev/client-runtime.js');
  const connection = await scenario('connection-restart');
  assert.equal(connection.trace.find(x => x.action === 'relaunch').state.outbox.length, 1);
  assert.equal(connection.state.outbox.length, 0);
  const recording = await scenario('recording-interruption');
  assert.equal(recording.state.recordings.length, 1);
  assert.equal(recording.state.recording, false);
});

test('an interrupted reply resumes before its cursor so missed deltas are fetched again', async t => {
  const h = harness(); let app = await createClient(h.ports); t.after(() => app.close()); await pair(app);
  h.opened[0].event('message', { id: 'reply', role: 'rich', text: 'partial', cursor: 7, complete: false }); await app.settle();
  h.opened[0].event('delta', { message_id: 'reply', text: ' answer', cursor: 7 }); await app.settle();
  assert.equal(app.state().messages[0].text, 'partial answer');
  app.close(); app = await createClient(h.ports); await turn();
  assert.match(h.opened.at(-1).url, /since=6/);
  h.opened.at(-1).event('message', { id: 'reply', role: 'rich', text: 'whole answer', cursor: 7, complete: true }); await app.settle();
  assert.equal(app.state().messages.length, 1); assert.equal(app.state().messages[0].text, 'whole answer');
});

test('a quiet accepted stream reconnects and drains the outbox without waiting for a frame', async t => {
  const h = harness(), app = await createClient(h.ports); t.after(() => app.close()); await pair(app);
  await app.dispatch({ type: 'compose', text: 'queued' }); await app.dispatch({ type: 'send' });
  h.opened.at(-1).onopen(); await turn();
  assert.equal(app.state().online, true); assert.equal(app.state().outbox.length, 0);
});

test('external snapshots cannot mutate messages or native recording metadata', async t => {
  const h = harness(), app = await createClient(h.ports); t.after(() => app.close()); await pair(app);
  h.opened[0].event('message', { id: 'reply', role: 'rich', text: 'original', cursor: 1 }); await app.settle();
  await app.dispatch({ type: 'record-start' }); await app.dispatch({ type: 'record-stop' });
  const snapshot = app.state(); snapshot.messages[0].text = 'changed'; snapshot.recordings[0].id = 'changed';
  assert.equal(app.state().messages[0].text, 'original'); assert.equal(app.state().recordings[0].id, 'recording-1');
});

test('oversized JSON-escaped text is rejected before it can strand the queue', async t => {
  const h = harness(), app = await createClient(h.ports); t.after(() => app.close()); await pair(app);
  await app.dispatch({ type: 'compose', text: '\u0000'.repeat(12000) });
  await assert.rejects(app.dispatch({ type: 'send' }), /too long/);
  assert.equal(app.state().outbox.length, 0); assert.equal(app.state().draft.length, 12000);
});

test('native fetch accepts a bodyless HTTP response', async () => {
  const { createPorts } = require('../platform/native.js');
  const ports = createPorts(async () => ({ status: 204, body: '', headers: {} }), () => () => {});
  const response = await ports.fetch('https://mac.example/api/pair');
  assert.equal(response.status, 204); assert.equal(await response.text(), '');
});


test('pairing accepts the production Mac colon-separated SHA-256 fingerprint', async t => {
  const h = harness();
  const fetch = h.ports.fetch;
  h.ports.fetch = async (...args) => {
    const response = await fetch(...args);
    const body = await response.json();
    if (body.ca_fingerprint_sha256) body.ca_fingerprint_sha256 = Array(32).fill('AB').join(':');
    return Response.json(body);
  };
  const client = await createClient(h.ports); t.after(() => client.close());
  await client.dispatch({ type: 'pair', link: 'https://mac.example/#pair=secret' });
  assert.equal(client.state().words, require('../../web/web-app/lib/fingerprint.js').phraseFromHex('ab'.repeat(32)));
});

test('native update subscriptions cannot close or receive data from the Mac event stream', async () => {
  const { createPorts } = require('../platform/native.js'); const calls = [], listeners = new Set();
  const ports = createPorts(async (method, args) => {
    calls.push({ method, args });
    if (method === 'updateInfo') return { version: '0.1.0', build: '2', osVersion: '16.7.16', configured: true };
    return true;
  }, listener => { listeners.add(listener); return () => listeners.delete(listener); });
  const mac = new ports.EventSource('https://mac.example/api/events');
  let signals = 0; const update = await ports.updates(), stream = await update.subscribe(() => { signals++; });
  const updateId = calls.find(call => call.method === 'updateSubscribe').args.id;
  for (const listener of listeners) listener({ kind: 'update-signal', id: updateId });
  assert.equal(signals, 1); assert.equal(mac.readyState, 0);
  stream.close(); assert.equal(calls.filter(call => call.method === 'streamClose').length, 0);
  mac.close(); assert.equal(calls.filter(call => call.method === 'streamClose').length, 1);
});

test('a late Connect outage probe cannot overwrite a recovered stream or queued work', async t => {
  const h = harness(), fetchOriginal = h.ports.fetch;
  const origin = 'https://c-' + 'a'.repeat(32) + '-g1.richos.ceo';
  h.ports.fetch = async (url, options) => {
    const result = await fetchOriginal(url, options);
    if (url.endsWith('/api/pair')) {
      const body = await result.json();
      if (body.api_base) body.api_base = origin;
      return Response.json(body);
    }
    return result;
  };
  let resolveProbe;
  h.ports.connectionHealth = () => new Promise(resolve => { resolveProbe = resolve; });
  const app = await createClient(h.ports); t.after(() => app.close());
  await app.dispatch({type:'pair',link:origin+'/#pair=secret'});
  await app.dispatch({type:'confirm-pair',matched:true}); await turn();
  await app.dispatch({type:'compose',text:'Keep this draft'});
  h.opened.at(-1).event('hello',{challenge:'fresh',capabilities:['text']}); await app.settle();
  assert(app.state().online);
  resolveProbe({serviceState:'unavailable'}); await turn();
  assert.equal(app.state().connectionReason,'connected');
  assert.equal(app.state().draft,'Keep this draft');
});
