// Hosted update policy: the exact Worker module and the operator publish path, sharing one
// SQLite database behind a D1 binding and Cloudflare's D1 query API. No timers: every wait is
// released by the test, and every read waits on a stream receipt.
const test = require('node:test');
const assert = require('node:assert/strict');
const { DatabaseSync } = require('node:sqlite');
const { readFileSync, writeFileSync, chmodSync, rmSync } = require('node:fs');
const { createHash } = require('node:crypto');
const { spawnSync } = require('node:child_process');
const { join, resolve } = require('node:path');
const { createScratch } = require('./storage.cjs');
const mobile = resolve(__dirname, '..');
const TOKEN = 'operator-token-sentinel-0123456789';
// The installed app is the shipped version and build; the notice offers the next minor version.
const release = require('../release-config.json');
const later = release.version.replace(/^(\d+)\.(\d+).*$/, (_, major, minor) => `${major}.${Number(minor) + 1}.0`);
const profile = { accountId: 'a'.repeat(32), databaseId: '11111111-2222-3333-4444-555555555555', hostname: 'updates.example.com' };

async function modules() {
  return { worker: await import('../service/policy-worker.mjs'), store: await import('../service/policy-store.mjs'), hosted: await import('../service/policy-hosted.mjs'), authoring: await import('../service/policy.mjs') };
}

function harness(t, worker, { schema = true } = {}) {
  const db = new DatabaseSync(':memory:'); t.after(() => db.close());
  if (schema) db.exec(readFileSync(join(mobile, 'service/policy-schema.sql'), 'utf8'));
  const workerSQL = [], api = { calls: 0, refuse: null };
  const bound = (sql, args) => { const query = db.prepare(sql); return {
    first: async () => query.get(...args) || null,
    all: async () => ({ results: query.all(...args) }),
    run: async () => ({ meta: { changes: Number(query.run(...args).changes) } }),
  }; };
  const DB = { prepare(sql) { workerSQL.push(sql); return { ...bound(sql, []), bind: (...args) => bound(sql, args) }; } };
  const env = { DB };
  // Cloudflare's D1 query API and the public hostname, both backed by the same database.
  async function fetch(url, init = {}) {
    const { pathname, hostname } = new URL(url);
    if (hostname === profile.hostname) return worker.handle(new Request(url, { headers: init.headers }), env);
    api.calls++;
    assert.equal(pathname, `/client/v4/accounts/${profile.accountId}/d1/database/${profile.databaseId}/query`);
    assert.equal(init.method, 'POST'); assert.equal(init.redirect, 'error');
    if (api.refuse) return Response.json({ success: false, errors: [{ code: 10000, message: `Authentication error for ${init.headers.Authorization}` }] }, { status: api.refuse });
    if (init.headers.Authorization !== `Bearer ${TOKEN}`) return Response.json({ success: false, errors: [{ code: 10000 }] }, { status: 403 });
    const { sql, params } = JSON.parse(init.body);
    assert(params.every(value => typeof value === 'string'), 'D1 HTTP parameters are strings');
    const query = db.prepare(sql);
    const result = query.columns().length ? { results: query.all(...params), meta: { changes: 0 } } : { results: [], meta: { changes: Number(query.run(...params).changes) } };
    return Response.json({ success: true, errors: [], messages: [], result: [{ success: true, ...result }] });
  }
  const get = (path, init) => worker.handle(new Request('https://updates.example.com' + path, init), env);
  const rows = () => db.prepare('SELECT revision, digest, audit FROM revisions ORDER BY revision').all();
  return { db, env, get, fetch, api, rows, workerSQL };
}

function policy(revision, extra = {}) {
  const now = Date.now();
  return { schema: 1, revision, issuedAt: new Date(now).toISOString(), expiresAt: new Date(now + 3600000).toISOString(),
    severity: 'none', title: '', message: '', allowDismiss: true, remindAfterSeconds: 60, ...extra };
}
function notice(revision) {
  const verifiedAt = new Date(Date.now() - 60000).toISOString();
  return policy(revision, { severity: 'banner', title: 'Update available', message: `RichOS ${later} is ready in the App Store.`,
    latest: { version: later, build: '3', minimumOS: '16.0', appId: '1234567890', storefronts: ['USA'], verifiedAt } });
}
const receipt = value => ({ downloadVerified: true, ...value.latest, evidence: 'Downloaded on a supported test iPhone in USA' });

async function publisher(t, options) {
  const m = await modules(), h = harness(t, m.worker, options);
  const request = (value, extra = {}) => ({ operator: 'release-operator', policy: value, previewDigest: m.authoring.preview(value, []).digest, ...extra });
  const publish = (value, extra) => m.hosted.publishHosted(profile, request(value, extra), { token: TOKEN, fetch: h.fetch });
  return { ...m, ...h, request, publish };
}

