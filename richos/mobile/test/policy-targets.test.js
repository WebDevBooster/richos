// Update-policy targeting: a record reaches exactly one app. The preserved iPhone app keeps its
// routes and sees only untargeted (or explicitly ios-preserved) records; the native iPhone and
// Android apps each read their own routes. Hosted Worker + operator path over one SQLite database,
// the local file service, and the real workerd runtime with D1.
const test = require('node:test');
const assert = require('node:assert/strict');
const { DatabaseSync } = require('node:sqlite');
const { readFileSync, rmSync } = require('node:fs');
const { join, resolve } = require('node:path');
const { createScratch } = require('./storage.cjs');
const mobile = resolve(__dirname, '..');
const TOKEN = 'operator-token-sentinel-0123456789';
const profile = { accountId: 'a'.repeat(32), databaseId: '11111111-2222-3333-4444-555555555555', hostname: 'updates.example.com' };

function policy(revision, extra = {}) {
  const now = Date.now();
  return { schema: 1, revision, issuedAt: new Date(now).toISOString(), expiresAt: new Date(now + 3600000).toISOString(),
    severity: 'none', title: '', message: '', allowDismiss: true, remindAfterSeconds: 60, ...extra };
}
const verifiedAt = () => new Date(Date.now() - 60000).toISOString();
const iosNotice = (revision, extra = {}) => policy(revision, { severity: 'blocking', title: 'Update required', message: 'Install the new RichOS.', allowDismiss: false,
  latest: { version: '1.0.0', build: '10', minimumOS: '17.0', appId: '1234567890', storefronts: ['USA'], verifiedAt: verifiedAt() }, minimum: { version: '1.0.0', build: '10' }, ...extra });
const androidNotice = (revision, extra = {}) => policy(revision, { target: 'android-native', severity: 'banner', title: 'Update available', message: 'RichOS 1.1.0 is on Google Play.',
  latest: { packageName: 'dev.richos.android', version: '1.1.0', build: '11', minimumSdk: 26, verifiedAt: verifiedAt() }, ...extra });
const receipt = value => ({ downloadVerified: true, ...value.latest, evidence: 'Downloaded on a supported test phone' });

async function hosted(t) {
  const worker = await import('../service/policy-worker.mjs'), store = await import('../service/policy-store.mjs');
  const operator = await import('../service/policy-hosted.mjs'), authoring = await import('../service/policy.mjs');
  const db = new DatabaseSync(':memory:'); t.after(() => db.close());
  db.exec(readFileSync(join(mobile, 'service/policy-schema.sql'), 'utf8'));
  const bound = (sql, args) => { const query = db.prepare(sql); return { first: async () => query.get(...args) || null, all: async () => ({ results: query.all(...args) }) }; };
  const env = { DB: { prepare: sql => ({ ...bound(sql, []), bind: (...args) => bound(sql, args) }) } };
  const served = [];
  async function fetch(url, init = {}) {
    const { hostname, pathname } = new URL(url);
    if (hostname === profile.hostname) { served.push(pathname); return worker.handle(new Request(url, { headers: init.headers }), env); }
    assert.equal(init.headers.Authorization, `Bearer ${TOKEN}`);
    const { sql, params } = JSON.parse(init.body);
    assert(params.every(value => typeof value === 'string'), 'D1 HTTP parameters are strings');
    const query = db.prepare(sql);
    const result = query.columns().length ? { results: query.all(...params), meta: { changes: 0 } } : { results: [], meta: { changes: Number(query.run(...params).changes) } };
    return Response.json({ success: true, result: [{ success: true, ...result }] });
  }
  const request = (value, extra = {}) => ({ operator: 'release-operator', policy: value, previewDigest: authoring.preview(value, []).digest, ...extra });
  const publish = (value, extra) => operator.publishHosted(profile, request(value, extra), { token: TOKEN, fetch });
  const get = (path, init) => worker.handle(new Request('https://updates.example.com' + path, init), env);
  // Each stream has its own clock: a stream blocks on an unread write, so they must not share waits.
  const stream = async path => {
    let time = 0, notify; const pending = [];
    const ports = { now: () => time, wait: ms => new Promise(resolve => { pending.push({ ms, resolve }); notify?.(); }) };
    const reader = (await worker.handle(new Request('https://updates.example.com' + path), env, ports)).body.getReader();
    return { read: async () => new TextDecoder().decode((await reader.read()).value), cancel: () => reader.cancel(),
      step: async () => { while (!pending.length) await new Promise(resolve => { notify = resolve; }); const { ms, resolve } = pending.shift(); time += ms; resolve(); } };
  };
  return { worker, store, operator, authoring, db, env, publish, request, get, served, fetch, stream };
}

