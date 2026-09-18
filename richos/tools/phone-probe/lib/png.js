'use strict';

// PNG, in about forty lines, because PNG is a container around zlib and Node already has zlib.
//
// This was inside `bin/make-icons.js` and is now shared, because the trust step's QR code needs the
// same encoder. Two copies of an image encoder in one tool is two things to get wrong.
//
// Deterministic: the same pixels always produce the same bytes, so the committed icons can be
// re-derived and diffed rather than trusted.

const zlib = require('node:zlib');

function crc32(buf) {
	let c = ~0;
	for (let i = 0; i < buf.length; i++) {
		c ^= buf[i];
		for (let k = 0; k < 8; k++) c = (c >>> 1) ^ (0xedb88320 & -(c & 1));
	}
	return ~c >>> 0;
}

function chunk(type, data) {
	const len = Buffer.alloc(4);
	len.writeUInt32BE(data.length, 0);
	const body = Buffer.concat([Buffer.from(type, 'ascii'), data]);
	const crc = Buffer.alloc(4);
	crc.writeUInt32BE(crc32(body), 0);
	return Buffer.concat([len, body, crc]);
}

/**
 * `pixels` is RGB, 3 bytes per pixel, row-major, length width*height*3.
 * @returns {Buffer} a complete PNG file
 */
function encodePng(width, height, pixels) {
	const stride = width * 3;
	if (pixels.length !== stride * height) {
		throw new Error(`png: expected ${stride * height} bytes of RGB for ${width}x${height}, got ${pixels.length}`);
	}

	const ihdr = Buffer.alloc(13);
	ihdr.writeUInt32BE(width, 0);
	ihdr.writeUInt32BE(height, 4);
	ihdr[8] = 8;  // bit depth
	ihdr[9] = 2;  // color type 2 = truecolor RGB
	ihdr[10] = 0; // deflate
	ihdr[11] = 0; // adaptive filtering
	ihdr[12] = 0; // no interlace

	// Every scanline is prefixed with its filter byte; 0 means "none", which compresses perfectly
	// well for flat art and keeps this readable.
	const raw = Buffer.alloc((stride + 1) * height);
	for (let y = 0; y < height; y++) {
		raw[y * (stride + 1)] = 0;
		pixels.copy(raw, y * (stride + 1) + 1, y * stride, (y + 1) * stride);
	}

	// Level 9 with a fixed strategy so the output is byte-identical between runs.
	const idat = zlib.deflateSync(raw, { level: 9 });

	return Buffer.concat([
		Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
		chunk('IHDR', ihdr),
		chunk('IDAT', idat),
		chunk('IEND', Buffer.alloc(0))
	]);
}

module.exports = { encodePng, crc32 };
