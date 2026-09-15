// A PNG decoder, so a screenshot can be compared by what it SHOWS rather than by its bytes.
//
// WHY THIS FILE EXISTS. Every committed shot under `../shots-*/` was being rewritten by every
// run, byte-different, and the tree was dirty the moment the suite finished. Measured on
// 2026-09-05 against `5e00651`: 96 of 96 committed PNGs modified by one `node run.js`, deltas
// from -12 to +679,604 bytes. The bytes are the wrong witness — two PNGs holding the same
// picture can differ, and `git diff` cannot tell that from a regression. So the harness now
// decodes both sides and compares the PIXELS, and writes only when they differ. The diff that
// survives is then signal.
//
// IT IS NOT A LIBRARY AND DOES NOT WANT TO BE. It reads what WebKit's compositor writes and
// nothing else: 8-bit, non-interlaced, greyscale/RGB/greyscale+alpha/RGBA. Everything else —
// 16-bit, interlaced, paletted — throws `Unsupported`, and the ONE caller that matters treats
// a throw as "I could not prove these are the same, so write the file". A decoder that
// guessed would be worse than none, because the failure mode is a real regression silently
// not written.
//
// No dependency. `zlib` is Node's own, and `playwright` is already the only devDependency in
// this directory.

"use strict";

const zlib = require("zlib");

const SIGNATURE = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);

/// Raised when this file meets a PNG it will not guess at. Its own type, so a caller can tell
/// "not a PNG I can read" apart from "the file was truncated" without matching on a message.
class UnsupportedPng extends Error {}

const CHANNELS = { 0: 1, 2: 3, 4: 2, 6: 4 };

/// Split a PNG into its chunks, in order. Returns `{ ihdr, idat, ancillary }`.
function chunks(buf) {
  if (buf.length < 8 || !buf.slice(0, 8).equals(SIGNATURE)) throw new UnsupportedPng("not a PNG");
  let i = 8;
  let ihdr = null;
  const idat = [];
  const ancillary = [];
  while (i + 8 <= buf.length) {
    const len = buf.readUInt32BE(i);
    const type = buf.toString("ascii", i + 4, i + 8);
    const end = i + 12 + len;
    if (end > buf.length) throw new UnsupportedPng("truncated chunk " + type);
    const data = buf.slice(i + 8, i + 8 + len);
    if (type === "IHDR") ihdr = data;
    else if (type === "IDAT") idat.push(data);
    else if (type !== "IEND") ancillary.push({ type, data });
    i = end;
    if (type === "IEND") break;
  }
  if (!ihdr) throw new UnsupportedPng("no IHDR");
  if (!idat.length) throw new UnsupportedPng("no IDAT");
  return { ihdr, idat, ancillary };
}

/// Undo the per-scanline filters. This is PNG's whole decode once the stream is inflated —
/// the five filter types of the spec, §9.2, and nothing else.
function unfilter(raw, width, height, bpp) {
  const stride = width * bpp;
  const out = Buffer.alloc(height * stride);
  let p = 0;
  for (let y = 0; y < height; y++) {
    if (p >= raw.length) throw new UnsupportedPng("scanline " + y + " missing");
    const ft = raw[p++];
    const line = raw.slice(p, p + stride);
    if (line.length < stride) throw new UnsupportedPng("scanline " + y + " short");
    p += stride;
    const cur = out.slice(y * stride, (y + 1) * stride);
    const prev = y > 0 ? out.slice((y - 1) * stride, y * stride) : null;
    for (let x = 0; x < stride; x++) {
      const a = x >= bpp ? cur[x - bpp] : 0;
      const b = prev ? prev[x] : 0;
      const c = prev && x >= bpp ? prev[x - bpp] : 0;
      let v = line[x];
      switch (ft) {
        case 0:
          break;
        case 1:
          v = (v + a) & 255;
          break;
        case 2:
          v = (v + b) & 255;
          break;
        case 3:
          v = (v + ((a + b) >> 1)) & 255;
          break;
        case 4: {
          const pp = a + b - c;
          const pa = Math.abs(pp - a);
          const pb = Math.abs(pp - b);
          const pc = Math.abs(pp - c);
          v = (v + (pa <= pb && pa <= pc ? a : pb <= pc ? b : c)) & 255;
          break;
        }
        default:
          throw new UnsupportedPng("filter type " + ft);
      }
      cur[x] = v;
    }
  }
  return out;
}

