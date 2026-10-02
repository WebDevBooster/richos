/**
 * RichOS extension — offscreen document host (shared core).
 *
 * Chrome allows exactly ONE offscreen document per extension, so the core owns its
 * lifecycle and modules ride on it via routed messages. The document is the only place
 * an MV3 extension can hold media (`getUserMedia`, `MediaRecorder`, `AudioContext`) or
 * create blob URLs — the service worker can do neither.
 */

const OFFSCREEN_PATH = 'core/offscreen.html';
const REASONS = ['USER_MEDIA', 'AUDIO_PLAYBACK', 'BLOBS'];
const JUSTIFICATION =
  'Records call audio (tab + microphone) to local disk, keeps the captured tab audible, and builds blob URLs for local file writes.';

/** @type {Promise<void>|null} guards the create-while-creating race */
let creating = null;
let closing = null;
const owners = new Map();

/** Hold the shared document without granting a module permission to close it. */
export async function acquireOffscreen(owner, onReset = () => {}) {
  const token = Symbol(owner);
  owners.set(token, { owner, onReset });
  try { await ensureOffscreen(); } catch (error) { owners.delete(token); throw error; }
  return async () => {
    owners.delete(token);
    // Core checks recorder and output ownership before reclaiming the idle document.
    await closeOffscreen();
  };
}

/** @returns {Promise<boolean>} */
export async function offscreenExists() {
  const contexts = await chrome.runtime.getContexts({ contextTypes: ['OFFSCREEN_DOCUMENT'] });
  return contexts.length > 0;
}

/**
 * Ensure the offscreen document exists. Idempotent and race-safe.
 * @returns {Promise<'existing'|'created'>}
 */
export async function ensureOffscreen() {
  if (closing) await closing;
  if (await offscreenExists()) return 'existing';
  if (creating) {
    await creating;
    return 'existing';
  }
  creating = chrome.offscreen
    .createDocument({ url: OFFSCREEN_PATH, reasons: REASONS, justification: JUSTIFICATION })
    .finally(() => {
      creating = null;
    });
  try {
    await creating;
  } catch (err) {
    // Another context won the race; treat "already exists" as success.
    if (!String(err && err.message).includes('Only a single offscreen')) throw err;
    return 'existing';
  }
  return 'created';
}

/** Tear the offscreen document down (used by recovery: a wedged document is replaced). */
export function closeOffscreen(options = {}) {
  if (closing) return closing;
  closing = closeOffscreenImpl(options).finally(() => { closing = null; });
  return closing;
}

async function closeOffscreenImpl({ force = false } = {}) {
  if (!force && owners.size) return false;
  if (!(await offscreenExists())) return true;
  if (!force) {
    const status = await callOffscreen({ type: 'core:resource-status' });
    if (!status?.ok || status.busy || owners.size) return false;
  } else {
    for (const entry of owners.values()) entry.onReset();
    owners.clear();
  }
  try {
    await chrome.offscreen.closeDocument();
    return true;
  } catch {
    /* already gone */
  }
}

/**
 * Send a message to the offscreen document and await its reply.
 * Returns `{ ok: false, error: 'no-offscreen' }` instead of throwing when the document is gone,
 * so callers can treat "the recorder vanished" as a health signal rather than an exception.
 * @param {object} message
 * @returns {Promise<any>}
 */
export async function callOffscreen(message) {
  const token = Symbol('message');
  if (message.type !== 'core:resource-status') owners.set(token, { owner: 'message', onReset: () => {} });
  try {
    if (!(await offscreenExists())) return { ok: false, error: 'no-offscreen' };
    return await chrome.runtime.sendMessage({ ...message, target: 'offscreen' });
  } catch (err) {
    return { ok: false, error: String((err && err.message) || err) };
  } finally { owners.delete(token); }
}