test('served policy is exactly the latest published revision, read back through the public route', async t => {
  const p = await publisher(t);
  assert.equal((await p.get('/v1/policy')).status, 503, 'an empty store serves no policy rather than an invented one');
  const first = policy(1, { features: { recording: false } });
  const published = await p.publish(first);
  assert.equal(published.revision, 1); assert.equal(published.served, 1); assert.equal(published.servedError, null);
  let response = await p.get('/v1/policy');
  assert.equal(response.status, 200);
  assert.equal(response.headers.get('cache-control'), 'no-store');
  assert.match(response.headers.get('content-type'), /^application\/json/);
  assert.deepEqual(await response.json(), first);
  const second = notice(2);
  await p.publish(second, { availability: receipt(second) });
  response = await p.get('/v1/policy');
  assert.deepEqual(await response.json(), second);
  assert.deepEqual((await (await p.get('/healthz')).json()), { service: 'richos-update-policy', protocol: 1, ready: true, revision: 2 });
});

test('the operator schema command creates the append-only store through the D1 API, repeatably', async t => {
  const p = await publisher(t, { schema: false });
  assert.equal(p.hosted.schemaStatements().length, 3);
  const first = await p.hosted.applySchema(profile, { token: TOKEN, fetch: p.fetch });
  assert.deepEqual(first.schema, ['revisions', 'revisions_no_delete', 'revisions_no_update']);
  assert.deepEqual((await p.hosted.applySchema(profile, { token: TOKEN, fetch: p.fetch })).schema, first.schema);
  await p.publish(policy(1));
  assert.throws(() => p.db.exec('DELETE FROM revisions'), /append-only/);
  assert.equal((await (await p.get('/v1/policy')).json()).revision, 1);
});

test('a stale or out-of-order revision is never served over a newer one', async t => {
  const p = await publisher(t);
  await p.publish(policy(5));
  await assert.rejects(p.publish(policy(3)), /new increasing revision \(hosted revision is 5\)/);
  await assert.rejects(p.publish(policy(5)), /new increasing revision/);
  // The statement itself refuses a lower revision, even if the CLI's pre-check was skipped.
  const stale = policy(4);
  assert.equal(Number(p.db.prepare(p.hosted.PUBLISH).run('4', JSON.stringify(stale), 'a'.repeat(64), '{}', 'now').changes), 0);
  // A hand-inserted older row still loses to the newest.
  p.db.prepare('INSERT INTO revisions VALUES (?, ?, ?, ?, ?)').run(4, JSON.stringify(stale), 'a'.repeat(64), '{}', 'now');
  assert.equal((await (await p.get('/v1/policy')).json()).revision, 5);
  assert.throws(() => p.db.exec('UPDATE revisions SET revision = 9 WHERE revision = 5'), /append-only/);
  assert.throws(() => p.db.exec('DELETE FROM revisions WHERE revision = 5'), /append-only/);
  // A corrupt newest row is refused, never replaced by the older record: the phone keeps its cache.
  p.db.prepare('INSERT INTO revisions VALUES (?, ?, ?, ?, ?)').run(6, JSON.stringify(policy(7)), 'a'.repeat(64), '{}', 'now');
  assert.equal((await p.get('/v1/policy')).status, 503);
});

test('the hint stream announces each newer revision and never an older one', { timeout: 10000 }, async t => {
  const p = await publisher(t);
  await p.publish(policy(5));
  let time = 0, notify; const pending = [];
  const ports = { now: () => time, wait: ms => new Promise(resolve => { pending.push({ ms, resolve }); notify?.(); }) };
  // Release exactly one wait once the stream has asked for it (a receipt, not a sleep).
  const step = async () => { while (!pending.length) await new Promise(resolve => { notify = resolve; }); const { ms, resolve } = pending.shift(); time += ms; resolve(); };
  const response = await p.worker.handle(new Request('https://updates.example.com/v1/events'), p.env, ports);
  assert.equal(response.status, 200);
  assert.equal(response.headers.get('content-type'), 'text/event-stream');
  assert.equal(response.headers.get('cache-control'), 'no-store');
  const reader = response.body.getReader(), decoder = new TextDecoder();
  const next = async () => decoder.decode((await reader.read()).value);
  assert.equal(await next(), 'event: policy\ndata: 5\n\n');
  await p.publish(policy(6));
  await step();
  assert.equal(await next(), 'event: policy\ndata: 6\n\n');
  p.db.prepare('INSERT INTO revisions VALUES (?, ?, ?, ?, ?)').run(2, JSON.stringify(policy(2)), 'a'.repeat(64), '{}', 'now');
  for (let i = 0; i < 4; i++) await step();
  assert.equal(await next(), ': alive\n\n', 'an older row produces no announcement');
  await reader.cancel();
});

