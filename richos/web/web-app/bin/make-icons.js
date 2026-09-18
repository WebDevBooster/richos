#!/usr/bin/env node
'use strict';

// The Home Screen icon — the app's OWN icon, resized here rather than drawn again.
//
// `node bin/make-icons.js`, run from `richos/web/web-app`.
//
// WHY THIS EXISTS AT ALL rather than four committed PNGs nobody can re-derive: the icon he taps on
// his Home Screen is the RichOS icon, and it must stay the RichOS icon when that one changes. The
// source is `richos/app/icon-source/richos-icon-1024.png`, which is the same image the desktop app
// ships. This script decodes it, box-filters it down and re-encodes, with no image library and no
// dependency of any kind — Node's own zlib is all a PNG needs.
//
// DETERMINISTIC: running it twice produces byte-identical files, so the committed icons can be
// re-derived and diffed rather than trusted. `test/icons.test.js` re-derives them and fails if what
// is committed is not what this script produces from the source that is committed beside it.
//
// The maskable variant is the same image inset inside the app's own ground color, because a
// launcher may crop a maskable icon to a circle and an icon that bleeds to its edges loses its
// corners when it does.

const fs = require('node:fs');
const path = require('node:path');
const zlib = require('node:zlib');

// `richos/app/icon-source/` — three levels up from `richos/web/web-app/bin/`, and then across.
// It was two-up-and-one-across until 2026-09-18, when this app moved out of `richos/app/`.
const SOURCE = path.join(__dirname, '..', '..', '..', 'app', 'icon-source', 'richos-icon-1024.png');
const OUT_DIR = path.join(__dirname, '..', 'icons');

// `--ground` from richos/app/ui/style.css. The maskable icon's safe zone is the middle 80%, so the
// mark is inset by 10% on each side and the rest is the app's own dark ground.
const GROUND = [0x0c, 0x13, 0x22, 0xff];
const MASKABLE_INSET = 0.12;

// ---------------------------------------------------------------------------------------------
// Decode — 8-bit RGBA, non-interlaced, which is what the source is (asserted, never assumed)
// ---------------------------------------------------------------------------------------------

function decodePng(buffer) {
	if (buffer.slice(0, 8).toString('hex') !== '89504e470d0a1a0a') throw new Error('not a PNG');
	let at = 8;
	let header = null;
	const idat = [];
	while (at < buffer.length) {
		const length = buffer.readUInt32BE(at);
		const type = buffer.slice(at + 4, at + 8).toString('ascii');
		const data = buffer.slice(at + 8, at + 8 + length);
		if (type === 'IHDR') {
			header = {
				width: data.readUInt32BE(0),
				height: data.readUInt32BE(4),
				bitDepth: data[8],
				colorType: data[9],
				interlace: data[12]
			};
		} else if (type === 'IDAT') {
			idat.push(data);
		} else if (type === 'IEND') {
			break;
		}
		at += 12 + length;
	}
	if (!header) throw new Error('no IHDR');
	if (header.bitDepth !== 8 || header.colorType !== 6 || header.interlace !== 0) {
		throw new Error(`this decoder handles 8-bit RGBA, non-interlaced only; got bitDepth ${header.bitDepth}, colorType ${header.colorType}, interlace ${header.interlace}`);
	}

	const raw = zlib.inflateSync(Buffer.concat(idat));
	const bpp = 4;
	const stride = header.width * bpp;
	const out = Buffer.alloc(header.height * stride);

	// The five PNG filters, undone row by row. Nothing clever: this is the specification's own
	// arithmetic, written out, because the alternative is a dependency.
	for (let y = 0; y < header.height; y++) {
		const filter = raw[y * (stride + 1)];
		const line = raw.slice(y * (stride + 1) + 1, y * (stride + 1) + 1 + stride);
		const target = out.slice(y * stride, (y + 1) * stride);
		const prior = y > 0 ? out.slice((y - 1) * stride, y * stride) : null;
		for (let i = 0; i < stride; i++) {
			const a = i >= bpp ? target[i - bpp] : 0;
			const b = prior ? prior[i] : 0;
			const c = prior && i >= bpp ? prior[i - bpp] : 0;
			const x = line[i];
			let value;
			switch (filter) {
				case 0: value = x; break;
				case 1: value = x + a; break;
				case 2: value = x + b; break;
				case 3: value = x + ((a + b) >> 1); break;
				case 4: {
					const p = a + b - c;
					const pa = Math.abs(p - a);
					const pb = Math.abs(p - b);
					const pc = Math.abs(p - c);
					value = x + (pa <= pb && pa <= pc ? a : pb <= pc ? b : c);
					break;
				}
				default: throw new Error(`unknown PNG filter ${filter} on row ${y}`);
			}
			target[i] = value & 0xff;
		}
	}
	return { width: header.width, height: header.height, pixels: out };
}

// ---------------------------------------------------------------------------------------------
// Resize — a box filter, which is the right one for an integer-ish reduction of a flat mark
// ---------------------------------------------------------------------------------------------

