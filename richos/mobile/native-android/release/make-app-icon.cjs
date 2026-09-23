#!/usr/bin/env node
'use strict';

// The Android launcher icon (adaptive, with the themed-icon monochrome layer) and the Google Play
// store icon, derived from the RichOS icon rather than drawn again.
//
//   node release/make-app-icon.cjs           write the files listed in OUTPUTS below
//   node release/make-app-icon.cjs --check   exit 1 if what is committed is not what this produces
//
// NO INVENTED ARTWORK. The source is `richos/app/icon-source/richos-icon-1024.png`, the image the
// desktop app, the PWA and the iPhone app already ship (`richos/mobile/native-ios/Release/
// make-app-icon.cjs`). Its decoder, box resizer, compositor and encoder are the PWA's
// (`richos/web/web-app/bin/make-icons.js`, read, never modified), so the four icons cannot differ.
//
// THE THREE LAYERS OF AN ADAPTIVE ICON (Android 8+; this app's minSdk is 29, so it is always used):
//
// * Background: the app's ground, #0C1322, the same color `onGround` flattens the iPhone and PWA
//   icons onto. A launcher shows 72 of the layer's 108 dp and may move or scale the layers.
// * Foreground: the source image unchanged, on a transparent 108 dp layer, at the LARGEST size at
//   which every painted pixel of it lies inside the 66 dp circle Android guarantees is never masked.
//   That size is measured from the source's own pixels (its painted edge reaches RMAX px from the
//   center), not chosen by eye, so a circle, a squircle or a rounded square launcher all show the
//   whole RichOS body with none of its corners cut. Measured on the 2026-09-23 source: 510.66 px of
//   1024, so the 1024 canvas is drawn at 66.17 dp and the body at about 53 dp of the visible 72 dp.
// * Monochrome (Android 13+ themed icons): the system tints this layer in one color and uses only
//   its alpha. It is the R from the icon's own SVG, `richos/app/icon-source/richos-icon.svg`, path
//   data read out of it untouched, at exactly the place the foreground draws it. The arrow is NOT
//   painted in it: that path is the R with the arrow already cut out of its outline, which is how
//   the CEO's black-and-white master (`assets/logo-wordmark/RichOS-logo_v3.5_black-and-white.svg`,
//   richos-hq) draws the logo in one color. Painting the arrow in the same single tint would merge
//   it into the R and lose the mark.
//
// THE PLAY STORE ICON is 512 x 512, 32-bit PNG, full square: Google Play applies its own mask and
// shadow. It is the iPhone's App Store composition, `onGround(source, 512, 0)`, byte for byte the
// PWA's `icon-512.png`.
//
// CONTRAST (non-text indicator floor 3:1): the pixels are the source's, whose README measures the R
// body at 9.03:1 and the arrow at 4.11:1 against the ground beneath them, and the arrow at 3.67:1
// against the R. A launcher icon does not change with the system's light or dark theme; the themed
// monochrome icon is drawn by the system in colors it pairs for contrast.
//
// DETERMINISTIC: the same source gives the same bytes, so `--check` can compare against what is
// committed (native-android-app.test.sh runs it).

const fs = require('node:fs');
const path = require('node:path');

const HERE = path.join(__dirname, '..');
const RICHOS = path.join(HERE, '..', '..');
const icons = require(path.join(RICHOS, 'web', 'web-app', 'bin', 'make-icons.js'));
const SVG = path.join(RICHOS, 'app', 'icon-source', 'richos-icon.svg');
const RES = path.join(HERE, 'app', 'src', 'main', 'res');

const GROUND = '#FF0C1322';
const LAYER_DP = 108;
const SAFE_RADIUS_DP = 33;
/// Foreground layer size in px per density bucket (108 dp at 1x, 1.5x, 2x, 3x, 4x).
const DENSITIES = [
	['mdpi', 108],
	['hdpi', 162],
	['xhdpi', 216],
	['xxhdpi', 324],
	['xxxhdpi', 432],
];