test('one stream stays inside the Free plan query budget and ends before the client resource timeout', { timeout: 10000 }, async t => {
  const p = await publisher(t);
  await p.publish(policy(1));
  let time = 0;
  const ports = { now: () => time, wait: async ms => { time += ms; } };
  const before = p.workerSQL.length;
  const response = await p.worker.handle(new Request('https://updates.example.com/v1/events'), p.env, ports);
  let body = ''; const decoder = new TextDecoder();
  for (const reader = response.body.getReader(); ;) { const { value, done } = await reader.read(); if (done) break; body += decoder.decode(value); }
  const queries = p.workerSQL.length - before;
  assert(queries <= 40, `${queries} D1 queries; Workers Free allows 50 per invocation`);
  assert(time >= p.store.STREAM.lifetime && time < 120000, `stream lasted ${time} ms of the client's 120 s resource timeout`);
  assert.equal(body.match(/event: policy/g).length, 1);
  const gaps = p.store.STREAM.keepalive; assert(gaps < 15000, 'keepalives stay inside the client 15 s idle timeout');
  assert.equal(body.match(/: alive/g).length, Math.floor(p.store.STREAM.lifetime / gaps));
});

test('no route accepts a write, and no request data is read, stored or logged', async t => {
  const p = await publisher(t);
  await p.publish(policy(1));
  const before = JSON.stringify(p.rows());
  const logged = []; const methods = ['log', 'info', 'warn', 'error', 'debug'];
  const original = Object.fromEntries(methods.map(name => [name, console[name]]));
  for (const name of methods) console[name] = (...args) => logged.push(args);
  t.after(() => Object.assign(console, original));
  let pulled = 0;
  const statements = p.workerSQL.length;
  for (const method of ['POST', 'PUT', 'PATCH', 'DELETE']) for (const path of ['/v1/policy', '/v1/events', '/v1/metrics', '/v1/publish', '/healthz', '/']) {
    const body = new ReadableStream({ pull(controller) { pulled++; controller.enqueue(new TextEncoder().encode('{"revision":99}')); controller.close(); } }, { highWaterMark: 0 });
    const response = await p.get(path, { method, body, duplex: 'half', headers: { Cookie: 'session=secret', 'CF-Connecting-IP': '192.0.2.1' } });
    assert.equal(response.status, 405, `${method} ${path}`); assert.equal(response.headers.get('allow'), 'GET');
  }
  assert.equal(pulled, 0, 'no request body was read');
  assert.equal(p.workerSQL.length, statements, 'refused writes touch no storage');
  assert.equal((await p.get('/v1/policy?revision=99')).status, 404);
  assert.equal((await p.worker.handle(new Request('http://updates.example.com/v1/policy'), p.env)).status, 400);
  const served = await (await p.get('/v1/policy', { headers: { Cookie: 'session=secret', 'CF-Connecting-IP': '192.0.2.1' } })).text();
  assert(!served.includes('secret') && !served.includes('192.0.2.1'));
  assert.equal(JSON.stringify(p.rows()), before, 'the store is unchanged');
  assert(p.workerSQL.every(sql => /^SELECT /.test(sql)), 'the Worker only issues SELECT statements');
  assert.deepEqual(logged, []);
  const source = ['service/policy-worker.mjs', 'service/policy-store.mjs'].map(name => readFileSync(join(mobile, name), 'utf8')).join('\n').replace(/\/\/.*$/gm, '');
  assert.doesNotMatch(source, /\b(INSERT|UPDATE|DELETE|REPLACE|CREATE|DROP|ALTER|PRAGMA)\b/, 'no write statement exists in the Worker');
  for (const [, sql] of source.matchAll(/'([^']*\brevisions\b[^']*)'/g)) assert.match(sql, /^SELECT /);
  assert.doesNotMatch(source, /console\.|request\.(headers|body|json|text|formData|arrayBuffer|cf)\b|cf-connecting-ip/i, 'no logging or request data access');
});