test('each record reaches exactly one app: the preserved routes never serve a native record', async t => {
  const h = await hosted(t);
  const preserved = policy(1, { features: { recording: true } });
  const iosNative = iosNotice(2, { target: 'ios-native', features: { recording: false } });
  const android = androidNotice(3, { features: { text: false } });
  assert.equal((await h.publish(preserved)).target, 'ios-preserved');
  const published = await h.publish(iosNative, { availability: receipt(iosNative) });
  assert.deepEqual([published.target, published.served], ['ios-native', 2]);
  assert.equal((await h.publish(android, { availability: receipt(android) })).served, 3);
  assert.deepEqual(h.served, ['/v1/policy', '/v1/policy/ios-native', '/v1/policy/android-native'], 'each readback goes through its own route');
  assert.deepEqual(await (await h.get('/v1/policy')).json(), preserved, 'the newest revisions are native and never reach the preserved app');
  assert.deepEqual(await (await h.get('/v1/policy/ios-native')).json(), iosNative);
  assert.deepEqual(await (await h.get('/v1/policy/android-native')).json(), android);
  // An explicitly targeted preserved record is the same audience as an untargeted one.
  const explicit = policy(4, { target: 'ios-preserved', features: { recording: true, text: true } });
  await h.publish(explicit);
  assert.deepEqual(await (await h.get('/v1/policy')).json(), explicit);
  assert.equal((await (await h.get('/v1/policy/ios-native')).json()).revision, 2);
  // Health reports the newest revision of any target, as before.
  assert.equal((await (await h.get('/healthz')).json()).revision, 4);
  for (const path of ['/v1/policy/ios-preserved', '/v1/policy/android', '/v1/policy/android-native/', '/v1/events/watch', '/v1/policy/android-native?x=1']) {
    assert.equal((await h.get(path)).status, 404, path);
  }
  for (const method of ['POST', 'PUT', 'DELETE']) assert.equal((await h.get('/v1/policy/android-native', { method })).status, 405);
});

test('an empty or broken native store never disturbs another app', async t => {
  const h = await hosted(t);
  await h.publish(policy(1));
  assert.equal((await h.get('/v1/policy/ios-native')).status, 503, 'no invented policy for a target with no record');
  // A corrupt newest Android row is refused on its route only; the others keep serving.
  h.db.prepare('INSERT INTO revisions VALUES (?, ?, ?, ?, ?)').run(2, JSON.stringify(androidNotice(9)), 'a'.repeat(64), '{}', 'now');
  h.db.prepare('INSERT INTO revisions VALUES (?, ?, ?, ?, ?)').run(3, JSON.stringify(policy(3, { target: 'watch' })), 'a'.repeat(64), '{}', 'now');
  assert.equal((await h.get('/v1/policy/android-native')).status, 503);
  assert.equal((await (await h.get('/v1/policy')).json()).revision, 1, 'an unknown target is served nowhere');
  // A record stored under one target is never served as another, even if its row is edited in.
  h.db.prepare('INSERT INTO revisions VALUES (?, ?, ?, ?, ?)').run(4, JSON.stringify(policy(4, { target: 'ios-native' })), 'a'.repeat(64), '{}', 'now');
  assert.equal((await (await h.get('/v1/policy')).json()).revision, 1);
  assert.equal((await (await h.get('/v1/policy/ios-native')).json()).revision, 4);
});