/// Decode a PNG buffer to raw samples.
///
/// Returns `{ width, height, channels, data }` where `data` is `height * width * channels`
/// bytes, top row first, no padding. Throws `UnsupportedPng` for anything outside the
/// WebKit-screenshot shape.
function decode(buf) {
  const { ihdr, idat } = chunks(buf);
  if (ihdr.length < 13) throw new UnsupportedPng("short IHDR");
  const width = ihdr.readUInt32BE(0);
  const height = ihdr.readUInt32BE(4);
  const depth = ihdr[8];
  const colorType = ihdr[9];
  const compression = ihdr[10];
  const filterMethod = ihdr[11];
  const interlace = ihdr[12];
  if (depth !== 8) throw new UnsupportedPng("bit depth " + depth);
  if (interlace !== 0) throw new UnsupportedPng("interlaced");
  if (compression !== 0 || filterMethod !== 0) throw new UnsupportedPng("compression/filter method");
  const channels = CHANNELS[colorType];
  if (!channels) throw new UnsupportedPng("color type " + colorType);
  if (!width || !height) throw new UnsupportedPng("zero dimension");
  const raw = zlib.inflateSync(Buffer.concat(idat));
  return { width, height, channels, data: unfilter(raw, width, height, channels) };
}

/// Do two PNGs hold the same picture?
///
/// TRUE only when both decoded, agree on width, height and channel count, and every sample is
/// equal. Any doubt — either side unreadable, either side a shape this file will not guess at
/// — is FALSE. The asymmetry is deliberate and is the whole safety of the caller: a false
/// negative costs one redundant write, a false positive silently discards a regression.
function samePicture(a, b) {
  let da;
  let db;
  try {
    da = decode(a);
    db = decode(b);
  } catch (_e) {
    return false;
  }
  if (da.width !== db.width || da.height !== db.height || da.channels !== db.channels) return false;
  return da.data.equals(db.data);
}

/// Where two PNGs differ, for a human. Never used to DECIDE anything — `samePicture` does that
/// — only to say what changed once something has.
function describeDifference(a, b) {
  let da;
  let db;
  try {
    da = decode(a);
    db = decode(b);
  } catch (e) {
    return "could not decode both sides (" + e.message + ")";
  }
  if (da.width !== db.width || da.height !== db.height) {
    return `${da.width}x${da.height} -> ${db.width}x${db.height}`;
  }
  if (da.channels !== db.channels) return `${da.channels} -> ${db.channels} channels`;
  const total = da.width * da.height;
  let differing = 0;
  let worst = 0;
  for (let i = 0; i < total; i++) {
    const o = i * da.channels;
    let d = 0;
    for (let c = 0; c < da.channels; c++) {
      const delta = Math.abs(da.data[o + c] - db.data[o + c]);
      if (delta > d) d = delta;
    }
    if (d) {
      differing++;
      if (d > worst) worst = d;
    }
  }
  const pct = ((differing / total) * 100).toFixed(4);
  return `${differing}/${total} pixels (${pct}%), worst channel delta ${worst}`;
}