test('publication without a matching preview digest, operator identity or availability receipt is refused before any network call', async t => {
  const p = await publisher(t);
  const plain = policy(1), update = notice(2);
  const cases = [
    [{ operator: 'release-operator', policy: plain }, /Preview/],
    [p.request(plain, { previewDigest: p.authoring.preview(policy(1, { message: 'other' }), []).digest }), /Preview/],
    [p.request(plain, { operator: undefined }), /operator identity/],
    [p.request(plain, { operator: 'x;rm -rf' }), /operator identity/],
    [p.request(update), /download verification receipt/],
    [p.request(update, { availability: { ...receipt(update), build: '4' } }), /download verification receipt/],
    [p.request(update, { availability: { ...receipt(update), downloadVerified: false } }), /download verification receipt/],
  ];
  for (const [request, message] of cases) await assert.rejects(p.hosted.publishHosted(profile, request, { token: TOKEN, fetch: p.fetch }), message);
  assert.equal(p.api.calls, 0);
  assert.deepEqual(p.rows(), []);
});

test('rollback is a higher revision carrying the earlier content, with every audit record kept', async t => {
  const p = await publisher(t);
  const good = policy(1, { features: { recording: true } });
  await p.publish(good);
  await p.publish(policy(2, { features: { recording: false }, message: 'Recording is paused while we fix a problem.' }));
  assert.equal((await (await p.get('/v1/policy')).json()).features.recording, false);
  const rollback = { ...good, revision: 3, issuedAt: new Date().toISOString() };
  await p.publish(rollback);
  const served = await (await p.get('/v1/policy')).json();
  assert.equal(served.revision, 3); assert.equal(served.features.recording, true);
  const rows = p.rows();
  assert.deepEqual(rows.map(row => row.revision), [1, 2, 3]);
  for (const row of rows) {
    const audit = JSON.parse(row.audit);
    assert.equal(audit.operator, 'release-operator'); assert.equal(audit.digest, row.digest); assert.equal(audit.availability, null);
    assert(Number.isFinite(Date.parse(audit.publishedAt)));
  }
});

test('the operator token stays in a private file and out of output, errors and the audit record', async t => {
  const p = await publisher(t), dir = createScratch('policy-token');
  t.after(() => rmSync(dir, { recursive: true, force: true }));
  const file = join(dir, 'token'); writeFileSync(file, TOKEN + '\n'); chmodSync(file, 0o644);
  assert.throws(() => p.hosted.readToken(file), /private/);
  chmodSync(file, 0o600); assert.equal(p.hosted.readToken(file), TOKEN);
  assert.throws(() => p.hosted.readToken(undefined), /RICHOS_POLICY_TOKEN_FILE/);
  p.api.refuse = 403;
  const refused = await p.publish(policy(1)).catch(error => error);
  assert.match(refused.message, /Cloudflare D1 query failed \(HTTP 403, codes 10000\)/);
  assert(!refused.message.includes(TOKEN) && !refused.stack.includes(TOKEN));
  p.api.refuse = null;
  const published = await p.publish(policy(1));
  assert(!JSON.stringify(published).includes(TOKEN));
  assert(!JSON.stringify(p.rows()).includes(TOKEN));
  // The CLI takes no token argument and refuses without the private profile and token file.
  const env = { ...process.env, RICHOS_MOBILE_CACHE: join(dir, 'cache'), TMPDIR: dir + '/' };
  delete env.RICHOS_POLICY_PROFILE; delete env.RICHOS_POLICY_TOKEN_FILE;
  const request = join(dir, 'request.json'); writeFileSync(request, JSON.stringify(p.request(policy(2))));
  const cli = spawnSync(process.execPath, [join(mobile, 'cli/mobile.mjs'), 'update', 'publish-hosted', request], { env, encoding: 'utf8' });
  assert.equal(cli.status, 1); assert.match(JSON.parse(cli.stderr).error, /RICHOS_POLICY_PROFILE/);
  writeFileSync(join(dir, 'profile.json'), JSON.stringify(profile));
  const noToken = spawnSync(process.execPath, [join(mobile, 'cli/mobile.mjs'), 'update', 'publish-hosted', request], { env: { ...env, RICHOS_POLICY_PROFILE: join(dir, 'profile.json') }, encoding: 'utf8' });
  assert.equal(noToken.status, 1); assert.match(JSON.parse(noToken.stderr).error, /RICHOS_POLICY_TOKEN_FILE/);
});