test('the unchanged preserved-app controller never sees a native notice or feature switch', { timeout: 10000 }, async t => {
  const h = await hosted(t), Updates = require('../core/updates.js');
  await h.publish(policy(1));
  let time = 0, notify; const pending = [];
  const ports = { now: () => time, wait: ms => new Promise(resolve => { pending.push({ ms, resolve }); notify?.(); }) };
  const step = async () => { while (!pending.length) await new Promise(resolve => { notify = resolve; }); const { ms, resolve } = pending.shift(); time += ms; resolve(); };
  const readers = []; let fetches = 0;
  const controller = await Updates.createController({
    client: { appId: '1234567890', storefront: 'USA', version: '0.9.0', build: '5', osVersion: '17.0' },
    authority: 'https://updates.example.com/v1/policy', load: async () => null, save: async () => {}, setTimeout: () => 0, clearTimeout: () => {},
    fetchPolicy: async () => { fetches++; return (await h.get('/v1/policy')).json(); },
    subscribe: async signal => {
      const response = await h.worker.handle(new Request('https://updates.example.com/v1/events'), h.env, ports);
      const reader = response.body.getReader(); readers.push(reader);
      (async () => { while (!(await reader.read()).done) signal(); })().catch(() => {});
      return { close: () => reader.cancel() };
    },
  });
  const initial = new Promise(resolve => { const stop = controller.subscribe(state => { if (state.policyRevision === 1) { queueMicrotask(() => stop()); resolve(); } }); });
  await controller.start(); await initial;
  // A blocking notice for the same App Store ID and a recording kill switch, both meant for the native app.
  // The dangerous case first: iOS-shaped, so the preserved client would accept it if it were served.
  const native = iosNotice(2, { target: 'ios-native', features: { recording: false } });
  await h.publish(native, { availability: receipt(native) });
  const unchanged = () => { const state = controller.state();
    assert.equal(state.policyRevision, 1); assert.equal(state.mode, 'none'); assert.equal(state.blocked, false); assert.equal(state.features.recording, true); };
  for (let i = 0; i < 5; i++) await step();
  unchanged();
  await controller.refresh(true); unchanged();
  const android = androidNotice(3); await h.publish(android, { availability: receipt(android) });
  for (let i = 0; i < 5; i++) await step();
  await controller.refresh(true); unchanged();
  controller.stop(); for (const reader of readers) await reader.cancel().catch(() => {});
  assert(fetches >= 1);
});

test('each target has its own hint stream; a native publication is silent on the preserved stream', { timeout: 10000 }, async t => {
  const h = await hosted(t);
  await h.publish(policy(1));
  const preserved = await h.stream('/v1/events'), android = await h.stream('/v1/events/android-native');
  t.after(async () => { await preserved.cancel(); await android.cancel(); });
  assert.equal(await preserved.read(), 'event: policy\ndata: 1\n\n');
  assert.equal(await android.read(), 'event: policy\ndata: 0\n\n');
  const notice = androidNotice(2); await h.publish(notice, { availability: receipt(notice) });
  await android.step();
  assert.equal(await android.read(), 'event: policy\ndata: 2\n\n');
  for (let i = 0; i < 4; i++) await preserved.step();
  assert.equal(await preserved.read(), ': alive\n\n', 'the preserved stream announces nothing for an Android revision');
});

