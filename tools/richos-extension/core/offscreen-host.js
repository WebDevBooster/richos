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
export async function closeOffscreen() {
  if (!(await offscreenExists())) return;
  try {
    await chrome.offscreen.closeDocument();
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
  if (!(await offscreenExists())) return { ok: false, error: 'no-offscreen' };
  try {
    return await chrome.runtime.sendMessage({ ...message, target: 'offscreen' });
  } catch (err) {
    return { ok: false, error: String((err && err.message) || err) };
  }
}