test('the worker artifact is the exact upload: three modules, one D1 binding, logs and traces off', async t => {
  const { hosted } = await modules(), dir = createScratch('policy-artifact');
  t.after(() => rmSync(dir, { recursive: true, force: true }));
  writeFileSync(join(dir, 'profile.json'), JSON.stringify({ ...profile, hostname: 'updates.richos.ceo' }));
  const run = spawnSync(process.execPath, [join(mobile, 'cli/mobile.mjs'), 'update', 'worker-artifact', join(dir, 'profile.json')],
    { env: { ...process.env, RICHOS_MOBILE_CACHE: join(dir, 'cache'), TMPDIR: dir + '/' }, encoding: 'utf8' });
  assert.equal(run.status, 0, run.stderr);
  const artifact = JSON.parse(run.stdout).result;
  assert.equal(artifact.worker, 'richos-update-policy');
  assert.equal(artifact.policyURL, 'https://updates.richos.ceo/v1/policy');
  assert.deepEqual(artifact.metadata, { main_module: 'service/policy-worker.mjs', compatibility_date: hosted.COMPATIBILITY_DATE,
    bindings: [{ name: 'DB', type: 'd1', id: profile.databaseId }], observability: { enabled: false }, logpush: false, tail_consumers: [] });
  assert.deepEqual(artifact.subdomain, { enabled: false, previews_enabled: false });
  const names = artifact.modules.map(module => module.name);
  assert.deepEqual(names, ['service/policy-worker.mjs', 'service/policy-store.mjs', 'core/updates.js']);
  for (const module of artifact.modules) {
    const source = readFileSync(join(mobile, module.name), 'utf8');
    assert.equal(module.source, source); assert.equal(module.sha256, createHash('sha256').update(source).digest('hex'));
    assert.equal(module.type, 'application/javascript+module');
    // Every relative import resolves to a module in the same upload.
    for (const [, specifier] of source.matchAll(/^import\s+(?:[^'"]*from\s+)?['"](\.[^'"]+)['"]/gm)) {
      assert(names.includes(new URL(specifier, 'file:///' + module.name).pathname.slice(1)), `${module.name} imports ${specifier}`);
    }
  }
  assert.equal(artifact.schema.sha256, createHash('sha256').update(readFileSync(join(mobile, 'service/policy-schema.sql'), 'utf8')).digest('hex'));
  assert(!JSON.stringify(artifact.metadata).match(/secret_text|token/i), 'no credential or secret binding in the upload');
  for (const bad of [{ accountId: 'x' }, { databaseId: 'dd8483e3' }, { hostname: 'policy.connect.richos.ceo' }, { hostname: 'richos.ceo' }]) {
    assert.throws(() => hosted.workerArtifact({ ...profile, ...bad }), /Invalid/);
  }
});

test('the unchanged client controller shows a newly published notice from the hosted service without relaunch', { timeout: 10000 }, async t => {
  const p = await publisher(t), Updates = require('../core/updates.js');
  await p.publish(policy(1));
  let time = 0, notify; const pending = [];
  const streamPorts = { now: () => time, wait: ms => new Promise(resolve => { pending.push({ ms, resolve }); notify?.(); }) };
  const step = async () => { while (!pending.length) await new Promise(resolve => { notify = resolve; }); const { ms, resolve } = pending.shift(); time += ms; resolve(); };
  const readers = [];
  const controller = await Updates.createController({
    client: { appId: '1234567890', storefront: 'USA', version: release.version, build: release.build, osVersion: '17.0' },
    authority: 'https://updates.example.com/v1/policy', load: async () => null, save: async () => {},
    setTimeout: () => 0, clearTimeout: () => {}, // the 60 s fallback never fires here; only the hint stream can deliver
    // Mirrors UpdateService.swift: 200 + application/json for policy, and any stream bytes are a refetch hint.
    fetchPolicy: async () => { const response = await p.get('/v1/policy'); assert.equal(response.status, 200); assert.match(response.headers.get('content-type'), /^application\/json/); return response.json(); },
    subscribe: async signal => {
      const response = await p.worker.handle(new Request('https://updates.example.com/v1/events'), p.env, streamPorts);
      assert.equal(response.headers.get('content-type'), 'text/event-stream');
      const reader = response.body.getReader(); readers.push(reader);
      (async () => { while (!(await reader.read()).done) signal(); })().catch(() => {});
      return { close: () => reader.cancel() };
    },
  });
  const seen = predicate => new Promise(resolve => { const stop = controller.subscribe(state => { if (predicate(state)) { queueMicrotask(() => stop()); resolve(state); } }); });
  const initial = seen(state => state.policyRevision === 1);
  await controller.start(); await initial;
  assert.equal(controller.state().mode, 'none');
  const update = notice(2);
  await p.publish(update, { availability: receipt(update) });
  const shown = seen(state => state.mode === 'banner');
  await step();
  const state = await shown;
  assert.equal(state.policyRevision, 2);
  assert.equal(state.storeURL, 'https://apps.apple.com/app/id1234567890');
  controller.stop(); for (const reader of readers) await reader.cancel().catch(() => {});
});
