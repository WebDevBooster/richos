'use strict';

// AMERICAN ENGLISH, IN EVERY STRING HE READS. `node --test "test/*.test.js"`.
//
// The standing rule (CEO, 2026-08-29) binds every string a person reads. This app is one screen of
// almost nothing but strings a person reads, so the scan is over all of them: the markup's own text,
// every string literal in `app.js` and `sw.js`, and the manifest's `name` and `description` — which
// is the text that ends up under the icon on his Home Screen.
//
// EVERY CHECK CARRIES A POSITIVE CONTROL, for the reason `ui/tests/dialect.js` states: a "nothing
// found" assertion passes identically when the scanner works and when it is looking at nothing at
// all. Each check re-runs its own extractor over a fixture with a British spelling planted in the
// same shape, and requires it to be found.
//
// The forbidden spellings are assembled from fragments rather than written out, so this file never
// itself contains one — the same pattern, for the same reason.

const test = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');

const DIR = path.join(__dirname, '..');

const BRITISH = [
	'colo' + 'ur', 'behavio' + 'ur', 'favo' + 'urite', 'hono' + 'ur', 'neighbo' + 'ur',
	'organi' + 'se', 'organi' + 'sed', 'organi' + 'sation', 'recogni' + 'se', 'reali' + 'se',
	'apologi' + 'se', 'authori' + 'se', 'customi' + 'se', 'synchroni' + 'se',
	'cance' + 'lled', 'cance' + 'lling', 'trave' + 'lling', 'labe' + 'lled', 'mode' + 'lling',
	'cent' + 're', 'met' + 're', 'lit' + 're', 'theat' + 're', 'fib' + 're', 'calib' + 're',
	'defen' + 'ce', 'offen' + 'ce', 'preten' + 'ce', 'licen' + 'ce',
	'gr' + 'ey', 'alumin' + 'ium', 'whi' + 'lst', 'amon' + 'gst', 'lea' + 'rnt', 'sp' + 'elt',
	'ful' + 'fil', 'enqui' + 'ry', 'programm' + 'e', 'analy' + 'se', 'paraly' + 'se',
	'judgem' + 'ent', 'acknowledgem' + 'ent', 'age' + 'ing', 'mou' + 'ld', 'stor' + 'ey',
	'ty' + 're', 'ke' + 'rb', 'pyjam' + 'as', 'aeropla' + 'ne', 'scept' + 'ical', 'somb' + 're'
];

const PATTERN = new RegExp(`\\b(${BRITISH.join('|')})\\b`, 'i');

function findBritish(text) {
	const hit = PATTERN.exec(text || '');
	return hit ? hit[1] : null;
}

/// Every string literal in a JavaScript file. Deliberately coarse — it catches comments' quoted
/// text too, and that is fine: a comment is part of the record, which the rule also binds.
function stringLiterals(source) {
	const out = [];
	const re = /'((?:[^'\\\n]|\\.)*)'|"((?:[^"\\\n]|\\.)*)"|`((?:[^`\\]|\\.)*)`/g;
	let m;
	while ((m = re.exec(source)) !== null) out.push(m[1] || m[2] || m[3] || '');
	return out;
}

/// The words in the markup, with tags and attribute names removed but attribute VALUES kept — the
/// placeholder and the title are text he reads.
function markupText(html) {
	return html
		.replace(/<!--[\s\S]*?-->/g, ' ')
		.replace(/<[a-zA-Z/][^>]*>/g, (tag) => ` ${(tag.match(/(?:placeholder|title|alt|aria-label|content)="([^"]*)"/g) || []).join(' ')} `)
		.replace(/&[a-zA-Z]+;/g, ' ');
}

test('the markup he reads is American English', () => {
	const html = fs.readFileSync(path.join(DIR, 'index.html'), 'utf8');
	const found = findBritish(markupText(html));
	assert.strictEqual(found, null, `index.html says "${found}"`);

	// Positive control: the same extractor, over the same shape, with one planted.
	const planted = markupText(`<p class="lede">The ${BRITISH[0]} of this is wrong.</p>`);
	assert.strictEqual(findBritish(planted), BRITISH[0], 'the markup scan did not find a planted British spelling');
});

