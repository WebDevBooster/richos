'use strict';

// A QR code, from scratch, in byte mode.
//
// WHY. The trust step (check 0) has to get an HTTPS URL containing a `.local` name, a port and an
// access code onto the CEO's iPhone. Typing `https://mm1.local:8788/?k=<32 hex characters>` into
// Safari with a thumb is a guaranteed typo, and a typo there presents as "the probe is broken".
// A QR code he points the camera at removes the whole class.
//
// WHY NOT A PACKAGE. Same reason `lib/webpush.js` implements RFC 8291 by hand: this repository is
// published and the artifact is something the CEO runs on his own machine, so every dependency is a
// supply-chain surface on that, and `package.json` declares zero dependencies on purpose.
//
// SCOPE, deliberately narrow. Byte mode, error-correction level M, versions 1 to 6 — up to 106
// bytes, which is more than any URL this probe can generate. Restricting to version 6 and below
// removes two whole sub-systems from this file: the version-information block (only present from
// version 7) and the mixed-size RS block tables (every version below 7 at level M has equal-sized
// blocks). Anything longer throws, loudly, rather than guessing.
//
// Specification: ISO/IEC 18004. The error-correction structure below is arithmetic-checked against
// the standard's own total-codeword counts by test/qr.test.js, and the Reed-Solomon core is checked
// against the worked example in the standard's Annex I. The whole encoder is then checked
// end-to-end by decoding a rendered PNG with Apple's Vision framework — the same decoder the
// iPhone camera uses — in test/qr-verify.js.

const { encodePng } = require('./png.js');

// ---------------------------------------------------------------------------
// The version table, level M only
// ---------------------------------------------------------------------------
// `total` is every codeword in the symbol; `blocks` is how many RS blocks; `dataPerBlock` and
// `ecPerBlock` are the split within one block. The test asserts
// blocks * (dataPerBlock + ecPerBlock) === total for every row, which is what makes a typo here a
// failing test rather than an unscannable code.

const VERSIONS = [
	{ version: 1, total: 26, blocks: 1, dataPerBlock: 16, ecPerBlock: 10 },
	{ version: 2, total: 44, blocks: 1, dataPerBlock: 28, ecPerBlock: 16 },
	{ version: 3, total: 70, blocks: 1, dataPerBlock: 44, ecPerBlock: 26 },
	{ version: 4, total: 100, blocks: 2, dataPerBlock: 32, ecPerBlock: 18 },
	{ version: 5, total: 134, blocks: 2, dataPerBlock: 43, ecPerBlock: 24 },
	{ version: 6, total: 172, blocks: 4, dataPerBlock: 27, ecPerBlock: 16 }
];

// Level M's two bits in the format information. L=01, M=00, Q=11, H=10 — M is zero, which is easy
// to leave out by accident and produces a code every scanner rejects.
const EC_LEVEL_M = 0;

const MODE_BYTE = 4; // the 4-bit mode indicator for 8-bit byte mode

// ---------------------------------------------------------------------------
// GF(256)
// ---------------------------------------------------------------------------
// The field QR uses: primitive polynomial x^8 + x^4 + x^3 + x^2 + 1 (0x11d), generator 2.

const EXP = new Uint8Array(256);
const LOG = new Uint8Array(256);
(() => {
	let x = 1;
	for (let i = 0; i < 255; i++) {
		EXP[i] = x;
		LOG[x] = i;
		x <<= 1;
		if (x & 0x100) x ^= 0x11d;
	}
	EXP[255] = EXP[0];
})();

function gfMul(a, b) {
	if (a === 0 || b === 0) return 0;
	return EXP[(LOG[a] + LOG[b]) % 255];
}

// The generator polynomial for `degree` error-correction codewords: (x - a^0)(x - a^1)...
function generatorPoly(degree) {
	let poly = [1];
	for (let i = 0; i < degree; i++) {
		const next = new Array(poly.length + 1).fill(0);
		for (let j = 0; j < poly.length; j++) {
			next[j] ^= gfMul(poly[j], 1);
			next[j + 1] ^= gfMul(poly[j], EXP[i]);
		}
		poly = next;
	}
	return poly;
}

/** The `ecCount` error-correction codewords for one block of data codewords. */
function reedSolomon(data, ecCount) {
	const gen = generatorPoly(ecCount);
	const remainder = new Uint8Array(ecCount);
	for (const byte of data) {
		const factor = byte ^ remainder[0];
		remainder.copyWithin(0, 1);
		remainder[ecCount - 1] = 0;
		if (factor !== 0) {
			for (let i = 0; i < ecCount; i++) {
				remainder[i] ^= gfMul(gen[i + 1], factor);
			}
		}
	}
	return remainder;
}

