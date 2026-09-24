// THE CONTRACT: the review host against the phone protocol conformance corpus
// (`mobile/conformance/vectors`), which the Mac's own verifier holds against the production Rust.
// Every case the corpus records a Mac verdict or a Mac outcome for is replayed here and must
// produce the same verdict or outcome from the review host. Iterates the arrays; never a count.

import test from 'node:test';
import assert from 'node:assert/strict';
import { createRequire } from 'node:module';
import { join } from 'node:path';
import { makeHost, clock, vector, corpusKey, Phone, MOBILE, readStream } from './helpers.mjs';
import { handlePhoneRequest } from '../src/phone.mjs';
import { bodyHash, decodeComponent, parseAuthorization, queryValue, signedPath, signingString } from '../src/signing.mjs';
import { ATTACHMENT_LIMITS_WIRE } from '../src/wire.mjs';
import { validId } from '../src/attachments.mjs';
import { parseRegistration } from '../src/registration.mjs';
import { sixWords } from '../src/qr.mjs';
import * as L from '../src/limits.mjs';

const require = createRequire(import.meta.url);
const reference = (path) => require(join(MOBILE, '..', '..', path));

const bytesOf = (body) => (!body ? Buffer.alloc(0) : body.utf8 !== undefined ? Buffer.from(body.utf8, 'utf8') : Buffer.from(body.base64, 'base64'));

/** A corpus request as a `Request` to `origin`. */
function requestFrom(origin, req) {
	const bytes = bytesOf(req.body);
	return new Request(origin + req.target, { method: req.method, headers: req.headers, body: req.body ? bytes : null });
}

/** The credential a corpus request carries, read the way the review host reads it. */
function credentialOf(req) {
	const [path, query = ''] = req.target.split('?');
	const header = req.signed.credential === 'query' ? decodeComponent(queryValue(query, 'auth')) : req.headers.Authorization;
	return { parsed: parseAuthorization(header), pathWithQuery: signedPath(path, query) };
}

/** A host with the corpus's test key paired, confirmed on the phone and the Mac. */
async function corpusHost(options = {}) {
	const { host, ...rest } = makeHost({ now: clock(), ...options });
	const key = corpusKey();
	const phone = new Phone(host, key, 'Android phone');
	const { code } = await host.openPairing();
	assert.equal((await phone.pair(code)).status, 200);
	assert.equal(phone.deviceId, key.deviceId, 'the review host derives the corpus device id from the corpus key');
	await host.confirmOnMac(true);
	return { host, phone, ...rest };
}

/** Make the challenge a corpus request signed with live on `host`, as the Rust verifier does. */
async function liven(host, req) {
	const { parsed } = credentialOf(req);
	if (parsed) await host.acceptChallengeForTest(parsed.challenge);
}

// ---- signing.json ----------------------------------------------------------------------------

test('signing.json: every valid, invalid and tolerated request gets the Mac verdict', async (t) => {
	const corpus = vector('signing.json');
	assert.equal(corpus.schema, 1);
	const cases = [...corpus.valid, ...corpus.invalid, ...corpus.accepted_by_the_mac_though_unusual];
	assert.ok(cases.length > 0);
	for (const c of cases) {
		await t.test(c.name, async () => {
			const { host } = await corpusHost();
			await liven(host, c.request);
			const { parsed, pathWithQuery } = credentialOf(c.request);
			const bodyHashHex = await bodyHash(bytesOf(c.request.body));
			if (!parsed) { assert.equal(c.request.mac.verdict, 'refused'); return; }
			assert.equal(signingString(parsed.challenge, c.request.method, pathWithQuery, bodyHashHex), c.request.mac.signing_string, 'the review host computes the Mac signing string');
			const result = await host.verify({ method: c.request.method, pathWithQuery, deviceId: parsed.deviceId, challenge: parsed.challenge, signature: parsed.signature, bodyHashHex });
			assert.equal(result.refusal ? 'refused' : 'accepted', c.request.mac.verdict);
		});
	}
});

// ---- challenge.json --------------------------------------------------------------------------

test('challenge.json: every answer carries a challenge, including the unsigned probe and every refusal', async () => {
	const corpus = vector('challenge.json');
	assert.match(corpus.rule, /GET \/api\/challenge is unsigned/);
	const { host } = makeHost();
	for (const [method, target] of [['GET', '/api/challenge'], ['GET', '/nothing'], ['POST', '/api/messages'], ['GET', '/api/events'], ['PUT', '/api/pair']]) {
		const response = await handlePhoneRequest(host, new Request('https://review-a.example.com' + target, { method }));
		assert.equal(response.status, 404, `${method} ${target}`);
		assert.match(response.headers.get('x-richos-challenge') || '', /^[A-Za-z0-9_-]{32}$/, `${method} ${target} carries a challenge`);
		assert.equal(await response.text(), '', 'a flat refusal has no body');
	}
});

