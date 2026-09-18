'use strict';

// The QR encoder, checked against the standard rather than against itself.
//
// A wrong QR code does not throw and does not look wrong — it simply does not scan, and the person
// holding the phone concludes the tool is broken. So the two parts that can be silently wrong are
// checked against published values:
//
//   - the Reed-Solomon core, against the worked example in ISO/IEC 18004 Annex I
//   - the format information, against the standard's own table of the eight level-M patterns
//
// and the version table is checked by arithmetic against the standard's total-codeword counts, so a
// typo in it is a failing test rather than an unscannable code.
//
// The end-to-end proof is not here: test/qr-verify.js renders a PNG and decodes it with Apple's
// Vision framework, which is the decoder the iPhone camera actually uses.

const test = require('node:test');
const assert = require('node:assert');
const qr = require('../lib/qr.js');
const { encodePng } = require('../lib/png.js');

test('the version table agrees with the standard\'s total codeword counts', () => {
	// total = blocks * (data + error correction), for every row. This is what makes a mistyped
	// table entry impossible to miss.
	const expectedTotals = { 1: 26, 2: 44, 3: 70, 4: 100, 5: 134, 6: 172 };
	const expectedEc = { 1: 10, 2: 16, 3: 26, 4: 36, 5: 48, 6: 64 };
	for (const row of qr.VERSIONS) {
		assert.strictEqual(row.blocks * (row.dataPerBlock + row.ecPerBlock), row.total,
			`version ${row.version} does not add up`);
		assert.strictEqual(row.total, expectedTotals[row.version], `version ${row.version} total`);
		assert.strictEqual(row.blocks * row.ecPerBlock, expectedEc[row.version],
			`version ${row.version} error-correction codewords`);
	}
});

test('Reed-Solomon matches the worked example in ISO/IEC 18004 Annex I', () => {
	// Version 1-M, the numeric string "01234567", as the standard itself encodes it.
	const data = [0x10, 0x20, 0x0c, 0x56, 0x61, 0x80, 0xec, 0x11, 0xec, 0x11, 0xec, 0x11, 0xec, 0x11, 0xec, 0x11];
	const expected = [0xa5, 0x24, 0xd4, 0xc1, 0xed, 0x36, 0xc7, 0x87, 0x2c, 0x55];
	assert.deepStrictEqual([...qr.reedSolomon(data, 10)], expected);
});

test('the format information matches the standard\'s table for level M, all eight masks', () => {
	// ISO/IEC 18004 Table C.1. Level M is the two bits 00, which is the easiest thing in the file to
	// leave out by accident — and the code still renders, it just never scans.
	const published = [0x5412, 0x5125, 0x5e7c, 0x5b4b, 0x45f9, 0x40ce, 0x4f97, 0x4aa0];
	for (let mask = 0; mask < 8; mask++) {
		assert.strictEqual(qr.formatInformation(mask), published[mask],
			`mask ${mask}: got 0x${qr.formatInformation(mask).toString(16)}, the standard says 0x${published[mask].toString(16)}`);
	}
});

test('the smallest version that fits is chosen, and the boundaries are exact', () => {
	// Byte mode spends 12 bits on the mode and the character count for versions 1-9, so the capacity
	// is floor((dataCodewords * 8 - 12) / 8).
	const capacity = (v) => Math.floor((v.blocks * v.dataPerBlock * 8 - 12) / 8);
	for (const row of qr.VERSIONS) {
		const cap = capacity(row);
		assert.strictEqual(qr.pickVersion(cap).version, row.version, `${cap} bytes should pick version ${row.version}`);
		if (row.version > 1) {
			const previous = qr.VERSIONS[row.version - 2];
			assert.strictEqual(qr.pickVersion(capacity(previous) + 1).version, row.version);
		}
	}
	assert.strictEqual(qr.pickVersion(106).version, 6, 'version 6 at level M holds 106 bytes');
	assert.strictEqual(qr.pickVersion(107), null, 'anything longer has no version in this table');
});

test('a payload too long to encode throws instead of being truncated', () => {
	// Silently dropping the end of a URL would produce a code that scans perfectly and opens the
	// wrong page, which is worse than any error.
	assert.throws(() => qr.encode('x'.repeat(107)), /does not fit/);
});

