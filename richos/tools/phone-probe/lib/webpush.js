'use strict';

// Web Push, with NO dependencies at all.
//
// Two RFCs and nothing else:
//   RFC 8291 — Message Encryption for Web Push (the `aes128gcm` content encoding)
//   RFC 8292 — Voluntary Application Server Identification (VAPID)
// plus RFC 8188 §2, which is the record framing `aes128gcm` actually uses.
//
// WHY NO PACKAGE. The obvious choice is the `web-push` npm package. It is not used, and the
// reason is not minimalism for its own sake:
//
//   1. Node's own `crypto` already ships every primitive this needs — ECDH on P-256
//      (`createECDH('prime256v1')`), HKDF-SHA256 (`hkdfSync`), AES-128-GCM (`createCipheriv`)
//      and ECDSA P-256 signing in the raw IEEE-P1363 form a JWT wants
//      (`sign(..., { dsaEncoding: 'ieee-p1363' })`). Verified on the Node in use, v25.5.0.
//   2. This repository is PUBLISHED. Every dependency is a supply-chain surface on a thing
//      the CEO installs on his own phone, and a probe that exists to answer one question
//      should not widen that surface to answer it.
//   3. The Mac side of the real phone client will do exactly this in Rust with `ring`
//      (plan §3.5 assumption 3, flagged `unverified:` there). Writing it out longhand once,
//      in a language where it is easy to read, is the cheapest way to de-risk that.
//
// So: `package.json` has an empty `dependencies` block, and that is deliberate.

const crypto = require('crypto');

// ---------------------------------------------------------------------------
// base64url — the only encoding either RFC uses
// ---------------------------------------------------------------------------

