// THE REVIEW CREDENTIALS: one reusable username and password for the access page, checked
// against a PBKDF2 hash, and a signed session cookie. The password itself never reaches the Worker;
// only `REVIEW_PASSWORD_HASH` does, and the plaintext lives in the operator's protected file for
// pasting into App Store Connect and Play Console review notes.

import { b64url, bytesOf, randomBytes, sameString, unb64url } from './codec.mjs';

/** Cloudflare Workers cap PBKDF2 at 100,000 iterations; the hash uses exactly that. */
export const PBKDF2_ITERATIONS = 100_000;
/** A session lasts 12 hours; a reviewer signs in again after that with the same credentials. */
export const SESSION_TTL_MS = 12 * 3_600_000;
export const COOKIE = '__Host-richconnect-review';

async function derive(password, salt, iterations) {
	const key = await crypto.subtle.importKey('raw', bytesOf(password), 'PBKDF2', false, ['deriveBits']);
	return new Uint8Array(await crypto.subtle.deriveBits({ name: 'PBKDF2', hash: 'SHA-256', salt, iterations }, key, 256));
}

/** `pbkdf2-sha256$<iterations>$<salt>$<hash>`, both base64url. */
export async function hashPassword(password, { salt = randomBytes(16), iterations = PBKDF2_ITERATIONS } = {}) {
	return `pbkdf2-sha256$${iterations}$${b64url(salt)}$${b64url(await derive(password, salt, iterations))}`;
}

/** Constant-time check of `password` against a stored hash. A malformed hash never matches. */
export async function verifyPassword(password, stored) {
	const parts = String(stored || '').split('$');
	if (parts.length !== 4 || parts[0] !== 'pbkdf2-sha256') return false;
	const iterations = Number(parts[1]);
	if (!Number.isInteger(iterations) || iterations < 10_000 || iterations > PBKDF2_ITERATIONS) return false;
	let salt, expected;
	try { salt = unb64url(parts[2]); expected = parts[3]; } catch { return false; }
	return sameString(b64url(await derive(String(password), salt, iterations)), expected);
}

async function hmac(keyB64url, text) {
	const key = await crypto.subtle.importKey('raw', unb64url(keyB64url), { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']);
	return b64url(new Uint8Array(await crypto.subtle.sign('HMAC', key, bytesOf(text))));
}

/**
 * A session value: `v1.<expires>.<subject>.<nonce>.<mac>`. `subject` is the reviewer username the
 * session belongs to (`[a-z0-9-]`), which decides the one review host the session can manage.
 */
export async function issueSession(keyB64url, now, subject) {
	if (!/^[a-z0-9-]{1,40}$/.test(subject)) throw new Error('invalid session subject');
	const payload = `v1.${now + SESSION_TTL_MS}.${subject}.${b64url(randomBytes(12))}`;
	return `${payload}.${await hmac(keyB64url, payload)}`;
}

/** Read the session cookie out of a `Cookie` header: the subject when authentic and unexpired, else null. */
export async function checkSession(cookieHeader, keyB64url, now) {
	const value = String(cookieHeader || '').split(/;\s*/).map((c) => c.split('=')).find(([name]) => name === COOKIE)?.slice(1).join('=');
	if (!value) return null;
	const parts = value.split('.');
	if (parts.length !== 5 || parts[0] !== 'v1' || !/^[a-z0-9-]{1,40}$/.test(parts[2])) return null;
	const expires = Number(parts[1]);
	if (!Number.isSafeInteger(expires) || expires <= now || expires > now + SESSION_TTL_MS) return null;
	try {
		return sameString(await hmac(keyB64url, parts.slice(0, 4).join('.')), parts[4]) ? parts[2] : null;
	} catch {
		return null;
	}
}

export function sessionCookie(value) {
	return `${COOKIE}=${value}; Path=/; Secure; HttpOnly; SameSite=Strict; Max-Age=${SESSION_TTL_MS / 1000}`;
}

export function clearedCookie() {
	return `${COOKIE}=; Path=/; Secure; HttpOnly; SameSite=Strict; Max-Age=0`;
}
