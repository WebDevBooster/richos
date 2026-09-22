#!/usr/bin/env node
// phone-client.mjs — a headless phone for a QA walk: the PRODUCTION mobile client
// (`richos/mobile/core/client.js` + `platform/native.js`) driven from a shell, against a
// real RichOS install's phone listener. No simulator, no physical phone, no browser.
//
// WHY THIS EXISTS. A walk that has to pair "a phone" to a Mac in the test VM had three
// options: a physical phone (forbidden while someone else owns it), the Mac's own Safari
// (the same machine, so it proves nothing about reaching the Mac from elsewhere), or a
// throwaway script that re-implements pairing. The mobile tree already has the real client
// and a Node port shape (`test/mac-server.test.mjs`), but only inside a test that expects
// the lab fixture's synthetic `ack:` replies. This is that port shape, standing alone.
//
//   phone-client.mjs pair    --state FILE --link 'https://host:8443/#pair=CODE' --decision FILE
//   phone-client.mjs send    --state FILE --text TEXT [--timeout SECONDS] [--no-reply]
//   phone-client.mjs state   --state FILE [--timeout SECONDS]
//   phone-client.mjs forget  --state FILE
//   phone-client.mjs foreign --state FILE --origin https://other-host:8443
//
// `pair` prints the six words the Mac must also show, then WAITS (up to --timeout) for the
// walker to compare them with the Mac's screen and write `match` or `mismatch` into the
// --decision file. The words live only in the pairing process's memory (core/client.js
// never persists them), so the comparison has to happen inside one process, as on a phone.
// `send` times acknowledgement and the first and completed reply on one monotonic clock.
// `foreign` presents THIS phone's device id and signature to a DIFFERENT origin and reports
// what that origin answered — the isolation question "can a phone paired to one Mac act on
// another?" asked from the outside, with no pairing made to the other Mac.
//
// The state file holds the phone's private signing key and session. It is created 0600 and
// is the caller's to delete. It never prints the key.
//
// Exit codes: 0 answered; 1 the product said no where this command needed a yes (a send
// that was never acknowledged, a foreign origin that ACCEPTED the credential); 2 the
// command could not run (bad arguments, missing state, unreachable origin), with a sentence.
import { createRequire } from 'node:module';
import { createHash, generateKeyPairSync, createPrivateKey, createPublicKey, sign } from 'node:crypto';
import { readFileSync, writeFileSync, existsSync, openSync, closeSync, chmodSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const HELP = readFileSync(fileURLToPath(import.meta.url), 'utf8').split('\n')
  .slice(1, 33).map(l => l.replace(/^\/\/ ?/, '')).join('\n');
const HERE = dirname(fileURLToPath(import.meta.url));
const MOBILE = join(HERE, '..', '..', '..', 'mobile');

function die(code, sentence) { process.stderr.write('phone-client: ' + sentence + '\n'); process.exit(code); }
function args(argv) {
  const out = { _: [] };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--help' || a === '-h') { process.stdout.write(HELP + '\n'); process.exit(0); }
    if (a === '--no-reply') { out[a.slice(2)] = true; continue; }
    if (a.startsWith('--')) { if (i + 1 >= argv.length) die(2, `${a} needs a value`); out[a.slice(2)] = argv[++i]; continue; }
    out._.push(a);
  }
  return out;
}

function loadState(file, create) {
  if (!file) die(2, '--state FILE is required');
  if (!existsSync(file)) {
    if (!create) die(2, `no phone state at ${file}; run \`pair\` first`);
    const { privateKey } = generateKeyPairSync('ec', { namedCurve: 'prime256v1' });
    const fd = openSync(file, 'wx', 0o600); closeSync(fd);
    const s = { key: privateKey.export({ format: 'jwk' }), disk: null };
    writeFileSync(file, JSON.stringify(s)); chmodSync(file, 0o600);
    return s;
  }
  try { return JSON.parse(readFileSync(file, 'utf8')); }
  catch (e) { die(2, `phone state at ${file} is unreadable: ${e.message}`); }
}
function saveState(file, s) { writeFileSync(file, JSON.stringify(s)); chmodSync(file, 0o600); }

