#!/usr/bin/env node
'use strict';

// Generate the probe's icons as PNGs, with no image library and no binary checked in that nobody
// can regenerate. `node bin/make-icons.js`.
//
// The PNG encoder used to live in this file and now lives in `lib/png.js`, because the trust step's
// QR code needs the same forty lines and two copies of an image encoder in one tool is two things to
// get wrong. The move is byte-for-byte: the committed icons regenerate identically, which is the
// only acceptable proof that a refactor of an encoder changed nothing.
//
// The mark is a level meter — three rising bars in the app's gold on the app's dark ground — because
// that is literally what the probe is: a thing that measures whether the microphone works.
//
// Deterministic: running this twice produces byte-identical files, so the committed icons can be
// re-derived and diffed rather than trusted.

const fs = require('node:fs');
const path = require('node:path');
const { encodePng } = require('../lib/png.js');

// From richos/app/ui/style.css.
const GROUND = [0x0c, 0x13, 0x22];
const GOLD = [0xc2, 0xa3, 0x5c];

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
