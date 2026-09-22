// signing.json: request canonicalization and raw 64-byte signatures, valid and invalid.
//
// Every VALID request below is what the real `api.js` put on the wire for one call. Every
// INVALID request is one of those, changed in exactly one way that a native client could
// plausibly get wrong, and re-signed (or not) accordingly. `mac` is the verdict the Mac's
// verifier must give: `verifier/tests/corpus.rs` runs the production Rust code over every one.

import { createPublicKey, verify } from 'node:crypto';
import { signDeterministic, rawToDer, highS } from './p256.mjs';
import {
	load, makeApi, answer, transcript, describeRequest, sha256hex, b64url, challenge,
	PRIVATE_KEY, OTHER_PRIVATE_KEY, POINT, DEVICE_ID, ORIGIN
} from './harness.mjs';

const KEY = createPublicKey({ key: { kty: 'EC', crv: 'P-256', x: b64url(POINT.subarray(1, 33)), y: b64url(POINT.subarray(33)) }, format: 'jwk' });

export function nodeVerifies(signingString, signatureB64url) {
	const sig = Buffer.from(signatureB64url.replace(/=+$/, ''), 'base64url');
	if (sig.length !== 64) return false;
	return verify('sha256', Buffer.from(signingString, 'utf8'), { key: KEY, dsaEncoding: 'ieee-p1363' }, sig);
}

const ok = { 'Content-Type': 'application/json; charset=utf-8' };
const json = (body, c) => answer(200, body, { ...ok, 'X-RichOS-Challenge': c });

/// One call through the real client, returning the one request it made.
async function capture(name, call, reply = {}) {
	const c = challenge(name);
	const { api, mac, signer } = makeApi({ script: [json(reply, c)], state: { challenge: c } });
	await call(api);
	const [request] = transcript(mac, signer);
	return { name, request };
}

async function captureStream(name, threadId, since) {
	const c = challenge(name);
	const opened = [];
	class Source { constructor(url) { opened.push(url); } addEventListener() {} close() {} }
	const { api, signer } = makeApi({ state: { challenge: c }, eventSource: Source });
	await api.openEvents(threadId, since, {});
	const record = { url: opened[0], method: 'GET', headers: {}, bytes: null };
	return { name, request: describeRequest(record, signer.inputs[0]) };
}

export async function validCases() {
	const text = (id, t, thread = 'thr_5c1e') => ({ clientId: id, threadId: thread, text: t, sentAt: '2026-09-22T13:00:00.000Z' });
	const wav = Buffer.from(new Uint8Array(load('pcm').encodeWav(Float32Array.from({ length: 160 }, (_, i) => Math.sin(i / 4) * 0.25), 16000)));
	return [
		await capture('text message', (api) => api.sendText(text('01J8CONFORMANCE000000000001', 'where are we on the proposal?'))),
		await capture('text with non-ASCII, quotes and a newline (UTF-8 bytes are hashed)', (api) => api.sendText(text('01J8CONFORMANCE000000000002', 'Café “naïve” 🚀\nsecond line with a \\ backslash'))),
		await capture('text with no thread_id (the Mac uses its active thread)', (api) => api.sendText({ clientId: '01J8CONFORMANCE000000000003', text: 'no thread', sentAt: '2026-09-22T13:00:01.000Z' })),
		await capture('voice message (WAV bytes, metadata in the signed query)', (api) => api.sendVoice({ clientId: '01J8CONFORMANCEVOICE0000001', threadId: 'thr_5c1e', bytes: wav, seconds: 0.01, sentAt: '2026-09-22T13:00:02.000Z' })),
		await captureStream('event stream, first connect (no since)', 'thr_5c1e', null),
		await captureStream('event stream, reconnect with since', 'thr_5c1e', 41),
		await capture('backfill (query credential, same route as the stream)', (api) => api.backfill('thr_5c1e', 41, 50), { messages: [], more: false }),
		await capture('revocation probe after a stream error', (api) => api.backfill('thr_5c1e', 0, 1), { messages: [], more: false }),
		await capture('audio fetch, id percent-encoded in the signed path', (api) => api.fetchAudio('turn_9:text:0', 'thr_5c1e')),
		await capture('six words confirmed (native client adds push_transport)', (api) => api.confirmFingerprint(true), { ok: true }),
		await capture('six words refused', (api) => api.confirmFingerprint(false), { ok: true }),
		await capture('native push registration (APNs shape today)', (api) => api.registerNativePush({ token: 'ab'.repeat(32), environment: 'sandbox', topic: 'dev.richos.mobile.loop', preview_key: b64url(Buffer.alloc(32, 7)), previews: true }), { host_id: '0'.repeat(32), registered: true }),
		await capture('native push unregistration', (api) => api.registerNativePush(null), { host_id: null, registered: false }),
		await capture('reply receipt', (api) => api.replySeen('thr_5c1e', 'turn_9:text:0'), { ok: true })
	];
}

function resign(request, signingString, privateKey = PRIVATE_KEY, encode = (raw) => b64url(raw)) {
	const signature = encode(signDeterministic(privateKey, Buffer.from(signingString, 'utf8')));
	return withSignature(request, signingString, signature);
}

