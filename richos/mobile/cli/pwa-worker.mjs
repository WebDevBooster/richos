// Development-only browser adapter. Serves the unmodified PWA from richos/web/web-app.
import { createRequire } from 'node:module';
import { existsSync, mkdirSync, readFileSync, writeFileSync, renameSync, readdirSync, rmSync } from 'node:fs';
import { join } from 'node:path';
import assert from 'node:assert/strict';
const require = createRequire(import.meta.url);
const { loadPlaywright } = require('../../app/ui/tests/lib/harness.js');
const { createStubMac } = require('../../web/web-app/test/stub-mac.js');
const { phraseFromHex } = require('../../web/web-app/lib/fingerprint.js');
const { createRuntime } = require('../dev/runtime.js');
const root = process.argv[2];
const statusFile = join(root, 'worker.json');
const mac = createStubMac({ host: '127.0.0.1', bindHost: '127.0.0.1', history: 0, autoReply: false,
  threadId: 'general', threads: [{ id: 'general', title: 'General' }, { id: 'planning', title: 'Planning' }] });
let browser, context, page, origin, stopping = false;
const errors = [];
const atomic = (path, data) => { writeFileSync(path + '.new', JSON.stringify(data)); renameSync(path + '.new', path); };
async function cleanup() {
  stopping = true;
  try { await browser?.close(); } finally {
    await mac.close();
    rmSync(statusFile, { force: true });
  }
}
for (const signal of ['SIGINT', 'SIGTERM']) process.on(signal, () => { cleanup().finally(() => process.exit(0)); });

