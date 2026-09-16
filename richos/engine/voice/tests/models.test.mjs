import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { test, testAsync, group, tmp } from './support/harness.mjs';
import { GGML, fakeModel, pinOf, CAPTIVE_PORTAL, PORTAL_STUB } from './support/models.mjs';
import { MODEL_PINS, pinFor, requirePin, validatePin, modelUrl, requiredFreeBytes, provenanceLine, isSingleWitness, human } from '../provisioning/model-catalog.js';
import { FAILURE, sniffBody, classify, describe, diskPreflight, resumePlan, hashFile, inspectFile } from '../provisioning/model-integrity.js';

group('model integrity — a pinned sha256, verified before the file is ever used');

// WHY THIS GROUP EXISTS. Until 2026-08-31 the model fetcher checked a byte count and four bytes of
// GGML magic. Both are trivially satisfiable by anyone who can serve bytes, so a hotel captive
// portal's login page padded to 574,041,195 bytes would have installed as the Accurate dictation
// model. These tests are the proof that it no longer can — and every one was run RED once against
// deliberately broken source, because a check nobody has watched fail is not a check.

test('every pin carries a well-formed sha256, a real byte count and a named provenance', () => {
  assert.ok(MODEL_PINS.length >= 6, 'the pin table lost entries');
  for (const pin of MODEL_PINS) {
    assert.match(pin.sha256, /^[0-9a-f]{64}$/, `${pin.id}: sha256 must be 64 lowercase hex`);
    assert.ok(Number.isInteger(pin.bytes) && pin.bytes > 1_000_000, `${pin.id}: implausible byte count`);
    assert.match(pin.file, /^ggml-.+\.bin$/, `${pin.id}: filename must match the resolver's convention`);
    assert.ok(pin.provenance.length >= 1, `${pin.id}: a pin with no stated provenance is a magic number`);
  }
});

test('no two pins share an id or a filename — one name, one set of bytes', () => {
  assert.equal(new Set(MODEL_PINS.map((m) => m.id)).size, MODEL_PINS.length);
  assert.equal(new Set(MODEL_PINS.map((m) => m.file)).size, MODEL_PINS.length);
});

test('a single-witness pin is labelled as one rather than presented as equal to the rest', () => {
  // The honest weakness of the table: a hash taken only from the host that serves the file checks
  // corruption and a stale CDN object, NOT that host. Which pins are in that position is allowed
  // to change; that the code can still tell, and says so where a reader will see it, is not.
  for (const pin of MODEL_PINS) {
    assert.equal(isSingleWitness(pin), pin.provenance.length < 2, pin.id);
    if (isSingleWitness(pin)) {
      assert.match(provenanceLine(pin), /SINGLE WITNESS/, `${pin.id} must say so in the line a human reads`);
      assert.ok(pin.witness.length > 20, `${pin.id}: a single-witness pin must explain itself in the table`);
    }
  }
});

test('an unpinned model is refused by name, and the refusal lists what IS pinned', () => {
  assert.equal(pinFor('no-such-model'), null);
  assert.throws(
    () => requirePin('no-such-model'),
    (err) =>
      /no pinned sha256 for model "no-such-model"/.test(err.message) &&
      /will not download a model it cannot verify/.test(err.message) &&
      err.message.includes('large-v3-turbo'),
  );
});

test('a pin that could not actually pin anything down is rejected before it is trusted', () => {
  // The manifest seam (payload architecture §6) will hand this path pins we did not write. "The
  // manifest said so" is worth something only if the manifest said something well-formed.
  assert.throws(() => validatePin({ id: 'x', file: 'ggml-x.bin', bytes: 10 }), /sha256 must be 64 hex/);
  assert.throws(() => validatePin({ id: 'x', file: 'x.bin', bytes: 10, sha256: 'a'.repeat(64) }), /ggml-<id>\.bin/);
  assert.throws(() => validatePin({ id: 'x', file: 'ggml-x.bin', bytes: 0, sha256: 'a'.repeat(64) }), /positive integer/);
  assert.throws(() => validatePin(null), /not a usable model pin/);
  const good = validatePin({ id: 'x', file: 'ggml-x.bin', bytes: 10, sha256: 'A'.repeat(64) });
  assert.equal(good.sha256, 'a'.repeat(64), 'a digest is normalised, not rejected, for its case');
});

