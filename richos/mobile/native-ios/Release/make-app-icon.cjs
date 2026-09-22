#!/usr/bin/env node
'use strict';

// The iPhone app icon, at every size the asset catalog lists and at 1024 px for the App Store,
// resized from the RichOS icon rather than drawn again.
//
//   node Release/make-app-icon.cjs           write App/Platform/Assets.xcassets/AppIcon.appiconset
//   node Release/make-app-icon.cjs --check   exit 1 if what is committed is not what this produces
//
// NO INVENTED ARTWORK. The source is `richos/app/icon-source/richos-icon-1024.png`, the desktop
// app's own icon, whose README says what it is made of: the R mark from
// `richos-hq assets/logo-wordmark/RichOS-logo_v3.5_black-and-white.svg`, path data untouched, in the
// ruled Sovereign colors (ceo-decisions §14). The composition is the one the preserved iPhone app
// and the PWA already put on the Home Screen: that image flattened onto the app's own ground,
// `onGround(source, size, 0)` in `richos/web/web-app/bin/make-icons.js` (read, never modified; its
// decoder, resizer and compositor are reused so the three phone icons cannot differ).
//
// WHAT IS DIFFERENT, AND WHY: App Store Connect refuses an app icon with an alpha channel (upload
// error ITMS-90717), so these PNGs are 8-bit RGB (color type 2), not RGBA. Every pixel is already
// opaque after flattening, so dropping the channel changes no pixel.
//
// DETERMINISTIC: the same source gives the same bytes, so `--check` can compare against what is
// committed (the suite runs it).

const fs = require('node:fs');
const path = require('node:path');
const zlib = require('node:zlib');

const HERE = path.join(__dirname, '..');
const PWA = path.join(HERE, '..', '..', 'web', 'web-app', 'bin', 'make-icons.js');
const icons = require(PWA);
const OUT = path.join(HERE, 'App', 'Platform', 'Assets.xcassets');
const SET = path.join(OUT, 'AppIcon.appiconset');

/// iPhone only (TARGETED_DEVICE_FAMILY 1): notification, settings, Spotlight, Home Screen, and
/// the App Store's 1024. Every entry names its file; none is left for Xcode to guess.
const SLOTS = [
	{ size: '20x20', scale: '2x', px: 40 },
	{ size: '20x20', scale: '3x', px: 60 },
	{ size: '29x29', scale: '2x', px: 58 },
	{ size: '29x29', scale: '3x', px: 87 },
	{ size: '40x40', scale: '2x', px: 80 },
	{ size: '40x40', scale: '3x', px: 120 },
	{ size: '60x60', scale: '2x', px: 120 },
	{ size: '60x60', scale: '3x', px: 180 },
	{ size: '1024x1024', scale: '1x', px: 1024, idiom: 'ios-marketing' },
];

function crc32(buffer) {
	let c = 0xffffffff;
	for (let i = 0; i < buffer.length; i++) {
		c ^= buffer[i];
		for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
	}
	return (c ^ 0xffffffff) >>> 0;
}

function chunk(type, data) {
	const out = Buffer.alloc(12 + data.length);
	out.writeUInt32BE(data.length, 0);
	out.write(type, 4, 'ascii');
	data.copy(out, 8);
	out.writeUInt32BE(crc32(Buffer.concat([Buffer.from(type, 'ascii'), data])), 8 + data.length);
	return out;
}

/// RGBA pixels (all opaque) to an 8-bit RGB PNG, filter 0, deflate level 9: fixed bytes.
function encodeRGB(image) {
	const stride = image.width * 3;
	const raw = Buffer.alloc((stride + 1) * image.height);
	for (let y = 0; y < image.height; y++) {
		raw[y * (stride + 1)] = 0;
		for (let x = 0; x < image.width; x++) {
			const from = (y * image.width + x) * 4;
			if (image.pixels[from + 3] !== 0xff) throw new Error(`pixel ${x},${y} is not opaque`);
			const to = y * (stride + 1) + 1 + x * 3;
			raw[to] = image.pixels[from];
			raw[to + 1] = image.pixels[from + 1];
			raw[to + 2] = image.pixels[from + 2];
		}
	}
	const header = Buffer.alloc(13);
	header.writeUInt32BE(image.width, 0);
	header.writeUInt32BE(image.height, 4);
	header[8] = 8; // bit depth
	header[9] = 2; // truecolor, no alpha
	return Buffer.concat([
		Buffer.from('89504e470d0a1a0a', 'hex'),
		chunk('IHDR', header),
		chunk('IDAT', zlib.deflateSync(raw, { level: 9 })),
		chunk('IEND', Buffer.alloc(0)),
	]);
}

function fileName(slot) {
	return `AppIcon-${slot.px}.png`;
}

function build() {
	const source = icons.decodePng(fs.readFileSync(icons.SOURCE));
	const files = new Map();
	for (const slot of SLOTS) {
		if (!files.has(fileName(slot))) files.set(fileName(slot), encodeRGB(icons.onGround(source, slot.px, 0)));
	}
	const contents = {
		images: SLOTS.map((slot) => ({ filename: fileName(slot), idiom: slot.idiom || 'iphone', scale: slot.scale, size: slot.size })),
		info: { author: 'xcode', version: 1 },
	};
	files.set('Contents.json', Buffer.from(`${JSON.stringify(contents, null, 2)}\n`));
	return files;
}

const CATALOG = Buffer.from(`${JSON.stringify({ info: { author: 'xcode', version: 1 } }, null, 2)}\n`);

function main() {
	const files = build();
	if (process.argv.includes('--check')) {
		const stale = [];
		for (const [name, bytes] of files) {
			const at = path.join(SET, name);
			if (!fs.existsSync(at) || !fs.readFileSync(at).equals(bytes)) stale.push(name);
		}
		const extra = fs.existsSync(SET) ? fs.readdirSync(SET).filter((name) => !files.has(name)) : [];
		const catalog = path.join(OUT, 'Contents.json');
		if (!fs.existsSync(catalog) || !fs.readFileSync(catalog).equals(CATALOG)) stale.push('../Contents.json');
		if (stale.length || extra.length) {
			process.stderr.write(`app icon is stale: ${[...stale, ...extra.map((n) => `${n} (not generated)`)].join(', ')}; run node Release/make-app-icon.cjs\n`);
			process.exit(1);
		}
		process.stdout.write(`app icon: ${files.size - 1} PNGs match the source\n`);
		return;
	}
	fs.mkdirSync(SET, { recursive: true });
	fs.writeFileSync(path.join(OUT, 'Contents.json'), CATALOG);
	for (const [name, bytes] of files) {
		fs.writeFileSync(path.join(SET, name), bytes);
		process.stdout.write(`${name}  ${(bytes.length / 1024).toFixed(1)} KB\n`);
	}
}

if (require.main === module) main();

module.exports = { build, encodeRGB, SLOTS, SET };