async function ready() {
  await page.locator('#composer').waitFor({ state: 'visible' });
  await page.waitForFunction(() => Boolean(globalThis.__richosPhone?.queue));
}
async function newPage() {
  page = await context.newPage();
  page.setDefaultTimeout(10000);
  page.on('pageerror', (error) => errors.push(error.message));
}
async function fixture(name) {
  if (!['online', 'offline', 'queued', 'revoked'].includes(name)) throw new Error(`Unknown PWA fixture: ${name}`);
  await context?.close();
  mac.setMode('normal');
  mac.state.received.length = 0;
  mac.state.ledger.length = 0;
  mac.state.clientIds.clear();
  mac.state.devices.clear();
  mac.state.challenges.clear();
  mac.state.nextCursor = 1;
  mac.state.pairCode = 'harness-pair-code';
  errors.length = 0;
  context = await browser.newContext({ viewport: { width: 360, height: 800 }, deviceScaleFactor: 2,
    isMobile: true, hasTouch: true, colorScheme: 'dark', locale: 'en-US' });
  await newPage();
  await page.goto(`${origin}/#pair=harness-pair-code`);
  await page.locator('#fingerprint-box:not([hidden])').waitFor();
  assert.equal((await page.locator('#fingerprint-words').textContent()).trim(), phraseFromHex(mac.caFingerprintHex));
  await page.locator('#pair-confirm').click();
  await ready();
  await page.waitForFunction(() => Boolean(navigator.serviceWorker.controller));
  assert.equal(await page.evaluate(() => isSecureContext), true);
  if (name === 'offline' || name === 'queued') await context.setOffline(true);
  if (name === 'queued') {
    await action({ type: 'compose', text: 'Queued from the PWA' });
    await action({ type: 'send' });
  }
  if (name === 'revoked') mac.setMode('revoked');
  return state();
}
async function state() {
  const current = await page.evaluate(() => ({
    online: navigator.onLine,
    selectedThreadId: document.getElementById('thread-picker').value,
    draft: document.getElementById('composer').value,
    outbox: globalThis.__richosPhone.queue.all(),
    revoked: !document.getElementById('revoked').hidden,
    secureContext: isSecureContext,
    serviceWorkerControlled: Boolean(navigator.serviceWorker.controller)
  }));
  return { state: current, receipts: structuredClone(mac.received()), errors: [...errors] };
}
async function action(input) {
  switch (input.type) {
    case 'compose': await page.locator('#composer').fill(input.text); break;
    case 'select-thread': await page.locator('#thread-picker').selectOption(input.threadId); break;
    case 'send': {
      const before = await state();
      const ids = new Set(before.state.outbox.map((item) => item.clientId));
      await page.locator('#send').click();
      const started = performance.now();
      while (true) {
        const after = await state();
        if (after.state.revoked || after.receipts.length > before.receipts.length || after.state.outbox.some((item) => !ids.has(item.clientId))) break;
        if (performance.now() - started > 10000) throw new Error('Visible Send produced no queued message or receipt');
        await new Promise((resolve) => setTimeout(resolve, 20));
      }
      break;
    }
    case 'network': await context.setOffline(!input.online); break;
    case 'retry': await page.locator('#queue-retry').click(); break;
    default: throw new Error(`Unsupported PWA action: ${input.type}`);
  }
  return state();
}
async function scenario(name) {
  if (name !== 'offline-reconnect') throw new Error(`Unknown PWA scenario: ${name}`);
  const headless = await (await createRuntime()).execute({ command: 'scenario', name });
  await fixture('offline');
  await action({ type: 'select-thread', threadId: 'planning' });
  await action({ type: 'compose', text: 'Typed through the PWA composer' });
  await action({ type: 'send' });
  await page.waitForFunction(() => globalThis.__richosPhone.queue.all().length === 1);
  const queued = await state();
  assert.equal(queued.state.outbox[0].threadId, 'planning');
  assert.equal(queued.state.outbox[0].text, 'Typed through the PWA composer');
  assert.equal(queued.receipts.length, 0);
  // Reload OFFLINE through the real service worker and IndexedDB, without reseeding storage.
  await page.reload();
  await ready();
  const reloaded = await state();
  assert.equal(reloaded.state.outbox.length, 1);
  assert.equal(reloaded.state.outbox[0].clientId, queued.state.outbox[0].clientId);
  assert.equal(reloaded.state.outbox[0].threadId, 'planning');
  await action({ type: 'network', online: true });
  await page.waitForFunction(() => globalThis.__richosPhone.queue.all().length === 0);
  const delivered = await state();
  assert.equal(delivered.receipts.length, 1);
  assert.equal(delivered.receipts[0].client_id, queued.state.outbox[0].clientId);
  assert.equal(delivered.receipts[0].thread_id, 'planning');
  assert.deepEqual(errors, []);
  return { name, sharedHeadlessSteps: headless.trace.length, visibleComposerVerified: true,
    offlineReloadPreservedOutbox: true, reconnectedExactlyOnce: true, trace: [queued, reloaded, delivered] };
}
async function execute(request) {
  switch (request.command) {
    case 'prepare': case 'state': return state();
    case 'reset': return fixture('offline');
    case 'fixture': return fixture(request.name);
    case 'action': return action(request.action);
    case 'scenario': return scenario(request.name);
    case 'verify': return scenario('offline-reconnect');
    case 'transport':
      if (!['accept', 'unreachable', 'revoked'].includes(request.mode)) throw new Error('PWA transport expects accept, unreachable or revoked');
      mac.setMode(request.mode === 'accept' ? 'normal' : request.mode); return state();
    case 'refresh':
      // Remove stale development assets while preserving IndexedDB and pairing.
      await context.setOffline(false);
      await page.evaluate(async () => { for (const name of await caches.keys()) await caches.delete(name); });
      await page.reload(); await ready(); return state();
    case 'restart':
      await page.close(); await newPage(); await page.goto(origin); await ready(); return state();
    case 'screenshot': {
      const path = join(root, 'output/playwright', `pwa-${Date.now()}.png`);
      mkdirSync(join(root, 'output/playwright'), { recursive: true });
      await page.screenshot({ path, fullPage: true }); return { path };
    }
    case 'stop': stopping = true; return { stopped: true };
    default: throw new Error(`Unknown PWA command: ${request.command}`);
  }
}
try {
  origin = `https://127.0.0.1:${await mac.listen(0)}`;
  browser = await loadPlaywright().chromium.launch({ headless: process.env.RICHOS_PWA_HEADED !== '1', args: [
    '--mute-audio', `--ignore-certificate-errors-spki-list=${mac.spkiPin}`] });
  await fixture('offline');
  atomic(statusFile, { pid: process.pid, origin, target: 'actual-pwa', viewport: { width: 360, height: 800 } });
  while (!stopping) {
    for (const file of readdirSync(root).filter((name) => /^[a-f0-9-]{36}\.request\.json$/.test(name))) {
      const input = join(root, file);
      const output = input.replace('.request.json', '.response.json');
      if (existsSync(output)) continue;
      try { atomic(output, { ok: true, result: await execute(JSON.parse(readFileSync(input, 'utf8'))) }); }
      catch (error) { atomic(output, { ok: false, error: error.message }); }
    }
    await new Promise((resolve) => setTimeout(resolve, 20));
  }
} catch (error) { console.error(error); process.exitCode = 1; }
finally { await cleanup(); }