// CEO ruling §91, 2026-09-26: the two phone apps are independent apps. So an iPhone release, minimum
// or blocked build never reaches an Android phone, and an Android one never reaches an iPhone: not on
// the policy route, not as a hint on the stream, in the hosted service and in the local one alike.
test('an iPhone release, minimum or blocked build never reaches the Android app, and an Android one never reaches the iPhone app', { timeout: 10000 }, async t => {
  const h = await hosted(t);
  const android = androidNotice(1, { minimum: { version: '1.1.0', build: '11' } });
  await h.publish(android, { availability: receipt(android) });
  const androidStream = await h.stream('/v1/events/android-native'), iosStream = await h.stream('/v1/events/ios-native');
  t.after(async () => { await androidStream.cancel(); await iosStream.cancel(); });
  assert.equal(await androidStream.read(), 'event: policy\ndata: 1\n\n');
  assert.equal(await iosStream.read(), 'event: policy\ndata: 0\n\n');
  // A newer iPhone release that blocks every older iPhone build, and names one blocked build.
  const ios = iosNotice(2, { target: 'ios-native', blockedBuilds: ['1.0.0+9'] });
  await h.publish(ios, { availability: receipt(ios) });
  await iosStream.step();
  assert.equal(await iosStream.read(), 'event: policy\ndata: 2\n\n');
  assert.deepEqual(await (await h.get('/v1/policy/android-native')).json(), android, 'the Android route still serves the Android record');
  for (let i = 0; i < 4; i++) await androidStream.step();
  assert.equal(await androidStream.read(), ': alive\n\n', 'the Android stream announces nothing for an iPhone revision');
  // And the reverse: a newer Android block reaches neither the iPhone route nor its stream.
  const block = androidNotice(3, { severity: 'blocking', allowDismiss: false, minimum: { version: '1.1.0', build: '11' }, blockedBuilds: ['1.0.0+5'] });
  await h.publish(block, { availability: receipt(block) });
  await androidStream.step();
  assert.equal(await androidStream.read(), 'event: policy\ndata: 3\n\n');
  assert.deepEqual(await (await h.get('/v1/policy/ios-native')).json(), ios, 'the iPhone route still serves the iPhone record');
  for (let i = 0; i < 4; i++) await iosStream.step();
  assert.equal(await iosStream.read(), ': alive\n\n', 'the iPhone stream announces nothing for an Android revision');
  // The local file service keeps the same separation in both directions.
  const { publish, preview, readPolicy } = await import('../service/policy.mjs');
  const directory = createScratch('policy-native-pair');
  t.after(() => rmSync(directory, { recursive: true, force: true }));
  const put = (value, extra = {}) => publish(directory, value, { operator: 'test', previewDigest: preview(value, []).digest, ...extra });
  put(android, { availability: receipt(android) });
  put(ios, { availability: receipt(ios) });
  assert.deepEqual(readPolicy(directory, 'android-native'), android, 'locally, the Android record survives a newer iPhone one');
  put(block, { availability: receipt(block) });
  assert.deepEqual(readPolicy(directory, 'ios-native'), ios, 'locally, the iPhone record survives a newer Android one');
});

test('publication rules per target: one revision sequence, targeted digests, Play receipts, refusals before any network call', async t => {
  const h = await hosted(t);
  // The digest covers the target: a preview for one app cannot publish to another.
  const plain = policy(1), targeted = policy(1, { target: 'android-native' });
  assert.notEqual(h.authoring.preview(plain, []).digest, h.authoring.preview(targeted, []).digest);
  await assert.rejects(h.operator.publishHosted(profile, { operator: 'release-operator', policy: targeted, previewDigest: h.authoring.preview(plain, []).digest }, { token: TOKEN, fetch: h.fetch }), /Preview/);
  const android = androidNotice(5);
  const refused = [
    [policy(1, { target: 'android' }), {}, /target/],
    [policy(1, { target: null }), {}, /target/],
    [androidNotice(1, { latest: { ...android.latest, appId: '1234567890', storefronts: ['USA'] } }), {}, /Google Play/],
    [androidNotice(1, { latest: { ...android.latest, packageName: 'richos' } }), {}, /Google Play/],
    [androidNotice(1, { latest: { ...android.latest, build: '1.2' } }), {}, /version code/],
    [androidNotice(1, { latest: { ...android.latest, minimumSdk: '26' } }), {}, /API level/],
    [androidNotice(1, { latest: undefined }), {}, /verified replacement/],
    [androidNotice(1, { minimum: { version: '2.0.0', build: '20' } }), {}, /minimum/],
    [androidNotice(1, { blockedBuilds: ['1.1.0+11'] }), {}, /blocked/],
    [androidNotice(1, { remindAfterSeconds: 1 }), {}, /reminder/],
    // An iOS target keeps the shared App Store rules; a Play release has no minimumOS and no App Store ID.
    [iosNotice(1, { target: 'ios-native', latest: { ...android.latest } }), {}, /Invalid numeric version|App Store/],
    [iosNotice(1, { target: 'ios-native', latest: { ...android.latest, minimumOS: '17.0' } }), {}, /App Store/],
  ];
  for (const [value, extra, message] of refused) assert.throws(() => h.authoring.preview(value, []), message, JSON.stringify(value.latest || value.target));
  for (const bad of [{ build: '12' }, { minimumSdk: 28 }, { packageName: 'dev.richos.other' }, { downloadVerified: false }]) {
    await assert.rejects(h.publish(android, { availability: { ...receipt(android), ...bad } }), /download verification receipt/, JSON.stringify(bad));
  }
  assert.throws(() => h.authoring.preview(android, [{ appId: '1', storefront: 'USA', version: '1', build: '1', osVersion: '17' }]), /Android core/);
  assert.equal(h.db.prepare('SELECT count(*) AS n FROM revisions').get().n, 0, 'nothing reached the store');
  await h.publish(android, { availability: receipt(android) });
  // One sequence across targets: every app's revisions still only increase, and nothing can go under the newest.
  await assert.rejects(h.publish(policy(4)), /new increasing revision \(hosted revision is 5\)/);
  assert.equal((await h.publish(policy(6))).served, 6);
});