// ---------------------------------------------------------------------------
// Bits
// ---------------------------------------------------------------------------

class BitBuffer {
	constructor() { this.bits = []; }
	push(value, length) {
		for (let i = length - 1; i >= 0; i--) this.bits.push((value >>> i) & 1);
	}
	get length() { return this.bits.length; }
	toBytes() {
		const out = new Uint8Array(Math.ceil(this.bits.length / 8));
		this.bits.forEach((bit, i) => { if (bit) out[i >> 3] |= 0x80 >> (i % 8); });
		return out;
	}
}

// ---------------------------------------------------------------------------
// Data codewords
// ---------------------------------------------------------------------------

function pickVersion(byteLength) {
	for (const v of VERSIONS) {
		const codewords = v.blocks * v.dataPerBlock;
		// 4 bits of mode + 8 bits of character count for versions 1-9.
		const capacityBytes = Math.floor((codewords * 8 - 12) / 8);
		if (byteLength <= capacityBytes) return v;
	}
	return null;
}

function dataCodewords(bytes, spec) {
	const buffer = new BitBuffer();
	buffer.push(MODE_BYTE, 4);
	buffer.push(bytes.length, 8); // character count, 8 bits in byte mode for versions 1-9
	for (const b of bytes) buffer.push(b, 8);

	const capacityBits = spec.blocks * spec.dataPerBlock * 8;
	if (buffer.length > capacityBits) throw new Error('qr: internal error — the payload overran the version chosen for it');

	// Terminator: up to four zero bits, fewer if there is not room.
	buffer.push(0, Math.min(4, capacityBits - buffer.length));
	// Pad to a byte boundary, then the standard's alternating pad bytes.
	while (buffer.length % 8 !== 0) buffer.push(0, 1);
	const bytesOut = Array.from(buffer.toBytes());
	const PAD = [0xec, 0x11];
	let p = 0;
	while (bytesOut.length < spec.blocks * spec.dataPerBlock) bytesOut.push(PAD[p++ % 2]);
	return bytesOut;
}

// Interleave: codeword 1 of every block, then codeword 2 of every block, and so on; then the same
// for the error-correction codewords. Every block is the same size below version 7 at level M, so
// this needs no group handling.
function interleave(bytes, spec) {
	const blocks = [];
	for (let b = 0; b < spec.blocks; b++) {
		const data = bytes.slice(b * spec.dataPerBlock, (b + 1) * spec.dataPerBlock);
		blocks.push({ data, ec: reedSolomon(data, spec.ecPerBlock) });
	}
	const out = [];
	for (let i = 0; i < spec.dataPerBlock; i++) for (const block of blocks) out.push(block.data[i]);
	for (let i = 0; i < spec.ecPerBlock; i++) for (const block of blocks) out.push(block.ec[i]);
	if (out.length !== spec.total) throw new Error(`qr: interleaved ${out.length} codewords, the symbol holds ${spec.total}`);
	return Uint8Array.from(out);
}

// ---------------------------------------------------------------------------
// The module matrix
// ---------------------------------------------------------------------------

const MASKS = [
	(i, j) => (i + j) % 2 === 0,
	(i, j) => i % 2 === 0,
	(i, j) => j % 3 === 0,
	(i, j) => (i + j) % 3 === 0,
	(i, j) => (Math.floor(i / 2) + Math.floor(j / 3)) % 2 === 0,
	(i, j) => ((i * j) % 2) + ((i * j) % 3) === 0,
	(i, j) => (((i * j) % 2) + ((i * j) % 3)) % 2 === 0,
	(i, j) => (((i * j) % 3) + ((i + j) % 2)) % 2 === 0
];

function blankMatrix(size) {
	// null means "not yet decided", which is what the data walk looks for. A zero-filled matrix
	// would make every function module look like a free slot.
	return Array.from({ length: size }, () => new Array(size).fill(null));
}

function placeFinder(m, row, col) {
	const size = m.length;
	for (let r = -1; r <= 7; r++) {
		for (let c = -1; c <= 7; c++) {
			const y = row + r;
			const x = col + c;
			if (y < 0 || x < 0 || y >= size || x >= size) continue;
			const onRing = (r >= 0 && r <= 6 && (c === 0 || c === 6)) || (c >= 0 && c <= 6 && (r === 0 || r === 6));
			const inCore = r >= 2 && r <= 4 && c >= 2 && c <= 4;
			m[y][x] = onRing || inCore;
		}
	}
}