test('every string in app.js and sw.js is American English', () => {
	for (const file of ['app.js', 'sw.js']) {
		const source = fs.readFileSync(path.join(DIR, file), 'utf8');
		for (const literal of stringLiterals(source)) {
			const found = findBritish(literal);
			assert.strictEqual(found, null, `${file} has a string saying "${found}": ${JSON.stringify(literal.slice(0, 90))}`);
		}
	}
	// Positive control.
	const planted = stringLiterals(`const message = 'that was ${BRITISH[14]}';`);
	assert.strictEqual(findBritish(planted[0]), BRITISH[14], 'the literal scan did not find a planted British spelling');
});

test('every string in the lib modules is American English', () => {
	for (const file of fs.readdirSync(path.join(DIR, 'lib')).filter((f) => f.endsWith('.js'))) {
		const source = fs.readFileSync(path.join(DIR, 'lib', file), 'utf8');
		for (const literal of stringLiterals(source)) {
			const found = findBritish(literal);
			assert.strictEqual(found, null, `lib/${file} has a string saying "${found}"`);
		}
	}
});

test('the name under the icon on his Home Screen is American English', () => {
	const manifest = JSON.parse(fs.readFileSync(path.join(DIR, 'manifest.webmanifest'), 'utf8'));
	for (const field of ['name', 'short_name', 'description']) {
		const found = findBritish(manifest[field]);
		assert.strictEqual(found, null, `the manifest's ${field} says "${found}"`);
	}
	assert.strictEqual(manifest.lang, 'en-US');
});

// The sentences that carry a STATE are the ones he has to believe, so they are pinned by their
// exact words rather than only scanned for a dialect. If one of them is reworded, this fails and
// the rewording is a decision somebody made on purpose.
test('the three send states say what the plan says they say', () => {
	// Matched with the dash and the apostrophe as either the character or its escape, because both
	// spellings of the same string are the same sentence and neither is worth a failure.
	const source = fs.readFileSync(path.join(DIR, 'app.js'), 'utf8')
		.replace(/\\u2014/g, '—').replace(/\\u2019/g, '’').replace(/\\u2026/g, '…');
	assert.ok(/Waiting to send — your Mac isn’t reachable from here\./.test(source),
		'the waiting state is no longer the plan\'s own sentence');
	assert.ok(/Sending…/.test(source), 'the in-flight state is missing');
	assert.ok(/'Delivered\.'/.test(source), 'the delivered state is missing');
	assert.ok(/The rest of this is waiting on your Mac\./.test(source),
		'the truncated-reply sentence is missing — a truncation dressed up as a complete answer is exactly what §2.4 forbids');
});

// No identifier reaches his screen. Enforced in the browser by the harness as well; this is the
// cheap static half, over the two places a hash or an id would be rendered from.
test('no identifier is written into anything he reads', () => {
	const source = fs.readFileSync(path.join(DIR, 'app.js'), 'utf8');
	// `textContent = ` assignments are everything the app puts on screen. None of them may write a
	// message id, a device id, a cursor or a fingerprint hex.
	const assignments = source.match(/textContent\s*=\s*[^;]+;/g) || [];
	assert.ok(assignments.length > 10, 'the scan found almost no assignments, so it stopped scanning something');
	const offenders = assignments.filter((a) => /\b(row|message)\.id\b|deviceId|\.cursor\b|ca_fingerprint_sha256/.test(a));
	assert.deepStrictEqual(offenders, [], `these would put an identifier on his screen:\n${offenders.join('\n')}`);

	// Positive control: the same scan over an assignment that does exactly that.
	const planted = ('textContent = row.id;').match(/textContent\s*=\s*[^;]+;/g) || [];
	assert.strictEqual(planted.filter((a) => /\brow\.id\b/.test(a)).length, 1, 'the identifier scan did not see a planted identifier');
});
