/**
 * RichOS extension — service worker (shell).
 *
 * The shell owns nothing but wiring: it registers modules, routes messages and boots.
 * All capture behaviour lives in `modules/call-capture/`; the next module
 * (`modules/chatgpt-export/`) registers the same way and reuses core settings/output/alerts.
 *
 * MV3 note: every listener below is registered in the first turn of worker evaluation, so an
 * evicted worker wakes up correctly on the next event.
 */

import { registerModule, initModules, routeMessage } from './core/registry.js';
import { callCaptureModule, __testHooks } from './modules/call-capture/controller.js';
import { ensureOffscreen, closeOffscreen, callOffscreen, offscreenExists } from './core/offscreen-host.js';
import * as idb from './core/idb.js';

registerModule(callCaptureModule);

chrome.runtime.onMessage.addListener((msg, sender, sendResponse) => {
  if (!msg || (msg.target && msg.target !== 'sw')) return false;
  const result = routeMessage(msg, sender);
  if (!result) return false;
  Promise.resolve(result)
    .then((value) => sendResponse(value === undefined ? { ok: true } : value))
    .catch((err) => sendResponse({ ok: false, error: String((err && err.message) || err) }));
  return true; // async response
});

chrome.runtime.onInstalled.addListener(() => void initModules());
chrome.runtime.onStartup.addListener(() => void initModules());

// Cold boot (including after an eviction).
void initModules();

/**
 * Local diagnostics seam. Only reachable from this machine's devtools / the CDP test
 * harness — it is not exposed to any web page and grants no capability a devtools console
 * would not already have. (Service workers cannot use dynamic `import()`, so the harness
 * needs these handles hung off a global rather than importing the modules itself.)
 */
globalThis.__richos = {
  callCapture: __testHooks,
  core: { ensureOffscreen, closeOffscreen, callOffscreen, offscreenExists, idb },
};
