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

const { createApi, ApiError, signingInput, offers, UNREACHABLE, REVOKED, REFUSED, FAULT } = require('../lib/api.js');

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

function makeApi(handler, initial, eventSourceImpl) {
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
		eventSourceImpl: eventSourceImpl || null
	});
	return { api, calls, signer, state };
}

/// An `EventSource` in the shape the browser gives one: constructed with a URL, listened to by
/// name, and closed. The test holds the handlers so it can deliver a frame by hand.
function makeEventSource() {
	const made = [];
	class Stub {
		constructor(url) {
			this.url = url;
			this.handlers = {};
			made.push(this);
		}
		addEventListener(name, fn) { this.handlers[name] = fn; }
		close() { this.closed = true; }
		/// Deliver a frame exactly as the browser would: one `data` string, already JSON.
		deliver(name, value) { this.handlers[name]({ data: JSON.stringify(value) }); }
	}
	Stub.made = made;
	return Stub;
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

// ---------------------------------------------------------------------------------------------
// The 503 that is an ANSWER, and the 503 that is an accident (contract §9, plan §2 A)
// ---------------------------------------------------------------------------------------------
//
// Both of these are `503 {"accepted":false,"reason":"…"}` and until today they were the same row of
// the contract. One of them MUST be retried — the Mac failed to write his words down — and the
// other must never be, because the answer will be identical every time this build is asked. Nothing
// in the status or the body shape can tell them apart, so the Mac says which it is: `"retry": false`.

test('a 503 the Mac marks final is an answer, not a fault, and is never retried', async () => {
	const { api } = makeApi(() => response(503, {
		accepted: false,
		retry: false,
		reason: 'Voice notes are not switched on yet. Your recording is still on your phone.'
	}));
	await assert.rejects(
		() => api.sendVoice({ clientId: 'c-20', threadId: 't', bytes: [1, 2, 3], seconds: 2, sentAt: 'now' }),
		(err) => {
			assert.strictEqual(err.reason, REFUSED);
			assert.strictEqual(err.retryable, false, 'a refusal that cannot change was queued for another try');
			assert.strictEqual(err.status, 503);
			// The Mac's own sentence survives, because the Mac is the only thing that knows WHY.
			// The phone never invents a reason for a refusal it was handed one for.
			assert.match(err.message, /Voice notes are not switched on yet/);
			return true;
		}
	);
});

test('the 503 that means the Mac could not write it down is still a fault, and is still retried', async () => {
	const { api } = makeApi(() => response(503, {
		accepted: false,
		reason: 'Your Mac could not save that message. Nothing was lost on your phone — try again.'
	}));
	await assert.rejects(
		() => api.sendText({ clientId: 'c-21', threadId: 't', text: 'where are we on the proposal?', sentAt: 'now' }),
		(err) => {
			assert.strictEqual(err.reason, FAULT);
			assert.strictEqual(err.retryable, true, 'the one 503 that MUST be retried stopped being retried');
			assert.strictEqual(err.status, 503);
			return true;
		}
	);
});

test('only `retry: false` is final — `retry: true`, a missing key and a non-JSON body are all faults', async () => {
	// The default is the safe one in the direction that loses nothing: a message that is retried
	// when it need not have been costs one request, and a message treated as refused when the Mac
	// would have taken it is a message he has to type again.
	const bodies = [
		[{ accepted: false, retry: true, reason: 'busy' }, 'retry: true'],
		[{ accepted: false, reason: 'no retry key at all' }, 'no retry key'],
		['not json at all', 'a body that is not JSON'],
		['', 'an empty body'],
		[{ accepted: false, retry: 'false', reason: 'a string, not a boolean' }, 'the string "false"'],
		[{ accepted: false, retry: 0, reason: 'a number, not a boolean' }, 'the number 0']
	];
	for (const [body, what] of bodies) {
		const { api } = makeApi(() => response(503, body));
		await assert.rejects(
			() => api.sendText({ clientId: 'c-22', threadId: 't', text: 'x', sentAt: 'now' }),
			(err) => {
				assert.strictEqual(err.retryable, true, `${what} was read as a final answer`);
				assert.strictEqual(err.reason, FAULT, `${what} was read as a final answer`);
				return true;
			}
		);
	}
});

test('a final answer can be given on any status — the Mac decides, the status number does not', async () => {
	const { api } = makeApi(() => response(500, { retry: false, reason: 'this build cannot do that' }));
	await assert.rejects(
		() => api.sendText({ clientId: 'c-23', threadId: 't', text: 'x', sentAt: 'now' }),
		(err) => {
			assert.strictEqual(err.reason, REFUSED);
			assert.strictEqual(err.retryable, false);
			assert.strictEqual(err.status, 500);
			return true;
		}
	);
});

test('a 403 that is not a revocation is still REFUSED — the new body read did not swallow the old branch', async () => {
	const { api } = makeApi(() => response(403, { revoked: false }));
	await assert.rejects(
		() => api.sendText({ clientId: 'c-24', threadId: 't', text: 'x', sentAt: 'now' }),
		(err) => {
			assert.strictEqual(err.reason, REFUSED);
			assert.strictEqual(err.status, 403);
			return true;
		}
	);
});

// ---------------------------------------------------------------------------------------------
// Capabilities — what this Mac can actually do, said out loud (plan §2 A)
// ---------------------------------------------------------------------------------------------
//
// The phone shipped a "Hold to record" button against a Mac that answers every voice note 503.
// A control that cannot work is worse than an absent one, so the Mac names what it has and the
// phone believes nothing it was not told. DEFAULT-DENY: absent, malformed or empty, the answer to
// "can this Mac take a voice note?" is no — which is the honest answer for every build that
// predates the `capabilities` key, because not one of them could take one.

test('capabilities are read from the Mac and nothing is assumed — a Mac that says nothing offers nothing', () => {
	assert.strictEqual(offers(['text', 'voice'], 'voice'), true);
	assert.strictEqual(offers(['text'], 'voice'), false);
	assert.strictEqual(offers(undefined, 'voice'), false, 'a Mac that said nothing was read as offering voice');
	assert.strictEqual(offers(null, 'voice'), false);
	assert.strictEqual(offers([], 'voice'), false);
	assert.strictEqual(offers('voice', 'voice'), false, 'a string was read as a list of capabilities');
	assert.strictEqual(offers(['voice '], 'voice'), false, 'an untrimmed name was accepted');
	assert.strictEqual(offers(['Voice'], 'voice'), false, 'the name is matched exactly, and it was not');
	assert.strictEqual(offers([{ name: 'voice' }], 'voice'), false, 'an object was read as the name');
	assert.strictEqual(offers(['text', 'voice'], 'text'), true);
});

test('the capabilities and the build from `hello` are held on the api state, where the screen can read them', async () => {
	const Stub = makeEventSource();
	const { api, state } = makeApi(() => response(200, {}), null, Stub);
	const frames = [];
	await api.openEvents('t-1', 0, { hello: (d) => frames.push(d) });
	const source = Stub.made[0];

	source.deliver('hello', { challenge: 'challenge-two', capabilities: ['text'], build: '1.2.0' });

	assert.deepStrictEqual(state.capabilities, ['text']);
	assert.strictEqual(state.build, '1.2.0');
	assert.strictEqual(api.offers('voice'), false);
	assert.strictEqual(api.offers('text'), true);
	assert.strictEqual(frames.length, 1, 'the app did not get the frame it is wired to');

	// A later frame from a Mac that has grown voice replaces the answer; it is never accumulated,
	// because a capability that was true once is not evidence about the Mac answering now.
	source.deliver('hello', { capabilities: ['text', 'voice'], build: '1.3.0' });
	assert.strictEqual(api.offers('voice'), true);
	assert.strictEqual(state.build, '1.3.0');

	// And a frame with no capabilities at all puts it back to offering nothing, rather than
	// leaving the phone showing a control on the strength of a frame that is no longer current.
	source.deliver('hello', { challenge: 'challenge-three' });
	assert.strictEqual(api.offers('voice'), false);
});
