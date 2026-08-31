/**
 * RichOS local service — the verified model fetch.
 *
 * THE INTEGRITY LAYER BENEATH "AUTOMATICALLY DOWNLOAD AND INSTALL WHATEVER THE USER NEEDS". The
 * consent surface — the sheet that asks before a byte moves — is app work and is deliberately NOT
 * here. This module's whole job is that once permission has been given, what lands on disk is the
 * bytes we pinned or nothing at all.
 *
 * The sequence, and why each step is where it is:
 *
 *   1. ALREADY PRESENT? A full hash of what is on disk. Re-downloading 1.6 GB the user already
 *      has is rude; installing a corrupted copy because it is the right length is worse.
 *   2. DISK PREFLIGHT. Before a single byte is requested. Finding out at 95% of 1.6 GB is the
 *      worst possible moment.
 *   3. RESUME OR RESTART. Decided by `resumePlan`, which refuses to resume onto a partial file
 *      that does not begin like a model — otherwise a captive portal's login page becomes the
 *      first 3 KB of a "model" that is exactly the right length.
 *   4. STREAM TO `<name>.part`. Never to the real name. A resolver searching the model directory
 *      can therefore never observe a half-written model, because a half-written model never has
 *      a model's name.
 *   5. VERIFY THE WHOLE FILE. Size, GGML magic, then sha256 over every byte on disk.
 *   6. `rename()` ONLY THEN. Atomic within a filesystem.
 *
 * A FAILED HASH IS DELETED, NOT QUARANTINED. There is no `.bad` file, no "keep it in case", no
 * second-chance path that could ever be read by the resolver. And a failed hash is NEVER retried
 * automatically: retrying a corrupted download in a loop is how a transient CDN fault becomes a
 * support ticket. Truncation is retried, because truncation is what a flaky connection does and
 * resuming is cheap.
 */

import fs from 'node:fs';
import path from 'node:path';
import { Readable } from 'node:stream';
import { pipeline } from 'node:stream/promises';

import { requirePin, requiredFreeBytes, human, MODEL_BASE_URL } from './model-catalog.js';
import {
  FAILURE,
  classify,
  describe,
  diskPreflight,
  resumePlan,
  hashFile,
  readHead,
  fileBytes,
  inspectFile,
} from './model-integrity.js';

/** Failure kinds a second attempt could plausibly fix. Everything else stops at one attempt. */
export const RETRYABLE = Object.freeze(new Set([FAILURE.EMPTY, FAILURE.SHORT, 'network']));

/** How many attempts a download gets before it stops and says so (the design's "2-3, then stop"). */
export const MAX_ATTEMPTS = 3;

/** How much of a rejected body is read back to work out what it actually is. Bounded on purpose. */
export const PEEK_BYTES = 64 * 1024;

/**
 * Read at most `limit` bytes of a response body and stop. Used only on a body we have ALREADY
 * decided not to install, purely so the failure can be named.
 * @param {Response} res
 * @param {number} limit
 * @returns {Promise<Buffer>}
 */
export async function peekBody(res, limit = PEEK_BYTES) {
  if (!res.body) return Buffer.alloc(0);
  const chunks = [];
  let n = 0;
  try {
    for await (const chunk of res.body) {
      chunks.push(Buffer.from(chunk));
      n += chunk.length;
      if (n >= limit) break;
    }
  } catch {
    /* a body that dies mid-peek tells us nothing more than we already have */
  }
  return Buffer.concat(chunks).subarray(0, limit);
}

/** Free bytes on the filesystem holding `dir`, or Infinity when the platform will not say. */
export function freeBytesFor(dir) {
  try {
    const s = fs.statfsSync(dir);
    return s.bavail * s.bsize;
  } catch {
    return Infinity;
  }
}

/**
 * Download one pinned artifact and install it only if it verifies. ONE attempt.
 *
 * @param {{url: string, dest: string,
 *          pin: {id: string, file: string, bytes: number, sha256: string},
 *          freeBytes?: number, onProgress?: (p: {received: number, total: number}) => void,
 *          signal?: AbortSignal}} opts
 * @returns {Promise<{ok: boolean, status: string, kind?: string, message: string, path?: string,
 *                     bytes?: number, resumedFrom?: number, retryable?: boolean}>}
 */
