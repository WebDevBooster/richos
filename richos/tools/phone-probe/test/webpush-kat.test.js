'use strict';

// Known-answer tests for lib/webpush.js. `node --test test/`.
//
// The first one is the whole reason this file exists: RFC 8291 §5 publishes a complete worked
// example — receiver key, auth secret, sender key, salt and the exact encrypted body. Hand-rolled
// crypto that is only tested against itself is hand-rolled crypto that is wrong in a way nobody
// notices until a push silently fails to decrypt on a phone. Reproducing the RFC's own bytes is
// the only test that can distinguish "it encrypts" from "it encrypts correctly".

const test = require('node:test');
const assert = require('node:assert');
const crypto = require('node:crypto');
const wp = require('../lib/webpush.js');

// --- RFC 8291 §5, verbatim -------------------------------------------------
const RFC8291 = {
	plaintext: 'When I grow up, I want to be a watermelon',
	uaPublic: 'BCVxsr7N_eNgVRqvHtD0zTZsEc6-VV-JvLexhqUzORcxaOzi6-AYWXvTBHm4bjyPjs7Vd8pZGH6SRpkNtoIAiw4',
	authSecret: 'BTBZMqHH6r4Tts7J_aSIgg',
	asPrivate: 'yfWPiYE-n46HLnH0KqZOF1fJJU3MYrct3AELtAQ-oRw',
	asPublic: 'BP4z9KsN6nGRTbVYI_c7VJSPQTBtkgcy27mlmlMoZIIgDll6e3vCYLocInmYWAmS6TlzAC8wEqKK6PBru3jl7A8',
	salt: 'DGv6ra1nlYgDCS1FRnbzlw',
	body: 'DGv6ra1nlYgDCS1FRnbzlwAAEABBBP4z9KsN6nGRTbVYI_c7VJSPQTBtkgcy27mlmlMoZIIgDll6e3vCYLocInmYWAmS6TlzAC8wEqKK6PBru3jl7A_yl95bQpu6cVPTpK4Mqgkf1CXztLVBSt2Ks3oZwbuwXPXLWyouBWLVWGNWQexSgSxsj_Qulcy4a-fN'
};

test('RFC 8291 §5: the encrypted body matches the RFC byte for byte', () => {
	const out = wp.encryptPayload(RFC8291.plaintext, RFC8291.uaPublic, RFC8291.authSecret, {
		salt: RFC8291.salt,
		asPrivateKey: RFC8291.asPrivate
	});
	assert.strictEqual(wp.b64url(out), RFC8291.body);
});

test('RFC 8291 §5: setting the sender private key derives the RFC\'s sender public key', () => {
	// If this fails, the header keyid is wrong and no client can derive the shared secret,
	// even though the body would still "look" encrypted.
	const ecdh = crypto.createECDH('prime256v1');
	ecdh.setPrivateKey(wp.unb64url(RFC8291.asPrivate));
	assert.strictEqual(wp.b64url(ecdh.getPublicKey()), RFC8291.asPublic);
});

test('the aes128gcm header is framed per RFC 8188 §2.1', () => {
	const out = wp.encryptPayload('hi', RFC8291.uaPublic, RFC8291.authSecret);
	assert.strictEqual(out.length > 16 + 4 + 1 + 65, true, 'body must exceed the header length');
	assert.strictEqual(out.readUInt32BE(16), 4096, 'record size field');
	assert.strictEqual(out[20], 65, 'keyid length field must be 65 (an uncompressed P-256 point)');
	assert.strictEqual(out[21], 0x04, 'keyid must be an uncompressed point');
	// plaintext(2) + delimiter(1) + GCM tag(16) = 19 bytes of ciphertext
	assert.strictEqual(out.length - (16 + 4 + 1 + 65), 19);
});

