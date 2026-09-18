'use strict';

// The route module, against a fake Mac. `node --test "test/*.test.js"`.
//
// Two things are being held still here, and both of them are things the Mac side has to match:
//
//   1. THE EXACT BYTES THAT GET SIGNED. If the Mac builds that string with a different separator or
//      a different order, every request fails authentication and both sides are certain they are
//      right. So the string is asserted literally, and a real P-256 signature over it is verified
//      with `node:crypto` — the same curve and hash the phone's WebCrypto uses.
//   2. THE FAILURE CLASSIFICATION. The send queue's honesty rests on it: unreachable is worth
//      retrying, a revoked device is final, a flat 404 is an answer. A test that only checked "it
//      threw" would let a revoked phone retry forever against a Mac that has forgotten it.
//
// And the seam from plan §10.7: the API base is read at every request, so changing it changes where
// the next request goes without touching the origin the app was installed from.

const test = require('node:test');
const assert = require('node:assert');
const crypto = require('node:crypto');

const { createApi, ApiError, signingInput, UNREACHABLE, REVOKED, REFUSED, FAULT } = require('../lib/api.js');

// A signer in the shape the browser provides over WebCrypto, implemented here over node:crypto so
// the signature this test verifies is a real ECDSA P-256 signature rather than a stub.
function makeSigner(deviceId) {
	const { privateKey, publicKey } = crypto.generateKeyPairSync('ec', { namedCurve: 'prime256v1' });
	return {
		deviceId,
		publicKey,
		signed: [],
		async sign(input) {
			this.signed.push(input);
			const sig = crypto.sign('sha256', Buffer.from(input, 'utf8'), { key: privateKey, dsaEncoding: 'ieee-p1363' });
			return sig.toString('base64url');
		},
		async sha256Hex(payload) {
			const bytes = typeof payload === 'string' ? Buffer.from(payload, 'utf8') : Buffer.from(payload);
			return crypto.createHash('sha256').update(bytes).digest('hex');
		}
	};
}

function response(status, body, headers) {
	const text = typeof body === 'string' ? body : JSON.stringify(body === undefined ? {} : body);
	const h = new Map(Object.entries(headers || {}));
	const make = () => ({
		status,
		ok: status >= 200 && status < 300,
		headers: { get: (k) => (h.has(k) ? h.get(k) : null) },
		text: async () => text,
		json: async () => JSON.parse(text),
		clone: () => make(),
		blob: async () => ({ size: text.length, type: 'audio/wav' })
	});
	return make();
}

function makeApi(handler, initial) {
	const calls = [];
	const signer = makeSigner('device-1');
	const state = Object.assign({ apiBase: 'https://mm1.local:8443', challenge: 'challenge-one', deviceId: 'device-1' }, initial || {});
	const api = createApi({
		state,
		signer,
		fetchImpl: async (url, init) => {
			calls.push({ url, init });
			return handler(url, init, calls.length);
		},
		eventSourceImpl: null
	});
	return { api, calls, signer, state };
}

test('the string that gets signed is the documented one, exactly', () => {
	assert.strictEqual(
		signingInput('chal', 'post', '/api/messages', 'abc123'),
		'chal\nPOST\n/api/messages\nabc123'
	);
	// An empty body signs an empty hash rather than the word "null" or the string "undefined".
	assert.strictEqual(signingInput('chal', 'GET', '/api/events?x=1', ''), 'chal\nGET\n/api/events?x=1\n');
});

test('a text send carries a real P-256 signature over that string, and the body hash is of the body', async () => {
	const { api, calls, signer } = makeApi(() => response(200, { message_id: 'm1', cursor: 7 }));
	const result = await api.sendText({ clientId: 'c-1', threadId: 't-1', text: 'where are we on the proposal?', sentAt: '2026-09-18T10:00:00Z' });
	assert.strictEqual(result.cursor, 7);

	const sent = calls[0];
	const body = sent.init.body;
	assert.strictEqual(JSON.parse(body).client_id, 'c-1');
	assert.strictEqual(JSON.parse(body).kind, 'text');

	const expectedHash = crypto.createHash('sha256').update(body).digest('hex');
	const expectedInput = `challenge-one\nPOST\n/api/messages\n${expectedHash}`;
	assert.deepStrictEqual(signer.signed, [expectedInput]);

	const [, , signature] = sent.init.headers.Authorization.replace('RichOS-Device ', '').split('.');
	const ok = crypto.verify('sha256', Buffer.from(expectedInput, 'utf8'),
		{ key: signer.publicKey, dsaEncoding: 'ieee-p1363' }, Buffer.from(signature, 'base64url'));
	assert.ok(ok, 'the signature on the wire does not verify against the device key');
});

test('a voice note goes as bytes, with the codec and the rate named in the query', async () => {
	const { api, calls } = makeApi(() => response(200, { message_id: 'm2', cursor: 8 }));
	const bytes = new Uint8Array([0x52, 0x49, 0x46, 0x46, 1, 2, 3, 4]);
	await api.sendVoice({ clientId: 'c-2', threadId: 't-1', bytes, seconds: 2.5, sentAt: '2026-09-18T10:01:00Z' });

	const url = new URL(calls[0].url);
	assert.strictEqual(url.pathname, '/api/messages');
	assert.strictEqual(url.searchParams.get('kind'), 'voice');
	assert.strictEqual(url.searchParams.get('codec'), 'wav16k');
	assert.strictEqual(url.searchParams.get('sample_rate'), '16000');
	assert.strictEqual(url.searchParams.get('seconds'), '2.5');
	assert.strictEqual(calls[0].init.headers['Content-Type'], 'audio/wav');
	assert.strictEqual(calls[0].init.body, bytes, 'the WAV was re-encoded instead of being sent as bytes');
});