function b64url(buf) {
	return Buffer.from(buf).toString('base64').replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

function unb64url(str) {
	return Buffer.from(String(str).replace(/-/g, '+').replace(/_/g, '/'), 'base64');
}

// ---------------------------------------------------------------------------
// Keys
// ---------------------------------------------------------------------------

// A VAPID key pair, in the shape every browser API and every dashboard expects:
// the public key as the 65-byte uncompressed P-256 point, base64url.
function generateVapidKeys() {
	const ecdh = crypto.createECDH('prime256v1');
	ecdh.generateKeys();
	return {
		publicKey: b64url(ecdh.getPublicKey()),          // 65 bytes, 0x04 || X || Y
		privateKey: b64url(ecdh.getPrivateKey(null, 'buffer')) // 32-byte scalar
	};
}

// Node will sign with a KeyObject, not with a raw scalar, so the 32-byte private key and the
// 65-byte public point are reassembled into a JWK. `d`, `x` and `y` are each exactly 32 bytes;
// a short scalar is left-padded, because base64url of a 31-byte `d` is a key Node rejects.
function vapidPrivateKeyObject(publicKeyB64, privateKeyB64) {
	const pub = unb64url(publicKeyB64);
	const priv = unb64url(privateKeyB64);
	if (pub.length !== 65 || pub[0] !== 0x04) {
		throw new Error(`VAPID public key must be 65 bytes starting 0x04, got ${pub.length} bytes starting 0x${pub[0].toString(16)}`);
	}
	const d = Buffer.alloc(32);
	priv.copy(d, 32 - priv.length);
	return crypto.createPrivateKey({
		key: {
			kty: 'EC',
			crv: 'P-256',
			x: b64url(pub.subarray(1, 33)),
			y: b64url(pub.subarray(33, 65)),
			d: b64url(d)
		},
		format: 'jwk'
	});
}

// ---------------------------------------------------------------------------
// RFC 8292 — the VAPID Authorization header
// ---------------------------------------------------------------------------

// `aud` is the ORIGIN of the push endpoint, never the whole URL. Getting that wrong is the
// single most common VAPID mistake and it presents as a flat 401 from the push service.
function vapidAuthorizationHeader({ endpoint, subject, publicKey, privateKey, expirySeconds = 12 * 60 * 60 }) {
	const audience = new URL(endpoint).origin;
	const header = { typ: 'JWT', alg: 'ES256' };
	const payload = {
		aud: audience,
		exp: Math.floor(Date.now() / 1000) + expirySeconds,
		sub: subject
	};
	const signingInput = `${b64url(JSON.stringify(header))}.${b64url(JSON.stringify(payload))}`;
	// ES256 wants the raw 64-byte r||s pair. Node's default for EC is DER, which a JWT
	// verifier will reject, hence `ieee-p1363`.
	const signature = crypto.sign('sha256', Buffer.from(signingInput), {
		key: vapidPrivateKeyObject(publicKey, privateKey),
		dsaEncoding: 'ieee-p1363'
	});
	const jwt = `${signingInput}.${b64url(signature)}`;
	return `vapid t=${jwt}, k=${publicKey}`;
}

// ---------------------------------------------------------------------------
// RFC 8291 — encrypt a payload to a subscription
// ---------------------------------------------------------------------------

// `hkdfSync` returns an ArrayBuffer and performs extract-then-expand in one call, which is
// exactly the shape both RFCs use at every step.
function hkdf(salt, ikm, info, length) {
	return Buffer.from(crypto.hkdfSync('sha256', ikm, salt, info, length));
}

// `testVector` exists so RFC 8291 §5's own example can be reproduced byte for byte — the salt
// and the sender key pair are the only non-deterministic inputs, so pinning those two pins the
// whole output. Production never passes it. `test/webpush-kat.test.js` is the reason it is here.
function encryptPayload(plaintext, uaPublicKeyB64, authSecretB64, testVector) {
	const uaPublic = unb64url(uaPublicKeyB64);
	const authSecret = unb64url(authSecretB64);
	if (uaPublic.length !== 65 || uaPublic[0] !== 0x04) {
		throw new Error(`subscription p256dh must be a 65-byte uncompressed point, got ${uaPublic.length} bytes`);
	}
	if (authSecret.length !== 16) {
		throw new Error(`subscription auth must be 16 bytes, got ${authSecret.length}`);
	}

	// Our ephemeral key pair, fresh for every single message.
	const as = crypto.createECDH('prime256v1');
	if (testVector && testVector.asPrivateKey) {
		as.setPrivateKey(unb64url(testVector.asPrivateKey));
	} else {
		as.generateKeys();
	}
	const asPublic = as.getPublicKey(); // 65 bytes — travels in the header as the keyid
	const sharedSecret = as.computeSecret(uaPublic); // 32 bytes

	// RFC 8291 §3.3: the shared secret is combined with the subscription's auth secret
	// before anything else touches it.
	const keyInfo = Buffer.concat([
		Buffer.from('WebPush: info\0', 'utf8'),
		uaPublic,
		asPublic
	]);
	const ikm = hkdf(authSecret, sharedSecret, keyInfo, 32);

	// RFC 8188 §2.2/§2.3: content-encryption key and nonce, from a random 16-byte salt.
	const salt = testVector && testVector.salt ? unb64url(testVector.salt) : crypto.randomBytes(16);
	const cek = hkdf(salt, ikm, Buffer.from('Content-Encoding: aes128gcm\0', 'utf8'), 16);
	const nonce = hkdf(salt, ikm, Buffer.from('Content-Encoding: nonce\0', 'utf8'), 12);

	// One record, so the delimiter is 0x02 ("last record"). 0x01 here is the bug that makes a
	// payload decrypt to garbage on some clients and fail outright on others.
	const body = Buffer.concat([Buffer.from(plaintext, 'utf8'), Buffer.from([0x02])]);

	const cipher = crypto.createCipheriv('aes-128-gcm', cek, nonce);
	const ciphertext = Buffer.concat([cipher.update(body), cipher.final(), cipher.getAuthTag()]);

	// Record size must leave room for the whole record: plaintext + delimiter + 16-byte tag.
	const recordSize = Math.max(4096, body.length + 16);
	const rs = Buffer.alloc(4);
	rs.writeUInt32BE(recordSize, 0);

	// RFC 8188 §2.1 header: salt(16) | rs(4) | idlen(1) | keyid(65) | ciphertext
	return Buffer.concat([salt, rs, Buffer.from([asPublic.length]), asPublic, ciphertext]);
}

// ---------------------------------------------------------------------------
// Send
// ---------------------------------------------------------------------------

// `subscription` is the object `PushSubscription.toJSON()` produces, verbatim.
// Resolves with { statusCode, body, gone } — `gone` is true for the 404/410 that means the
// subscription has lapsed, which plan risk 2 says must be treated as a real event rather than
// swallowed.
async function sendNotification(subscription, payload, options) {
	const { vapidPublicKey, vapidPrivateKey, vapidSubject, ttl = 120, urgency = 'high', topic } = options;
	const endpoint = subscription.endpoint;

	const headers = {
		TTL: String(ttl),
		Urgency: urgency,
		Authorization: vapidAuthorizationHeader({
			endpoint,
			subject: vapidSubject,
			publicKey: vapidPublicKey,
			privateKey: vapidPrivateKey
		})
	};
	if (topic) headers.Topic = topic;

	let bodyBuffer = null;
	if (payload != null) {
		const plaintext = typeof payload === 'string' ? payload : JSON.stringify(payload);
		bodyBuffer = encryptPayload(plaintext, subscription.keys.p256dh, subscription.keys.auth);
		headers['Content-Encoding'] = 'aes128gcm';
		headers['Content-Type'] = 'application/octet-stream';
		headers['Content-Length'] = String(bodyBuffer.length);
	} else {
		headers['Content-Length'] = '0';
	}

	const response = await fetch(endpoint, { method: 'POST', headers, body: bodyBuffer });
	const text = await response.text().catch(() => '');
	return {
		statusCode: response.status,
		body: text,
		gone: response.status === 404 || response.status === 410
	};
}

module.exports = {
	b64url,
	unb64url,
	generateVapidKeys,
	vapidAuthorizationHeader,
	vapidPrivateKeyObject,
	encryptPayload,
	sendNotification
};