async function makeClient(file, s) {
  const require = createRequire(import.meta.url);
  let createClient, createPorts;
  try {
    ({ createClient } = require(join(MOBILE, 'core', 'client.js')));
    ({ createPorts } = require(join(MOBILE, 'platform', 'native.js')));
  } catch (e) { die(2, `cannot load the mobile client from ${MOBILE}: ${e.message}`); }
  const privateKey = createPrivateKey({ key: s.key, format: 'jwk' });
  const publicJwk = createPublicKey(privateKey).export({ format: 'jwk' });
  const listeners = new Set(), streams = new Map(), log = [];
  const emit = ev => { for (const fn of listeners) fn(ev); };
  const call = async (method, a) => {
    switch (method) {
      case 'configure': return true;
      case 'load': return s.disk ? structuredClone(s.disk) : null;
      case 'save': s.disk = structuredClone(a.value); saveState(file, s); return true;
      case 'recordings': case 'recordPrune': return [];
      case 'updateInfo': return { version: '0.0.0', build: '1', osVersion: 'qa-headless', appId: null, storefront: null, configured: false };
      case 'connectHealth': return {};
      case 'hash': return createHash('sha256').update(a.value).digest('hex');
      case 'publicKey': return publicJwk;
      case 'sign': return sign('sha256', Buffer.from(a.input), { key: privateKey, dsaEncoding: 'ieee-p1363' }).toString('base64url');
      case 'pushInfo': return { available: false };
      case 'request': {
        const started = Date.now();
        const r = await fetch(a.url, { method: a.method, headers: a.headers, body: a.method === 'GET' ? undefined : a.body, signal: AbortSignal.timeout(30000) });
        const body = await r.text();
        log.push({ method: a.method, path: new URL(a.url).pathname, status: r.status, ms: Date.now() - started });
        return { status: r.status, headers: Object.fromEntries(r.headers), body };
      }
      case 'streamClose': streams.get(a.id)?.abort(); streams.delete(a.id); return true;
      case 'streamOpen': {
        const c = new AbortController(); streams.set(a.id, c);
        void (async () => {
          try {
            const r = await fetch(a.url, { signal: c.signal });
            log.push({ method: 'GET', path: new URL(a.url).pathname, status: r.status, stream: true });
            if (r.status !== 200) { emit({ kind: 'stream-error', id: a.id, error: 'HTTP ' + r.status }); return; }
            emit({ kind: 'stream-open', id: a.id });
            for await (const chunk of r.body) emit({ kind: 'stream-data', id: a.id, data: Buffer.from(chunk).toString('base64') });
          } catch (e) { if (!c.signal.aborted) emit({ kind: 'stream-error', id: a.id, error: e.message }); }
        })();
        return true;
      }
      default: throw Error(`the headless phone has no ${method}; this command cannot use that feature`);
    }
  };
  const ports = createPorts(call, fn => { listeners.add(fn); return () => listeners.delete(fn); });
  const client = await createClient(ports);
  return { client, log, closeAll() { client.close(); for (const c of streams.values()) c.abort(); } };
}

const clock = () => Number(process.hrtime.bigint() / 1000000n);
async function until(pred, seconds) {
  const end = clock() + seconds * 1000;
  while (clock() < end) { if (pred()) return true; await new Promise(r => setTimeout(r, 50)); }
  return pred();
}
function summary(st) {
  return {
    confirmed: st.confirmed, online: st.online, connectionReason: st.connectionReason,
    threads: (st.threads || []).map(t => ({ id: t.id, title: t.title })), selectedThreadId: st.selectedThreadId,
    outbox: (st.outbox || []).length, messages: (st.messages || []).length, canText: st.canText, error: st.error,
  };
}

