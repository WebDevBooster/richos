/**
 * RichOS local service — the model pin catalog.
 *
 * WHY THIS FILE EXISTS. Until today the only thing standing between the CEO and a hostile or
 * broken download was a byte count and a four-byte magic number. Both are trivially satisfiable
 * by anyone who can serve bytes — a hotel captive portal, a misconfigured proxy, a CDN serving a
 * stale object. The design brief's own words for that case: *"this is the case the current
 * size-and-magic check would let through, and it is not exotic — it is a hotel."*
 *
 * So every model RichOS may download carries a PINNED sha256, held in `model-pins.json` as
 * source, never fetched. This module is the only reader of that file inside the service; the
 * shell fetcher reads the same file directly and the test suite asserts the two agree.
 *
 * Nothing here does I/O beyond loading the pin file once. Verification lives in
 * `model-integrity.js`, fetching in `model-fetch.js` — the split is deliberate, so the rules can
 * be tested without a network and the network code has nothing to decide.
 */

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));

/** Absolute path to the pin file. Exported so the drift test and the CLI can name it. */
export const PIN_FILE = path.join(HERE, 'model-pins.json');

const RAW = JSON.parse(fs.readFileSync(PIN_FILE, 'utf8'));

/** Where pinned models are fetched from. One host, HTTPS, no mirrors (the design's §"No CDN of our own"). */
export const MODEL_BASE_URL = RAW.baseUrl;

/**
 * whisper.cpp's GGML magic: the uint32 0x67676d6c ("ggml") stored little-endian, so the first
 * four bytes on disk are `6c 6d 67 67`. Verified against real model files, not inferred from the
 * spelling. Kept even though the sha256 subsumes it — four bytes buy a far better sentence for
 * the "an HTML error page got saved as .bin" case than a hash mismatch ever could.
 */
export const GGML_MAGIC_HEX = RAW.ggmlMagicHex;

/** The date every pin in the table was last confirmed against its stated witnesses. */
export const PINS_VERIFIED_ON = RAW.verifiedOn;

/**
 * Every pinned model, in the order the table lists them (smallest first).
 * @typedef {{id: string, file: string, bytes: number, sha256: string,
 *            provenance: string[], note: string}} ModelPin
 * @type {ModelPin[]}
 */
export const MODEL_PINS = Object.freeze(
  RAW.models.map((m) =>
    Object.freeze({
      id: m.id,
      file: m.file,
      bytes: m.bytes,
      sha256: m.sha256.toLowerCase(),
      provenance: Object.freeze([...m.provenance]),
      note: m.note,
    }),
  ),
);

const BY_ID = new Map(MODEL_PINS.map((m) => [m.id, m]));
const BY_FILE = new Map(MODEL_PINS.map((m) => [m.file, m]));

/** Every pinned model id, for CLI listings and error messages. */
export function pinnedModelIds() {
  return MODEL_PINS.map((m) => m.id);
}

/**
 * The pin for a portable model id, or `null` if that model is not pinned.
 *
 * NULL IS NOT "FINE". An unpinned model is one we cannot verify, and every caller that fetches
 * must refuse rather than fall back to size-and-magic — that fallback is exactly the hole this
 * work closes. `requirePin` is the form to use on the fetch path.
 * @param {string} modelId
 * @returns {ModelPin|null}
 */
export function pinFor(modelId) {
  return BY_ID.get(String(modelId)) || null;
}

/** The pin for a filename (`ggml-small.en.bin`), or null. Lets a resolver check a file it found. */
export function pinForFile(fileName) {
  return BY_FILE.get(path.basename(String(fileName))) || null;
}

/**
 * The pin for a model id, or a throw that names the model and lists what IS pinned.
 * @param {string} modelId
 * @returns {ModelPin}
 */
export function requirePin(modelId) {
  const pin = pinFor(modelId);
  if (pin) return pin;
  throw new Error(
    `no pinned sha256 for model "${modelId}" — RichOS will not download a model it cannot verify. ` +
      `Pinned models: ${pinnedModelIds().join(', ')}. Add it to lib/model-pins.json with its ` +
      `provenance if it should be downloadable.`,
  );
}

/** The download URL for a pinned model. */
export function modelUrl(modelId) {
  return `${MODEL_BASE_URL}/${requirePin(modelId).file}`;
}

/**
 * How much free disk a fetch of this model should require before it starts.
 *
 * The 1.1 headroom factor is the design's, and the reason is timing rather than arithmetic:
 * finding out at 95% of 574 MB is the worst possible moment to learn the disk is full. The extra
 * 10% covers the `.part` file coexisting with filesystem overhead, not a second copy — the final
 * `rename()` is in-place.
 * @param {string} modelId
 * @returns {number} bytes
 */
export function requiredFreeBytes(modelId) {
  return Math.ceil(requirePin(modelId).bytes * 1.1);
}

/** Human-readable MB, one decimal — the unit every model figure in the docs uses. */
export function mb(bytes) {
  return (Number(bytes) / 1_000_000).toFixed(1);
}

/**
 * A one-line description of how much a pin is trusted, for the CLI and for review.
 * Single-witness pins are called out rather than presented as equal.
 * @param {ModelPin} pin
 */
export function provenanceLine(pin) {
  const names = {
    'x-linked-etag': "HuggingFace's x-linked-etag header",
    'ceo-disk': "shasum of the CEO's own copy",
    'wiki-record': 'a hash recorded in the wiki beforehand',
  };
  const listed = pin.provenance.map((p) => names[p] || p);
  if (listed.length === 1) return `${listed[0]} (single witness)`;
  return `${listed.slice(0, -1).join(', ')} and ${listed[listed.length - 1]} — ${listed.length} witnesses agree`;
}