test('the module matrix has the three finder patterns, the timing patterns and the dark module', () => {
	const { modules, size, version } = qr.encode('https://mm1.local:8788/');
	assert.strictEqual(version, 2);
	assert.strictEqual(size, 25); // 17 + 4 * 2

	// A finder pattern is a 7x7 ring with a 3x3 core. Checking the ring, the middle and the far
	// corner is enough to catch an off-by-one in placement.
	for (const [r0, c0] of [[0, 0], [0, size - 7], [size - 7, 0]]) {
		assert.strictEqual(modules[r0][c0], true, 'finder corner');
		assert.strictEqual(modules[r0 + 1][c0 + 1], false, 'the ring must have a light second ring');
		assert.strictEqual(modules[r0 + 3][c0 + 3], true, 'the middle of the finder');
		assert.strictEqual(modules[r0 + 6][c0 + 6], true, 'finder far corner');
	}

	// The timing patterns alternate along row 6 and column 6 between the finders.
	for (let i = 8; i < size - 8; i++) {
		assert.strictEqual(modules[6][i], i % 2 === 0, `row 6 at ${i}`);
		assert.strictEqual(modules[i][6], i % 2 === 0, `column 6 at ${i}`);
	}

	// The module that is always dark.
	assert.strictEqual(modules[size - 8][8], true, 'the dark module must be set');

	// Every module must have been decided — a null anywhere means the data walk missed a slot.
	for (let r = 0; r < size; r++) {
		for (let c = 0; c < size; c++) {
			assert.notStrictEqual(modules[r][c], null, `module ${r},${c} was never written`);
		}
	}
});

test('an alignment pattern appears from version 2 and not in version 1', () => {
	const v1 = qr.encode('short');
	assert.strictEqual(v1.version, 1);
	const v2 = qr.encode('https://mm1.local:8788/');
	// Version 2's only alignment pattern sits at (size-7, size-7): a 5x5 ring around one dark module.
	const at = v2.size - 7;
	assert.strictEqual(v2.modules[at][at], true, 'the middle of the alignment pattern');
	assert.strictEqual(v2.modules[at - 1][at], false, 'its inner ring is light');
	assert.strictEqual(v2.modules[at - 2][at], true, 'its outer ring is dark');
});

test('the mask is one of the eight and the penalty is real', () => {
	const chosen = qr.encode('https://mm1.local:8788/?k=0123456789abcdef0123456789abcdef');
	assert.ok(chosen.mask >= 0 && chosen.mask <= 7);
	assert.ok(Number.isFinite(chosen.penalty));
	assert.ok(chosen.penalty > 0, 'a real symbol always incurs some penalty');
});

test('the same payload always produces the same code', () => {
	// Determinism matters: an image served twice must be the same image, or a cached QR and a fresh
	// one could disagree about where the phone is being sent.
	const a = qr.toPng('https://mm1.local:8788/');
	const b = qr.toPng('https://mm1.local:8788/');
	assert.deepStrictEqual(a.png, b.png);
	assert.strictEqual(a.mask, b.mask);
});

test('the PNG is a real PNG, square, with the four-module quiet zone the standard requires', () => {
	const { png, size, pixelSize } = qr.toPng('https://mm1.local:8788/', { scale: 8 });
	assert.deepStrictEqual([...png.subarray(0, 8)], [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);
	// IHDR width and height, big-endian, at a fixed offset.
	assert.strictEqual(png.readUInt32BE(16), pixelSize);
	assert.strictEqual(png.readUInt32BE(20), pixelSize);
	assert.strictEqual(pixelSize, (size + 8) * 8, 'four light modules on every side');
	assert.strictEqual(png[24], 8, 'eight bits per channel');
	assert.strictEqual(png[25], 2, 'truecolor RGB');
});

test('the PNG encoder refuses a pixel buffer that is the wrong size', () => {
	// A silent mismatch here would produce an image that renders as noise.
	assert.throws(() => encodePng(4, 4, Buffer.alloc(10)), /expected 48 bytes/);
});

test('a URL with an access code still fits, with room to spare', () => {
	// The longest URL this probe can generate: an https origin, a .local name, a port, and a
	// 32-character code.
	const url = 'https://mm1.local:8788/?k=0123456789abcdef0123456789abcdef';
	assert.strictEqual(Buffer.byteLength(url), 58);
	const encoded = qr.encode(url);
	assert.ok(encoded.version <= 6, `version ${encoded.version} is past the table`);
	assert.strictEqual(encoded.version, 4);
});
