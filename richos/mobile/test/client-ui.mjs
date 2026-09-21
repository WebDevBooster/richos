// Real bundled DOM/controller with delayed native persistence. This catches lost
// keystrokes that headless core actions alone cannot reveal.
import assert from 'node:assert/strict';
import { createRequire } from 'node:module';
import { join } from 'node:path';
import { rmSync } from 'node:fs';
import { pathToFileURL } from 'node:url';
import { stageAssets } from '../cli/simulator.mjs';
const require = createRequire(import.meta.url);
const { createScratch } = require('./storage.cjs');
const { loadPlaywright } = require('../../app/ui/tests/lib/harness.js');
export async function clientUI() {
  const scratch = createScratch('client-ui'), assets = join(scratch, 'mobile-ui');
  let browser;
  try {
    stageAssets(assets, false);
    browser = await loadPlaywright().chromium.launch({ headless: true });
    const context = await browser.newContext({ viewport: { width: 375, height: 812 }, isMobile: true });
    await context.addInitScript(() => {
      let data = null;
      window.webkit = { messageHandlers: { richos: { async postMessage({ method, args }) {
        if (method === 'load') return data;
        if (method === 'save') { await new Promise(resolve => setTimeout(resolve, 25)); data = args.value; return true; }
        if (method === 'updateInfo') return { version: '0.1.0', build: '2', osVersion: '16.7.16', configured: false, appId: null, storefront: null };
        if (method === 'recordings') return [];
        if (method === 'incomingLink') return null;
        throw Error(method);
      } } } };
    });
    const page = await context.newPage(), errors = []; page.on('pageerror', error => errors.push(error.message));
    await page.goto(pathToFileURL(join(assets, 'client.html')).href);
    const message = page.getByRole('textbox', { name: 'Message', exact: true });
    await page.getByRole('button', { name: 'Record', exact: true }).waitFor();
    const text = 'Native phone check 0123456789';
    await message.pressSequentially(text, { delay: 1 });
    await page.waitForFunction(value => document.querySelector('#message').value === value, text);
    // Wait on a semantic durability boundary, not a timing guess.
    await page.waitForFunction(() => !document.querySelector('#error').textContent);
    assert.equal(await message.inputValue(), text);
    // A new character after the delayed writes settle must append to the complete draft.
    await page.waitForTimeout(text.length * 35);
    assert.equal(await message.inputValue(), text);
    await message.pressSequentially('!'); assert.equal(await message.inputValue(), text + '!');
    for (const colorScheme of ['light', 'dark']) {
      await page.emulateMedia({ colorScheme });
      for (const width of [320, 375, 430]) {
        await page.setViewportSize({ width, height: 812 });
        assert(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth), `${colorScheme} ${width}: horizontal overflow`);
      }
    }
    assert.deepEqual(errors, []);
    return { rapidTypingPreserved: true, bothThemesFitPhoneWidths: true };
  } finally { await browser?.close(); rmSync(scratch, { recursive: true, force: true }); }
}
