// Test doubles for the review host: Durable Object storage in memory, a controllable clock, the
// conformance corpus's published TEST-ONLY device key, and a signed phone that speaks to a host.

import { readFileSync } from 'node:fs';
import { createPrivateKey, createPublicKey, sign as nodeSign, generateKeyPairSync } from 'node:crypto';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { Host } from '../src/host.mjs';
import { handlePhoneRequest } from '../src/phone.mjs';
import { signingString } from '../src/signing.mjs';

const here = dirname(fileURLToPath(import.meta.url));
export const MOBILE = join(here, '..', '..');
export const VECTORS = join(MOBILE, 'conformance', 'vectors');
export const vector = (name) => JSON.parse(readFileSync(join(VECTORS, name), 'utf8'));

/** Durable Object storage, in memory. Values are cloned in and out, as the real store serializes them. */
export function memoryStorage() {
	const map = new Map();
	let alarm = null;
	return {
		map,
		async get(key) { return map.has(key) ? structuredClone(map.get(key)) : undefined; },
		async put(key, value) { map.set(key, structuredClone(value)); },
		async delete(key) { return map.delete(key); },
		async list({ prefix = '' } = {}) {
			return new Map([...map].filter(([k]) => k.startsWith(prefix)).sort(([a], [b]) => (a < b ? -1 : 1)).map(([k, v]) => [k, structuredClone(v)]));
		},
		async getAlarm() { return alarm; },
		async setAlarm(at) { alarm = at; },
		async deleteAlarm() { alarm = null; },
		get alarm() { return alarm; }
	};
}

export function clock(start = 1_790_000_000_000) {
	let t = start;
	const now = () => t;
	now.advance = (ms) => { t += ms; };
	now.set = (ms) => { t = ms; };
	return now;
}

export const ORIGIN_OF = (hostname) => `https://${hostname}`;

/** A host with in-memory ports. `wakes` records every alarm the host asked for. */
export function makeHost({ hostname = 'review-a.example.com', now = clock(), push = null, pairingVersion = 1, storage = memoryStorage() } = {}) {
	const wakes = [];
	const host = new Host({ storage, hostname, now, push, pairingVersion, schedule: (at) => { wakes.push(at); }, sleep: async () => {} });
	return { host, storage, now, wakes };
}

// ---- keys ----------------------------------------------------------------------------------

/** The corpus's published TEST-ONLY key (`vectors/keys.json`), as a Node signing key. */
export function corpusKey() {
	const keys = vector('keys.json');
	const jwk = { ...keys.public_key_jwk, d: Buffer.from(keys.test_only_private_scalar_hex, 'hex').toString('base64url') };
	return { privateKey: createPrivateKey({ key: jwk, format: 'jwk' }), jwk: keys.public_key_jwk, deviceId: keys.device_id };
}

/** A fresh phone key, like a phone's Keystore or Secure Enclave key. */
export function freshKey() {
	const { privateKey, publicKey } = generateKeyPairSync('ec', { namedCurve: 'P-256' });
	const jwk = publicKey.export({ format: 'jwk' });
	return { privateKey, jwk: { kty: 'EC', crv: 'P-256', x: jwk.x, y: jwk.y } };
}

export function signRaw(privateKey, text) {
	return nodeSign('sha256', Buffer.from(text, 'utf8'), { key: privateKey, dsaEncoding: 'ieee-p1363' }).toString('base64url');
}

// ---- a phone -------------------------------------------------------------------------------

import { createHash } from 'node:crypto';
const sha256hex = (bytes) => createHash('sha256').update(bytes).digest('hex');

/**
 * A minimal phone: pairs, then signs requests exactly as the contract says (challenge from the
 * last response, method, path with query minus auth, SHA-256 of the body or '' for none).
 */
export class Phone {
	constructor(host, key = freshKey(), name = 'Test iPhone') {
		this.host = host;
		this.key = key;
		this.name = name;
		this.origin = host.origin;
		this.deviceId = null;
		this.challenge = null;
	}

	async fetch(target, { method = 'GET', headers = {}, body = null } = {}) {
		const response = await handlePhoneRequest(this.host, new Request(this.origin + target, { method, headers, body }));
		const next = response.headers.get('x-richos-challenge');
		if (next) this.challenge = next;
		return response;
	}

	authorization(method, pathWithQuery, bytes) {
		const input = signingString(this.challenge, method, pathWithQuery, bytes && bytes.length ? sha256hex(bytes) : '');
		return `RichOS-Device ${this.deviceId}.${this.challenge}.${signRaw(this.key.privateKey, input)}`;
	}

	/** A signed request with the credential in the header. `body` is a string, bytes or an object. */
	async signed(method, target, body = null, contentType = 'application/json') {
		const bytes = body === null ? null : typeof body === 'string' ? Buffer.from(body) : body instanceof Uint8Array ? Buffer.from(body) : Buffer.from(JSON.stringify(body));
		const headers = { authorization: this.authorization(method, target, bytes) };
		if (bytes) headers['content-type'] = contentType;
		return this.fetch(target, { method, headers, body: bytes });
	}

	/** GET /api/events with the credential as the last query parameter. */
	async events(query = '') {
		const target = '/api/events' + (query ? `?${query}` : '');
		const auth = encodeURIComponent(this.authorization('GET', target, null));
		return this.fetch(`${target}${query ? '&' : '?'}auth=${auth}`);
	}

	async pair(code, extra = {}) {
		const response = await this.fetch('/api/pair', { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ code, public_key_jwk: this.key.jwk, device_name: this.name, ...extra }) });
		if (response.status === 200) {
			const answer = await response.clone().json();
			this.deviceId = answer.device_id;
			this.challenge = answer.challenge;
		}
		return response;
	}

	confirmOnPhone(match = true, transport = 'apns') {
		return this.signed('POST', '/api/pair', { device_id: this.deviceId, fingerprint_confirmed: match, ...(match ? { push_transport: transport } : {}) });
	}
}

/** Pair a new phone with `host` and confirm it on the phone and on the Mac (the access page). */
export async function pairedPhone(host, key, name) {
	const phone = new Phone(host, key, name);
	const { code } = await host.openPairing();
	const answer = await phone.pair(code);
	if (answer.status !== 200) throw new Error(`pairing failed: ${answer.status}`);
	await phone.confirmOnPhone(true);
	await host.confirmOnMac(true);
	return phone;
}

/** Read an SSE body until `until(text)` or `limit` reads. */
export async function readStream(response, until, limit = 200) {
	const reader = response.body.getReader();
	const decoder = new TextDecoder();
	let text = '';
	for (let i = 0; i < limit && !until(text); i++) {
		const { value, done } = await reader.read();
		if (done) break;
		text += decoder.decode(value, { stream: true });
	}
	return { text, reader };
}
