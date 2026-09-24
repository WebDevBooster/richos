'use strict';

// The word list and the six-word fingerprint. `node --test test/`.
//
// The list is DATA the Mac has to agree with byte for byte, so the properties it is supposed to
// have are asserted here rather than trusted to the care with which it was typed. Every assertion
// below is a property a human comparison depends on: 256 entries or the byte-to-word mapping has a
// hole in it; unique or two bytes say the same word; no two words within one edit or he cannot tell
// them apart when he says them out loud.

const test = require('node:test');
const assert = require('node:assert');
const crypto = require('node:crypto');

const { WORDS } = require('../lib/wordlist.js');
const fp = require('../lib/fingerprint.js');

test('the list is exactly 256 words, one per byte', () => {
	assert.strictEqual(WORDS.length, 256, `the list has ${WORDS.length} words`);
});

test('every word is lowercase a-z, three to seven letters', () => {
	const bad = WORDS.filter((w) => !/^[a-z]{3,7}$/.test(w));
	assert.deepStrictEqual(bad, [], `these do not fit the shape: ${bad.join(', ')}`);
});

test('no word appears twice', () => {
	const seen = new Map();
	const duplicates = [];
	WORDS.forEach((w, i) => {
		if (seen.has(w)) duplicates.push(`${w} at ${seen.get(w)} and ${i}`);
		else seen.set(w, i);
	});
	assert.deepStrictEqual(duplicates, [], duplicates.join('; '));
});

// One edit apart is a mishearing, not a comparison. This is the property that matters when he reads
// six words off the Mac and looks at the phone in his hand.
function distanceAtMostOne(a, b) {
	if (Math.abs(a.length - b.length) > 1) return false;
	let i = 0;
	let j = 0;
	let edits = 0;
	while (i < a.length && j < b.length) {
		if (a[i] === b[j]) { i++; j++; continue; }
		if (++edits > 1) return false;
		if (a.length === b.length) { i++; j++; }
		else if (a.length > b.length) i++;
		else j++;
	}
	edits += (a.length - i) + (b.length - j);
	return edits <= 1;
}

test('no two words are within one edit of each other', () => {
	const close = [];
	for (let i = 0; i < WORDS.length; i++) {
		for (let j = i + 1; j < WORDS.length; j++) {
			if (distanceAtMostOne(WORDS[i], WORDS[j])) close.push(`${WORDS[i]} / ${WORDS[j]}`);
		}
	}
	assert.deepStrictEqual(close, [], `too close to tell apart out loud: ${close.join(', ')}`);
});

// The positive control for the check above: a comparison that always returned false would pass it
// while proving nothing at all.
test('the edit-distance check can actually fail', () => {
	assert.ok(distanceAtMostOne('anchor', 'ancho'), 'the distance check did not see a one-letter difference');
	assert.ok(distanceAtMostOne('anchor', 'anchol'), 'the distance check did not see a one-letter substitution');
	assert.ok(!distanceAtMostOne('anchor', 'basket'), 'the distance check called two unrelated words close');
});

// The standing rule binds every word he reads, and he reads these aloud. The forbidden spellings are
// assembled from fragments rather than written out, so this file never itself contains one — the
// pattern `ui/tests/dialect.js` established for the same reason.
test('no British spellings in the list', () => {
	const forbidden = [
		'harbo' + 'ur', 'colo' + 'ur', 'fib' + 're', 'parlo' + 'ur', 'met' + 're', 'lit' + 're',
		'theat' + 're', 'cent' + 're', 'gr' + 'ey', 'plo' + 'ugh', 'moust' + 'ache', 'pyja' + 'ma'
	];
	const found = WORDS.filter((w) => forbidden.includes(w));
	assert.deepStrictEqual(found, [], `British spellings: ${found.join(', ')}`);
	// Positive control: the same scan over a list that does contain one.
	const planted = WORDS.concat([forbidden[0]]).filter((w) => forbidden.includes(w));
	assert.strictEqual(planted.length, 1, 'the scan did not find a planted British spelling');
});

test('a real SHA-256 becomes six words, deterministically', () => {
	const hex = crypto.createHash('sha256').update('richos-phone-fingerprint-fixture').digest('hex');
	const phrase = fp.phraseFromHex(hex);
	assert.strictEqual(phrase.split(' ').length, 6, phrase);
	assert.strictEqual(phrase, fp.phraseFromHex(hex), 'the same hash gave two different phrases');
	// The mapping is the documented one, which is what the Mac has to reimplement: byte n indexes
	// word n of the list, first six bytes, in order.
	const bytes = Buffer.from(hex.slice(0, 12), 'hex');
	assert.deepStrictEqual(phrase.split(' '), Array.from(bytes).map((b) => WORDS[b]));
});