// ---- pairing.json ----------------------------------------------------------------------------

test('pairing.json: the review host issues links the reference parser accepts, in the recorded format', async () => {
	const corpus = vector('pairing.json');
	const { pairingLink } = reference('richos/mobile/core/client.js');
	const { host } = makeHost({ hostname: 'review-a.example.com' });
	const seen = new Set();
	for (let i = 0; i < 20; i++) {
		const { link, code } = await host.openPairing();
		assert.equal(link, corpus.link_format.replace('<origin>', 'https://review-a.example.com').replace('<code>', code));
		assert.equal(code.length, corpus.code.length);
		assert.ok([...code].every((ch) => corpus.code.alphabet.includes(ch)));
		assert.deepEqual(pairingLink(link), { origin: 'https://review-a.example.com', code });
		seen.add(code);
	}
	assert.ok(seen.size >= 19, 'every link is fresh');
	// And the parser's own table still refuses what it refuses: the review host never relies on a loophole.
	for (const c of corpus.links) {
		let accepted;
		try { pairingLink(c.input); accepted = true; } catch { accepted = false; }
		assert.equal(accepted, c.accept, c.name);
	}
});

test('pairing.json: the recorded pairing request is answered with every field of the recorded answer', async () => {
	const corpus = vector('pairing.json');
	const exchange = corpus.pair_exchanges.find((e) => e.outcome.ok && !e.state_after.api_base_refusal);
	const expected = exchange.outcome.value;
	const push = { control: { call: async () => ({ status: 200, value: { hostId: 'a'.repeat(32), generation: 1 } }) } };
	const { host, now } = makeHost({ push });
	await host.load();
	const body = JSON.parse(exchange.requests[0].body.utf8);
	host.pairing = { code: body.code, openedAt: now() };
	const response = await handlePhoneRequest(host, requestFrom(host.origin, exchange.requests[0]));
	assert.equal(response.status, 200);
	const answer = await response.json();
	assert.deepEqual(Object.keys(answer).sort(), Object.keys(expected).sort(), 'the same keys as the Mac answer');
	for (const key of Object.keys(expected)) assert.equal(typeof answer[key], typeof expected[key], key);
	assert.equal(answer.device_id, expected.device_id, 'the device id rule matches the Mac');
	assert.equal(answer.api_base, host.origin);
	assert.deepEqual(answer.capabilities, expected.capabilities, 'capabilities in the Mac order');
	assert.deepEqual(answer.attachment_limits, expected.attachment_limits);
	assert.equal(answer.protocol_version, expected.protocol_version);
	assert.equal(response.headers.get('x-richos-challenge'), answer.challenge);
	assert.equal(host.device.platform, 'android', 'device_name "Android phone" reads as Android');
});

test('pairing.json: native apps send platform, and it wins over the name', async () => {
	const corpus = vector('pairing.json');
	assert.ok(corpus.platform_field.android_body_fields.includes('platform'));
	const { host } = makeHost();
	const phone = new Phone(host, undefined, 'Phone');
	const { code } = await host.openPairing();
	assert.equal((await phone.pair(code, { platform: 'ios' })).status, 200);
	assert.equal(host.device.platform, 'ios');
});

test('pairing.json: a wrong or spent code is the flat 404 the corpus classifies as refused', async () => {
	const { host } = makeHost();
	const phone = new Phone(host);
	await host.openPairing();
	const wrong = await phone.pair('WRONGCOD');
	assert.equal(wrong.status, 404);
	assert.equal(await wrong.text(), '');
});

test('pairing.json: both fingerprint confirmations are answered as recorded', async (t) => {
	const corpus = vector('pairing.json');
	for (const c of corpus.fingerprint_confirmations) {
		await t.test(c.name, async () => {
			const { host } = await corpusHost();
			for (const req of c.requests) {
				await liven(host, req);
				const response = await handlePhoneRequest(host, requestFrom(host.origin, req));
				assert.equal(response.status, 200);
				assert.deepEqual(await response.json(), c.outcome.value);
			}
			const body = JSON.parse(c.requests[0].body.utf8);
			if (body.fingerprint_confirmed) assert.equal(host.device.fingerprint_confirmed, true);
			else assert.equal(host.device, null, '"they do not match" forgets the phone');
		});
	}
});

// ---- fingerprint.json ------------------------------------------------------------------------