/// The farthest distance, in source px from the canvas center, that any painted pixel reaches.
/// Each pixel is taken at its outer corner, so the measure can only overstate.
function paintedRadius(image) {
	const cx = image.width / 2;
	const cy = image.height / 2;
	let r = 0;
	for (let y = 0; y < image.height; y++) {
		for (let x = 0; x < image.width; x++) {
			if (image.pixels[(y * image.width + x) * 4 + 3] === 0) continue;
			const dx = Math.max(Math.abs(x - cx), Math.abs(x + 1 - cx));
			const dy = Math.max(Math.abs(y - cy), Math.abs(y + 1 - cy));
			r = Math.max(r, Math.hypot(dx, dy));
		}
	}
	if (r === 0) throw new Error('the icon source has no painted pixel');
	return r;
}

/// The source on a transparent square layer of `layerPx`, drawn at `canvasPx` and centered.
function onLayer(source, layerPx, canvasPx) {
	const out = Buffer.alloc(layerPx * layerPx * 4);
	const scaled = icons.resize(source, canvasPx);
	const offset = Math.floor((layerPx - canvasPx) / 2);
	for (let y = 0; y < canvasPx; y++) {
		scaled.pixels.copy(out, ((y + offset) * layerPx + offset) * 4, y * canvasPx * 4, (y + 1) * canvasPx * 4);
	}
	return { width: layerPx, height: layerPx, pixels: out };
}

/// The R's path data and the transform that places it on the 1024 canvas, read from the icon SVG.
function markFromSvg() {
	const svg = fs.readFileSync(SVG, 'utf8');
	const match = svg.match(/<g transform="translate\(([-\d.]+),([-\d.]+)\) scale\(([-\d.]+)\)"[^>]*><path d="([^"]+)" fill="url\(#ink\)"\/>/);
	if (!match) throw new Error(`${SVG}: the R (the path filled with url(#ink) inside the translate/scale group) was not found`);
	return { tx: Number(match[1]), ty: Number(match[2]), scale: Number(match[3]), d: match[4] };
}

function fixed(n) {
	return Number(n.toFixed(4)).toString();
}

