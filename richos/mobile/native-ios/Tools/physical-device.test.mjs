import test from 'node:test';
import assert from 'node:assert/strict';
import { createHash, randomBytes } from 'node:crypto';
import { cpSync, existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync, statSync, utimesSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { KEEP, allowanceSeconds, buildTree, configuration, deviceToolSources, plan, prebuilt, prune, resolveProducts, storeKey, verifyPushEnvironment } from './physical-device.mjs';

test('only verify may reuse an earlier build, and only when asked', () => {
  assert.equal(prebuilt({ RICHOS_PHYSICAL_PREBUILT: '1' }, 'verify'), true);
  assert.equal(prebuilt({ RICHOS_PHYSICAL_PREBUILT: '1' }, 'build'), false);
  assert.equal(prebuilt({}, 'verify'), false);
  assert.equal(prebuilt({ RICHOS_PHYSICAL_PREBUILT: 'yes' }, 'verify'), false);
});

const env = { RICHOS_IOS_DEVICE: '00000000-0000000000000000', RICHOS_APPLE_TEAM: 'ABCDEFGHIJ' };
test('physical checks require a named device, team and single supported selection', () => {
  assert.throws(() => configuration({}, 'verify', 'recording'), /physical UDID/);
  assert.throws(() => configuration({ ...env, RICHOS_APPLE_TEAM: '' }, 'verify', 'recording'), /signing team/);
  assert.throws(() => configuration(env, 'verify', 'all'), /one named/);
  assert.throws(() => configuration(env, 'erase', 'recording'), /device build/);
  assert.equal(configuration(env, 'verify', 'recording').test, 'testActualMicrophonePreservesUnsentAudioAfterHomeAndTermination');
});

test('APNs registration must match actual signing regardless of Release optimization', () => {
  assert.throws(() => verifyPushEnvironment('production', 'development'), /must match/);
  assert.throws(() => verifyPushEnvironment(undefined, 'development'), /must match/);
  assert.doesNotThrow(() => verifyPushEnvironment('development', 'development'));
  assert.doesNotThrow(() => verifyPushEnvironment('production', 'production'));
});

test('a walker script is one named selection with a bounded time allowance', () => {
  assert.equal(configuration(env, 'verify', 'script').test, 'testScript');
  assert.equal(allowanceSeconds({}), 240);
  assert.equal(allowanceSeconds({ allowanceSeconds: '900' }), 900);
  for (const bad of ['59', '1801', '12.5', 'forever']) assert.throws(() => allowanceSeconds({ allowanceSeconds: bad }), /60 to 1800/);
});

// --- The test phone keeps its runner: nothing rebuilt, re-signed or reinstalled when nothing changed.

const TREE = 'a'.repeat(40);
function hashDir(path) {
  if (!existsSync(path)) return 'absent';
  const h = createHash('sha256');
  const walk = dir => {
    for (const name of readdirSync(dir).sort()) {
      const full = join(dir, name);
      if (statSync(full).isDirectory()) walk(full);
      else h.update(full.slice(path.length) + '\0').update(readFileSync(full));
    }
  };
  walk(path);
  return h.digest('hex');
}

// A checkout on this Mac: its own derived directory, and a "build" that signs differently every
// time it runs (as a real automatic-signing build does), so any rebuild shows up as new bytes.
function checkout(world, name, source = { tree: TREE, commit: 'c'.repeat(40), dirty: false }) {
  const derived = join(world, name, 'derived');
  const deps = {
    builds: 0,
    source: () => source,
    xcode: () => 'Xcode 26.3 Build version 17C529',
    hash: hashDir,
    copy: (from, to) => cpSync(from, to, { recursive: true }),
    build: async () => {
      deps.builds += 1;
      for (const app of ['RichOSNative.app', 'RichOSNativeUITests-Runner.app']) {
        const dir = join(derived, 'Build/Products/Release-iphoneos', app);
        mkdirSync(dir, { recursive: true });
        writeFileSync(join(dir, '_CodeSignature'), randomBytes(16));
      }
      writeFileSync(join(derived, 'Build/Products/RichOSPhysical_iphoneos26.2-arm64.xctestrun'), 'spec');
    },
  };
  return { derived, deps };
}
const runner = products => hashDir(join(products, 'Release-iphoneos/RichOSNativeUITests-Runner.app'));

test('an unchanged committed tree is built and signed ONCE; every later build or walk, from any checkout, installs the same runner bytes', async () => {
  const world = mkdtempSync(join(tmpdir(), 'physical-store-'));
  try {
    const store = join(world, 'store');
    const first = checkout(world, 'quint');
    const a = await resolveProducts({ command: 'verify', env: {}, team: 'ABCDEFGHIJ', derived: first.derived, store }, first.deps);
    assert.equal(a.mode, 'publish');
    assert.equal(first.deps.builds, 1);

    // The same checkout walks again: no build, no signing, the same runner.
    const again = await resolveProducts({ command: 'verify', env: {}, team: 'ABCDEFGHIJ', derived: first.derived, store }, first.deps);
    assert.equal(again.mode, 'store');
    assert.equal(first.deps.builds, 1, 'a second walk of unchanged source must not build or sign again');
    assert.equal(runner(again.products), runner(a.products));

    // A NEW checkout (a new agent's worktree) at the same tree: still no build, the same runner.
    const second = checkout(world, 'isaac');
    for (const command of ['build', 'verify']) {
      const b = await resolveProducts({ command, env: {}, team: 'ABCDEFGHIJ', derived: second.derived, store }, second.deps);
      assert.equal(b.mode, 'store', `${command} of an unchanged tree must reuse the stored build`);
      assert.equal(b.products, a.products);
      assert.equal(runner(b.products), runner(a.products), `${command} must hand the phone the same signed runner`);
    }
    assert.equal(second.deps.builds, 0, 'a new checkout of an unchanged tree must not build or sign');
  } finally { rmSync(world, { recursive: true, force: true }); }
});

test('changed source builds; uncommitted source is never published; a store entry whose bytes changed is refused', async () => {
  const world = mkdtempSync(join(tmpdir(), 'physical-store-'));
  try {
    const store = join(world, 'store');
    const base = checkout(world, 'one');
    await resolveProducts({ command: 'verify', env: {}, team: 'ABCDEFGHIJ', derived: base.derived, store }, base.deps);

    const changed = checkout(world, 'two', { tree: 'b'.repeat(40), commit: 'd'.repeat(40), dirty: false });
    const c = await resolveProducts({ command: 'verify', env: {}, team: 'ABCDEFGHIJ', derived: changed.derived, store }, changed.deps);
    assert.equal(c.mode, 'publish');
    assert.equal(changed.deps.builds, 1);

    const dirty = checkout(world, 'three', { tree: TREE, commit: 'c'.repeat(40), dirty: true });
    const d = await resolveProducts({ command: 'verify', env: {}, team: 'ABCDEFGHIJ', derived: dirty.derived, store }, dirty.deps);
    assert.equal(d.mode, 'local');
    assert.equal(d.products, join(dirty.derived, 'Build/Products'));
    assert.equal(readdirSync(store).filter(n => !n.startsWith('.')).length, 2, 'uncommitted source never enters the store');

    const key = storeKey({ tree: TREE, team: 'ABCDEFGHIJ', xcode: base.deps.xcode() });
    writeFileSync(join(store, key, 'Products/Release-iphoneos/RichOSNativeUITests-Runner.app/_CodeSignature'), 'tampered');
    const later = checkout(world, 'four');
    await assert.rejects(resolveProducts({ command: 'verify', env: {}, team: 'ABCDEFGHIJ', derived: later.derived, store }, later.deps), /freshness mismatch/);
    assert.equal(later.deps.builds, 0, 'a changed store entry is refused, never silently rebuilt over');
  } finally { rmSync(world, { recursive: true, force: true }); }
});

test('a prebuilt run hands the phone the products its stamp named: a store entry is used as it is, never rebuilt', async () => {
  const world = mkdtempSync(join(tmpdir(), 'physical-store-'));
  try {
    const store = join(world, 'store');
    const publisher = checkout(world, 'publisher');
    const stored = await resolveProducts({ command: 'verify', env: {}, team: 'ABCDEFGHIJ', derived: publisher.derived, store }, publisher.deps);
    // Another checkout whose own tree differs (a perf tool branch) walks the measured build's products.
    const other = checkout(world, 'perf', { tree: 'b'.repeat(40), commit: 'd'.repeat(40), dirty: false });
    const env = { RICHOS_PHYSICAL_PREBUILT: '1', RICHOS_PHYSICAL_PRODUCTS: stored.products };
    const r = await resolveProducts({ command: 'verify', env, team: 'ABCDEFGHIJ', derived: other.derived, store }, other.deps);
    assert.equal(r.mode, 'checkout');
    assert.equal(r.products, stored.products);
    assert.equal(runner(r.products), runner(stored.products));
    assert.equal(other.deps.builds, 0, 'the named products are used as they are');
    // Without the name, a prebuilt run is this checkout's own build, as before.
    await assert.rejects(resolveProducts({ command: 'verify', env: { RICHOS_PHYSICAL_PREBUILT: '1' }, team: 'ABCDEFGHIJ',
      derived: other.derived, store }, other.deps), /no earlier build/);
    // A named directory without the runner is refused rather than half-installed.
    rmSync(join(world, 'publisher', 'derived', 'Build/Products/Release-iphoneos/RichOSNativeUITests-Runner.app'), { recursive: true });
    await assert.rejects(resolveProducts({ command: 'verify', env: { ...env, RICHOS_PHYSICAL_PRODUCTS: join(world, 'publisher', 'derived', 'Build/Products') },
      team: 'ABCDEFGHIJ', derived: other.derived, store }, other.deps), /has no Release-iphoneos\/RichOSNativeUITests-Runner\.app/);
  } finally { rmSync(world, { recursive: true, force: true }); }
});

test('the store key changes with the tree, the team or Xcode, and with nothing else', () => {
  const k = storeKey({ tree: TREE, team: 'ABCDEFGHIJ', xcode: 'Xcode 26.3' });
  assert.equal(k, storeKey({ tree: TREE, team: 'ABCDEFGHIJ', xcode: 'Xcode 26.3' }));
  assert.notEqual(k, storeKey({ tree: 'b'.repeat(40), team: 'ABCDEFGHIJ', xcode: 'Xcode 26.3' }));
  assert.notEqual(k, storeKey({ tree: TREE, team: 'KLMNOPQRST', xcode: 'Xcode 26.3' }));
  assert.notEqual(k, storeKey({ tree: TREE, team: 'ABCDEFGHIJ', xcode: 'Xcode 26.4' }));
  assert.throws(() => storeKey({ tree: 'HEAD', team: 'ABCDEFGHIJ', xcode: 'x' }), /git tree id/);
  assert.equal(plan({ command: 'build', env: { RICHOS_PHYSICAL_PREBUILT: '1' }, source: { dirty: false }, stored: {} }), 'store');
  assert.equal(plan({ command: 'verify', env: { RICHOS_PHYSICAL_PREBUILT: '1' }, source: { dirty: false }, stored: {} }), 'checkout');
});

test('a change to the tooling or prose beside the app keeps the same build; a change to the app does not', () => {
  const tree = names => names.map((name, i) => `040000 tree ${String(i).repeat(40).slice(0, 40)}\t${name}`).join('\n');
  const base = ['App', 'Core', 'Release', 'Tools', 'UITests', 'README.md', 'bin', 'docs'];
  const before = buildTree(tree(base));
  const toolsChanged = tree(base).replace(/^040000 tree \S+\tTools$/m, `040000 tree ${'f'.repeat(40)}\tTools`);
  const appChanged = tree(base).replace(/^040000 tree \S+\tApp$/m, `040000 tree ${'f'.repeat(40)}\tApp`);
  assert.equal(buildTree(toolsChanged), before, 'a Tools/ change must not re-sign or reinstall the app');
  assert.notEqual(buildTree(appChanged), before, 'an App/ change must build');
  assert.match(before, /^[0-9a-f]{64}$/);
});

test('the store stays bounded without removing a recent entry or the one in use', () => {
  const store = mkdtempSync(join(tmpdir(), 'physical-prune-'));
  try {
    const old = (Date.now() - 3 * 86400000) / 1000;
    const names = Array.from({ length: KEEP + 3 }, (_, i) => i.toString(16).padStart(24, '0'));
    names.forEach((name, i) => {
      mkdirSync(join(store, name));
      writeFileSync(join(store, name, 'identity.json'), '{}');
      if (i < 3) utimesSync(join(store, name, 'identity.json'), old - i, old - i);
    });
    const removed = prune(store, names[0]);
    assert.deepEqual(removed.sort(), [names[1], names[2]].sort(), 'only day-old entries past the newest KEEP, never the entry in use');
    assert.ok(existsSync(join(store, names[0])));
  } finally { rmSync(store, { recursive: true, force: true }); }
});

// CEO, 2026-10-01: the phone is dedicated to testing; its app and runner stay installed for good.
const REMOVES_AN_APP = /(['"])(uninstall|erase)\1|devicectl[^\n]*\buninstall\b|\buninstall_app\b|ideviceinstaller|simctl[^\n]*\b(uninstall|erase)\b/i;
test('no device tool can uninstall or wipe an app on the phone', () => {
  for (const bad of ["['device', 'uninstall', 'app']", 'xcrun devicectl device uninstall app --device x', 'ideviceinstaller -U dev.richos.connect']) {
    assert.match(bad, REMOVES_AN_APP, `the check must catch: ${bad}`);
  }
  const sources = deviceToolSources();
  assert.ok(sources.length >= 4);
  for (const file of sources) {
    readFileSync(file, 'utf8').split('\n').forEach((line, i) => {
      assert.doesNotMatch(line, REMOVES_AN_APP, `${file}:${i + 1} would remove an app from the test phone: ${line.trim()}`);
    });
  }
});
