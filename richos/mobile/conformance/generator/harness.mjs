// THE HARNESS: the real client modules, driven against a scripted Mac that records every byte.
//
// Nothing in the corpus is typed as an expected value. Each case is a script of what the Mac
// answers; the REAL `web/web-app/lib/*.js` and `mobile/core/*.js` modules decide what the phone
// sends and what it concludes; this file only records both. So a vector is what the shipped
// client does, by construction, and a change to a shipped module shows up as a `--check` diff.

import { createHash } from 'node:crypto';
import { createRequire } from 'node:module';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { signDeterministic, publicPoint } from './p256.mjs';

const here = dirname(fileURLToPath(import.meta.url));
export const RICHOS = join(here, '..', '..', '..');
const require = createRequire(import.meta.url);

/// The modules the corpus is generated from, by repository path. Read-only: loaded, never edited.
export const SOURCES = {
	api: 'richos/web/web-app/lib/api.js',
	queue: 'richos/web/web-app/lib/queue.js',
	thread: 'richos/web/web-app/lib/thread.js',
	inbound: 'richos/web/web-app/lib/inbound.js',
	fingerprint: 'richos/web/web-app/lib/fingerprint.js',
	wordlist: 'richos/web/web-app/lib/wordlist.js',
	pcm: 'richos/web/web-app/lib/pcm.js',
	client: 'richos/mobile/core/client.js',
	native: 'richos/mobile/platform/native.js'
};
export const load = (name) => require(join(RICHOS, '..', SOURCES[name]));

export const sha256 = (bytes) => createHash('sha256').update(bytes).digest();
export const sha256hex = (bytes) => sha256(bytes).toString('hex');
export const b64url = (bytes) => Buffer.from(bytes).toString('base64url');

// ---- the test-only device key ---------------------------------------------------------------

/// Derived from a published seed so anybody can re-derive it, and identical to the test key in
/// the fixtures of the 2026-09-22 phone protocol contract (kept in the private RichOS records).
export const KEY_SEED = 'richos-phone-protocol-test-device-key-v1';
export const PRIVATE_KEY = sha256(Buffer.from(KEY_SEED, 'utf8'));
export const POINT = publicPoint(PRIVATE_KEY);
export const DEVICE_ID = 'dev_' + sha256hex(POINT).slice(0, 12);

/// A second key, used only to make signatures the Mac must refuse.
export const OTHER_PRIVATE_KEY = sha256(Buffer.from('richos-phone-protocol-test-OTHER-key-v1', 'utf8'));

/// A challenge in the Mac's format: base64url of 24 bytes, 32 characters (`phone/device.rs`
/// `issue_challenge`). Derived from a label so every case names its own.
export const challenge = (label) => b64url(sha256(Buffer.from('challenge:' + label, 'utf8')).subarray(0, 24));

export const ORIGIN = 'https://mm1.tail1a2b3c.ts.net:8443';
export const CONNECT_ORIGIN = 'https://c-5de0dbe0862dd461ae305af5cef35202-g2.richos.ceo';

// ---- the signer port `api.js` asks for ------------------------------------------------------

export function makeSigner(privateKey = PRIVATE_KEY) {
	return {
		inputs: [],
		async sign(input) {
			this.inputs.push(input);
			return b64url(signDeterministic(privateKey, Buffer.from(input, 'utf8')));
		},
		async sha256Hex(payload) {
			return sha256hex(typeof payload === 'string' ? Buffer.from(payload, 'utf8') : Buffer.from(payload));
		}
	};
}

// ---- the scripted Mac -----------------------------------------------------------------------

/// One scripted answer. `transport: true` means the request never reached a Mac (fetch throws).
export function answer(status, body, headers = {}) {
	return { status, body, headers };
}
export const unreachable = () => ({ transport: true });

function bodyText(body) {
	if (body === undefined || body === null) return '';
	return typeof body === 'string' ? body : JSON.stringify(body);
}

/// A `fetch` that answers from `script` in order and records what it was sent.
export function scriptedFetch(script) {
	const sent = [];
	let at = 0;
	async function fetchImpl(url, init = {}) {
		const bytes = init.body === undefined || init.body === null ? null
			: typeof init.body === 'string' ? Buffer.from(init.body, 'utf8') : Buffer.from(init.body);
		sent.push({ url: String(url), method: init.method || 'GET', headers: { ...(init.headers || {}) }, bytes });
		const next = script[at++];
		if (!next) throw new Error(`the scripted Mac has no answer for request ${at}: ${init.method} ${url}`);
		if (next.transport) throw new TypeError('fetch failed');
		const text = bodyText(next.body);
		return new Response([204, 205, 304].includes(next.status) ? null : text, { status: next.status, headers: next.headers });
	}
	return { fetchImpl, sent, remaining: () => script.length - at };
}

/// An `EventSource` stand-in that records the URL it was opened with and lets a case push frames.
export function recordingEventSource() {
	const opened = [];
	class Recorded {
		constructor(url) { this.url = url; this.handlers = {}; opened.push(this); }
		addEventListener(name, fn) { (this.handlers[name] ||= []).push(fn); }
		emit(name, data) { for (const fn of this.handlers[name] || []) fn({ data: typeof data === 'string' ? data : JSON.stringify(data) }); }
		close() { this.closed = true; }
	}
	return { Recorded, opened };
}