function build() {
	const source = icons.decodePng(fs.readFileSync(icons.SOURCE));
	if (source.width !== 1024 || source.height !== 1024) throw new Error('the icon source must be 1024 x 1024');
	const rmax = paintedRadius(source);
	/// The 1024 canvas, in dp, at the largest size that keeps every painted pixel inside the safe circle.
	const canvasDp = (SAFE_RADIUS_DP * source.width) / rmax;
	const files = new Map();

	for (const [bucket, layerPx] of DENSITIES) {
		const canvasPx = Math.floor((layerPx * canvasDp) / LAYER_DP);
		files.set(`mipmap-${bucket}/ic_launcher_foreground.png`, icons.encodePng(onLayer(source, layerPx, canvasPx)));
	}

	const adaptive = [
		'<?xml version="1.0" encoding="utf-8"?>',
		'<!-- Generated by release/make-app-icon.cjs from richos/app/icon-source; do not edit. -->',
		'<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">',
		'    <background android:drawable="@drawable/ic_launcher_background" />',
		'    <foreground android:drawable="@mipmap/ic_launcher_foreground" />',
		'    <monochrome android:drawable="@drawable/ic_launcher_monochrome" />',
		'</adaptive-icon>',
		'',
	].join('\n');
	files.set('mipmap-anydpi/ic_launcher.xml', Buffer.from(adaptive));
	files.set('mipmap-anydpi/ic_launcher_round.xml', Buffer.from(adaptive));

	files.set('drawable/ic_launcher_background.xml', Buffer.from([
		'<?xml version="1.0" encoding="utf-8"?>',
		'<!-- Generated by release/make-app-icon.cjs: the app ground the iPhone and PWA icons sit on. -->',
		`<color xmlns:android="http://schemas.android.com/apk/res/android" android:color="${GROUND}" />`,
		'',
	].join('\n')));

	// The foreground draws the 1024 canvas at canvasDp, centered on the 108 dp layer; the R sits on
	// that canvas at translate(tx, ty) scale(s). One group: p' = scale * p + translate.
	const mark = markFromSvg();
	const k = canvasDp / source.width;
	const offset = (LAYER_DP - canvasDp) / 2;
	files.set('drawable/ic_launcher_monochrome.xml', Buffer.from([
		'<?xml version="1.0" encoding="utf-8"?>',
		'<!-- Generated by release/make-app-icon.cjs; do not edit. The R from richos/app/icon-source/',
		'     richos-icon.svg, path data untouched, placed where the foreground draws it. The arrow is',
		'     cut out of the R path itself, as in the black-and-white master logo. -->',
		'<vector xmlns:android="http://schemas.android.com/apk/res/android"',
		`    android:width="${LAYER_DP}dp"`,
		`    android:height="${LAYER_DP}dp"`,
		`    android:viewportWidth="${LAYER_DP}"`,
		`    android:viewportHeight="${LAYER_DP}">`,
		'    <group',
		`        android:translateX="${fixed(offset + k * mark.tx)}"`,
		`        android:translateY="${fixed(offset + k * mark.ty)}"`,
		`        android:scaleX="${fixed(k * mark.scale)}"`,
		`        android:scaleY="${fixed(k * mark.scale)}">`,
		'        <path',
		'            android:fillColor="#FFFFFFFF"',
		`            android:pathData="${mark.d}" />`,
		'    </group>',
		'</vector>',
		'',
	].join('\n')));

	return { files, store: icons.encodePng(icons.onGround(source, 512, 0)), rmax, canvasDp };
}

const STORE = path.join(HERE, 'release', 'play-store-icon-512.png');

function main() {
	const { files, store, rmax, canvasDp } = build();
	const summary = `painted radius ${rmax.toFixed(2)} px of 1024; canvas ${canvasDp.toFixed(2)} dp of ${LAYER_DP}`;
	if (process.argv.includes('--check')) {
		const stale = [];
		for (const [name, bytes] of files) {
			const at = path.join(RES, name);
			if (!fs.existsSync(at) || !fs.readFileSync(at).equals(bytes)) stale.push(name);
		}
		if (!fs.existsSync(STORE) || !fs.readFileSync(STORE).equals(store)) stale.push('release/play-store-icon-512.png');
		// Every mipmap directory holds only what this script writes: a hand-added launcher icon
		// would win over the generated one on some density and never be checked.
		const extra = [];
		for (const dir of fs.existsSync(RES) ? fs.readdirSync(RES) : []) {
			if (!dir.startsWith('mipmap')) continue;
			for (const name of fs.readdirSync(path.join(RES, dir))) {
				if (!files.has(`${dir}/${name}`)) extra.push(`${dir}/${name}`);
			}
		}
		if (stale.length || extra.length) {
			process.stderr.write(`app icon is stale: ${[...stale, ...extra.map((n) => `${n} (not generated)`)].join(', ')}; run node release/make-app-icon.cjs\n`);
			process.exit(1);
		}
		process.stdout.write(`app icon: ${files.size} launcher files and the Play icon match the source (${summary})\n`);
		return;
	}
	for (const [name, bytes] of files) {
		const at = path.join(RES, name);
		fs.mkdirSync(path.dirname(at), { recursive: true });
		fs.writeFileSync(at, bytes);
		process.stdout.write(`${name}  ${(bytes.length / 1024).toFixed(1)} KB\n`);
	}
	fs.writeFileSync(STORE, store);
	process.stdout.write(`release/play-store-icon-512.png  ${(store.length / 1024).toFixed(1)} KB\n${summary}\n`);
}

if (require.main === module) main();

module.exports = { build, paintedRadius, DENSITIES, RES, STORE };
