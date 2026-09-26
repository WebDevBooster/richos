import test from 'node:test';
import assert from 'node:assert/strict';
import { createRequire } from 'node:module';
import { createHash, generateKeyPairSync, sign } from 'node:crypto';
import { readFileSync, rmSync, existsSync } from 'node:fs';
import { join } from 'node:path';
import { startMac } from '../dev/mac-server.mjs';
const require = createRequire(import.meta.url);
const { createScratch } = require('./storage.cjs');
const { createClient } = require('../core/client.js');
const { createPorts } = require('../platform/native.js');
// The native bridge reports the shipped version and build, from their one source.
const release = require('../release-config.json');
const pause = ms => new Promise(resolve => setTimeout(resolve, ms));

test('actual mobile client pairs, signs, receives and resumes against the production Rust stack', { timeout: 360000 }, async t => {
  const cache = createScratch('mac-proof');
  let server, client;
  t.after(async () => { client?.close(); await server?.close(); rmSync(cache, { recursive: true, force: true }); });
  const remoteFile = process.env.RICHOS_MOBILE_REMOTE_STATE;
  if (remoteFile && !remoteFile.startsWith('/Volumes/E1TB/')) throw Error('Remote proof state must be on the external SSD');
  server = remoteFile ? null : await startMac(cache);
  const publicRoute = !!remoteFile || process.env.RICHOS_MOBILE_USE_PUBLIC_ROUTE === '1';
  const state = remoteFile ? JSON.parse(readFileSync(remoteFile, 'utf8')) : server.state;
  const { privateKey, publicKey } = generateKeyPairSync('ec', { namedCurve: 'prime256v1' });
  const listeners = new Set(), streams = new Map(), events = [], requests = [];
  let disk;
  const voiceFile = process.env.RICHOS_MOBILE_VOICE_FIXTURE;
  const voicePhrase = process.env.RICHOS_MOBILE_VOICE_PHRASE;
  if (voiceFile && (!voiceFile.startsWith('/Volumes/E1TB/') || !voicePhrase)) throw Error('Voice proof requires an external WAV and expected phrase');
  let replyAudio, played = false;
  const local = url => {
    assert.equal(new URL(url).origin, state.origin);
    if (publicRoute) return url;
    return `http://127.0.0.1:${state.port}${new URL(url).pathname}${new URL(url).search}`;
  };
  const emit = event => { events.push(event.kind); for (const fn of listeners) fn(event); };
  const call = async (method, args) => {
    switch (method) {
      case 'configure': assert.equal(args.origin, state.origin); return true;
      case 'load': return structuredClone(disk);
      case 'save': disk = structuredClone(args.value); return true;
      case 'recordings': return voiceFile ? [{id:'voice-proof',seconds:10,codec:'wav16k',sampleRate:16000}] : [];
      case 'recordHash': assert.equal(args.id,'voice-proof'); return createHash('sha256').update(readFileSync(voiceFile)).digest('hex');
      case 'replyPlay': assert.equal(args.id,'reply-proof'); assert(replyAudio.length>44); played=true; return true;
      case 'updateInfo': return { version: release.version, build: release.build, osVersion: '16.7.16', appId: null, storefront: null, configured: false };
      case 'hash': return createHash('sha256').update(args.value).digest('hex');
      case 'publicKey': return publicKey.export({ format: 'jwk' });
      case 'sign': return sign('sha256', Buffer.from(args.input), { key: privateKey, dsaEncoding: 'ieee-p1363' }).toString('base64url');
      case 'request': {
        requests.push(args);
        const body = args.body?.recordingFile ? readFileSync(voiceFile) : args.body;
        const response = await fetch(local(args.url), { method: args.method, headers: args.headers, body: args.method === 'GET' ? undefined : body });
        if (new URL(args.url).pathname.startsWith('/api/audio/') && response.status===200) {
          replyAudio=Buffer.from(await response.arrayBuffer());
          assert.equal(replyAudio.subarray(0,4).toString(),'RIFF');
          return {status:200,headers:{},body:'',audioId:'reply-proof'};
        }
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
    const deadline = Date.now() + (voiceFile ? 60000 : publicRoute ? 30000 : 10000);
    while (!predicate() && Date.now() < deadline) await pause(25);
    assert(predicate(), JSON.stringify({ state: client.state(), events }));
  };
  if (publicRoute) {
    let ready = false;
    const deadline = Date.now() + 30000;
    while (!ready && Date.now() < deadline) {
      try { ready = (await fetch(local(state.origin + '/api/challenge'),{signal:AbortSignal.timeout(5000)})).headers.has('x-richos-challenge'); } catch {}
      if (!ready) await pause(200);
    }
    assert(ready,'managed tunnel did not become ready');
  }
  assert.equal((await fetch(local(state.origin + "/api/messages"), { method: 'POST', body: '{}' })).status, 404);
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
  const challengeResponse = await fetch(local(state.origin + "/api/challenge"));
  const challenge = challengeResponse.headers.get('x-richos-challenge');
  const input = `${challenge}\nPOST\n/api/messages\n${createHash('sha256').update(sent.body).digest('hex')}`;
  const wrong = await call('sign', { input: input + 'wrong' });
  const signed = await call('sign', { input });
  const headers = signature => ({ 'Content-Type': 'application/json', Authorization: `RichOS-Device ${disk.api.deviceId}.${challenge}.${signature}` });
  assert.equal((await fetch(local(sent.url), { method: 'POST', body: sent.body, headers: headers(wrong) })).status, 404);
  const duplicate = await fetch(local(sent.url), { method: 'POST', body: sent.body, headers: headers(signed) });
  assert.equal(duplicate.status, 200); assert.equal((await duplicate.json()).duplicate, true);
  client.close();
  if (server) {
    await server.restart();
    let challenge;
    const recoveryDeadline = Date.now() + 30000;
    while (!challenge && Date.now() < recoveryDeadline) {
      try { challenge = (await fetch(local(state.origin + '/api/challenge'),{signal:AbortSignal.timeout(5000)})).headers.get('x-richos-challenge'); } catch {}
      if (!challenge) await pause(200);
    }
    assert(challenge,'Mac/tunnel did not recover within 30 seconds');
    const input = `${challenge}\nPOST\n/api/messages\n${createHash('sha256').update(sent.body).digest('hex')}`;
    const signature = await call('sign',{input});
    const result = await fetch(local(sent.url),{method:'POST',body:sent.body,headers:{'Content-Type':'application/json',Authorization:`RichOS-Device ${disk.api.deviceId}.${challenge}.${signature}`}});
    assert.equal(result.status,200); assert.equal((await result.json()).duplicate,true,'Mac restart lost the delivery receipt');
  }
  client = await createClient(ports);
  assert(reply(), 'reply survives client process state restoration');
  const previous = events.filter(kind => kind === 'stream-open').length;
  await wait(() => client.state().online && events.filter(kind => kind === 'stream-open').length > previous);
  const second = message + ' after restart';
  await client.dispatch({ type: 'compose', text: second }); await client.dispatch({ type: 'send' });
  await wait(() => client.state().messages.some(row => row.role === 'rich' && row.text === 'ack: ' + second && row.complete));
  if (voiceFile) {
    assert(client.state().canVoice,'The real Mac speech model must be available');
    await client.dispatch({type:'record-refresh'});
    await client.dispatch({type:'record-send',id:'voice-proof'});
    const spoken = () => client.state().messages.find(row=>row.role==='rich' && row.complete && row.text.toLowerCase().includes(voicePhrase.toLowerCase()));
    await wait(() => spoken() && client.state().outbox.length===0);
    assert.equal(client.state().messages.filter(row=>row.role==='ceo' && (row.kind==='voice' || row.text.toLowerCase().includes(voicePhrase.toLowerCase()))).length,1,'Transcription must replace the voice placeholder');
    await client.dispatch({type:'reply-play',id:spoken().id});
    await wait(()=>played);
    t.diagnostic('Actual WAV passed signed upload, local Mac transcription, durable intake, gated Rich projection and WAV reply generation; phone microphone and speaker are separate physical checks');
  }
  client.close();
  if (remoteFile) {
    const timeline = JSON.parse(readFileSync(join(state.data, 'timeline.json'), 'utf8'));
    assert.equal(timeline.items.filter(row => row.kind === 'user_message' && row.text === message).length, 1);
    return;
  }
  await server.close();
  assert.deepEqual(await server.exited, [0, null]);
  const timeline = JSON.parse(readFileSync(join(cache, 'mac-timeline.json'), 'utf8'));
  assert.equal(timeline.items.filter(row => row.kind === 'user_message' && row.text === message).length, 1);
  assert(timeline.items.some(row => row.kind === 'rich_message' && row.text === 'ack: ' + second));
  if (!publicRoute) await assert.rejects(fetch(local(state.origin + "/api/challenge")));
  else {
    const stoppedResponse = await fetch(local(state.origin + '/api/challenge'));
    assert(!stoppedResponse.headers.has('x-richos-challenge'),'stopped helper still reaches a phone listener');
  }
});


test('manual Mac fixture retains pairing state after explicit shutdown and refuses to overwrite it', { timeout: 360000 }, async t => {
  if (process.env.RICHOS_MOBILE_REMOTE_STATE) { t.skip('Remote proof does not own the running Mac fixture'); return; }
  const cache = createScratch('manual-mac-proof');
  let server;
  t.after(async () => { await server?.close(); rmSync(cache, { recursive: true, force: true }); });
  server = await startMac(cache, { manual: true });
  assert.equal(server.state.data, join(cache, 'manual-data'));
  await server.close();
  assert.deepEqual(await server.exited, [0, null]);
  assert(existsSync(join(server.state.data, 'lab-owner')));
  assert(existsSync(server.state.ca));
  assert(existsSync(join(server.state.data, 'ledger.jsonl')));
  await assert.rejects(startMac(cache, { manual: true }), /existing test data is preserved/);
});