function placeAlignment(m, version) {
	if (version < 2) return; // version 1 has no alignment pattern
	const size = m.length;
	const coords = [6, size - 7];
	for (const row of coords) {
		for (const col of coords) {
			// The three that would land on a finder pattern are skipped.
			if (m[row][col] !== null) continue;
			for (let r = -2; r <= 2; r++) {
				for (let c = -2; c <= 2; c++) {
					const ring = Math.max(Math.abs(r), Math.abs(c));
					m[row + r][col + c] = ring !== 1;
				}
			}
		}
	}
}

function placeTiming(m) {
	const size = m.length;
	for (let i = 8; i < size - 8; i++) {
		const dark = i % 2 === 0;
		if (m[6][i] === null) m[6][i] = dark;
		if (m[i][6] === null) m[i][6] = dark;
	}
}

// BCH(15,5) with generator 0b10100110111, then the standard's 0x5412 mask. Without the final XOR a
// code with format bits of all zeros would be indistinguishable from unwritten modules.
function formatInformation(maskPattern) {
	const data = (EC_LEVEL_M << 3) | maskPattern;
	let d = data << 10;
	const G15 = 0b10100110111;
	const bitLength = (n) => { let len = 0; while (n !== 0) { len++; n >>>= 1; } return len; };
	while (bitLength(d) - bitLength(G15) >= 0) d ^= G15 << (bitLength(d) - bitLength(G15));
	return ((data << 10) | d) ^ 0b101010000010010;
}

function placeFormatInformation(m, maskPattern) {
	const size = m.length;
	const bits = formatInformation(maskPattern);
	for (let i = 0; i < 15; i++) {
		const bit = ((bits >> i) & 1) === 1;
		// The copy beside the top-left finder, running down column 8 and along row 8. Column 6 and
		// row 6 are the timing patterns and are stepped over.
		if (i < 6) m[i][8] = bit;
		else if (i < 8) m[i + 1][8] = bit;
		else m[size - 15 + i][8] = bit;

		if (i < 8) m[8][size - i - 1] = bit;
		else if (i < 9) m[8][15 - i] = bit;
		else m[8][14 - i] = bit;
	}
	// The one module that is always dark, immediately above the bottom-left format copy.
	m[size - 8][8] = true;
}

// The zigzag: two-module-wide columns from the right, alternating up and down, skipping column 6.
function placeData(m, codewords, maskPattern) {
	const size = m.length;
	let bitIndex = 7;
	let byteIndex = 0;
	let rowStep = -1;
	let row = size - 1;
	for (let col = size - 1; col > 0; col -= 2) {
		if (col === 6) col--;
		for (;;) {
			for (let c = 0; c < 2; c++) {
				if (m[row][col - c] !== null) continue;
				let dark = false;
				if (byteIndex < codewords.length) dark = ((codewords[byteIndex] >>> bitIndex) & 1) === 1;
				// The remainder bits past the last codeword stay light before masking, which is what
				// the standard says: they are not data, they are filler.
				if (MASKS[maskPattern](row, col - c)) dark = !dark;
				m[row][col - c] = dark;
				bitIndex--;
				if (bitIndex === -1) { byteIndex++; bitIndex = 7; }
			}
			row += rowStep;
			if (row < 0 || row >= size) { row -= rowStep; rowStep = -rowStep; break; }
		}
	}
}

// ---------------------------------------------------------------------------
// Mask selection
// ---------------------------------------------------------------------------
// The four penalty rules of ISO/IEC 18004 §8.8.2. Any mask produces a readable code most of the
// time; picking the lowest-penalty one is what keeps it readable on a phone held at an angle in
// poor light, which is the only condition this code will ever be read in.