export async function fetchVerified({ url, dest, pin, freeBytes, onProgress, signal }) {
  const label = pin.file;
  const part = `${dest}.part`;
  fs.mkdirSync(path.dirname(dest), { recursive: true });

  // 1. Already present and genuinely correct?
  if (fs.existsSync(dest)) {
    const verdict = await inspectFile(dest, pin, { deep: true });
    if (verdict.ok) {
      return { ok: true, status: 'already-present', message: `${label} is already installed and verifies.`, path: dest, bytes: pin.bytes };
    }
    // Present but wrong. Say so, remove it, and fetch again — leaving it would let the resolver
    // pick a file we have just proved is not the model.
    fs.rmSync(dest, { force: true });
  }

  // 2. Disk preflight, before a byte is requested.
  const need = requiredFreeBytes(pin);
  const have = freeBytes != null ? freeBytes : freeBytesFor(path.dirname(dest));
  const space = diskPreflight({ freeBytes: have, needBytes: need });
  if (!space.ok) {
    return { ok: false, status: 'refused', kind: space.kind, retryable: false, message: describe(space, { file: label }) };
  }

  // 3. Resume, restart, or start.
  const partBytes = fileBytes(part);
  const plan = resumePlan({ partBytes, totalBytes: pin.bytes, partHead: partBytes ? readHead(part) : null });
  if (plan.action === 'restart') fs.rmSync(part, { force: true });
  let from = plan.action === 'resume' ? plan.from : 0;

  // 4. Stream to `<name>.part`, never to the real name.
  let res;
  try {
    res = await fetch(url, { signal, headers: from > 0 ? { Range: `bytes=${from}-` } : {} });
  } catch (err) {
    return {
      ok: false,
      status: 'failed',
      kind: 'network',
      retryable: true,
      message: `Could not reach ${url} to download ${label}: ${String(err?.cause?.message || err?.message || err)}. ${
        from > 0 ? `The ${fmtBytes(from)} already downloaded were kept.` : 'Nothing was downloaded.'
      }`,
    };
  }
  if (!res.ok) {
    return {
      ok: false,
      status: 'failed',
      kind: 'http',
      retryable: res.status >= 500 || res.status === 429,
      message: `${label} could not be downloaded: the server answered ${res.status} ${res.statusText || ''}`.trim() + '. Nothing was installed.',
    };
  }
  // A server that ignores `Range` answers 200 with the WHOLE file. Appending that onto a partial
  // would produce a longer-than-pinned file that hashes to nothing, so the partial is dropped and
  // the full body is written from zero. Silent corruption avoided by reading the status, not by
  // trusting the request.
  if (from > 0 && res.status !== 206) {
    fs.rmSync(part, { force: true });
    from = 0;
  }

  // The server has told us how long the file is before sending it. If that disagrees with the
  // pin, refuse NOW rather than after transferring 1.6 GB we already know we will delete. This is
  // the one check that can save a whole download on a metered or slow connection.
  const declared = declaredTotal(res, from);
  if (declared != null && declared !== pin.bytes) {
    // BUT LOOK AT IT FIRST. A captive portal declares a Content-Length too, and "the server
    // offered 3,104 bytes where RichOS pinned 487,614,201" is a puzzle where "you are behind a
    // wifi login page" is an instruction. Peek at a bounded prefix — never the whole body — so
    // the better sentence wins whenever there is one to be had.
    const peek = await peekBody(res, PEEK_BYTES);
    const shape = classify({ exists: true, bytes: declared, head: peek, sha256: null, pin });
    if (shape.kind && shape.kind !== FAILURE.SHORT && shape.kind !== FAILURE.OVERSIZE) {
      return { ok: false, status: 'refused', kind: shape.kind, retryable: false, message: describe(shape, { file: label }) };
    }
    return {
      ok: false,
      status: 'refused',
      kind: declared < pin.bytes ? FAILURE.SHORT : FAILURE.OVERSIZE,
      retryable: false,
      message:
        `${label} was not downloaded: the server offered ${fmtBytes(declared)} where RichOS pinned ${fmtBytes(pin.bytes)}. ` +
        'That is a different file, so the transfer was stopped before it started rather than after.',
    };
  }

  const total = pin.bytes;
  let received = from;
  try {
    const body = Readable.fromWeb(res.body);
    if (onProgress) {
      body.on('data', (c) => {
        received += c.length;
        onProgress({ received, total });
      });
    }
    await pipeline(body, fs.createWriteStream(part, { flags: from > 0 ? 'a' : 'w' }));
  } catch (err) {
    const got = fileBytes(part);
    return {
      ok: false,
      status: 'failed',
      kind: 'network',
      retryable: true,
      resumedFrom: from,
      message: `The download of ${label} stopped after ${fmtBytes(got)} of ${fmtBytes(total)} (${String(err?.cause?.message || err?.message || err)}). The partial file was kept, so the next attempt resumes from there rather than starting over.`,
    };
  }

  // 5. Verify the whole file: size, magic, then sha256 over every byte.
  const bytes = fileBytes(part);
  const head = readHead(part);
  const cheap = classify({ exists: true, bytes, head, sha256: null, pin });
  if (!cheap.ok) {
    // A short file is a kept prefix; anything else is not a model at all and is deleted.
    const keep = cheap.kind === FAILURE.SHORT;
    if (!keep) fs.rmSync(part, { force: true });
    return {
      ok: false,
      status: 'failed',
      kind: cheap.kind,
      retryable: RETRYABLE.has(cheap.kind),
      resumedFrom: from,
      message: describe(cheap, { file: label, resumable: keep }),
    };
  }
  const sha256 = await hashFile(part);
  const full = classify({ exists: true, bytes, head, sha256, pin });
  if (!full.ok) {
    fs.rmSync(part, { force: true }); // discarded, never quarantined-and-used
    return {
      ok: false,
      status: 'failed',
      kind: full.kind,
      retryable: false,
      resumedFrom: from,
      message: describe(full, { file: label }),
    };
  }

  // 6. Only now does it get a model's name.
  fs.renameSync(part, dest);
  return {
    ok: true,
    status: from > 0 ? 'resumed' : 'downloaded',
    message: `${label} downloaded and verified against its pinned sha256 (${fmtBytes(bytes)}).`,
    path: dest,
    bytes,
    resumedFrom: from,
    sha256,
  };
}