test('models are fetched over HTTPS from one host — a hash is not a licence for plaintext', () => {
  for (const pin of MODEL_PINS) {
    const url = modelUrl(pin.id);
    assert.ok(url.startsWith('https://huggingface.co/'), `${pin.id}: ${url}`);
    assert.ok(url.endsWith(`/${pin.file}`));
  }
});

test('the disk requirement is the model plus 10% headroom, and is checked before anything starts', () => {
  const pin = pinFor('small.en');
  assert.equal(requiredFreeBytes('small.en'), Math.ceil(pin.bytes * 1.1));
  const refusal = diskPreflight({ freeBytes: pin.bytes, needBytes: requiredFreeBytes('small.en') });
  assert.equal(refusal.ok, false, 'exactly the model size is NOT enough — the headroom is the point');
  assert.equal(refusal.kind, FAILURE.NO_SPACE);
  assert.match(describe(refusal, { file: pin.file }), /Free up .* and try again/);
  assert.ok(diskPreflight({ freeBytes: Infinity, needBytes: 1 }).ok, 'unknown free space is not a refusal');
});

test('sniffBody tells a model from a web page, an archive, a message, and nothing at all', () => {
  assert.equal(sniffBody(fakeModel()), 'ggml');
  assert.equal(sniffBody(CAPTIVE_PORTAL), 'html');
  assert.equal(sniffBody(PORTAL_STUB), 'html', 'a portal stub has no doctype and is still a portal');
  assert.equal(sniffBody(Buffer.from([0x1f, 0x8b, 0x08, 0x00])), 'gzip');
  assert.equal(sniffBody(Buffer.from('PKrest')), 'zip');
  assert.equal(sniffBody(Buffer.from('Internal Server Error: upstream timed out\n')), 'text');
  assert.equal(sniffBody(Buffer.alloc(0)), 'empty');
  assert.equal(sniffBody(Buffer.from([0xde, 0xad, 0xbe, 0xef, 0x00, 0x01])), 'binary');
});

test('content is diagnosed BEFORE size — a login page is a login page, not a short download', () => {
  // "You are behind a wifi portal" is an instruction. "expected 487,614,201 bytes, got 3,104" is a
  // puzzle. The order of the checks is what decides which of those the CEO gets.
  const pin = pinFor('small.en');
  const finding = classify({ bytes: CAPTIVE_PORTAL.length, head: CAPTIVE_PORTAL, pin });
  assert.equal(finding.kind, FAILURE.HTML_BODY);
  const sentence = describe(finding, { file: pin.file });
  assert.match(sentence, /came back as a web page/);
  assert.match(sentence, /hotel, airport or conference wifi/);
  assert.match(sentence, /Nothing was installed/);
});

test('the case size-and-magic could never see: right size, right magic, wrong bytes', () => {
  // This is the whole reason for the work. The old fetcher installed this file.
  const pin = pinFor('small.en');
  const head = fakeModel('impostor');
  const old = classify({ bytes: pin.bytes, head, sha256: null, pin });
  assert.equal(old.ok, true, 'size and magic alone still say yes — which is exactly the problem');
  assert.equal(old.hashed, false, 'and the answer is marked as one nobody hashed');
  const now = classify({ bytes: pin.bytes, head, sha256: 'ab'.repeat(32), pin });
  assert.equal(now.ok, false);
  assert.equal(now.kind, FAILURE.HASH_MISMATCH);
  assert.match(describe(now, { file: pin.file }), /exactly the right size and starts like a real model/);
});

test('a cheap pass is never dressed up as a verified one', () => {
  const pin = pinFor('small.en');
  assert.deepEqual(classify({ bytes: pin.bytes, head: fakeModel(), sha256: null, pin }), { ok: true, hashed: false });
  assert.deepEqual(classify({ bytes: pin.bytes, head: fakeModel(), sha256: pin.sha256, pin }), { ok: true, hashed: true });
  assert.equal(
    classify({ bytes: pin.bytes, head: fakeModel(), sha256: pin.sha256.toUpperCase(), pin }).ok,
    true,
    'a digest is compared case-insensitively — an uppercase hash is the same hash',
  );
});

