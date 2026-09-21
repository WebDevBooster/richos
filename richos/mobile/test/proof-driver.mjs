// Registered platform proofs. No missing tool/runtime can produce a passing suite.
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { createRequire } from 'node:module';
import { createHash } from 'node:crypto';
import { existsSync, statSync, mkdirSync, readFileSync, rmSync } from 'node:fs';
import { join } from 'node:path';
import { mobile, cacheRoot } from '../cli/simulator.mjs';

const require = createRequire(import.meta.url);
const { createScratch, proofCache } = require('./storage.cjs');
const target = process.argv[2];
assert(['pwa', 'ios'].includes(target), 'Expected pwa or ios');
const label = `mobile-${target}`;
function notRun(reason) { console.log(`  NOT RUN  ${label}: ${reason}`); process.exit(2); }
function hostTool(bin, args) {
  const result = spawnSync(bin, args, { encoding: 'utf8' });
  if (result.error?.code === 'ENOENT') notRun(`${bin} is unavailable`);
  if (result.error) throw result.error;
  return result;
}

// Establish host capability before creating a simulator or starting any worker.
if (target === 'ios') {
  if (process.platform !== 'darwin') notRun('iOS Simulator requires macOS');
  for (const [bin, args] of [['xcodebuild', ['-version']], ['xcodegen', ['--version']]]) {
    const result = hostTool(bin, args);
    if (result.status !== 0) notRun(`${bin} is not configured: ${result.stderr.trim()}`);
  }
  const available = hostTool('xcrun', ['simctl', 'list', 'runtimes', '--json']);
  assert.equal(available.status, 0, available.stderr); // A broken simctl query is a failure.
  if (!JSON.parse(available.stdout).runtimes.some((r) => r.isAvailable && r.name.startsWith('iOS'))) notRun('no available iOS simulator runtime');
} else {
  const { loadPlaywright } = require('../../app/ui/tests/lib/harness.js');
  let playwright;
  try { playwright = loadPlaywright(); }
  catch (error) {
    if (error.message.startsWith('playwright not found')) notRun(error.message);
    throw error;
  }
  if (!existsSync(playwright.chromium.executablePath())) notRun('Playwright Chromium is not installed');
}
if (!existsSync('/Volumes/E1TB') || statSync('/Volumes/E1TB').dev === statSync('/Volumes').dev) notRun('mount /Volumes/E1TB for test storage');

const key = createHash('sha256').update(mobile).digest('hex').slice(0, 10);
// Browser proofs are disposable. Native builds use an isolated reusable cache and
// device per checkout, separate from the developer's interactive CLI session.
// Apple's default device storage was approved for this workflow. This is an
// explicit suite default, not a fallback after an external creation failure.
const storage = process.env.RICHOS_MOBILE_SIMULATOR_STORAGE || 'system';
if (target === 'ios') process.env.RICHOS_MOBILE_SIMULATOR_STORAGE = storage;
const cache = target === 'ios'
  ? proofCache(`/Volumes/E1TB/caches/richos-mobile-ios-proof/${key}`, storage, process.env.RICHOS_MOBILE_IOS_TEST_CACHE)
  : createScratch('pwa-proof');
