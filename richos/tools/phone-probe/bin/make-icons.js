#!/usr/bin/env node
'use strict';

// Generate the probe's icons as PNGs, with no image library and no binary checked in that nobody
// can regenerate. `node bin/make-icons.js`.
//
// PNG is a container around zlib, which Node already has, so the whole encoder is about forty lines.
// The mark is a level meter — three rising bars in the app's gold on the app's dark ground — because
// that is literally what the probe is: a thing that measures whether the microphone works.
//
// Deterministic: running this twice produces byte-identical files, so the committed icons can be
// re-derived and diffed rather than trusted.

const zlib = require('node:zlib');
const fs = require('node:fs');
const path = require('node:path');

// From richos/app/ui/style.css.
const GROUND = [0x0c, 0x13, 0x22];
const GOLD = [0xc2, 0xa3, 0x5c];

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

// `pixels` is RGB, 3 bytes per pixel, row-major.
function encodePng(width, height, pixels) {
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
	const stride = width * 3;
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

// `maskable` keeps the mark inside the safe circle iOS and Android may crop to; `any` uses the
// full square. Drawing both from one function is what stops them drifting apart.
function draw(size, maskable) {
	const px = Buffer.alloc(size * size * 3);
	const set = (x, y, rgb) => {
		const at = (y * size + x) * 3;
		px[at] = rgb[0]; px[at + 1] = rgb[1]; px[at + 2] = rgb[2];
	};

	for (let y = 0; y < size; y++) for (let x = 0; x < size; x++) set(x, y, GROUND);

	// The safe zone for a maskable icon is the middle 80%; a full-bleed mark loses its ends when
	// the launcher crops to a circle.
	const inset = maskable ? size * 0.28 : size * 0.20;
	const area = size - inset * 2;

	// Three bars of rising height, like a level meter mid-speech.
	const bars = 3;
	const gap = area * 0.12;
	const barWidth = (area - gap * (bars - 1)) / bars;
	const heights = [0.45, 1.0, 0.68];

	for (let b = 0; b < bars; b++) {
		const left = Math.round(inset + b * (barWidth + gap));
		const right = Math.round(left + barWidth);
		const barHeight = area * heights[b];
		const bottom = Math.round(inset + area);
		const top = Math.round(bottom - barHeight);
		const radius = Math.max(1, Math.round(barWidth / 2));

		for (let y = top; y < bottom; y++) {
			for (let x = left; x < right; x++) {
				if (x < 0 || y < 0 || x >= size || y >= size) continue;
				// Round the two ends of each bar.
				const cx = Math.min(Math.max(x, left + radius), right - radius);
				const cyTop = top + radius;
				const cyBottom = bottom - radius;
				const cy = Math.min(Math.max(y, cyTop), cyBottom);
				const dx = x - cx;
				const dy = y - cy;
				if (dx * dx + dy * dy <= radius * radius) set(x, y, GOLD);
			}
		}
	}
	return px;
}

const outDir = path.join(__dirname, '..', 'public', 'icons');
fs.mkdirSync(outDir, { recursive: true });

const targets = [
	['icon-192.png', 192, false],
	['icon-512.png', 512, false],
	['icon-maskable-512.png', 512, true],
	// iOS uses this one for Add to Home Screen and applies its own rounded-rect mask, so it is the
	// non-maskable art at the size Apple asks for.
	['apple-touch-icon.png', 180, false]
];

for (const [name, size, maskable] of targets) {
	const png = encodePng(size, size, draw(size, maskable));
	fs.writeFileSync(path.join(outDir, name), png);
	process.stdout.write(`${name.padEnd(26)} ${size}x${size}  ${png.length} bytes\n`);
}