function resize(image, size) {
	const out = Buffer.alloc(size * size * 4);
	const ratio = image.width / size;
	for (let y = 0; y < size; y++) {
		const y0 = Math.floor(y * ratio);
		const y1 = Math.max(y0 + 1, Math.floor((y + 1) * ratio));
		for (let x = 0; x < size; x++) {
			const x0 = Math.floor(x * ratio);
			const x1 = Math.max(x0 + 1, Math.floor((x + 1) * ratio));
			let r = 0; let g = 0; let b = 0; let a = 0; let n = 0;
			for (let sy = y0; sy < y1 && sy < image.height; sy++) {
				for (let sx = x0; sx < x1 && sx < image.width; sx++) {
					const at = (sy * image.width + sx) * 4;
					// Premultiplied, so a transparent edge does not drag its own color into the
					// average and leave a halo.
					const alpha = image.pixels[at + 3] / 255;
					r += image.pixels[at] * alpha;
					g += image.pixels[at + 1] * alpha;
					b += image.pixels[at + 2] * alpha;
					a += image.pixels[at + 3];
					n++;
				}
			}
			const at = (y * size + x) * 4;
			const alpha = n ? a / n : 0;
			const scale = alpha > 0 ? 255 / alpha : 0;
			out[at] = n ? Math.round((r / n) * scale) : 0;
			out[at + 1] = n ? Math.round((g / n) * scale) : 0;
			out[at + 2] = n ? Math.round((b / n) * scale) : 0;
			out[at + 3] = Math.round(alpha);
		}
	}
	return { width: size, height: size, pixels: out };
}

/// Flatten onto the app's ground, optionally inset. An icon with transparency is shown by iOS on
/// black; giving it the app's own ground instead is what makes it look like RichOS on the Home
/// Screen rather than like a cut-out.
function onGround(image, size, insetFraction) {
	const out = Buffer.alloc(size * size * 4);
	for (let i = 0; i < size * size; i++) {
		out[i * 4] = GROUND[0];
		out[i * 4 + 1] = GROUND[1];
		out[i * 4 + 2] = GROUND[2];
		out[i * 4 + 3] = GROUND[3];
	}
	const inner = Math.round(size * (1 - insetFraction * 2));
	const offset = Math.round((size - inner) / 2);
	const scaled = resize(image, inner);
	for (let y = 0; y < inner; y++) {
		for (let x = 0; x < inner; x++) {
			const from = (y * inner + x) * 4;
			const to = ((y + offset) * size + (x + offset)) * 4;
			const alpha = scaled.pixels[from + 3] / 255;
			out[to] = Math.round(scaled.pixels[from] * alpha + out[to] * (1 - alpha));
			out[to + 1] = Math.round(scaled.pixels[from + 1] * alpha + out[to + 1] * (1 - alpha));
			out[to + 2] = Math.round(scaled.pixels[from + 2] * alpha + out[to + 2] * (1 - alpha));
			out[to + 3] = 0xff;
		}
	}
	return { width: size, height: size, pixels: out };
}

// ---------------------------------------------------------------------------------------------
// Encode
// ---------------------------------------------------------------------------------------------

function chunk(type, data) {
	const out = Buffer.alloc(8 + data.length + 4);
	out.writeUInt32BE(data.length, 0);
	out.write(type, 4, 'ascii');
	data.copy(out, 8);
	out.writeUInt32BE(crc32(Buffer.concat([Buffer.from(type, 'ascii'), data])) >>> 0, 8 + data.length);
	return out;
}

const CRC_TABLE = (() => {
	const table = new Int32Array(256);
	for (let n = 0; n < 256; n++) {
		let c = n;
		for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
		table[n] = c;
	}
	return table;
})();

function crc32(buffer) {
	let c = 0xffffffff;
	for (let i = 0; i < buffer.length; i++) c = CRC_TABLE[(c ^ buffer[i]) & 0xff] ^ (c >>> 8);
	return c ^ 0xffffffff;
}

function encodePng(image) {
	const stride = image.width * 4;
	const raw = Buffer.alloc((stride + 1) * image.height);
	for (let y = 0; y < image.height; y++) {
		raw[y * (stride + 1)] = 0; // filter 0: none. Deterministic, and the image is already small.
		image.pixels.copy(raw, y * (stride + 1) + 1, y * stride, (y + 1) * stride);
	}
	const header = Buffer.alloc(13);
	header.writeUInt32BE(image.width, 0);
	header.writeUInt32BE(image.height, 4);
	header[8] = 8;   // bit depth
	header[9] = 6;   // RGBA
	header[10] = 0;  // deflate
	header[11] = 0;  // adaptive filtering
	header[12] = 0;  // no interlace
	return Buffer.concat([
		Buffer.from('89504e470d0a1a0a', 'hex'),
		chunk('IHDR', header),
		// Level 9 and nothing else: the same input must always give the same bytes.
		chunk('IDAT', zlib.deflateSync(raw, { level: 9 })),
		chunk('IEND', Buffer.alloc(0))
	]);
}

// ---------------------------------------------------------------------------------------------

function build() {
	const source = decodePng(fs.readFileSync(SOURCE));
	return [
		{ name: 'apple-touch-icon.png', bytes: encodePng(onGround(source, 180, 0)) },
		{ name: 'icon-192.png', bytes: encodePng(onGround(source, 192, 0)) },
		{ name: 'icon-512.png', bytes: encodePng(onGround(source, 512, 0)) },
		{ name: 'icon-maskable-512.png', bytes: encodePng(onGround(source, 512, MASKABLE_INSET)) }
	];
}

if (require.main === module) {
	fs.mkdirSync(OUT_DIR, { recursive: true });
	for (const icon of build()) {
		fs.writeFileSync(path.join(OUT_DIR, icon.name), icon.bytes);
		process.stdout.write(`${icon.name}  ${(icon.bytes.length / 1024).toFixed(1)} KB\n`);
	}
}

module.exports = { build, decodePng, encodePng, resize, onGround, SOURCE, OUT_DIR };
