/**
 * RichOS local service — model integrity: what is wrong with these bytes, said in a sentence.
 *
 * THE POINT OF THIS MODULE IS THE DIAGNOSIS, NOT THE BOOLEAN. A fetcher that answers "failed"
 * sends the CEO to a support conversation; one that answers "that came back as a web page, which
 * is what hotel wifi does when it wants you to log in" sends him to the wifi login page. The
 * failure states below are the ones the design brief names as his ACTUAL first-run conditions —
 * hotel wifi, a plane, a flaky connection — plus the two an attacker or a broken CDN produces.
 *
 * Everything here except the four functions at the bottom marked I/O is PURE: it takes the size,
 * the first bytes and (optionally) the hash of a file and decides. That is what makes the failure
 * paths testable without a network, and it is why the network code in `model-fetch.js` contains
 * no judgment of its own.
 *
 * ORDER OF DIAGNOSIS IS DELIBERATE, and it is not "cheapest first":
 *   absent -> empty -> CONTENT -> size -> hash
 * Content beats size because a captive portal's login page that happens to be the wrong length
 * should be reported as a login page, not as a short download. "You are behind a wifi portal" is
 * actionable; "expected 487,614,201 bytes, got 3,104" is a puzzle.
 */

import fs from 'node:fs';
import crypto from 'node:crypto';
import { GGML_MAGIC_HEX, human } from './model-catalog.js';

/** How many leading bytes are enough to tell a model from a web page. */
export const SNIFF_BYTES = 1024;

/**
 * Every way a candidate model file can be wrong. Exported so callers can branch on a kind rather
 * than match on a message, and so the test suite can assert the set has not silently shrunk.
 */
export const FAILURE = Object.freeze({
  ABSENT: 'absent',
  EMPTY: 'empty',
  HTML_BODY: 'html-body',
  TEXT_BODY: 'text-body',
  COMPRESSED_BODY: 'compressed-body',
  NOT_GGML: 'not-ggml',
  SHORT: 'short',
  OVERSIZE: 'oversize',
  HASH_MISMATCH: 'hash-mismatch',
  NO_SPACE: 'no-space',
  UNPINNED: 'unpinned',
});

/**
 * What do these first bytes look like?
 *
 * @param {Buffer|Uint8Array|null|undefined} head first bytes of the file (>= 4 is enough for GGML)
 * @returns {'ggml'|'html'|'gzip'|'zip'|'text'|'binary'|'empty'}
 */
export function sniffBody(head) {
  if (!head || head.length === 0) return 'empty';
  const buf = Buffer.from(head);
  if (buf.length >= 4 && buf.subarray(0, 4).toString('hex') === GGML_MAGIC_HEX) return 'ggml';
  if (buf.length >= 2 && buf[0] === 0x1f && buf[1] === 0x8b) return 'gzip';
  if (buf.length >= 4 && buf.subarray(0, 2).toString('latin1') === 'PK') return 'zip';

  // Markup sniffing over the first KB. Captive portals are not tidy: some return a full
  // `<!DOCTYPE html>`, some a bare `<html>`, and some a naked `<meta http-equiv="refresh">`
  // redirect stub with no doctype at all. All three are the same event to the user.
  const text = buf.subarray(0, SNIFF_BYTES).toString('latin1').toLowerCase();
  if (/<!doctype\s+html|<html[\s>]|<head[\s>]|<body[\s>]|<meta\s|<title[\s>]|<script[\s>]/.test(text)) {
    return 'html';
  }
  // Printable-ASCII-dominant with no binary noise => somebody sent us a message, not a model.
  const sample = buf.subarray(0, Math.min(buf.length, SNIFF_BYTES));
  let printable = 0;
  for (const b of sample) {
    if (b === 0x09 || b === 0x0a || b === 0x0d || (b >= 0x20 && b <= 0x7e)) printable += 1;
  }
  if (printable / sample.length > 0.95) return 'text';
  return 'binary';
}