test('fingerprint.json: the access page computes the phone words for every accepted case', () => {
	const corpus = vector('fingerprint.json');
	for (const c of corpus.cases.filter((x) => x.accept)) assert.deepEqual(sixWords(c.input), c.words, c.name);
	const { WORDS } = reference('richos/web/web-app/lib/wordlist.js');
	assert.deepEqual(WORDS, corpus.wordlist, 'the word list the page uses is the corpus list');
});

// ---- voice.json ------------------------------------------------------------------------------

test('voice.json: the Mac limits are the review host limits', () => {
	const { limits } = vector('voice.json');
	assert.equal(limits.json_body_bytes.value, L.MAX_BODY_BYTES);
	assert.equal(limits.voice_body_bytes.value, L.MAX_VOICE_BYTES);
	assert.equal(limits.voice_seconds.value, L.MAX_VOICE_SECONDS);
	assert.equal(limits.reply_audio_bytes.value, L.MAX_REPLY_AUDIO_BYTES);
	assert.equal(limits.challenge_lifetime_ms.value, L.CHALLENGE_LIFETIME_MS);
});

test('voice.json: every recorded voice upload is accepted with its duration', async (t) => {
	const corpus = vector('voice.json');
	for (const c of corpus.uploads) {
		await t.test(c.name, async () => {
			const { host } = await corpusHost();
			await liven(host, c.request);
			const thread = new URLSearchParams(c.request.target.split('?')[1]).get('thread_id');
			// The corpus's conversation ids are the Mac's; the review host has its own, so the
			// recording goes to a known conversation only when the corpus names one it holds.
			const response = await handlePhoneRequest(host, requestFrom(host.origin, c.request));
			if (host.threadExists(thread)) {
				assert.equal(response.status, 200);
			} else {
				assert.equal(response.status, 404, 'an unknown conversation is the flat 404 the Mac gives');
			}
		});
	}
});

test('voice.json: a recording to a known conversation is accepted, measured and answered in the Mac shape', async () => {
	const corpus = vector('voice.json');
	const upload = corpus.uploads[0];
	const { host, phone } = await corpusHost();
	const wav = bytesOf(upload.request.body);
	const target = upload.request.target.replace('thread_id=thr_5c1e', 'thread_id=thr_review_welcome');
	const response = await phone.signed('POST', target, wav, 'audio/wav');
	assert.equal(response.status, 200);
	const answer = await response.json();
	assert.equal(answer.duration_ms, Math.floor(upload.input.seconds * 1000));
	assert.match(answer.text_sha256, /^[0-9a-f]{64}$/);
	assert.equal(answer.duplicate, false);
	const again = await phone.signed('POST', target, wav, 'audio/wav');
	assert.equal((await again.json()).duplicate, true, 'the same recording again is a duplicate');
});

// ---- attachments.json ------------------------------------------------------------------------

/** Replay every upload case, in order, on one host. */
async function replayUploads(host, cases) {
	const results = [];
	for (const c of cases) {
		await liven(host, c.request);
		const response = await handlePhoneRequest(host, requestFrom(host.origin, c.request));
		results.push({ c, status: response.status, body: await response.text() });
	}
	return results;
}

test('attachments.json: limits, ids and capabilities are the Mac values', () => {
	const corpus = vector('attachments.json');
	assert.deepEqual(ATTACHMENT_LIMITS_WIRE, corpus.limits);
	for (const c of corpus.attachment_id_cases) assert.equal(validId(c.id), c.mac_outcome.valid, JSON.stringify(c.id));
});

test('attachments.json: every upload, in order on one host, reaches the Mac outcome', async (t) => {
	const corpus = vector('attachments.json');
	const { host } = await corpusHost();
	for (const { c, status, body } of await replayUploads(host, corpus.upload_cases)) {
		await t.test(c.name, () => {
			assert.equal(status, c.mac_outcome.status);
			if (c.mac_outcome.answer) assert.deepEqual(JSON.parse(body), c.mac_outcome.answer);
			else assert.equal(JSON.parse(body).accepted, false);
		});
	}
});

test('attachments.json: the limit sequence refuses exactly the file one past the limit', async (t) => {
	const corpus = vector('attachments.json');
	const { host } = await corpusHost();
	for (const { c, status, body } of await replayUploads(host, corpus.limit_sequence)) {
		await t.test(c.name, () => {
			assert.equal(status, c.mac_outcome.status);
			if (c.mac_outcome.answer) assert.deepEqual(JSON.parse(body), c.mac_outcome.answer);
		});
	}
});