test('the API base is DATA: changing it changes where the next request goes, and the origin is untouched', async () => {
	const { api, calls } = makeApi(() => response(200, { message_id: 'm', cursor: 1 }));
	await api.sendText({ clientId: 'c-3', threadId: 't-1', text: 'at home', sentAt: 'now' });
	assert.ok(calls[0].url.startsWith('https://mm1.local:8443/'), calls[0].url);

	api.setApiBase('https://198.51.100.7:8443');
	await api.sendText({ clientId: 'c-4', threadId: 't-1', text: 'from away', sentAt: 'now' });
	assert.ok(calls[1].url.startsWith('https://198.51.100.7:8443/'), calls[1].url);
});

test('a fresh challenge in a response header is picked up for the next request', async () => {
	const { api, signer } = makeApi((url, init, n) => response(200, { message_id: `m${n}`, cursor: n },
		{ 'X-RichOS-Challenge': `challenge-${n + 1}` }));
	await api.sendText({ clientId: 'c-5', threadId: 't', text: 'one', sentAt: 'now' });
	await api.sendText({ clientId: 'c-6', threadId: 't', text: 'two', sentAt: 'now' });
	assert.ok(signer.signed[0].startsWith('challenge-one\n'), signer.signed[0]);
	assert.ok(signer.signed[1].startsWith('challenge-2\n'), signer.signed[1]);
});

test('a fetch that throws is UNREACHABLE and is worth retrying — this is the queue\'s whole basis', async () => {
	const { api } = makeApi(() => { throw new TypeError('Load failed'); });
	await assert.rejects(
		() => api.sendText({ clientId: 'c-7', threadId: 't', text: 'x', sentAt: 'now' }),
		(err) => {
			assert.ok(err instanceof ApiError);
			assert.strictEqual(err.reason, UNREACHABLE);
			assert.strictEqual(err.retryable, true);
			return true;
		}
	);
});

test('a forgotten phone is REVOKED and is never retried', async () => {
	const { api } = makeApi(() => response(403, { revoked: true }));
	await assert.rejects(
		() => api.sendText({ clientId: 'c-8', threadId: 't', text: 'x', sentAt: 'now' }),
		(err) => {
			assert.strictEqual(err.reason, REVOKED);
			assert.strictEqual(err.retryable, false);
			return true;
		}
	);
});

test('the flat 404 an unauthorized caller gets is an answer, not an outage', async () => {
	const { api } = makeApi(() => response(404, 'Not Found'));
	await assert.rejects(
		() => api.sendText({ clientId: 'c-9', threadId: 't', text: 'x', sentAt: 'now' }),
		(err) => {
			assert.strictEqual(err.reason, REFUSED);
			assert.strictEqual(err.retryable, false);
			return true;
		}
	);
});

test('a 500 is a fault, and a fault is worth one more try', async () => {
	const { api } = makeApi(() => response(500, 'boom'));
	await assert.rejects(
		() => api.sendText({ clientId: 'c-10', threadId: 't', text: 'x', sentAt: 'now' }),
		(err) => {
			assert.strictEqual(err.reason, FAULT);
			assert.strictEqual(err.retryable, true);
			assert.strictEqual(err.status, 500);
			return true;
		}
	);
});

test('pairing stores the device and the first challenge, and needs no signature of its own', async () => {
	const { api, calls, signer, state } = makeApi(() => response(200, {
		device_id: 'device-9',
		ca_fingerprint_sha256: 'a'.repeat(64),
		challenge: 'first-challenge',
		api_base: 'https://mm1.local:8443',
		vapid_public_key: 'BPk…'
	}), { deviceId: null, challenge: null });

	const body = await api.pair('one-shot-code', { kty: 'EC', crv: 'P-256' }, 'iPhone');
	assert.strictEqual(body.device_id, 'device-9');
	assert.strictEqual(state.deviceId, 'device-9');
	assert.strictEqual(state.challenge, 'first-challenge');
	assert.strictEqual(calls[0].init.headers.Authorization, undefined, 'pairing signed something it has no key for yet');
	assert.deepStrictEqual(signer.signed, [], 'pairing asked the signer to sign');
});

test('backfill asks for what is BEFORE a cursor — chunked loading behind a scroll, never a page number', async () => {
	const { api, calls } = makeApi(() => response(200, { messages: [], more: false }));
	await api.backfill('t-1', 42, 25);
	const url = new URL(calls[0].url);
	assert.strictEqual(url.pathname, '/api/events');
	assert.strictEqual(url.searchParams.get('before'), '42');
	assert.strictEqual(url.searchParams.get('limit'), '25');
	assert.strictEqual(url.searchParams.get('page'), null, 'a page number reached the wire');
	assert.strictEqual(url.searchParams.get('offset'), null, 'an offset reached the wire');
});

test('audio is fetched with the credential, by an id the Mac minted', async () => {
	const { api, calls } = makeApi(() => response(200, 'RIFF....', { 'Content-Type': 'audio/wav' }));
	const blob = await api.fetchAudio('message with spaces/and-slash');
	assert.ok(blob);
	assert.ok(calls[0].url.endsWith('/api/audio/message%20with%20spaces%2Fand-slash'), calls[0].url);
	assert.ok(calls[0].init.headers.Authorization.startsWith('RichOS-Device device-1.'), 'the audio request was unauthenticated');
});
