'use strict';

// THE SENTENCE UNDER THE SIX WORDS SAYS THE RIGHT THING, AND THERE IS ONE OF IT. `npm test`.
//
// **CEO §61, 2026-09-18:** *"it's an app that lets the user use RichOS (in some way) while being
// on the go and away from office i.e. outside the home network. Because any mobile app or PWA is
// utterly useless within the home network. The desktop app is a much better tool in that case …
// The Tailscale setup is where we start now."*
//
// WHAT THIS FILE USED TO BE. The Mac served this app on two kinds of origin —
// `https://<name>.local:8443` with a certificate it had made for itself and asked the phone to
// install, and `https://<name>.ts.net:8443` with a publicly trusted one — and `app.js` chose one
// of two sentences by reading `location.hostname`. Six tests pinned that choice, including three
// about the suffix match, because handing the "nothing was installed" promise to whoever registers
// `evilts.net` would have been a real defect.
//
// §61 removed the first origin. There is nothing left to choose between, so the whole class of
// defect those three tests guarded is gone with the branch rather than still guarded — and what
// remains to assert is the thing Ray's §4.2 was actually about.
//
// Ray's candidate .11 walk, §4.2
// (`docs/verification/2026-09-19-nightly-1.2.0-nightly.20260918.6-mac-and-android-audit.md`):
//
//     "The Mac had just told him, in bold on the same flow: 'There is no certificate to install on
//      this path. If your phone asks you to install a profile, something is wrong — tell me.' A
//      careful person reading both concludes something IS wrong, at the exact moment he is being
//      asked to make a security decision."
//
// THE FUNCTION UNDER TEST IS THE SHIPPED ONE, lifted out of `app.js` by name and run here.
// `app.js` is an IIFE that boots a browser app the moment it loads, so it cannot be `require`d;
// this one is pure, takes nothing at all, and is therefore driveable exactly as it ships.

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

/// The shipped function, with nothing else in scope.
function theSentence() {
	// eslint-disable-next-line no-new-func
	return new Function(`${lift('whatTheSixWordsAre')}\nreturn whatTheSixWordsAre();`)();
}

test('the phone does not claim there is a certificate — the Mac says there is none', () => {
	const said = theSentence();
	assert.doesNotMatch(
		said,
		/certificate/i,
		`the phone talks about a certificate on a path the Mac promised has none: ${said}`
	);
	assert.match(said, /your Mac/, 'the sentence stopped naming whose key it is');
	assert.match(
		said,
		/this phone is talking to your Mac and to nothing else/,
		'the sentence he is actually making the decision on is gone'
	);
	assert.match(
		said,
		/Nothing was installed on this phone/,
		'the sentence stopped saying the thing that makes the Mac and the phone agree'
	);
});

test('nothing reads the address bar to decide what to say', () => {
	// The branch is the defect class. A build that grew one back would be choosing a sentence
	// from an origin again, and the origin it would choose the second sentence for is a path
	// §61 removed.
	assert.strictEqual(
		appJs.includes('function onTheTailscalePath()'),
		false,
		'the origin sniff is back, so there are two sentences again'
	);
	assert.doesNotMatch(
		lift('whatTheSixWordsAre'),
		/location|hostname|if\s*\(/,
		'the sentence is chosen rather than stated'
	);
});

test('the pairing screen writes the sentence before it shows the words', () => {
	const flow = appJs.match(/\$\('pairing-lede'\)\.textContent = 'Almost done[\s\S]*?\$\('pairing-row'\)\.hidden = false;/);
	assert.ok(flow, 'the moment the six words go on screen has moved');
	const noteAt = flow[0].indexOf("$('fingerprint-note').textContent = whatTheSixWordsAre()");
	const wordsAt = flow[0].indexOf("$('fingerprint-words').textContent");
	assert.ok(noteAt !== -1, 'nothing sets the sentence, so the markup default is what he reads');
	assert.ok(noteAt < wordsAt, 'the words appear before the sentence that explains them is set');
});

test('the markup ships the same sentence app.js sets, so the two cannot disagree', () => {
	const note = html.match(/<p class="fingerprint-note"[^>]*>([^<]*)<\/p>/);
	assert.ok(note, 'the note under the six words is gone from index.html');
	assert.match(note[0], /id="fingerprint-note"/, 'the note has no id, so nothing can set it');
	assert.strictEqual(
		note[1].trim(),
		theSentence(),
		'the markup and app.js say different things under the six words'
	);
	assert.doesNotMatch(note[1], /certificate/i, 'the markup still names a certificate');
});