function withSignature(request, signingString, signature, challengeInAuth = request.signed.challenge) {
	const authorization = `RichOS-Device ${DEVICE_ID}.${challengeInAuth}.${signature}`;
	const out = structuredClone(request);
	out.signed = { ...out.signed, signing_string: signingString, signature_b64url: signature, authorization };
	if (out.signed.credential === 'header') out.headers.Authorization = authorization;
	else out.target = out.target.replace(/auth=[^&]*$/, 'auth=' + encodeURIComponent(authorization));
	return out;
}

const lines = (s) => s.split('\n');
const joined = (parts) => parts.join('\n');

/// The mutations. Each takes a valid request and returns the request a mistaken client sends.
export function invalidCases(valid) {
	const byName = Object.fromEntries(valid.map((v) => [v.name, v.request]));
	const textPost = byName['text message'];
	const stream = byName['event stream, reconnect with since'];
	const audio = byName['audio fetch, id percent-encoded in the signed path'];
	const flip = (sig) => { const b = Buffer.from(sig, 'base64url'); b[10] ^= 0x01; return b64url(b); };
	const cases = [
		['DER-encoded signature (Android SHA256withECDSA and iOS SecKeyCreateSignature output, not converted to raw r||s)',
			resign(textPost, textPost.signed.signing_string, PRIVATE_KEY, (raw) => b64url(rawToDer(raw)))],
		['one bit of the signature flipped', withSignature(textPost, textPost.signed.signing_string, flip(textPost.signed.signature_b64url))],
		['signature truncated to 63 bytes', withSignature(textPost, textPost.signed.signing_string, b64url(Buffer.from(textPost.signed.signature_b64url, 'base64url').subarray(0, 63)))],
		['signed with a different key under this device id', resign(textPost, textPost.signed.signing_string, OTHER_PRIVATE_KEY)],
		['method signed in lowercase', resign(textPost, joined([lines(textPost.signed.signing_string)[0], 'post', ...lines(textPost.signed.signing_string).slice(2)]))],
		['body changed after signing (the retry-must-resend-the-same-bytes trap)', (() => {
			const out = structuredClone(textPost);
			const utf8 = out.body.utf8.replace('proposal', 'proposal!');
			out.body = { utf8, sha256_hex: sha256hex(Buffer.from(utf8)), length: Buffer.byteLength(utf8) };
			return out;
		})()],
		['GET signed with SHA-256 of zero bytes instead of an empty fourth line', resign(stream, joined([...lines(stream.signed.signing_string).slice(0, 3), sha256hex(Buffer.alloc(0))]))],
		['stream signed with the auth parameter still in the path', resign(stream, joined([lines(stream.signed.signing_string)[0], 'GET', stream.target.replace(/auth=[^&]*$/, 'auth='), '']))],
		['audio id signed decoded instead of as sent on the wire', resign(audio, joined([lines(audio.signed.signing_string)[0], 'GET', decodeURIComponent(audio.signed.path_with_query), '']))],
		['credential names a different challenge than the one signed', withSignature(textPost, textPost.signed.signing_string, textPost.signed.signature_b64url, challenge('some other live challenge'))]
	];
	return cases.map(([name, request]) => ({ name, request }));
}

/// Encodings the Mac accepts that a strict client might not produce. Recorded so a native
/// verifier in a test double does not refuse what the real Mac takes.
export function tolerated(valid) {
	const textPost = valid.find((v) => v.name === 'text message').request;
	const raw = Buffer.from(textPost.signed.signature_b64url, 'base64url');
	return [
		{ name: 'high-S form of a valid signature (s replaced by n - s)', request: withSignature(textPost, textPost.signed.signing_string, b64url(highS(raw))) },
		{ name: 'base64url signature with = padding', request: withSignature(textPost, textPost.signed.signing_string, textPost.signed.signature_b64url + '=') }
	];
}

/// What the MAC will compute for this request, read the way `phone/routes.rs` reads it: the
/// challenge from the credential, the method uppercased, the path as sent minus `auth`
/// (`signed_path`), and the body hash of the bytes actually sent ('' for no bytes).
export function macSigningString(request) {
	const auth = request.signed.authorization;
	const head = auth.slice('RichOS-Device '.length, auth.lastIndexOf('.'));
	const challengeValue = head.slice(head.lastIndexOf('.') + 1);
	const q = request.target.indexOf('?');
	const path = q === -1 ? request.target : request.target.slice(0, q);
	const query = q === -1 ? '' : request.target.slice(q + 1);
	const kept = query.split('&').filter((p) => p && p.split('=')[0] !== 'auth');
	const signedPath = kept.length ? `${path}?${kept.join('&')}` : path;
	const bytes = bodyBytes(request.body);
	return `${challengeValue}\n${request.method.toUpperCase()}\n${signedPath}\n${bytes.length ? sha256hex(bytes) : ''}`;
}

export function bodyBytes(body) {
	if (!body) return Buffer.alloc(0);
	return body.utf8 !== undefined ? Buffer.from(body.utf8, 'utf8') : Buffer.from(body.base64, 'base64');
}

/// The verdict the Mac's verifier gives, assuming the challenge the credential names is live:
/// `verifier/tests/corpus.rs` issues exactly that challenge and then runs the production code.
export function mac(request) {
	const signingString = macSigningString(request);
	return nodeVerifies(signingString, request.signed.signature_b64url)
		? { signing_string: signingString, verdict: 'accepted' }
		: { signing_string: signingString, verdict: 'refused', refusal: 'BadSignature' };
}
