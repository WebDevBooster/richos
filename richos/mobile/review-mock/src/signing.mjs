// THE DEVICE CREDENTIAL, exactly as the Mac checks it.
//
// Every function names the Mac function it restates. `test/conformance.test.mjs` runs the whole
// signing corpus (`vectors/signing.json`: valid, invalid and tolerated) through `verifySignature`
// and requires the verdict the Mac's production verifier gives for each case.

import { bytesOf, hex, sha256, sha256hex, unb64url, b64url } from './codec.mjs';

/**
 * `phone/device.rs` signing_string: the challenge, the method uppercased, the path and query as
 * sent minus `auth`, and the SHA-256 hex of the body bytes, or the EMPTY string for no body.
 * @param {string} challenge @param {string} method @param {string} pathWithQuery @param {string} bodyHashHex '' when the body is empty
 */
export function signingString(challenge, method, pathWithQuery, bodyHashHex) {
	return `${challenge}\n${String(method).toUpperCase()}\n${pathWithQuery}\n${bodyHashHex}`;
}

/** The body hash that goes into the signing string: '' for zero bytes (`device.rs`). */
export async function bodyHash(bytes) {
	return bytes && bytes.length ? sha256hex(bytes) : '';
}

/**
 * `phone/routes.rs` signed_path: the raw path plus every query parameter except `auth`, in the
 * order the caller sent them. `query` is the raw query string without `?`.
 */
export function signedPath(path, query) {
	if (!query) return path;
	const kept = query.split('&').filter((pair) => pair !== '' && pair.split('=')[0] !== 'auth');
	return kept.length ? `${path}?${kept.join('&')}` : path;
}

/** `phone/routes.rs` query_value: the first raw value for `name`, or null. */
export function queryValue(query, name) {
	for (const pair of (query || '').split('&')) {
		const at = pair.indexOf('=');
		if (at === -1) continue;
		if (pair.slice(0, at) === name) return pair.slice(at + 1);
	}
	return null;
}

/**
 * Percent-decode one query value where `+` also means a space (`routes.rs`
 * percent_decode_component). A malformed escape is left alone, as the Mac's `percent_decode` does.
 */
export function decodeComponent(value) {
	const spaced = value.replace(/\+/g, ' ');
	const out = [];
	const bytes = bytesOf(spaced);
	for (let i = 0; i < bytes.length; i++) {
		if (bytes[i] === 0x25 && i + 2 < bytes.length && /^[0-9a-fA-F]{2}$/.test(String.fromCharCode(bytes[i + 1], bytes[i + 2]))) {
			out.push(parseInt(String.fromCharCode(bytes[i + 1], bytes[i + 2]), 16));
			i += 2;
		} else {
			out.push(bytes[i]);
		}
	}
	return new TextDecoder().decode(new Uint8Array(out));
}

/**
 * `phone/device.rs` parse_authorization: `RichOS-Device <device_id>.<challenge>.<base64url sig>`,
 * split from the right twice. Returns null for anything else.
 */
export function parseAuthorization(header) {
	if (typeof header !== 'string' || !header.startsWith('RichOS-Device ')) return null;
	const rest = header.slice('RichOS-Device '.length);
	const lastDot = rest.lastIndexOf('.');
	if (lastDot === -1) return null;
	const head = rest.slice(0, lastDot), signature = rest.slice(lastDot + 1);
	const secondDot = head.lastIndexOf('.');
	if (secondDot === -1) return null;
	const deviceId = head.slice(0, secondDot), challenge = head.slice(secondDot + 1);
	if (!deviceId || !challenge) return null;
	let signatureBytes;
	try { signatureBytes = unb64url(signature); } catch { return null; }
	return { deviceId, challenge, signature: signatureBytes };
}

const SPKI_PREFIX = Uint8Array.from([
	0x30, 0x59, 0x30, 0x13, 0x06, 0x07, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02, 0x01, 0x06, 0x08, 0x2a,
	0x86, 0x48, 0xce, 0x3d, 0x03, 0x01, 0x07, 0x03, 0x42, 0x00
]);

/**
 * `phone/device.rs` PublicKeyForm::to_point: a P-256 JWK, or base64url of the 65-byte point or its
 * 91-byte SPKI wrapper, normalized to the 65-byte uncompressed point. Throws with the reason.
 * @param {{public_key_jwk?: any, public_key?: string}} body
 */
export function publicPointOf(body) {
	if (body.public_key_jwk !== undefined) {
		const jwk = body.public_key_jwk || {};
		if (jwk.kty !== 'EC' || jwk.crv !== 'P-256') throw new Error('a device key must be an EC P-256 JWK');
		if (typeof jwk.x !== 'string' || typeof jwk.y !== 'string') throw new Error('the JWK has no x or y');
		const x = unb64url(jwk.x), y = unb64url(jwk.y);
		if (x.length !== 32 || y.length !== 32) throw new Error("a P-256 JWK's x and y are 32 bytes each");
		const point = new Uint8Array(65);
		point[0] = 4; point.set(x, 1); point.set(y, 33);
		return point;
	}
	if (typeof body.public_key === 'string') {
		const bytes = unb64url(body.public_key);
		if (bytes.length === 65 && bytes[0] === 4) return bytes;
		if (bytes.length === 91 && SPKI_PREFIX.every((b, i) => bytes[i] === b) && bytes[26] === 4) return bytes.slice(26);
		throw new Error('a device key must be a 65-byte uncompressed P-256 point or its SPKI wrapper');
	}
	throw new Error('no public key');
}

/** `phone/device.rs` complete_pairing: `dev_` + hex of the first 6 bytes of SHA-256(point). */
export async function deviceIdOf(point) {
	return 'dev_' + hex((await sha256(point)).slice(0, 6));
}

/** Import a 65-byte point for verification; throws when it is not on the curve. */
export async function importPoint(point) {
	return crypto.subtle.importKey('raw', point, { name: 'ECDSA', namedCurve: 'P-256' }, false, ['verify']);
}

/**
 * `phone/device.rs` verify step 3: the raw 64-byte `r||s` signature over the exact signing string.
 * A DER signature (70-72 bytes) is refused, as `ECDSA_P256_SHA256_FIXED` refuses it. High-S is
 * accepted, as the Mac accepts it.
 */
export async function verifySignature(pointB64url, message, signature) {
	if (!(signature instanceof Uint8Array) || signature.length !== 64) return false;
	try {
		const key = await importPoint(unb64url(pointB64url));
		return await crypto.subtle.verify({ name: 'ECDSA', hash: 'SHA-256' }, key, signature, bytesOf(message));
	} catch {
		return false;
	}
}

export { b64url };