/**
 * Decide whether a candidate file is the model we pinned.
 *
 * `sha256` is optional so a cheap check (stat + 4 bytes) and a full check share one rule set. A
 * cheap check can only ever return ok:true meaning "nothing disqualifying was visible" — the
 * `hashed` field says which kind of answer this is, and no caller may install on the strength of
 * a `hashed:false` pass.
 *
 * @param {{exists?: boolean, bytes?: number, head?: Buffer|null, sha256?: string|null,
 *          pin: {id: string, file: string, bytes: number, sha256: string}}} input
 * @returns {{ok: boolean, hashed: boolean, kind?: string, have?: any, want?: any, detail?: string}}
 */
export function classify({ exists = true, bytes = 0, head = null, sha256 = null, pin }) {
  if (!pin) return { ok: false, hashed: false, kind: FAILURE.UNPINNED };
  if (!exists) return { ok: false, hashed: false, kind: FAILURE.ABSENT };
  if (bytes === 0) return { ok: false, hashed: false, kind: FAILURE.EMPTY };

  if (head && head.length > 0) {
    const shape = sniffBody(head);
    if (shape === 'html') {
      return { ok: false, hashed: false, kind: FAILURE.HTML_BODY, bytes, detail: firstLine(head) };
    }
    if (shape === 'text') {
      return { ok: false, hashed: false, kind: FAILURE.TEXT_BODY, bytes, detail: firstLine(head) };
    }
    if (shape === 'gzip' || shape === 'zip') {
      return { ok: false, hashed: false, kind: FAILURE.COMPRESSED_BODY, bytes, detail: shape };
    }
    if (shape !== 'ggml') {
      return {
        ok: false,
        hashed: false,
        kind: FAILURE.NOT_GGML,
        bytes,
        have: Buffer.from(head).subarray(0, 4).toString('hex'),
        want: GGML_MAGIC_HEX,
      };
    }
  }

  if (bytes < pin.bytes) return { ok: false, hashed: false, kind: FAILURE.SHORT, have: bytes, want: pin.bytes };
  if (bytes > pin.bytes) return { ok: false, hashed: false, kind: FAILURE.OVERSIZE, have: bytes, want: pin.bytes };

  if (sha256 == null) return { ok: true, hashed: false };
  if (String(sha256).toLowerCase() !== pin.sha256) {
    return { ok: false, hashed: true, kind: FAILURE.HASH_MISMATCH, have: String(sha256).toLowerCase(), want: pin.sha256 };
  }
  return { ok: true, hashed: true };
}

function firstLine(head) {
  return Buffer.from(head)
    .subarray(0, 200)
    .toString('latin1')
    .split(/\r?\n/)
    .map((s) => s.trim())
    .find((s) => s.length > 0) || '';
}

/**
 * The sentence. One per failure kind, naming what happened and what the person can do about it.
 * @param {{kind?: string, have?: any, want?: any, bytes?: number, detail?: string}} finding
 * @param {{file?: string, id?: string, resumable?: boolean, context?: 'download'|'disk'}} [ctx]
 * @returns {string}
 */