// ---- turning what was recorded into the corpus's request shape -----------------------------

/// The request exactly as the reference put it on the wire, plus what its signature covers.
/// `signed` is null for an unsigned request (pairing, the challenge probe).
export function describeRequest(record, signingInput, base = ORIGIN) {
	if (!record.url.startsWith(base)) throw new Error(`request left the paired origin: ${record.url}`);
	const target = record.url.slice(base.length);
	const headers = {};
	for (const key of Object.keys(record.headers).sort()) headers[key] = record.headers[key];
	const out = { method: record.method, target, headers, body: describeBody(record.bytes, headers['Content-Type']) };
	let authorization = headers.Authorization || null;
	let credential = authorization ? 'header' : null;
	if (!authorization) {
		const query = target.split('?')[1] || '';
		const auth = query.split('&').find((p) => p.startsWith('auth='));
		if (auth) { authorization = decodeURIComponent(auth.slice(5)); credential = 'query'; }
	}
	if (!authorization) {
		if (signingInput !== undefined) throw new Error(`a signed request carried no credential: ${target}`);
		out.signed = null;
		return out;
	}
	const [, challengeValue, pathWithQuery, bodyHash] = signingInput.match(/^([^\n]*)\n[^\n]*\n([^\n]*)\n([^\n]*)$/) || [];
	const signature = authorization.slice(authorization.lastIndexOf('.') + 1);
	out.signed = {
		credential,
		challenge: challengeValue,
		path_with_query: pathWithQuery,
		body_sha256_hex: bodyHash,
		signing_string: signingInput,
		signature_b64url: signature,
		authorization
	};
	return out;
}

export function describeBody(bytes, contentType) {
	if (bytes === null) return null;
	const isText = !contentType || /json|text/.test(contentType);
	return isText ? { utf8: bytes.toString('utf8'), sha256_hex: sha256hex(bytes), length: bytes.length }
		: { base64: bytes.toString('base64'), sha256_hex: sha256hex(bytes), length: bytes.length };
}

/// `ApiError` (and the core's plain errors that carry the same fields) as data.
export function describeError(error) {
	if (!error) return null;
	return {
		reason: error.reason ?? null,
		status: error.status ?? null,
		retryable: error.retryable ?? null,
		about_this_message: error.aboutThisMessage ?? null
	};
}

/// A fresh API client over the real `api.js`, with the scripted Mac behind it.
export function makeApi({ script = [], state = {}, signer = makeSigner(), origin = ORIGIN, nativeClient = true, eventSource } = {}) {
	const { createApi } = load('api');
	const mac = scriptedFetch(script);
	const s = { apiBase: origin, deviceId: DEVICE_ID, challenge: challenge('initial'), ...state };
	const api = createApi({ state: s, signer, fetchImpl: mac.fetchImpl, origin, nativeClient, eventSourceImpl: eventSource });
	return { api, mac, signer, state: s };
}

/// Every request the scripted Mac saw, paired with the signing input the signer produced for it.
/// `api.js` signs exactly once per credentialed attempt, in order, so the two lists line up.
export function transcript(mac, signer, base = ORIGIN) {
	let s = 0;
	return mac.sent.map((record) => {
		const credentialed = Boolean(record.headers.Authorization) || /[?&]auth=/.test(record.url);
		return describeRequest(record, credentialed ? signer.inputs[s++] : undefined, base);
	});
}

/// A signed request for a route the reference client has no method for (attachments, the
/// Android confirmation). The canonical string is still the real `api.js` `signingInput`, the
/// query is built the way `api.js` builds every query (`URLSearchParams`), and the body hash is
/// the MAC's rule: empty when the body has no bytes, including a zero-length file (`api.js` would
/// hash those, and the Mac would refuse the signature; contract section 3.1).
export function signedRequest({ method, path, query = null, body = null, contentType = null, label }) {
	const { signingInput } = load('api');
	const c = challenge(label);
	const search = query ? '?' + new URLSearchParams(query).toString() : '';
	const target = path + search;
	const bytes = body === null ? null : typeof body === 'string' ? Buffer.from(body, 'utf8') : Buffer.from(body);
	const input = signingInput(c, method, target, bytes && bytes.length ? sha256hex(bytes) : '');
	const signature = b64url(signDeterministic(PRIVATE_KEY, Buffer.from(input, 'utf8')));
	const headers = { Authorization: `RichOS-Device ${DEVICE_ID}.${c}.${signature}` };
	if (contentType) headers['Content-Type'] = contentType;
	return describeRequest({ url: ORIGIN + target, method, headers, bytes }, input);
}

/// Run a promise that may reject with an ApiError, and describe the outcome.
export async function outcome(promise) {
	try {
		const value = await promise;
		return { ok: true, value: value === undefined ? null : value };
	} catch (error) {
		if (!error || error.reason === undefined) throw error;
		return { ok: false, error: describeError(error) };
	}
}
