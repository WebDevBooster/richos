// Byte helpers shared by every module. WebCrypto only, so the same code runs in workerd and Node.

const utf8 = new TextEncoder();

/** @param {string|Uint8Array|ArrayBuffer} value @returns {Uint8Array} */
export function bytesOf(value) {
	if (typeof value === 'string') return utf8.encode(value);
	if (value instanceof Uint8Array) return value;
	if (value instanceof ArrayBuffer) return new Uint8Array(value);
	throw new TypeError('expected a string or bytes');
}

/** Lowercase hexadecimal of `bytes`. */
export function hex(bytes) {
	return Array.from(bytesOf(bytes), (b) => b.toString(16).padStart(2, '0')).join('');
}

/** SHA-256 of `value` as raw bytes. */
export async function sha256(value) {
	return new Uint8Array(await crypto.subtle.digest('SHA-256', bytesOf(value)));
}

/** SHA-256 of `value` as lowercase hexadecimal. */
export async function sha256hex(value) {
	return hex(await sha256(value));
}

/** base64url with no padding. */
export function b64url(bytes) {
	let binary = '';
	for (const b of bytesOf(bytes)) binary += String.fromCharCode(b);
	return btoa(binary).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

/**
 * Decode base64url, tolerating `=` padding exactly as the Mac does (`phone/mod.rs` unb64url trims
 * trailing `=` and decodes URL-safe without padding). Anything else throws.
 */
export function unb64url(text) {
	if (typeof text !== 'string') throw new Error('not base64url');
	const trimmed = text.replace(/=+$/, '');
	if (!/^[A-Za-z0-9_-]*$/.test(trimmed) || trimmed.length % 4 === 1) throw new Error('not base64url');
	const binary = atob(trimmed.replace(/-/g, '+').replace(/_/g, '/'));
	return Uint8Array.from(binary, (c) => c.charCodeAt(0));
}

/** Constant-time comparison of two strings of possibly different length. */
export function sameString(a, b) {
	const x = bytesOf(String(a)), y = bytesOf(String(b));
	let diff = x.length ^ y.length;
	for (let i = 0; i < Math.max(x.length, y.length); i++) diff |= (x[i] ?? 0) ^ (y[i] ?? 0);
	return diff === 0;
}

/** `count` cryptographically random bytes. */
export function randomBytes(count) {
	return crypto.getRandomValues(new Uint8Array(count));
}

/** Concatenate byte arrays. */
export function concat(...parts) {
	const out = new Uint8Array(parts.reduce((n, p) => n + p.length, 0));
	let at = 0;
	for (const p of parts) { out.set(p, at); at += p.length; }
	return out;
}

/** The Mac's timestamp format (`phone/rows.rs` iso8601): milliseconds, `Z`. */
export function iso8601(ms) {
	return new Date(ms).toISOString();
}