export function describe(finding, ctx = {}) {
  const file = ctx.file || 'the model file';
  switch (finding.kind) {
    case FAILURE.UNPINNED:
      return `${file} is not in RichOS's pin table, so there is no hash to check it against — refusing to install a model that cannot be verified.`;
    case FAILURE.ABSENT:
      return `${file} is not on disk — RichOS has no copy of this model to check.`;
    case FAILURE.EMPTY:
      return `${file} is empty — the download produced no bytes at all. That usually means the connection dropped before anything arrived.`;
    case FAILURE.HTML_BODY:
      return (
        `${file} came back as a web page, not a model — the response starts with HTML` +
        (finding.detail ? ` ("${truncate(finding.detail, 80)}")` : '') +
        `. That is what a hotel, airport or conference wifi looks like when it is intercepting the download to show you a login page. Sign in to the network, then try again. Nothing was installed.`
      );
    case FAILURE.TEXT_BODY:
      return (
        `${file} came back as plain text, not a model` +
        (finding.detail ? ` — the server said: "${truncate(finding.detail, 120)}"` : '') +
        `. That is an error message saved under a model's name. Nothing was installed.`
      );
    case FAILURE.COMPRESSED_BODY:
      return `${file} came back as a ${finding.detail} archive, not a whisper model. RichOS expects the raw .bin. Nothing was installed.`;
    case FAILURE.NOT_GGML:
      return `${file} is not a whisper model — its first four bytes are ${finding.have}, and every GGML model starts with ${finding.want}. Nothing was installed.`;
    case FAILURE.SHORT:
      // Three different situations produce a short file and they need three different next steps:
      // a file sitting on disk under a model's name, a partial we kept for a resume, and a partial
      // we could not keep. Saying "resume" about an installed file would be advice that goes
      // nowhere, which is how a good error message becomes a wrong one.
      if (ctx.context === 'disk') {
        return `${file} is only ${fmt(finding.have)} of the ${fmt(finding.want)} bytes a real model has (${pct(finding.have, finding.want)}) — it is a download that never finished, not a usable model. Delete it and fetch the model again.`;
      }
      return (
        `${file} is incomplete: ${fmt(finding.have)} of ${fmt(finding.want)} bytes arrived (${pct(finding.have, finding.want)}). ` +
        (ctx.resumable === false
          ? 'The partial file was discarded; the next attempt starts from the beginning.'
          : 'The partial download was kept, so the next attempt resumes from where it stopped rather than starting over.')
      );
    case FAILURE.OVERSIZE:
      return `${file} is larger than the model RichOS pinned: ${fmt(finding.have)} bytes where ${fmt(finding.want)} were expected. These are not the bytes we meant. Nothing was installed.`;
    case FAILURE.HASH_MISMATCH:
      return (
        `${file} is exactly the right size and starts like a real model, but its contents are not the bytes RichOS pinned. ` +
        `Expected sha256 ${short(finding.want)}, got ${short(finding.have)}. Something between HuggingFace and this machine changed the file. It has been deleted and nothing was installed.`
      );
    case FAILURE.NO_SPACE:
      return `Not enough free disk to download ${file}: it needs ${human(finding.want)} free (the model plus 10% headroom) and this disk has ${human(finding.have)}. Free up ${human(Math.max(0, finding.want - finding.have))} and try again — nothing was started.`;
    default:
      return `${file} verified.`;
  }
}

function truncate(s, n) {
  const t = String(s);
  return t.length > n ? `${t.slice(0, n - 1)}…` : t;
}
function short(h) {
  return `${String(h).slice(0, 12)}…`;
}
function fmt(n) {
  return Number(n).toLocaleString('en-US');
}
function pct(have, want) {
  if (!want) return '0%';
  const p = (Number(have) / Number(want)) * 100;
  return `${p < 1 ? p.toFixed(2) : p.toFixed(1)}%`;
}

/**
 * Is there room to do this at all? Checked BEFORE a byte is requested, because the alternative is
 * finding out at 95% of 1.6 GB.
 * @param {{freeBytes: number, needBytes: number}} input
 * @returns {{ok: boolean, kind?: string, have?: number, want?: number}}
 */
export function diskPreflight({ freeBytes, needBytes }) {
  if (!Number.isFinite(freeBytes)) return { ok: true }; // unknown free space is not a refusal
  if (freeBytes >= needBytes) return { ok: true };
  return { ok: false, kind: FAILURE.NO_SPACE, have: freeBytes, want: needBytes };
}

/**
 * What should the next attempt do about an existing `.part` file?
 *
 * RESUMABILITY IS REAL AND THIS IS WHERE IT IS DECIDED. A failed 1.5 GB download does NOT start
 * over: the partial file is kept and the next attempt sends `Range: bytes=<n>-`. Two cases refuse
 * to resume, both because resuming would be wrong rather than merely slow:
 *   - the partial is already >= the pinned size: it is not a prefix of the model, it is garbage
 *     with the model's name on it. Restart.
 *   - the partial does not begin with the GGML magic: whatever the last attempt saved, it was not
 *     the beginning of a model — resuming would append real bytes onto a captive portal's login
 *     page and hand us a file that is the right length and hashes to nothing. Restart.
 * A server that ignores `Range` and replies 200 is handled in the fetch layer, which restarts.
 *
 * @param {{partBytes: number, totalBytes: number, partHead?: Buffer|null}} input
 * @returns {{action: 'start'|'resume'|'restart', from: number, reason: string}}
 */
