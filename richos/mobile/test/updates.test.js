const test = require('node:test');
const assert = require('node:assert/strict');
const { compare, validate, evaluate, createController } = require('../core/updates.js');
const at = Date.parse('2026-09-22T00:00:00Z');
// The installed app is the shipped version and build, read from their one source; the replacement
// is the next minor version, so the scenario stays a real upgrade whatever the shipped version is.
const release = require('../release-config.json');
const client = { version: release.version, build: release.build, osVersion: '16.7.16', appId: '1234567890', storefront: 'GBR' };
const installed = `${client.version}+${client.build}`;
const later = { version: release.version.replace(/^(\d+)\.(\d+).*$/, (_, major, minor) => `${major}.${Number(minor) + 1}.0`), build: '3' };
function policy(overrides = {}) { return { schema: 1, revision: 1, issuedAt: new Date(at).toISOString(), expiresAt: new Date(at + 3600000).toISOString(), severity: 'banner', title: 'Update available', message: 'A new version is ready.', allowDismiss: true, remindAfterSeconds: 60,
  latest: { ...later, minimumOS: '16.7', appId: client.appId, storefronts: ['GBR'], verifiedAt: new Date(at).toISOString() }, ...overrides }; }
function clock() {
  let now = at, id = 0; const timers = new Map();
  return { now: () => now, setTimeout: (fn, ms) => { timers.set(++id, { fn, at: now + ms }); return id; }, clearTimeout: id => timers.delete(id),
    async advance(ms) { now += ms; const due = [...timers.entries()].filter(([, t]) => t.at <= now); for (const [id, t] of due) { timers.delete(id); t.fn(); } await new Promise(r => setImmediate(r)); } };
}
test('numeric versions and builds, OS floor and actual storefront gate every promotion', () => {
  assert.equal(compare('1.10', '1.9'), 1); assert.equal(compare('1', '1.0'), 0);
  assert.equal(evaluate(policy(), client, at).mode, 'banner');
  for (const change of [{ appId: null }, { storefront: null }, { storefront: 'USA' }, { osVersion: '15.8' }, later]) assert.equal(evaluate(policy(), { ...client, ...change }, at).mode, 'none');
  assert.throws(() => compare('v1', '2'));
  assert.throws(() => validate(policy({ latest: null })));
  assert.throws(() => validate(policy({ features: [] })));
  assert.throws(() => validate(policy({ minimum: { version: '9', build: '1' } })));
  assert.throws(() => validate(policy({ blockedBuilds: [`${later.version}+${later.build}`] })));
});
test('mandatory updates require an affected build and installable replacement; expired policy releases lockout', () => {
  const p = policy({ severity: 'blocking', minimum: later, features: { text: false } });
  assert(evaluate(p, client, at, null, true).blocked);
  assert.equal(evaluate(p, { ...client, storefront: 'USA' }, at).blocked, false);
  assert.equal(evaluate(p, client, at + 3600001).blocked, false);
  assert.equal(evaluate(p, client, at + 3600001).features.text, true);
  assert.equal(evaluate(policy(), client, at, null, true).mode, 'none');
  assert.equal(evaluate(policy({ severity: 'blocking', blockedBuilds: [installed] }), client, at).mode, 'blocking');
});
test('controller retains validated policy across outage/relaunch, handles dismissal and refuses rollback', async t => {
  const time = clock(); let disk, next = policy();
  const ports = { ...time, client, load: async () => disk, save: async value => { disk = structuredClone(value); }, fetchPolicy: async () => { if (next instanceof Error) throw next; return next; } };
  let controller = await createController(ports); t.after(() => controller.stop());
  await controller.start(); await controller.refresh(); assert.equal(controller.state().mode, 'banner');
  await controller.dismiss(); assert.equal(controller.state().mode, 'none');
  await time.advance(61000); assert.equal(controller.state().mode, 'banner');
  next = policy({ revision: 2, severity: 'blocking', blockedBuilds: [installed] });
  await controller.refresh(true); assert(controller.state().blocked);
  next = Error('offline'); await controller.refresh(); assert(controller.state().blocked); assert(controller.state().error);
  controller.stop(); controller = await createController(ports); assert(controller.state().blocked);
  assert.equal(await controller.accept(policy()), false);
  await controller.start(); await time.advance(3600001); assert.equal(controller.state().blocked, false);
});
test('change signals coalesce but cannot be lost behind a stale in-flight fetch', async t => {
  let signal, finish, count = 0; const time = clock();
  const controller = await createController({ ...time, client, load: async () => null, save: async () => {},
    subscribe: async fn => { signal = fn; return { close() {} }; },
    fetchPolicy: async () => { count++; if (count === 1) return new Promise(resolve => { finish = resolve; }); return policy({ revision: 2 }); } });
  t.after(() => controller.stop()); await controller.start(); signal(); signal(); finish(policy());
  await new Promise(r => setImmediate(r)); assert.equal(count, 2); assert.equal(controller.state().policyRevision, 2);
});
test('an unavailable signal connection cannot delay the first check and late owners are closed', async t => {
  let open, closes = 0, fetches = 0;
  const controller = await createController({ ...clock(), client, load: async () => null, save: async () => {},
    subscribe: () => new Promise(resolve => { open = resolve; }), fetchPolicy: async () => { fetches++; return policy(); } });
  const started = controller.start(); await new Promise(r => setImmediate(r)); assert.equal(fetches, 1);
  controller.stop(); open({ close() { closes++; } }); await started; assert.equal(closes, 1); t.after(() => controller.stop());
});
test('concurrent policy writes cannot put an older revision back on disk', async () => {
  let disk; const c = await createController({ ...clock(), client, load: async () => null, save: async value => { await new Promise(r => setImmediate(r)); disk = value; } });
  await Promise.all([c.accept(policy({ revision: 3 })), c.accept(policy({ revision: 2 }))]);
  assert.equal(c.state().policyRevision, 3); assert.equal(disk.policy.revision, 3);
});
module.exports = { policy, client, clock };

test('changing the fixed service authority cannot retain its old cached block', async () => {
  let disk;
  const first = await createController({ ...clock(), authority: 'https://old.example/v1/policy', client, load: async () => null, save: async value => { disk = value; } });
  await first.accept(policy({ severity: 'blocking', blockedBuilds: [installed] })); assert(first.state().blocked);
  const changed = await createController({ ...clock(), authority: 'https://new.example/v1/policy', client, load: async () => disk, save: async () => {} });
  assert.equal(changed.state().blocked, false); assert.equal(changed.state().policyRevision, 0);
});
test('dismissal cannot overwrite a concurrently arriving mandatory policy', async () => {
  let disk;
  const controller = await createController({ ...clock(), client, load: async () => null, save: async value => { await new Promise(r => setImmediate(r)); disk = value; } });
  await controller.accept(policy());
  const next = controller.accept(policy({ revision: 2, severity: 'blocking', blockedBuilds: [installed] }));
  await assert.rejects(controller.dismiss(), /cannot be dismissed/); await next;
  assert(controller.state().blocked); assert.equal(disk.policy.revision, 2);
});