async function main() {
  const [cmd, ...rest] = process.argv.slice(2);
  if (!cmd || cmd === '--help' || cmd === '-h') { process.stdout.write(HELP + '\n'); process.exit(cmd ? 0 : 2); }
  const o = args(rest);
  const timeout = o.timeout ? Number(o.timeout) : 60;
  if (!Number.isFinite(timeout) || timeout <= 0) die(2, '--timeout must be a positive number of seconds');

  if (cmd === 'pair') {
    if (!o.link) die(2, 'pair needs --link with the complete HTTPS pairing link the Mac shows');
    if (!o.decision) die(2, 'pair needs --decision FILE: write match or mismatch into it after comparing the words');
    if (existsSync(o.decision)) die(2, `${o.decision} already exists; a stale decision would confirm without a comparison`);
    const s = loadState(o.state, true);
    const { client, log, closeAll } = await makeClient(o.state, s);
    const t0 = clock();
    try { await client.dispatch({ type: 'pair', link: o.link }); }
    catch (e) { closeAll(); die(1, `the Mac refused the pairing: ${e.message}`); }
    const words = client.state().words;
    console.log(JSON.stringify({ stage: 'compare', words, pair_ms: clock() - t0, requests: log.slice() }));
    const read = () => existsSync(o.decision) ? readFileSync(o.decision, 'utf8').trim() : '';
    if (!(await until(() => ['match', 'mismatch'].includes(read()), timeout))) {
      closeAll(); die(1, `no decision in ${o.decision} within ${timeout}s; nothing was confirmed`);
    }
    const matched = read() === 'match';
    const t1 = clock();
    await client.dispatch({ type: 'confirm-pair', matched });
    const online = matched ? await until(() => client.state().online, 30) : false;
    const st = client.state(); closeAll();
    console.log(JSON.stringify({ stage: 'confirmed', ok: matched ? online : true, matched, online_ms: online ? clock() - t1 : null, requests: log, ...summary(st) }));
    process.exit(matched && !online ? 1 : 0);
  }
  if (cmd === 'foreign') {
    if (!o.origin) die(2, 'foreign needs --origin of the OTHER Mac');
    const s = loadState(o.state, false);
    const deviceId = s.disk?.api?.deviceId;
    if (!deviceId) die(2, 'this phone state has no device id; pair and confirm it first');
    const origin = new URL(o.origin).origin;
    const privateKey = createPrivateKey({ key: s.key, format: 'jwk' });
    let challenge;
    try {
      const r = await fetch(origin + '/api/challenge', { signal: AbortSignal.timeout(15000) });
      challenge = r.headers.get('x-richos-challenge');
    } catch (e) { die(2, `cannot reach ${origin}: ${e.message}`); }
    if (!challenge) die(2, `${origin} issued no challenge header, so it is not a RichOS phone listener that could be asked`);
    const body = JSON.stringify({ client_id: 'qa-foreign-' + Date.now(), kind: 'text', text: 'isolation probe — must be refused' });
    const probe = async (method, path, b) => {
      const input = `${challenge}\n${method}\n${path}\n${createHash('sha256').update(b).digest('hex')}`;
      const sig = sign('sha256', Buffer.from(input), { key: privateKey, dsaEncoding: 'ieee-p1363' }).toString('base64url');
      const r = await fetch(origin + path, { method, body: method === 'GET' ? undefined : b, signal: AbortSignal.timeout(15000),
        headers: { 'Content-Type': 'application/json', Authorization: `RichOS-Device ${deviceId}.${challenge}.${sig}` } });
      const text = method === 'GET' && r.status === 200 ? '(stream opened)' : (await r.text()).slice(0, 120);
      return { method, path, status: r.status, accepted: r.status >= 200 && r.status < 300, body: text };
    };
    const results = [await probe('POST', '/api/messages', body), await probe('GET', '/api/events', '')];
    const accepted = results.some(r => r.accepted);
    console.log(JSON.stringify({ ok: !accepted, origin, results }));
    process.exit(accepted ? 1 : 0);
  }

  const s = loadState(o.state, false);
  const { client, log, closeAll } = await makeClient(o.state, s);
  try {
    if (cmd === 'state') {
      await client.dispatch({ type: 'resume' }).catch(() => {});
      await until(() => client.state().online, timeout);
      const st = client.state();
      console.log(JSON.stringify({ ok: true, requests: log, ...summary(st),
        last: (st.messages || []).slice(-4).map(m => ({ role: m.role, complete: m.complete, chars: (m.text || '').length })) }));
    } else if (cmd === 'send') {
      if (!o.text) die(2, 'send needs --text');
      await client.dispatch({ type: 'resume' }).catch(() => {});
      if (!(await until(() => client.state().online, Math.min(timeout, 30)))) {
        console.log(JSON.stringify({ ok: false, reason: 'never came online', requests: log, ...summary(client.state()) }));
        process.exitCode = 1; return;
      }
      const before = (client.state().messages || []).length;
      const t0 = clock();
      await client.dispatch({ type: 'compose', text: o.text });
      await client.dispatch({ type: 'send' });
      const mine = () => (client.state().messages || []).findIndex(m => m.role === 'ceo' && m.text === o.text);
      const acked = await until(() => client.state().outbox.length === 0 && mine() >= 0, timeout);
      const tAck = clock() - t0;
      let tFirst = null, tDone = null, reply = null;
      if (acked && !o['no-reply']) {
        const rich = () => (client.state().messages || []).slice(mine() + 1).find(m => m.role === 'rich');
        if (await until(() => rich(), timeout)) tFirst = clock() - t0;
        if (await until(() => rich()?.complete, timeout)) { tDone = clock() - t0; }
        reply = rich() ? { complete: !!rich().complete, chars: (rich().text || '').length } : null;
      }
      const st = client.state();
      console.log(JSON.stringify({ ok: acked && (o['no-reply'] || tDone !== null), acknowledged: acked, ack_ms: acked ? tAck : null,
        first_reply_ms: tFirst, complete_reply_ms: tDone, reply, messages_before: before, requests: log, ...summary(st) }));
      process.exitCode = acked && (o['no-reply'] || tDone !== null) ? 0 : 1;
    } else if (cmd === 'forget') {
      await client.dispatch({ type: 'forget-pair', confirm: true });
      console.log(JSON.stringify({ ok: true, ...summary(client.state()) }));
    } else {
      die(2, `unknown command ${cmd}; see --help`);
    }
  } catch (e) {
    console.log(JSON.stringify({ ok: false, error: e.message, requests: log }));
    process.exitCode = 1;
  } finally { closeAll(); }
}
main().then(() => process.exit(process.exitCode ?? 0), e => die(2, e.message));
