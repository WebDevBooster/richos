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
// THAT IS v1, AND A PHONE THAT PAIRS WITH THIS FILE NO LONGER SHOWS IT. Sage's pairing review F2
// (2026-09-24) found the hash alone binds nothing about the connection, so the words this app
// shows are v2 — see `wordsV2` below — and v1 stays only for reading the corpus's old vectors.
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

	// ---- v2, `pair-v2` — Sage's pairing review F2, 2026-09-24 ----------------------------------
	//
	// THE v1 WORDS ABOVE BIND NOTHING ABOUT THE CONNECTION. They are a function of the hash the
	// answering server STATES, so a relay that forwards the pairing to the real Mac gets the real
	// hash and the words match (Tom's X-2). v2 hashes three things with a label in front:
	//
	//     SHA-256("RICHCONNECT-PAIR-V2\n" + origin + "\n" + ca_fingerprint_sha256 + "\n" + point)
	//
	//   origin  the origin THIS PHONE DIALED, as `new URL(...).origin` writes it — never one the
	//           Mac advertised. A relay is a different origin, so its words differ.
	//   ca_fingerprint_sha256  the pair answer's field, byte for byte as the Mac sent it.
	//   point   this phone's own public key, the 65-byte uncompressed point, base64url, no padding.
	//           The Mac hashes the key IT REGISTERED, so an intruder who redeemed the code first
	//           makes the Mac's words differ from these.
	//
	// The Mac computes the same thing over its own origin and the key it holds
	// (`app/src-tauri/src/phone/words.rs`), and the conformance corpus holds the two together.
	// A v2 phone NEVER falls back to v1: a relay can strip a capability (review §3.5).

	const PAIR_V2_LABEL = 'RICHCONNECT-PAIR-V2';

	/// `https://host[:port]`, lowercase, default port omitted — `URL.origin`'s own rule, which the
	/// Mac's `normalize_origin` mirrors. Anything that is not an https origin is refused rather than
	/// hashed, because a phrase over a malformed origin is a phrase nobody can reproduce.
	function normalizeOrigin(text) {
		let url;
		try { url = new URL(String(text)); } catch { throw new Error('that is not an address this phone can use'); }
		if (url.protocol !== 'https:') throw new Error('pairing needs an https address');
		return url.origin;
	}

	function b64urlOf(bytes) {
		let binary = '';
		for (let i = 0; i < bytes.length; i++) binary += String.fromCharCode(bytes[i]);
		const b64 = typeof btoa === 'function' ? btoa(binary) : Buffer.from(binary, 'binary').toString('base64');
		return b64.replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
	}

	function bytesOfB64url(text) {
		const b64 = String(text).replace(/-/g, '+').replace(/_/g, '/');
		const padded = b64 + '='.repeat((4 - (b64.length % 4)) % 4);
		const binary = typeof atob === 'function' ? atob(padded) : Buffer.from(padded, 'base64').toString('binary');
		const out = new Uint8Array(binary.length);
		for (let i = 0; i < binary.length; i++) out[i] = binary.charCodeAt(i);
		return out;
	}

	/// The uncompressed point, base64url, from the JWK WebCrypto exports: `04 || x || y`. The same
	/// value the Mac stores as the device's `public_key`.
	function pointFromJwk(jwk) {
		if (!jwk || jwk.kty !== 'EC' || jwk.crv !== 'P-256') throw new Error('a device key must be an EC P-256 key');
		const x = bytesOfB64url(jwk.x);
		const y = bytesOfB64url(jwk.y);
		if (x.length !== 32 || y.length !== 32) throw new Error('a P-256 key has 32-byte coordinates');
		const point = new Uint8Array(65);
		point[0] = 4;
		point.set(x, 1);
		point.set(y, 33);
		return b64urlOf(point);
	}

	/// The exact text a v2 phrase is the hash of. Exported so a test can pin it byte for byte.
	function v2Input(origin, caFingerprintSha256, devicePointB64url) {
		if (typeof caFingerprintSha256 !== 'string' || !caFingerprintSha256) throw new Error('the Mac sent no fingerprint');
		if (typeof devicePointB64url !== 'string' || !devicePointB64url) throw new Error('this phone has no key to name');
		return `${PAIR_V2_LABEL}\n${normalizeOrigin(origin)}\n${caFingerprintSha256}\n${devicePointB64url}`;
	}

	/// The v2 six words. `subtle` is WebCrypto's (`crypto.subtle` in the page, `webcrypto.subtle`
	/// in Node); the digest is asynchronous there, so this is too.
	async function wordsV2(origin, caFingerprintSha256, devicePointB64url, subtle) {
		const engine = subtle || (typeof crypto !== 'undefined' && crypto.subtle);
		if (!engine) throw new Error('this browser cannot compute the six words');
		const input = new TextEncoder().encode(v2Input(origin, caFingerprintSha256, devicePointB64url));
		return wordsFromBytes(new Uint8Array(await engine.digest('SHA-256', input)));
	}

	async function phraseV2(origin, caFingerprintSha256, devicePointB64url, subtle) {
		return (await wordsV2(origin, caFingerprintSha256, devicePointB64url, subtle)).join(' ');
	}

	return {
		WORD_COUNT, WORDS, bytesFromHex, wordsFromBytes, wordsFromHex, phraseFromHex,
		PAIR_V2_LABEL, normalizeOrigin, pointFromJwk, v2Input, wordsV2, phraseV2
	};
});