process.env.RICHOS_MOBILE_CACHE = cache;
cacheRoot(); // Enforce the CLI's external path and symlink checks.
const lock = join(cache, 'suite.lock');
mkdirSync(lock); // Concurrent proofs may not reset one another's fixture.
const env = { ...process.env, RICHOS_PWA_HEADED: '0' };
let browserStarted = false;
let passed = 0;
function cli(...args) {
  const result = spawnSync(process.execPath, [join(mobile, 'cli/mobile.mjs'), ...args], {
    env, encoding: 'utf8', timeout: 300000, maxBuffer: 8 * 1024 * 1024
  });
  assert.ifError(result.error);
  assert.equal(result.status, 0, `${args.join(' ')}\n${result.stdout}\n${result.stderr}`);
  const data = JSON.parse(result.stdout);
  assert.equal(data.ok, true);
  return data.result;
}
function pass(message) { passed++; console.log(`  PASS  ${message}`); }
function cleanup() {
  try {
    if (browserStarted) {
      cli('pwa', 'stop');
      assert(!existsSync(join(cache, 'pwa/worker.json')), 'Browser worker must finish shutdown');
    }
    if (target === 'ios' && existsSync(join(cache, 'device.json'))) {
      const { id, deviceSet } = JSON.parse(readFileSync(join(cache, 'device.json'), 'utf8'));
      const args = ['simctl', ...(deviceSet === 'system' ? [] : ['--set', deviceSet]), 'shutdown', id];
      const result = spawnSync('xcrun', args, { encoding: 'utf8' });
      if (result.status !== 0 && !/current state: Shutdown/.test(result.stderr || '')) throw new Error(`Simulator shutdown failed: ${result.stderr}`);
    }
  } finally {
    rmSync(lock, { recursive: true, force: true });
    if (target === 'pwa' && !existsSync(join(cache, 'pwa/worker.json'))) rmSync(cache, { recursive: true, force: true });
  }
}
for (const signal of ['SIGTERM', 'SIGINT']) process.on(signal, () => { cleanup(); process.exit(130); });
try {
  if (target === 'pwa') {
    browserStarted = true;
    const prepared = cli('pwa', 'prepare');
    assert.equal(prepared.state.secureContext, true);
    assert.equal(prepared.state.serviceWorkerControlled, true);
    pass('real PWA paired in a secure browser context');
    const verified = cli('pwa', 'verify');
    assert.equal(verified.visibleComposerVerified, true);
    assert.equal(verified.offlineReloadPreservedOutbox, true);
    assert.equal(verified.reconnectedExactlyOnce, true);
    assert.deepEqual(verified.trace.map((s) => s.receipts.length), [0, 0, 1]);
    assert(verified.trace.every((s) => s.errors.length === 0));
    pass('visible send, offline reload and exactly-once reconnect');
    const queued = cli('pwa', 'fixture', 'queued');
    const restarted = cli('pwa', 'restart');
    assert.equal(restarted.state.outbox[0].clientId, queued.state.outbox[0].clientId);
    const refreshed = cli('pwa', 'refresh');
    assert.equal(refreshed.state.online, true);
    assert.equal(refreshed.state.revoked, false);
    pass('page restart and source refresh retain the paired session');
    const client = await (await import('./client-ui.mjs')).clientUI();
    assert(client.rapidTypingPreserved && client.bothThemesFitPhoneWidths);
    pass('bundled native UI preserves rapid typing with delayed storage and fits both phone themes');
  } else {
    cli('sim', 'prepare');
    const verified = cli('sim', 'verify');
    assert.equal(verified.scenarios.length, 3);
    assert(verified.scenarios.every((s) => s.identical));
    assert.equal(verified.processRestartPreservedOutbox, true);
    pass('all native/headless traces agree and native process restart preserves outbox');
    const before = cli('sim', 'state');
    assert.deepEqual(cli('sim', 'refresh').state, before.state);
    pass('current UI assets refresh without losing semantic state');
    const controls = cli('sim', 'ui-test');
    assert.equal(controls.visibleSendVerifiedInCore, true);
    assert.equal(controls.state.outbox[0].text, 'Typed through the visible composer');
    pass(`XCUITest visible composer and Send: ${controls.result}`);
    const client = cli('sim', 'client-prepare');
    assert.equal(client.state.confirmed, false);
    cli('sim', 'action', JSON.stringify({ type: 'compose', text: 'Native client refresh proof' }));
    assert.equal(cli('sim', 'refresh').state.draft, 'Native client refresh proof');
    pass('native client actions and protected-file persistence survive a UI refresh');
    const { policy } = require('../dev/update-fixture.js');
    const revision = Date.now();
    assert.equal(cli('sim', 'policy', JSON.stringify(policy('banner', revision))).state.updates.mode, 'banner');
    assert.equal(cli('sim', 'action', JSON.stringify({ type: 'update-dismiss' })).state.updates.mode, 'none');
    assert.equal(cli('sim', 'policy', JSON.stringify(policy('blocking', revision + 1))).state.updates.mode, 'blocking');
    assert.equal(cli('sim', 'policy', JSON.stringify(policy('none', revision + 2))).state.updates.blocked, false);
    pass('real client update policy decisions and dismissal use the simulator action path');
    assert.equal(cli('check-release').developmentBridgeExcluded, true);
    pass('Release excludes development runtime and native command access');
  }
} catch (error) {
  console.error(`  FAIL  ${label}: ${error.stack}`);
  process.exitCode = 1;
} finally {
  try { cleanup(); }
  catch (error) { console.error(`  FAIL  ${label} cleanup: ${error.stack}`); process.exitCode = 1; }
}
if (!process.exitCode) console.log(`=== ${label} tests: all ${passed} passed ===`);
