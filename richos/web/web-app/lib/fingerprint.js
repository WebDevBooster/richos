// SIX WORDS INSTEAD OF A HASH — the certificate authority's identity, in a form he can compare.
//
// Plan §4.1: at pairing, the Mac and the phone show the same six-word fingerprint of the certificate
// authority his phone is about to trust, he confirms they match, and he taps Pair. "One tap, and it
// remains the difference between 'a code got out' and 'someone is talking to Rich as me.'"
//
// THE DERIVATION IS DELIBERATELY DULL, because the Mac has to reproduce it in Rust exactly:
//
//     take the SHA-256 of the certificate authority's DER
//     the first six bytes index the 256-word list
//     join them with spaces
//
// That is 48 bits of the fingerprint. It is not the whole hash and it is not meant to be: the phone
// is talking over a TLS session that already validated against the root he installed, and these six
// words exist so a HUMAN can catch the case where the thing he is pairing with is not the Mac he is
// standing in front of. Forty-eight bits of preimage resistance is far beyond what that check needs,
// and a twelve-word fingerprint nobody reads would be worth less than six he does.
//
// THE WORDS ARE COMPUTED HERE, ON THE PHONE, FROM THE HASH — never taken from the Mac as words.
// The Mac sends the hexadecimal fingerprint and this file renders it. That ordering matters: if the
// Mac sent pretty words, a Mac that wanted to could send words that do not belong to the certificate
// it is actually serving. Words derived locally from the hash are a pure function of the hash.
//
// Loads as a plain script (defines `globalThis.RichOSFingerprint`) and as a CommonJS module.

(function (root, factory) {
	const list = (typeof module === 'object' && module.exports)
		? require('./wordlist.js')
		: root.RichOSWordList;
	const api = factory(list.WORDS);
	if (typeof module === 'object' && module.exports) module.exports = api;
	root.RichOSFingerprint = api;
})(typeof globalThis !== 'undefined' ? globalThis : this, function (WORDS) {
	'use strict';

	const WORD_COUNT = 6;

	// Accepts what a certificate tool actually hands you: bare hexadecimal, colon-separated
	// hexadecimal, upper or lower case, with or without a `SHA-256` label in front of it. Being
	// liberal here is not sloppiness — it is what stops the Mac's exact formatting choice from
	// becoming a thing two implementations have to agree on.
	function bytesFromHex(text) {
		if (typeof text !== 'string') throw new TypeError('a fingerprint must be a string of hexadecimal');
		const cleaned = text.replace(/^\s*sha-?256\s*[:=]?\s*/i, '').replace(/[\s:-]/g, '');
		if (!/^[0-9a-f]+$/i.test(cleaned)) throw new Error('that is not a hexadecimal fingerprint');
		if (cleaned.length % 2 !== 0) throw new Error('a hexadecimal fingerprint has an even number of characters');
		if (cleaned.length < WORD_COUNT * 2) throw new Error(`a fingerprint needs at least ${WORD_COUNT} bytes`);
		const bytes = new Uint8Array(cleaned.length / 2);
		for (let i = 0; i < bytes.length; i++) bytes[i] = parseInt(cleaned.substr(i * 2, 2), 16);
		return bytes;
	}

	function wordsFromBytes(bytes, count) {
		const n = count || WORD_COUNT;
		if (!bytes || bytes.length < n) throw new Error(`need at least ${n} bytes`);
		const out = [];
		for (let i = 0; i < n; i++) out.push(WORDS[bytes[i] & 0xff]);
		return out;
	}

	function wordsFromHex(text, count) {
		return wordsFromBytes(bytesFromHex(text), count);
	}

	// One line, spoken as one line. The spaces are ordinary spaces: he may read this aloud to
	// himself while looking at the Mac, and a separator that has to be pronounced ("dash", "dot")
	// is a separator that gets in the way of the only thing this string is for.
	function phraseFromHex(text, count) {
		return wordsFromHex(text, count).join(' ');
	}

	return { WORD_COUNT, WORDS, bytesFromHex, wordsFromBytes, wordsFromHex, phraseFromHex };
});