test('the local file service serves each target from its own record and signals it on its own stream', { timeout: 10000 }, async t => {
  const { publish, preview, readPolicy, serve } = await import('../service/policy.mjs');
  const directory = createScratch('policy-targets');
  t.after(() => rmSync(directory, { recursive: true, force: true }));
  const put = (value, extra = {}) => publish(directory, value, { operator: 'test', previewDigest: preview(value, []).digest, ...extra });
  put(policy(1));
  const before = readFileSync(join(directory, 'active.json'));
  const android = androidNotice(2); put(android, { availability: receipt(android) });
  put(policy(3, { target: 'ios-native' }));
  assert.deepEqual(readFileSync(join(directory, 'active.json')), before, 'a native publication never rewrites the preserved record');
  assert.throws(() => put(policy(2)), /increasing/, 'one revision sequence across targets');
  assert.equal(readPolicy(directory).revision, 1);
  assert.equal(readPolicy(directory, 'android-native').revision, 2);
  assert.equal(readPolicy(directory, 'ios-native').revision, 3);
  const instance = serve(directory, { signalInterval: 20 });
  await new Promise(resolve => instance.server.once('listening', resolve));
  t.after(() => instance.close());
  const origin = `http://127.0.0.1:${instance.server.address().port}`;
  assert.equal((await (await fetch(origin + '/v1/policy')).json()).revision, 1);
  assert.deepEqual(await (await fetch(origin + '/v1/policy/android-native')).json(), android);
  assert.equal((await (await fetch(origin + '/v1/policy/ios-native')).json()).revision, 3);
  assert.equal((await fetch(origin + '/v1/policy/ios-preserved')).status, 404);
  const abort = new AbortController(); t.after(() => abort.abort());
  const readerFor = async path => (await fetch(origin + path, { signal: abort.signal })).body.getReader();
  const androidStream = await readerFor('/v1/events/android-native'), preservedStream = await readerFor('/v1/events');
  await androidStream.read(); await preservedStream.read();
  const next = androidNotice(4); put(next, { availability: receipt(next) });
  let chunks = ''; const deadline = setTimeout(() => abort.abort(), 3000);
  try { while (!chunks.includes('data: 4')) chunks += new TextDecoder().decode((await androidStream.read()).value); }
  finally { clearTimeout(deadline); }
  assert.match(chunks, /event: policy\ndata: 4/);
  assert.equal(readPolicy(directory).revision, 1);
});

test('workerd with D1 serves each target from its own route', { timeout: 60000 }, async t => {
  const { locateMiniflare, startLocalPolicyWorker } = await import('../dev/policy-worker-local.mjs');
  const entry = locateMiniflare();
  if (!entry) return t.skip('Cloudflare local runtime not installed (no Wrangler with Miniflare on PATH; set RICHOS_MINIFLARE)');
  const local = await startLocalPolicyWorker(entry);
  t.after(() => local.dispose());
  assert.equal((await local.insert(policy(1))).meta.changes, 1);
  assert.equal((await local.insert(androidNotice(2))).meta.changes, 1);
  assert.equal((await local.insert(policy(3, { target: 'ios-native', features: { recording: false } }))).meta.changes, 1);
  assert.equal((await (await local.fetch('/v1/policy')).json()).revision, 1);
  const android = await local.fetch('/v1/policy/android-native');
  assert.equal(android.status, 200); assert.equal((await android.json()).latest.packageName, 'dev.richos.android');
  assert.equal((await (await local.fetch('/v1/policy/ios-native')).json()).revision, 3);
  const events = await local.fetch('/v1/events/android-native'), reader = events.body.getReader();
  let text = ''; while (!text.includes('data: 2\n\n')) text += new TextDecoder().decode((await reader.read()).value);
  await reader.cancel();
  assert.equal((await local.fetch('/v1/policy/android-native', { method: 'POST' })).status, 405);
});