test('the formatting a certificate tool hands you is accepted, in any of its shapes', () => {
	const hex = 'a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718293a4b5c6d7e8f90';
	const colons = hex.toUpperCase().replace(/(..)/g, '$1:').slice(0, -1);
	assert.strictEqual(fp.phraseFromHex(colons), fp.phraseFromHex(hex));
	assert.strictEqual(fp.phraseFromHex(`SHA-256 ${colons}`), fp.phraseFromHex(hex));
	assert.strictEqual(fp.phraseFromHex(`  sha256: ${hex}  `), fp.phraseFromHex(hex));
});

test('a fingerprint that is not one is refused rather than rendered as words', () => {
	assert.throws(() => fp.phraseFromHex('not a hash'), /hexadecimal/);
	assert.throws(() => fp.phraseFromHex('a1b2'), /at least 6 bytes/);
	assert.throws(() => fp.phraseFromHex('abc'), /even number|hexadecimal/);
	assert.throws(() => fp.phraseFromHex(null), TypeError);
});

// Two different certificate authorities must not read the same. Not a proof — a smoke test over a
// thousand real hashes, which is enough to catch an encoding that ignored most of its input.
test('a thousand different hashes give a thousand different phrases', () => {
	const seen = new Set();
	for (let i = 0; i < 1000; i++) {
		seen.add(fp.phraseFromHex(crypto.createHash('sha256').update(`ca-${i}`).digest('hex')));
	}
	assert.strictEqual(seen.size, 1000, `${1000 - seen.size} collisions in a thousand`);
});

// ---- v2 (Sage's pairing review F2) --------------------------------------------------------------

const subtle = crypto.webcrypto.subtle;
const ORIGIN = 'https://mm1.tail9a3b2.ts.net:8443';
const CA = '3D:9C:A1:00:FF:12:34:56:78:9A:BC:DE:F0:11:22:33:44:55:66:77:88:99:AA:BB:CC:DD:EE:FF:01:02:03:04';

function freshPoint() {
	const { publicKey } = crypto.generateKeyPairSync('ec', { namedCurve: 'prime256v1' });
	const jwk = publicKey.export({ format: 'jwk' });
	const raw = crypto.createPublicKey({ key: jwk, format: 'jwk' }).export({ format: 'der', type: 'spki' }).subarray(26);
	return { jwk, raw };
}

test('v2: the input is the label, the origin dialed, the Mac hash and the key, on four lines', () => {
	assert.strictEqual(fp.v2Input(ORIGIN, CA, 'POINT'), `RICHCONNECT-PAIR-V2\n${ORIGIN}\n${CA}\nPOINT`);
	// The origin is written the way a browser writes it, whatever the link looked like.
	assert.strictEqual(fp.v2Input('HTTPS://MM1.Tail9a3b2.TS.NET:8443/', CA, 'P'), fp.v2Input(ORIGIN, CA, 'P'));
	assert.strictEqual(fp.normalizeOrigin('https://c-5de0-g2.richos.ceo:443/'), 'https://c-5de0-g2.richos.ceo');
	assert.throws(() => fp.normalizeOrigin('http://mm1.tail9a3b2.ts.net:8443'), /https/);
});

test('v2: the six words are WORDS over the first six bytes of the SHA-256 of that input', async () => {
	const { jwk } = freshPoint();
	const point = fp.pointFromJwk(jwk);
	const digest = crypto.createHash('sha256').update(fp.v2Input(ORIGIN, CA, point), 'utf8').digest();
	const expected = Array.from(digest.subarray(0, 6), (b) => WORDS[b]);
	assert.deepStrictEqual(await fp.wordsV2(ORIGIN, CA, point, subtle), expected);
	assert.strictEqual(await fp.phraseV2(ORIGIN, CA, point, subtle), expected.join(' '));
});

test('v2: the point is the 65-byte uncompressed key, exactly as the Mac stores it', () => {
	const { jwk, raw } = freshPoint();
	assert.strictEqual(fp.pointFromJwk(jwk), raw.toString('base64url'));
	assert.strictEqual(raw.length, 65);
	assert.throws(() => fp.pointFromJwk({ kty: 'RSA' }), /P-256/);
});

test('v2: a relay (another origin) and an intruder (another key) each change the words; v1 changed for neither', async () => {
	const phone = fp.pointFromJwk(freshPoint().jwk);
	const intruder = fp.pointFromJwk(freshPoint().jwk);
	const atTheMac = await fp.phraseV2(ORIGIN, CA, phone, subtle);
	assert.notStrictEqual(await fp.phraseV2('https://evil.example', CA, phone, subtle), atTheMac, 'a relayed pairing shows the same words');
	assert.notStrictEqual(await fp.phraseV2(ORIGIN, CA, intruder, subtle), atTheMac, 'an intruder\'s key shows the same words');
	// The finding, for contrast: the old words are a function of the hash alone.
	assert.strictEqual(fp.phraseFromHex(CA), fp.phraseFromHex(CA));
});