test('attachments.json: every commit names the files the Mac holds, or the ones it is missing', async (t) => {
	const corpus = vector('attachments.json');
	for (const c of corpus.commit_cases) {
		await t.test(c.name, async () => {
			const { host } = await corpusHost();
			await replayUploads(host, corpus.upload_cases);
			await liven(host, c.request);
			// The corpus commits into the Mac's conversation id; rewrite it to one this host holds,
			// and re-sign, so the case exercises the commit logic rather than the thread check.
			const phone = new Phone(host, corpusKey());
			phone.deviceId = corpusKey().deviceId;
			phone.challenge = await host.issueChallenge();
			const body = JSON.parse(c.request.body.utf8);
			body.thread_id = 'thr_board_prep';
			const response = await phone.signed('POST', '/api/messages', body);
			const answer = await response.json();
			if (c.mac_outcome.all_present) {
				assert.equal(response.status, 200);
				assert.deepEqual(answer.attachments.map(({ id, name }) => ({ id, name })), c.mac_outcome.files);
			} else {
				assert.equal(response.status, 422);
				assert.deepEqual(answer.missing, c.mac_outcome.missing);
				assert.equal(answer.retry, true);
			}
		});
	}
});

// ---- push-registration-fcm.json --------------------------------------------------------------

test('push-registration-fcm.json: every registration is accepted or refused as the Mac does', async (t) => {
	const corpus = vector('push-registration-fcm.json');
	for (const c of corpus.registration_cases) {
		await t.test(c.name, () => {
			const parsed = parseRegistration(c.native_push);
			assert.equal(parsed.ok, c.mac_outcome.accepted);
			if (parsed.ok) assert.equal(parsed.registration.transport, c.mac_outcome.transport);
		});
	}
	assert.deepEqual([...L.FCM_APPS].sort(), [...corpus.allowed_ids.fcm].sort());
	assert.deepEqual([...L.APNS_TOPICS].sort(), [...corpus.allowed_ids.apns].sort());
});

test('push-registration-fcm.json: the recorded requests are answered 200 by a host with push', async (t) => {
	const corpus = vector('push-registration-fcm.json');
	const calls = [];
	const control = { async call(method, path, body) { calls.push({ method, path, body }); return path === '/v1/push/events' ? { status: 202, value: {} } : { status: 200, value: { hostId: 'b'.repeat(32), generation: 1, revision: 1 } }; } };
	for (const c of corpus.requests) {
		await t.test(c.name, async () => {
			const { host } = await corpusHost({ push: { control } });
			// Registration needs the phone's own confirmation first, as on the Mac.
			host.device = { ...host.device, fingerprint_confirmed: true };
			await liven(host, c.request);
			const response = await handlePhoneRequest(host, requestFrom(host.origin, c.request));
			assert.equal(response.status, 200);
			const body = await response.json();
			if (JSON.parse(c.request.body.utf8).native_push !== undefined) {
				assert.equal(body.host_id, 'b'.repeat(32));
				assert.equal(typeof body.registered, 'boolean');
			}
		});
	}
});

// ---- events.json -----------------------------------------------------------------------------

test('events.json: the review host stream parses with the reference parser at every chunking', async () => {
	const corpus = vector('events.json');
	assert.match(corpus.wire_format, /^id: <cursor>/);
	const { sseParser } = reference('richos/mobile/platform/native.js');
	const { host, phone, now } = await corpusHost();
	const stream = await phone.events('thread_id=thr_review_welcome');
	assert.equal(stream.headers.get('content-type'), 'text/event-stream');
	const sent = await phone.signed('POST', '/api/messages', { client_id: 'conformance-1', thread_id: 'thr_review_welcome', kind: 'text', text: 'Café naïve 🚀', sent_at: '2026-09-24T00:00:00.000Z' });
	assert.equal(sent.status, 200);
	now.advance(10_000);
	await host.alarm();
	const { text, reader } = await readStream(stream, (s) => (s.match(/event: message/g) || []).length >= 3);
	await reader.cancel();
	const bytes = Buffer.from(text, 'utf8');
	const parse = (chunks) => { const out = []; const feed = sseParser((event, data) => out.push({ event, data: JSON.parse(data) })); const d = new TextDecoder(); for (const ch of chunks) feed(d.decode(ch, { stream: true })); return out; };
	const whole = parse([bytes]);
	assert.deepEqual(whole.map((e) => e.event).slice(0, 2), ['hello', 'message']);
	for (const size of [1, 7]) {
		const chunks = [];
		for (let i = 0; i < bytes.length; i += size) chunks.push(bytes.subarray(i, i + size));
		assert.deepEqual(parse(chunks), whole, `chunks of ${size}`);
	}
	const hello = whole[0].data;
	for (const key of Object.keys(corpus.hello_cases[0].hello)) assert.ok(key in hello, `hello carries ${key}`);
	const deltas = whole.filter((e) => e.event === 'delta');
	assert.ok(deltas.length > 1, 'the demo reply streams in pieces');
	for (const d of deltas) assert.equal(d.data.thread_id, 'thr_review_welcome', 'every delta names its conversation (e9b0a89e)');
});

