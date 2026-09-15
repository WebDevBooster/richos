/**
 * RichOS extension — offscreen document router (shared core).
 *
 * Core services provided here (usable by every module):
 *   · blob-URL minting / revoking, because a service worker cannot create object URLs
 *   · the CEO-only audible alarm
 * Module handlers are dispatched by message prefix.
 */

import * as recorder from '../modules/call-capture/recorder.js';

/** @type {Set<string>} blob URLs we minted, so nothing leaks if a download is abandoned. */
const minted = new Set();

/** A short two-tone alarm. Off by default — an open microphone would pick it up. */
async function chime() {
  const ctx = new AudioContext();
  const now = ctx.currentTime;
  const gain = ctx.createGain();
  gain.gain.setValueAtTime(0.0001, now);
  gain.connect(ctx.destination);
  const osc = ctx.createOscillator();
  osc.type = 'sine';
  osc.frequency.setValueAtTime(880, now);
  osc.frequency.setValueAtTime(660, now + 0.18);
  osc.connect(gain);
  gain.gain.exponentialRampToValueAtTime(0.25, now + 0.02);
  gain.gain.exponentialRampToValueAtTime(0.0001, now + 0.42);
  osc.start(now);
  osc.stop(now + 0.45);
  await new Promise((resolve) => setTimeout(resolve, 600));
  await ctx.close();
  return { ok: true };
}

/**
 * @param {any} msg
 * @returns {Promise<any>|undefined}
 */
function handle(msg) {
  switch (msg.type) {
    case 'core:ping':
      return Promise.resolve({ ok: true, at: Date.now() });
    case 'core:mint-blob-url': {
      const url = URL.createObjectURL(new Blob([msg.text], { type: msg.mime || 'text/plain' }));
      minted.add(url);
      return Promise.resolve({ ok: true, url });
    }
    case 'core:revoke-blob-url': {
      if (msg.url) {
        URL.revokeObjectURL(msg.url);
        minted.delete(msg.url);
      }
      return Promise.resolve({ ok: true });
    }
    case 'core:chime':
      return chime();
    default:
      if (typeof msg.type === 'string' && msg.type.startsWith('cc:')) return recorder.handleMessage(msg);
      return undefined;
  }
}

chrome.runtime.onMessage.addListener((msg, sender, sendResponse) => {
  if (!msg || msg.target !== 'offscreen') return false;
  const result = handle(msg);
  if (!result) return false;
  result
    .then((value) => sendResponse(value === undefined ? { ok: true } : value))
    .catch((err) => sendResponse({ ok: false, error: String((err && err.message) || err) }));
  return true; // async response
});