test('every failure kind has its own sentence, and none of them is a generic error', () => {
  const pin = pinFor('small.en');
  const seen = new Map();
  for (const kind of Object.values(FAILURE)) {
    const sentence = describe({ kind, have: 10, want: 100, detail: 'detail' }, { file: pin.file });
    assert.ok(sentence.length > 40, `${kind}: too short to say anything`);
    assert.ok(sentence.includes(pin.file) || kind === FAILURE.NO_SPACE, `${kind}: does not name the file`);
    assert.notEqual(sentence, `${pin.file} verified.`, `${kind} fell through to the default branch`);
    assert.ok(!seen.has(sentence), `${kind} shares its sentence with ${seen.get(sentence)}`);
    seen.set(sentence, kind);
  }
});

test('a short file on disk is told to be deleted; a short download is told it will resume', () => {
  // The same failure in two situations needs two next steps. Telling somebody to "resume" a file
  // that is sitting installed in their model directory is advice that goes nowhere.
  const onDisk = describe({ kind: FAILURE.SHORT, have: 5000, want: 1_624_555_275 }, { file: 'm.bin', context: 'disk' });
  assert.match(onDisk, /download that never finished/);
  assert.match(onDisk, /Delete it and fetch the model again/);
  const midFlight = describe({ kind: FAILURE.SHORT, have: 5000, want: 1_624_555_275 }, { file: 'm.bin' });
  assert.match(midFlight, /resumes from where it stopped/);
  assert.doesNotMatch(midFlight, /Delete it/);
});

test('resumePlan resumes a real prefix and refuses to resume onto anything else', () => {
  const total = 4096;
  assert.equal(resumePlan({ partBytes: 0, totalBytes: total }).action, 'start');
  const ok = resumePlan({ partBytes: 2000, totalBytes: total, partHead: fakeModel() });
  assert.equal(ok.action, 'resume');
  assert.equal(ok.from, 2000, 'a resume starts at the length of what we already have');
  assert.equal(resumePlan({ partBytes: total, totalBytes: total, partHead: fakeModel() }).action, 'restart');
  assert.equal(resumePlan({ partBytes: total + 1, totalBytes: total, partHead: fakeModel() }).action, 'restart');
  // THE ONE THAT MATTERS. Resuming onto a captive portal's login page appends real model bytes to
  // HTML and hands back a file of exactly the right length that hashes to nothing anybody meant.
  const portal = resumePlan({ partBytes: 200, totalBytes: total, partHead: CAPTIVE_PORTAL });
  assert.equal(portal.action, 'restart');
  assert.match(portal.reason, /does not start like a model/);
});

testAsync('hashFile streams, and agrees with a one-shot hash over the whole file', async () => {
  const dir = tmp();
  try {
    const body = fakeModel('stream', 3 << 20); // 3 MB — several stream chunks, not one buffer
    const p = path.join(dir, 'm.bin');
    fs.writeFileSync(p, body);
    assert.equal(await hashFile(p), crypto.createHash('sha256').update(body).digest('hex'));
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

testAsync('inspectFile hashes what is on disk and says, in a sentence, what is wrong with it', async () => {
  const dir = tmp();
  try {
    const body = fakeModel('inspect');
    const pin = pinOf(body);
    const p = path.join(dir, pin.file);
    assert.match((await inspectFile(p, pin)).message, /is not on disk/);
    fs.writeFileSync(p, body);
    const good = await inspectFile(p, pin);
    assert.equal(good.ok, true);
    assert.equal(good.hashed, true, 'a deep inspect must actually have hashed the file');
    fs.writeFileSync(p, Buffer.concat([GGML, Buffer.alloc(body.length - 4, 0x42)]));
    const bad = await inspectFile(p, pin);
    assert.equal(bad.kind, FAILURE.HASH_MISMATCH);
    const cheap = await inspectFile(p, pin, { deep: false });
    assert.equal(cheap.ok, true, 'the cheap check cannot see this, which is why it is not the guarantee');
    assert.equal(cheap.hashed, false);
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

// ---------------------------------------------------------------------------------------