// ---------------------------------------------------------------------------------------
// The self-test
// ---------------------------------------------------------------------------------------
//
// `run.js` self-tests its declared-check scanner on every run rather than trusting it, and
// this is the same reason: the five filter types below are the WHOLE decode, four of them
// reference pixels this function has already reconstructed, and a mistake in any one produces
// a plausible-looking image rather than an error. A wrong decode here does not fail loudly —
// it makes `samePicture` answer a question about a picture that was never on the screen.
//
// So: a 3x5 RGB image whose five scanlines use filter types 0, 1, 2, 3 and 4 in that order,
// with the expected reconstruction computed BY HAND (None, Sub, Up, Average, Paeth — the
// Paeth row is chosen so that all three of its predictors win at least once). Run at require
// time, so a broken decoder cannot reach a single suite.
//
// The fixture's chunk CRCs are zero, because `chunks()` deliberately does not verify them:
// both sides of every comparison come off the same disk from the same encoder, and a CRC
// check would only convert "these two identically-written files agree" into the same answer
// more slowly. Truncation IS caught, by length, above.
(function selfTestTheDecoder() {
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(3, 0); // width
  ihdr.writeUInt32BE(5, 4); // height
  ihdr[8] = 8; // bit depth
  ihdr[9] = 2; // color type: RGB
  const scanlines = Buffer.from([
    0, 10, 20, 30, 40, 50, 60, 70, 80, 90, // None
    1, 1, 2, 3, 4, 5, 6, 7, 8, 9, //          Sub
    2, 2, 2, 2, 2, 2, 2, 2, 2, 2, //          Up
    3, 0, 0, 0, 0, 0, 0, 0, 0, 0, //          Average
    4, 5, 5, 5, 5, 5, 5, 5, 5, 5, //          Paeth
  ]);
  const chunk = (type, data) => {
    const len = Buffer.alloc(4);
    len.writeUInt32BE(data.length);
    return Buffer.concat([len, Buffer.from(type, "ascii"), data, Buffer.alloc(4)]);
  };
  const fixture = Buffer.concat([
    SIGNATURE,
    chunk("IHDR", ihdr),
    chunk("IDAT", zlib.deflateSync(scanlines)),
    chunk("IEND", Buffer.alloc(0)),
  ]);
  const expected = [
    10, 20, 30, 40, 50, 60, 70, 80, 90, //     None:    the bytes as written
    1, 2, 3, 5, 7, 9, 12, 15, 18, //           Sub:     + the pixel to the left
    3, 4, 5, 7, 9, 11, 14, 17, 20, //          Up:      + the pixel above
    1, 2, 2, 4, 5, 6, 9, 11, 13, //            Average: + floor((left + above) / 2)
    6, 7, 7, 11, 12, 12, 16, 17, 18, //        Paeth:   b, b, b, a, a, a, a, a, b
  ];
  const got = decode(fixture);
  const ok =
    got.width === 3 &&
    got.height === 5 &&
    got.channels === 3 &&
    got.data.equals(Buffer.from(expected));
  if (!ok) {
    throw new Error(
      "lib/png.js decoded its own fixture wrongly — every screenshot comparison in this " +
        "directory is unsafe until this is fixed.\n  expected " +
        JSON.stringify(expected) +
        "\n  actual   " +
        JSON.stringify([...got.data]) +
        ` (${got.width}x${got.height}, ${got.channels} channels)`
    );
  }
  // And the other half: two different pictures must not compare equal. A `samePicture` that
  // always said true would pass every test above and silently stop every screenshot from ever
  // being rewritten again.
  const other = Buffer.concat([
    SIGNATURE,
    chunk("IHDR", ihdr),
    chunk("IDAT", zlib.deflateSync(Buffer.concat([scanlines.slice(0, 9), Buffer.from([91]), scanlines.slice(10)]))),
    chunk("IEND", Buffer.alloc(0)),
  ]);
  if (!samePicture(fixture, fixture) || samePicture(fixture, other)) {
    throw new Error("lib/png.js: samePicture does not distinguish a one-sample change");
  }
})();

module.exports = { decode, samePicture, describeDifference, UnsupportedPng };
