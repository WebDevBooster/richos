'use strict';

// The Home Screen icon. `node --test "test/*.test.js"`.
//
// A committed binary nobody can re-derive is a binary that drifts from the thing it is supposed to
// be a copy of. These four PNGs are the desktop app's own icon, resized — so this suite re-derives
// them from the same source and fails if what is committed is not what the generator produces. If
// the app's icon changes, `node bin/make-icons.js` is the whole of the fix and this test is what
// says it was not forgotten.
//
// It also asserts the two things the manifest promises about them, because a manifest that declares
// a 512-pixel maskable icon and ships a 192-pixel one is a manifest iOS quietly ignores.

const test = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');

const icons = require('../bin/make-icons.js');

const DIR = path.join(__dirname, '..', 'icons');
const MANIFEST = JSON.parse(fs.readFileSync(path.join(__dirname, '..', 'manifest.webmanifest'), 'utf8'));

test('the committed icons are exactly what the generator produces from the committed source', () => {
	const built = icons.build();
	for (const icon of built) {
		const onDisk = fs.readFileSync(path.join(DIR, icon.name));
		assert.ok(onDisk.equals(icon.bytes),
			`${icon.name} on disk differs from what bin/make-icons.js produces — run it, or say why the difference is right`);
	}
	assert.strictEqual(built.length, 4);
});

test('the generator is deterministic, which is what makes the check above meaningful', () => {
	const first = icons.build();
	const second = icons.build();
	first.forEach((icon, i) => assert.ok(icon.bytes.equals(second[i].bytes), `${icon.name} is not deterministic`));
});

test('each icon is a real PNG of the size the manifest claims', () => {
	const expected = { 'apple-touch-icon.png': 180, 'icon-192.png': 192, 'icon-512.png': 512, 'icon-maskable-512.png': 512 };
	for (const [name, size] of Object.entries(expected)) {
		const bytes = fs.readFileSync(path.join(DIR, name));
		assert.strictEqual(bytes.slice(0, 8).toString('hex'), '89504e470d0a1a0a', `${name} is not a PNG`);
		assert.strictEqual(bytes.readUInt32BE(16), size, `${name} is not ${size} pixels wide`);
		assert.strictEqual(bytes.readUInt32BE(20), size, `${name} is not ${size} pixels tall`);
	}
});

test('the manifest declares what iOS needs, and points at files that exist', () => {
	// Without `standalone` there is no push at all on iOS — plan §3.1, and it is the first thing to
	// check when push stops working.
	assert.strictEqual(MANIFEST.display, 'standalone');
	assert.strictEqual(MANIFEST.scope, '/');
	assert.strictEqual(MANIFEST.start_url, '/');
	assert.strictEqual(MANIFEST.lang, 'en-US');
	assert.ok(MANIFEST.icons.some((i) => i.purpose === 'maskable'), 'no maskable icon is declared');
	for (const icon of MANIFEST.icons) {
		const file = path.join(__dirname, '..', icon.src.replace(/^\//, ''));
		assert.ok(fs.existsSync(file), `the manifest points at ${icon.src}, which is not there`);
		const bytes = fs.readFileSync(file);
		const declared = Number(icon.sizes.split('x')[0]);
		assert.strictEqual(bytes.readUInt32BE(16), declared, `${icon.src} is declared ${icon.sizes} and is not`);
	}
});

test('the icon decoder refuses a format it cannot actually read, instead of producing mush', () => {
	// The source happens to be 8-bit RGBA today. If it is ever replaced with a palette or a 16-bit
	// image, this must stop rather than emit a silently wrong icon.
	const paletted = Buffer.concat([
		Buffer.from('89504e470d0a1a0a', 'hex'),
		(() => {
			const header = Buffer.alloc(13);
			header.writeUInt32BE(8, 0); header.writeUInt32BE(8, 4);
			header[8] = 8; header[9] = 3; // colorType 3 = palette
			const out = Buffer.alloc(8 + 13 + 4);
			out.writeUInt32BE(13, 0); out.write('IHDR', 4, 'ascii'); header.copy(out, 8);
			return out;
		})()
	]);
	assert.throws(() => icons.decodePng(paletted), /8-bit RGBA/);
});
