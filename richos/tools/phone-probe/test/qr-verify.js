#!/usr/bin/env node
'use strict';

// End-to-end verification of the QR encoder: render a PNG, then decode it with Apple's Vision
// framework and compare the payload to what went in.
//
// WHY THIS AND NOT A UNIT TEST. Every assertion in test/qr.test.js is about my own arithmetic
// agreeing with the standard's published numbers. None of them can tell you whether a phone camera
// can read the result — and "it renders but does not scan" is the only failure mode that matters,
// because it presents to the CEO as the tool being broken. Vision is the detector behind the iPhone
// camera's own QR scanning, so a payload that survives this round trip has been read by the thing
// that will actually read it.
//
// `swiftc` is NOT a dependency. If the developer tools are absent this says so and exits 0, the same
// way test/desktop-verify.js reports a missing Playwright instead of pretending.
//
// Every scratch file goes in one temp directory and is removed however this process ends, including
// on a signal — garbage is always cleaned up (ceo-decisions.md §54).

const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { execFileSync } = require('node:child_process');
const qr = require('../lib/qr.js');

const CASES = [
	// The two URLs this probe actually prints, plus the extremes of the table.
	'https://mm1.local:8788/',
	'http://mm1.local:8787/',
	'https://mm1.local:8788/?k=0123456789abcdef0123456789abcdef',
	'https://192.168.1.249:8788/?k=0123456789abcdef0123456789abcdef&from=push',
	'x', // version 1, the smallest symbol there is
	'y'.repeat(106) // version 6, the largest this encoder will make
];

let failures = 0;
function check(label, ok, detail) {
	process.stdout.write(`${ok ? 'PASS' : 'FAIL'}  ${label}${detail ? `\n        ${detail}` : ''}\n`);
	if (!ok) failures++;
}

const scratch = fs.mkdtempSync(path.join(os.tmpdir(), 'richos-qr-verify-'));
let cleaned = false;
const cleanup = () => {
	if (cleaned) return;
	cleaned = true;
	try { fs.rmSync(scratch, { recursive: true, force: true }); } catch { /* nothing else to do */ }
};
process.on('exit', cleanup);
for (const signal of ['SIGINT', 'SIGTERM']) process.on(signal, () => { cleanup(); process.exit(1); });

function haveSwift() {
	try {
		execFileSync('/usr/bin/xcrun', ['--find', 'swiftc'], { stdio: 'ignore' });
		return true;
	} catch {
		try { execFileSync('/usr/bin/which', ['swiftc'], { stdio: 'ignore' }); return true; } catch { return false; }
	}
}

if (process.platform !== 'darwin' || !haveSwift()) {
	process.stdout.write('SKIPPED: this check needs macOS and swiftc (Apple\'s Vision framework is the decoder under test).\n' +
		'Nothing was verified. This is reported, not hidden.\n');
	process.exit(0);
}

const binary = path.join(scratch, 'qr-decode');
try {
	execFileSync('swiftc', ['-O', '-o', binary, path.join(__dirname, 'qr-decode.swift')], { stdio: ['ignore', 'ignore', 'pipe'] });
} catch (err) {
	process.stdout.write(`SKIPPED: could not compile the Vision decoder, so nothing was verified:\n${String(err.stderr || err.message)}\n`);
	process.exit(0);
}

process.stdout.write('=== every code this probe renders, decoded by Apple Vision ===\n');

for (const payload of CASES) {
	const rendered = qr.toPng(payload, { scale: 8 });
	const file = path.join(scratch, `case-${Buffer.byteLength(payload)}-${rendered.version}.png`);
	fs.writeFileSync(file, rendered.png);
	let decoded = '';
	let status = 0;
	try {
		decoded = execFileSync(binary, [file], { encoding: 'utf8' }).trim();
	} catch (err) {
		status = err.status === undefined ? -1 : err.status;
	}
	check(`v${rendered.version} mask ${rendered.mask}, ${Buffer.byteLength(payload)} bytes, decoded back to exactly what went in`,
		status === 0 && decoded === payload,
		status === 3 ? 'Vision found no QR code in the image at all'
			: decoded === payload ? `${rendered.pixelSize}x${rendered.pixelSize} px` : `got ${JSON.stringify(decoded.slice(0, 120))}`);
}

// A NEGATIVE control. Without it, a decoder that returned the right answer for any image at all
// would pass every case above.
const corrupt = qr.toPng('https://mm1.local:8788/', { scale: 8 });
const broken = Buffer.from(corrupt.png);
// Overwrite the middle of the image data with noise. The PNG stays well-formed enough to load and
// the symbol inside it does not.
for (let i = Math.floor(broken.length / 2); i < broken.length - 12; i++) broken[i] = 0x5a;
const brokenFile = path.join(scratch, 'corrupt.png');
fs.writeFileSync(brokenFile, broken);
let brokenStatus = 0;
try { execFileSync(binary, [brokenFile], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] }); } catch (err) { brokenStatus = err.status; }
check('NEGATIVE CONTROL: a corrupted image does not decode, so the passes above mean something',
	brokenStatus !== 0, `exit ${brokenStatus}`);

// The quiet zone is not decoration: a code rendered flush to its edge is one a scanner may refuse.
const noQuiet = qr.toPng('https://mm1.local:8788/', { scale: 8, quietZone: 0 });
const noQuietFile = path.join(scratch, 'no-quiet-zone.png');
fs.writeFileSync(noQuietFile, noQuiet.png);
let noQuietDecoded = '';
try { noQuietDecoded = execFileSync(binary, [noQuietFile], { encoding: 'utf8' }).trim(); } catch { noQuietDecoded = '(did not decode)'; }
process.stdout.write(`        FOR THE RECORD: with no quiet zone, Vision returned ${JSON.stringify(noQuietDecoded)} — ` +
	'the served code always carries the standard four modules.\n');

process.stdout.write(`\n=== ${failures === 0 ? 'ALL CHECKS PASSED' : `${failures} CHECK(S) FAILED`} ===\n`);
process.exit(failures ? 1 : 0);