export function resumePlan({ partBytes, totalBytes, partHead = null }) {
  if (!partBytes || partBytes <= 0) return { action: 'start', from: 0, reason: 'no partial file' };
  if (partBytes >= totalBytes) {
    return { action: 'restart', from: 0, reason: 'the partial file is already at or past the pinned size' };
  }
  if (partHead && partHead.length >= 4 && sniffBody(partHead) !== 'ggml') {
    return {
      action: 'restart',
      from: 0,
      reason: 'the partial file does not start like a model, so it is not a prefix worth resuming',
    };
  }
  return { action: 'resume', from: partBytes, reason: `resuming from byte ${fmt(partBytes)}` };
}

// ---------------------------------------------------------------------------------------------
// I/O. Thin wrappers, no judgment — every decision above is pure and tested without a filesystem.
// ---------------------------------------------------------------------------------------------

/** I/O — the first `n` bytes of a file, or null if it cannot be read. */
export function readHead(filePath, n = SNIFF_BYTES) {
  let fd;
  try {
    fd = fs.openSync(filePath, 'r');
    const buf = Buffer.alloc(n);
    const read = fs.readSync(fd, buf, 0, n, 0);
    return buf.subarray(0, read);
  } catch {
    return null;
  } finally {
    if (fd !== undefined) fs.closeSync(fd);
  }
}

/**
 * I/O — sha256 of a whole file, streamed so a 1.6 GB model never lands in memory.
 *
 * The hash is taken over the COMPLETE file at the end rather than accumulated chunk by chunk
 * during the transfer, and that is a resumability requirement, not laziness: a resumed download
 * never sees the first half of its own bytes, so an incremental hash would be a hash of the
 * wrong thing. One extra read pass over the file costs seconds; being unable to verify a resumed
 * download would cost the feature.
 * @param {string} filePath
 * @returns {Promise<string>} lowercase hex
 */
export function hashFile(filePath) {
  return new Promise((resolve, reject) => {
    const h = crypto.createHash('sha256');
    const s = fs.createReadStream(filePath, { highWaterMark: 1 << 20 });
    s.on('error', reject);
    s.on('data', (c) => h.update(c));
    s.on('end', () => resolve(h.digest('hex')));
  });
}

/** I/O — bytes on disk, or 0 when the file is not there. */
export function fileBytes(filePath) {
  try {
    return fs.statSync(filePath).size;
  } catch {
    return 0;
  }
}

/**
 * I/O — the full verdict on a file that claims to be a pinned model.
 *
 * `deep` defaults to true because the whole point of this work is that the cheap check is not an
 * integrity check. Pass `deep: false` only where the caller genuinely wants the free check (a
 * resolver deciding whether to even offer a file), and never to decide an install.
 * @param {string} filePath
 * @param {{id: string, file: string, bytes: number, sha256: string}} pin
 * @param {{deep?: boolean}} [opts]
 * @returns {Promise<{ok: boolean, hashed: boolean, kind?: string, message: string}>}
 */
export async function inspectFile(filePath, pin, { deep = true } = {}) {
  const label = pin ? pin.file : filePath;
  if (!pin) {
    const f = { kind: FAILURE.UNPINNED };
    return { ...f, ok: false, hashed: false, message: describe(f, { file: label }) };
  }
  if (!fs.existsSync(filePath)) {
    const f = { kind: FAILURE.ABSENT };
    return { ...f, ok: false, hashed: false, message: describe(f, { file: label }) };
  }
  const bytes = fileBytes(filePath);
  const head = readHead(filePath);
  const cheap = classify({ exists: true, bytes, head, sha256: null, pin });
  if (!cheap.ok || !deep) {
    return { ...cheap, message: describe(cheap, { file: label, context: 'disk' }) };
  }
  const sha256 = await hashFile(filePath);
  const full = classify({ exists: true, bytes, head, sha256, pin });
  return { ...full, message: describe(full, { file: label, context: 'disk' }) };
}