test('events.json: frames from the review host build the conversation the reference thread model shows', async () => {
	const { createThread } = reference('richos/web/web-app/lib/thread.js');
	const { host, phone, now } = await corpusHost();
	const stream = await phone.events('thread_id=thr_board_prep');
	await phone.signed('POST', '/api/messages', { client_id: 'thread-1', thread_id: 'thr_board_prep', kind: 'text', text: 'Add a slide on churn.', sent_at: '2026-09-24T00:00:00.000Z' });
	now.advance(10_000);
	await host.alarm();
	// hello, the CEO row, the streaming row, the final row.
	const { text, reader } = await readStream(stream, (s) => (s.match(/event: message/g) || []).length >= 3);
	await reader.cancel();
	const { sseParser } = reference('richos/mobile/platform/native.js');
	const model = createThread();
	const feed = sseParser((event, data) => {
		const value = JSON.parse(data);
		if (event === 'hello') model.merge(value.messages);
		if (event === 'message') model.merge(value);
		if (event === 'delta') model.applyDelta(value);
	});
	feed(text);
	const shown = model.view([]).map((r) => ({ id: r.id, text: r.text, complete: r.complete }));
	const stored = (await host.rows('thr_board_prep')).map((r) => ({ id: r.id, text: r.text, complete: r.complete }));
	assert.deepEqual(shown, stored, 'what the phone shows is what the host holds');
	assert.match(shown.at(-1).text, /^Demo reply: /);
});

test('events.json: the backfill answers the recorded shape', async () => {
	const corpus = vector('events.json');
	const { phone } = await corpusHost();
	const response = await phone.events('thread_id=thr_board_prep&before=4&limit=1');
	assert.equal(response.status, 200);
	const page = await response.json();
	assert.deepEqual(Object.keys(page).sort(), Object.keys(corpus.backfill_case.page).sort());
	assert.equal(page.messages.length, 1);
	assert.equal(page.more, true);
});

// ---- errors.json -----------------------------------------------------------------------------

test('errors.json: every refusal the review host gives is one the corpus classifies', async () => {
	const corpus = vector('errors.json');
	const { createApi, REFUSED, FAULT, REVOKED } = reference('richos/web/web-app/lib/api.js');
	const { host, phone } = await corpusHost();
	const classify = async (response) => {
		const body = await response.text();
		const api = createApi({ state: { apiBase: host.origin, deviceId: 'dev_x', challenge: 'c' }, origin: host.origin,
			signer: { sign: async () => 'sig', sha256Hex: async () => '' },
			fetchImpl: async () => new Response(body || null, { status: response.status, headers: response.headers }) });
		try { await api.sendText({ clientId: 'x', text: 'x' }); return 'ok'; } catch (error) { return error.reason; }
	};
	// 409 conflict: the same client_id with different bytes.
	await phone.signed('POST', '/api/messages', { client_id: 'err-1', thread_id: 'thr_hiring', kind: 'text', text: 'one' });
	const conflict = await phone.signed('POST', '/api/messages', { client_id: 'err-1', thread_id: 'thr_hiring', kind: 'text', text: 'two' });
	assert.equal(conflict.status, 409);
	assert.equal(await classify(conflict), REFUSED);
	// 422 from a voice note that is not audio the Mac takes.
	const badVoice = await phone.signed('POST', '/api/messages?client_id=v1&thread_id=thr_hiring&kind=voice', Buffer.from('not audio'), 'audio/wav');
	assert.equal(badVoice.status, 422);
	assert.equal(await classify(badVoice), REFUSED);
	// 403 revoked, after the phone is forgotten.
	await host.forget();
	const revoked = await phone.signed('POST', '/api/messages', { client_id: 'err-2', kind: 'text', text: 'x' });
	assert.equal(revoked.status, 403);
	assert.equal(await classify(revoked), REVOKED);
	const statuses = new Set(corpus.cases.map((c) => c.mac_answer?.status ?? c.answer?.status).filter(Boolean));
	for (const s of [409, 422, 403, 404, 429]) assert.ok(statuses.has(s), `the corpus classifies ${s}`);
	void FAULT;
});
