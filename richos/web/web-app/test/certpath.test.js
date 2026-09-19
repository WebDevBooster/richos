'use strict';

// THE SENTENCE UNDER THE SIX WORDS SAYS THE RIGHT THING FOR THE WAY IN. `npm test`.
//
// Ray's candidate .11 walk, §4.2
// (`docs/verification/2026-09-19-nightly-1.2.0-nightly.20260918.6-mac-and-android-audit.md`):
//
//     "The Mac had just told him, in bold on the same flow: 'There is no certificate to install on
//      this path. If your phone asks you to install a profile, something is wrong — tell me.' A
//      careful person reading both concludes something IS wrong, at the exact moment he is being
//      asked to make a security decision."
//
// The Mac serves this app on two kinds of origin and only two: `https://<name>.local:8443` from a
// certificate authority it made for itself (`app/src-tauri/src/phone/api_base.rs:13`), and
// `https://<name>.ts.net:8443` with a publicly trusted certificate — *"which is what deletes the"*
// profile step (`phone/listen.rs:213`, `phone/mod.rs:315`). Ray reached the second one on the
// CEO's Android with no interstitial, which is only possible with a certificate the phone already
// trusts.
//
// THE TWO FUNCTIONS UNDER TEST ARE THE SHIPPED ONES, lifted out of `app.js` by name and run here.
// `app.js` is an IIFE that boots a browser app the moment it loads, so it cannot be `require`d;
// these two are pure, take nothing but `location`, and are therefore driveable exactly as they
// ship. What is NOT proved here is that the pairing screen calls them — `test/desktop-verify.js`
// walks the running app for that, and a byte-level assertion below stands in for it in `npm test`.

const test = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');

const ROOT = path.join(__dirname, '..');
const appJs = fs.readFileSync(path.join(ROOT, 'app.js'), 'utf8');
const html = fs.readFileSync(path.join(ROOT, 'index.html'), 'utf8');

function lift(name) {
	const found = appJs.match(new RegExp(`\\nfunction ${name}\\(\\) \\{[\\s\\S]*?\\n\\}`));
	assert.ok(found, `${name} is gone from app.js`);
	return found[0];
}

/// The two shipped functions, with a `location` of this test's choosing and nothing else in scope.
function sentenceOn(hostname) {
	const source = `${lift('onTheTailscalePath')}\n${lift('whatTheSixWordsAre')}\nreturn whatTheSixWordsAre();`;
	// eslint-disable-next-line no-new-func
	return new Function('location', source)({ hostname });
}

test('on the Tailscale path the phone does not claim there is a certificate — the Mac just said there is none', () => {
	const said = sentenceOn('mm1.tail770f6e.ts.net');
	assert.doesNotMatch(
		said,
		/certificate/i,
		`the phone still talks about a certificate on the path the Mac promised has none: ${said}`
	);
	assert.match(said, /your Mac/, 'the sentence stopped naming whose key it is');
	assert.match(
		said,
		/this phone is talking to your Mac and to nothing else/,
		'the sentence he is actually making the decision on is gone'
	);
});

test('on the home path it still names the certificate, because that is the one he was asked to install', () => {
	const said = sentenceOn('mm1.local');
	assert.match(said, /the certificate your Mac made for itself/, `the home-path sentence changed: ${said}`);
});

test('an address nobody has thought of gets the home-path sentence, not the Tailscale one', () => {
	// The cautious way round: the home sentence names a profile he may have installed and is
	// harmless where he has not; the Tailscale sentence PROMISES nothing was installed, which is a
	// promise this app must not make about a path it cannot recognize.
	for (const host of ['192.168.1.42', 'mm1.local', 'localhost', 'ts.net.example.com', '']) {
		assert.match(
			sentenceOn(host),
			/the certificate your Mac made for itself/,
			`${host || '(empty)'} was read as the Tailscale path`
		);
	}
});

test('the Tailscale path is matched on the whole label, not on the three characters', () => {
	// `evil-ts.net` is a different domain from `ts.net`, and `nots.net` is a third. A suffix test
	// that forgets the dot hands the "nothing was installed" promise to whoever registers one.
	assert.match(sentenceOn('mm1.evilts.net'), /the certificate your Mac made for itself/);
	assert.match(sentenceOn('nots.net'), /the certificate your Mac made for itself/);
	assert.doesNotMatch(sentenceOn('MM1.TAIL770F6E.TS.NET'), /certificate/i, 'the host is not compared case-insensitively');
});

test('the pairing screen writes the sentence before it shows the words', () => {
	const flow = appJs.match(/\$\('pairing-lede'\)\.textContent = 'Almost done[\s\S]*?\$\('pairing-row'\)\.hidden = false;/);
	assert.ok(flow, 'the moment the six words go on screen has moved');
	const noteAt = flow[0].indexOf("$('fingerprint-note').textContent = whatTheSixWordsAre()");
	const wordsAt = flow[0].indexOf("$('fingerprint-words').textContent");
	assert.ok(noteAt !== -1, 'nothing sets the sentence, so the markup default is what he reads on every path');
	assert.ok(noteAt < wordsAt, 'the words appear before the sentence that explains them is corrected');
});

test('what ships in the markup is the home-path sentence, and it has an id to replace', () => {
	const note = html.match(/<p class="fingerprint-note"[^>]*>([^<]*)<\/p>/);
	assert.ok(note, 'the note under the six words is gone from index.html');
	assert.match(note[0], /id="fingerprint-note"/, 'the note has no id, so nothing can correct it');
	assert.match(note[1], /the certificate your Mac made for itself/);
});