test('a round trip decrypts back to the plaintext, and the delimiter is 0x02', () => {
	// Stand in for the browser: generate a receiver key pair and an auth secret, encrypt to it,
	// then run the receiver's half of RFC 8291 by hand. This proves the derivation is symmetric,
	// which the KAT above cannot (the KAT only proves we match one fixed output).
	const ua = crypto.createECDH('prime256v1');
	ua.generateKeys();
	const uaPublic = wp.b64url(ua.getPublicKey());
	const authSecret = crypto.randomBytes(16);
	const plaintext = 'Rich has a reply for you.';

	const body = wp.encryptPayload(plaintext, uaPublic, wp.b64url(authSecret));

	const salt = body.subarray(0, 16);
	const idlen = body[20];
	const asPublic = body.subarray(21, 21 + idlen);
	const ciphertext = body.subarray(21 + idlen);

	const shared = ua.computeSecret(asPublic);
	const keyInfo = Buffer.concat([
		Buffer.from('WebPush: info\0', 'utf8'),
		ua.getPublicKey(),
		asPublic
	]);
	const ikm = Buffer.from(crypto.hkdfSync('sha256', shared, authSecret, keyInfo, 32));
	const cek = Buffer.from(crypto.hkdfSync('sha256', ikm, salt, Buffer.from('Content-Encoding: aes128gcm\0'), 16));
	const nonce = Buffer.from(crypto.hkdfSync('sha256', ikm, salt, Buffer.from('Content-Encoding: nonce\0'), 12));

	const tag = ciphertext.subarray(ciphertext.length - 16);
	const decipher = crypto.createDecipheriv('aes-128-gcm', cek, nonce);
	decipher.setAuthTag(tag);
	const opened = Buffer.concat([
		decipher.update(ciphertext.subarray(0, ciphertext.length - 16)),
		decipher.final()
	]);

	assert.strictEqual(opened[opened.length - 1], 0x02, 'last record delimiter');
	assert.strictEqual(opened.subarray(0, opened.length - 1).toString('utf8'), plaintext);
});

test('a payload larger than the default record size still fits its declared rs', () => {
	const big = 'x'.repeat(5000);
	const out = wp.encryptPayload(big, RFC8291.uaPublic, RFC8291.authSecret);
	const rs = out.readUInt32BE(16);
	const record = out.length - (16 + 4 + 1 + 65);
	assert.strictEqual(rs >= record, true, `rs ${rs} must be >= the record it frames (${record})`);
});

// --- RFC 8292 VAPID -------------------------------------------------------

test('RFC 8292: the VAPID header is a verifiable ES256 JWT whose aud is the endpoint ORIGIN', () => {
	const keys = wp.generateVapidKeys();
	const header = wp.vapidAuthorizationHeader({
		endpoint: 'https://push.example.net/push/v1/subscription-id?token=abc',
		subject: 'mailto:rich@example.com',
		publicKey: keys.publicKey,
		privateKey: keys.privateKey
	});

	const m = /^vapid t=([^,]+), k=(.+)$/.exec(header);
	assert.ok(m, `header shape: ${header}`);
	assert.strictEqual(m[2], keys.publicKey, 'k must be the raw 65-byte public point');

	const [h, p, s] = m[1].split('.');
	assert.deepStrictEqual(JSON.parse(wp.unb64url(h).toString()), { typ: 'JWT', alg: 'ES256' });
	const claims = JSON.parse(wp.unb64url(p).toString());
	// The origin, NOT the full URL. A full URL here is a flat 401 from the push service.
	assert.strictEqual(claims.aud, 'https://push.example.net');
	assert.strictEqual(claims.sub, 'mailto:rich@example.com');
	assert.strictEqual(claims.exp > Math.floor(Date.now() / 1000), true);

	// Verify the signature with the PUBLIC key alone — this is what the push service does.
	const pub = wp.unb64url(keys.publicKey);
	const publicKeyObject = crypto.createPublicKey({
		key: {
			kty: 'EC',
			crv: 'P-256',
			x: wp.b64url(pub.subarray(1, 33)),
			y: wp.b64url(pub.subarray(33, 65))
		},
		format: 'jwk'
	});
	assert.strictEqual(wp.unb64url(s).length, 64, 'ES256 signature must be raw r||s, not DER');
	assert.strictEqual(
		crypto.verify('sha256', Buffer.from(`${h}.${p}`), { key: publicKeyObject, dsaEncoding: 'ieee-p1363' }, wp.unb64url(s)),
		true
	);
});

test('generated VAPID keys are the shape the browser applicationServerKey wants', () => {
	const keys = wp.generateVapidKeys();
	assert.strictEqual(wp.unb64url(keys.publicKey).length, 65);
	assert.strictEqual(wp.unb64url(keys.publicKey)[0], 0x04);
	assert.strictEqual(wp.unb64url(keys.privateKey).length, 32);
	assert.strictEqual(/[+/=]/.test(keys.publicKey), false, 'must be base64url, not base64');
});

test('a malformed subscription is refused loudly, not silently mis-encrypted', () => {
	assert.throws(() => wp.encryptPayload('x', wp.b64url(Buffer.alloc(64)), RFC8291.authSecret), /65-byte/);
	assert.throws(() => wp.encryptPayload('x', RFC8291.uaPublic, wp.b64url(Buffer.alloc(8))), /auth must be 16 bytes/);
});
