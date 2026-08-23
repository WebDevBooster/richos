/**
 * RichOS extension — drop-zone writer (shared core).
 *
 * Every module writes its artifacts through here, so there is exactly one place that knows
 * how bytes leave the browser. v0 uses `chrome.downloads`, which can only write inside the
 * user's downloads folder (any OS) — the sync helper moves finished sessions into loro.
 * See ARCHITECTURE.md for the native-messaging increment that removes that constraint.
 *
 * Blob URLs cannot be created in a service worker, so the offscreen document mints them and
 * the worker performs the download.
 */

import { callOffscreen, ensureOffscreen } from './offscreen-host.js';

/**
 * Make a path component safe on every OS Chrome runs on (`:` `\` `?` `*` `"` `<` `>` `|`
 * are illegal or awkward somewhere).
 * @param {string} value
 * @returns {string}
 */
export function safeName(value) {
  return String(value == null ? '' : value)
    .normalize('NFKD')
    .replace(/[^\w.\- ]+/g, '-')
    .replace(/\s+/g, '_')
    // NB: repeated hyphens are NOT collapsed — `--` separates the fields of a session
    // directory name, and collapsing it would make `session.json`'s `dir` disagree with the
    // folder the files actually landed in.
    .replace(/^[.\-]+|[.\-]+$/g, '')
    .slice(0, 80) || 'unnamed';
}

/**
 * Build a downloads-relative path. Never absolute, never `..`.
 * @param {...string} parts
 * @returns {string}
 */
export function dropPath(...parts) {
  return parts
    .filter(Boolean)
    .map((p) => String(p).split('/').map(safeName).join('/'))
    .join('/');
}

/**
 * Wait for a download to reach a terminal state.
 * @param {number} downloadId
 * @returns {Promise<{ok: boolean, state: string, error?: string, filename?: string}>}
 */
function awaitDownload(downloadId) {
  return new Promise((resolve) => {
    const finish = (result) => {
      chrome.downloads.onChanged.removeListener(listener);
      resolve(result);
    };
    const listener = (delta) => {
      if (delta.id !== downloadId) return;
      if (delta.state?.current === 'complete') finish({ ok: true, state: 'complete' });
      if (delta.state?.current === 'interrupted') {
        finish({ ok: false, state: 'interrupted', error: delta.error?.current || 'interrupted' });
      }
    };
    chrome.downloads.onChanged.addListener(listener);
    // Terminal-state races: the download may already be finished when we attach.
    chrome.downloads.search({ id: downloadId }, (items) => {
      const item = items && items[0];
      if (!item) return;
      if (item.state === 'complete') finish({ ok: true, state: 'complete', filename: item.filename });
      if (item.state === 'interrupted') finish({ ok: false, state: 'interrupted', error: item.error });
    });
  });
}

/**
 * Write text (JSON / JSONL / markdown) to the drop zone.
 * @param {string} filename downloads-relative path
 * @param {string} text
 * @param {{mime?: string, overwrite?: boolean}} [opts]
 * @returns {Promise<{ok: boolean, error?: string, downloadId?: number}>}
 */
export async function writeText(filename, text, opts = {}) {
  await ensureOffscreen();
  const minted = await callOffscreen({
    type: 'core:mint-blob-url',
    text,
    mime: opts.mime || 'application/json',
  });
  if (!minted?.ok) return { ok: false, error: minted?.error || 'mint-failed' };
  return writeUrl(filename, minted.url, opts);
}

/**
 * Write an already-minted blob URL (used for audio, which never passes through the worker).
 * @param {string} filename
 * @param {string} url
 * @param {{overwrite?: boolean}} [opts]
 * @returns {Promise<{ok: boolean, error?: string, downloadId?: number}>}
 */
export async function writeUrl(filename, url, opts = {}) {
  let downloadId;
  try {
    downloadId = await chrome.downloads.download({
      url,
      filename,
      conflictAction: opts.overwrite ? 'overwrite' : 'uniquify',
      saveAs: false,
    });
  } catch (err) {
    await callOffscreen({ type: 'core:revoke-blob-url', url });
    return { ok: false, error: String((err && err.message) || err) };
  }
  const result = await awaitDownload(downloadId);
  await callOffscreen({ type: 'core:revoke-blob-url', url });
  return { ...result, downloadId };
}

/**
 * Suppress (or restore) Chrome's own download bubble. Invisible-by-default requires this:
 * otherwise every session write animates the toolbar mid-call.
 * Side effect the CEO must know: while we hold it, ALL downloads are silent.
 * @param {boolean} enabled true = show Chrome's normal download UI
 */
export async function setDownloadUi(enabled) {
  try {
    if (chrome.downloads.setUiOptions) {
      await chrome.downloads.setUiOptions({ enabled });
      return { ok: true };
    }
  } catch (err) {
    // Another extension already holds the UI lock — not fatal, just noisier.
    return { ok: false, error: String((err && err.message) || err) };
  }
  return { ok: false, error: 'unsupported' };
}