function penalty(m) {
	const size = m.length;
	let score = 0;

	// N1 — runs of five or more modules of one shade, in rows and in columns.
	for (const transpose of [false, true]) {
		for (let a = 0; a < size; a++) {
			let runValue = null;
			let runLength = 0;
			for (let b = 0; b < size; b++) {
				const value = transpose ? m[b][a] : m[a][b];
				if (value === runValue) runLength++;
				else { if (runLength >= 5) score += 3 + (runLength - 5); runValue = value; runLength = 1; }
			}
			if (runLength >= 5) score += 3 + (runLength - 5);
		}
	}

	// N2 — every 2x2 block that is all dark or all light.
	for (let r = 0; r < size - 1; r++) {
		for (let c = 0; c < size - 1; c++) {
			const v = m[r][c];
			if (v === m[r][c + 1] && v === m[r + 1][c] && v === m[r + 1][c + 1]) score += 3;
		}
	}

	// N3 — the finder-lookalike 1:1:3:1:1 pattern with four light modules on either side, which is
	// what makes a scanner mistake data for a finder pattern.
	const P1 = [true, false, true, true, true, false, true, false, false, false, false];
	const P2 = [false, false, false, false, true, false, true, true, true, false, true];
	const matches = (get, at) => {
		let one = true;
		let two = true;
		for (let i = 0; i < 11; i++) {
			const v = get(at + i);
			if (v !== P1[i]) one = false;
			if (v !== P2[i]) two = false;
		}
		return (one ? 1 : 0) + (two ? 1 : 0);
	};
	for (let a = 0; a < size; a++) {
		for (let b = 0; b <= size - 11; b++) {
			score += 40 * matches((i) => m[a][i], b);
			score += 40 * matches((i) => m[i][a], b);
		}
	}

	// N4 — the overall balance of dark to light.
	let dark = 0;
	for (let r = 0; r < size; r++) for (let c = 0; c < size; c++) if (m[r][c]) dark++;
	const percent = (dark * 100) / (size * size);
	score += 10 * Math.floor(Math.abs(percent - 50) / 5);

	return score;
}

// ---------------------------------------------------------------------------
// The public surface
// ---------------------------------------------------------------------------

// A placeholder that is definitely not null, so `placeData` steps over these modules. Every one of
// them is overwritten by placeFormatInformation afterwards. Without this the data walk would write
// fifteen bits into the format area and then lose them, with no error anywhere.
function reserveFormatArea(m) {
	const size = m.length;
	for (let i = 0; i < 9; i++) {
		if (m[8][i] === null) m[8][i] = false;
		if (m[i][8] === null) m[i][8] = false;
	}
	for (let i = 0; i < 8; i++) {
		if (m[8][size - 1 - i] === null) m[8][size - 1 - i] = false;
		if (m[size - 1 - i][8] === null) m[size - 1 - i][8] = false;
	}
}

/**
 * @param {string} text the payload — a URL here, always
 * @returns {{version: number, size: number, mask: number, modules: boolean[][], penalty: number}}
 */
function encode(text) {
	const bytes = Buffer.from(text, 'utf8');
	const spec = pickVersion(bytes.length);
	if (!spec) {
		throw new Error(`qr: ${bytes.length} bytes does not fit in a version 1-6 level-M symbol (106 bytes is the ceiling). ` +
			'Shorten the URL or extend the version table — do not silently truncate.');
	}
	const codewords = interleave(dataCodewords(bytes, spec), spec);
	const size = 17 + 4 * spec.version;

	let best = null;
	for (let mask = 0; mask < 8; mask++) {
		const m = blankMatrix(size);
		placeFinder(m, 0, 0);
		placeFinder(m, 0, size - 7);
		placeFinder(m, size - 7, 0);
		placeAlignment(m, spec.version);
		placeTiming(m);
		reserveFormatArea(m);
		placeData(m, codewords, mask);
		placeFormatInformation(m, mask);
		const score = penalty(m);
		if (!best || score < best.penalty) best = { modules: m, mask, penalty: score };
	}

	return { version: spec.version, size, mask: best.mask, modules: best.modules, penalty: best.penalty };
}

/**
 * The code as a PNG: black modules on white, with the four-module quiet zone the standard requires.
 * Black on white is 21:1 — and the quiet zone is part of the code, not decoration. A code drawn
 * flush to a page background does not scan.
 */
function toPng(text, options = {}) {
	const scale = options.scale || 8;
	const quiet = options.quietZone === undefined ? 4 : options.quietZone;
	const { modules, size, version, mask } = encode(text);

	const pixelSize = (size + quiet * 2) * scale;
	const px = Buffer.alloc(pixelSize * pixelSize * 3, 0xff); // white
	for (let r = 0; r < size; r++) {
		for (let c = 0; c < size; c++) {
			if (!modules[r][c]) continue;
			for (let y = 0; y < scale; y++) {
				for (let x = 0; x < scale; x++) {
					const py = (r + quiet) * scale + y;
					const pxx = (c + quiet) * scale + x;
					const at = (py * pixelSize + pxx) * 3;
					px[at] = 0; px[at + 1] = 0; px[at + 2] = 0;
				}
			}
		}
	}
	return { png: encodePng(pixelSize, pixelSize, px), version, mask, size, pixelSize };
}

module.exports = { encode, toPng, reedSolomon, generatorPoly, formatInformation, pickVersion, dataCodewords, interleave, VERSIONS, BitBuffer };