/**
 * Fetch a PINNED model by id into a directory, retrying only what a retry could fix.
 *
 * @param {string|object} modelIdOrPin a pinned id ('small.en'), or a pin object from a manifest
 * @param {string} destDir where models live
 * @param {{maxAttempts?: number, baseUrl?: string, onProgress?: Function, onAttempt?: Function,
 *          freeBytes?: number, signal?: AbortSignal}} [opts]
 */
export async function downloadModel(modelIdOrPin, destDir, opts = {}) {
  const pin = requirePin(modelIdOrPin); // no hash, no network — there is no third option
  const url = `${opts.baseUrl || MODEL_BASE_URL}/${pin.file}`;
  const dest = path.join(destDir, pin.file);
  const maxAttempts = opts.maxAttempts ?? MAX_ATTEMPTS;
  const attempts = [];

  for (let n = 1; n <= maxAttempts; n += 1) {
    if (opts.onAttempt) opts.onAttempt({ attempt: n, of: maxAttempts });
    // eslint-disable-next-line no-await-in-loop
    const r = await fetchVerified({ url, dest, pin, freeBytes: opts.freeBytes, onProgress: opts.onProgress, signal: opts.signal });
    attempts.push({ attempt: n, ok: r.ok, kind: r.kind, message: r.message });
    if (r.ok) return { ...r, attempts };
    if (!r.retryable) return { ...r, attempts, message: r.message };
    if (n === maxAttempts) {
      return {
        ...r,
        attempts,
        message: `${r.message} RichOS tried ${maxAttempts} times and stopped rather than looping.`,
      };
    }
  }
  /* istanbul ignore next — the loop always returns */
  return { ok: false, status: 'failed', message: 'unreachable', attempts };
}

/**
 * What RichOS would need to do to make this model usable — the question the consent sheet asks,
 * answered without downloading anything. Pure-ish: one stat + one hash of what is already there.
 * @param {string|object} modelIdOrPin
 * @param {string} destDir
 * @param {{deep?: boolean}} [opts]
 */
export async function modelStatus(modelIdOrPin, destDir, { deep = true } = {}) {
  const pin = requirePin(modelIdOrPin);
  const dest = path.join(destDir, pin.file);
  const verdict = await inspectFile(dest, pin, { deep });
  const partBytes = fileBytes(`${dest}.part`);
  return {
    id: pin.id,
    file: pin.file,
    path: dest,
    installed: verdict.ok,
    verified: verdict.ok && verdict.hashed,
    kind: verdict.kind,
    message: verdict.message,
    downloadBytes: verdict.ok ? 0 : pin.bytes - (partBytes && partBytes < pin.bytes ? partBytes : 0),
    partialBytes: partBytes,
    needFreeBytes: requiredFreeBytes(pin),
    freeBytes: freeBytesFor(fs.existsSync(destDir) ? destDir : path.dirname(destDir)),
  };
}

function fmtBytes(n) {
  return `${Number(n).toLocaleString('en-US')} bytes (${human(n)})`;
}

/**
 * What the server SAYS it is about to send, as an absolute file length.
 *
 * On a 206 the `Content-Length` is the remaining bytes, so the resume offset has to be added back
 * before it can be compared with anything. Returns null when the server declines to say, which is
 * legal and is not an error — it only means this early check cannot run.
 * @param {Response} res
 * @param {number} from resume offset
 * @returns {number|null}
 */
export function declaredTotal(res, from) {
  const range = res.headers.get('content-range');
  if (range) {
    const m = /\/\s*(\d+)\s*$/.exec(range);
    if (m) return Number(m[1]);
  }
  const len = res.headers.get('content-length');
  if (len == null || len === '') return null;
  const n = Number(len);
  if (!Number.isFinite(n)) return null;
  return res.status === 206 ? n + from : n;
}
