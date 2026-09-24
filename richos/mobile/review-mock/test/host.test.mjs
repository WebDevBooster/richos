// The review host's behavior beyond the corpus: Sage's v2 pairing gate (the Mac-side press), the
// spent-code alarm, isolation between review hosts, receipts, demo replies, limits and reset.

import test from 'node:test';
import assert from 'node:assert/strict';
import { makeHost, Phone, pairedPhone, freshKey, clock, memoryStorage, readStream } from './helpers.mjs';
import { AWAITING, REPLY_DELAY_MS, pairingWords } from '../src/host.mjs';
import { PAIRING_WINDOW_MS, RATE_LIMIT, MAX_STREAMS } from '../src/limits.mjs';
import { sixWords } from '../src/qr.mjs';
import { DEMO_PREFIX } from '../src/script.mjs';
import { chime } from '../src/wav.mjs';

const text = (clientId, words, thread = 'thr_review_welcome') => ({ client_id: clientId, thread_id: thread, kind: 'text', text: words, sent_at: '2026-09-24T00:00:00.000Z' });

// ---- Sage F1: nothing but the six words until the person presses on the Mac -------------------

test('a newly paired phone is answered only for its confirmation until They match is pressed on the access page', async () => {
	const { host } = makeHost();
	const phone = new Phone(host);
	const { code } = await host.openPairing();
	assert.equal((await phone.pair(code)).status, 200);
	const awaiting = JSON.parse(AWAITING.body);
	for (const request of [
		() => phone.signed('POST', '/api/messages', text('c1', 'hello')),
		() => phone.events('thread_id=thr_review_welcome'),
		() => phone.events('thread_id=thr_review_welcome&before=5&limit=1'),
		() => phone.signed('GET', '/api/audio/sample_2%3Atext%3A0'),
		() => phone.signed('POST', '/api/pair', { delivered_cursor: 3 })
	]) {
		const response = await request();
		assert.equal(response.status, 409);
		assert.deepEqual(await response.json(), awaiting);
	}
	// The phone's own "They match" is recorded and activates nothing (it protects the phone only).
	assert.equal((await phone.confirmOnPhone(true)).status, 200);
	assert.equal(host.device.fingerprint_confirmed, true);
	assert.equal((await phone.signed('POST', '/api/messages', text('c2', 'still waiting'))).status, 409);
	// The Mac-side press activates it.
	assert.deepEqual(await host.confirmOnMac(true), { ok: true });
	assert.equal((await phone.signed('POST', '/api/messages', text('c3', 'now it works'))).status, 200);
	assert.equal((await host.status()).notice.kind, 'confirmed');
});

test('the awaiting answer is a retryable fault to the reference client, never a final refusal', async () => {
	const { createRequire } = await import('node:module');
	const require = createRequire(import.meta.url);
	const { createApi, FAULT } = require('../../../web/web-app/lib/api.js');
	const api = createApi({ state: { apiBase: 'https://r.example.com', deviceId: 'dev_x', challenge: 'c' }, origin: 'https://r.example.com',
		signer: { sign: async () => 'sig', sha256Hex: async () => '' },
		fetchImpl: async () => new Response(AWAITING.body, { status: 409, headers: { 'content-type': 'application/json' } }) });
	await assert.rejects(api.sendText({ clientId: 'x', text: 'x' }), (error) => error.reason === FAULT);
});

test('They do not match on the access page forgets the phone, which is then told it was removed', async () => {
	const { host } = makeHost();
	const phone = new Phone(host);
	const { code } = await host.openPairing();
	await phone.pair(code);
	await host.confirmOnMac(false);
	assert.equal(host.device, null);
	assert.equal((await host.status()).notice.kind, 'rejected-on-mac');
	const after = await phone.signed('POST', '/api/messages', text('c1', 'x'));
	assert.equal(after.status, 403);
	assert.deepEqual(await after.json(), { revoked: true });
});

test('a phone nobody confirmed on the Mac is forgotten when its pairing window closes', async () => {
	const { host, now, wakes } = makeHost();
	const phone = new Phone(host);
	const { code } = await host.openPairing();
	await phone.pair(code);
	assert.ok(wakes.some((at) => at > now()), 'the host asked to be woken at the window end');
	now.advance(PAIRING_WINDOW_MS + 1);
	await host.alarm();
	assert.equal(host.device, null);
	assert.equal((await host.status()).notice.kind, 'expired');
	assert.equal((await phone.signed('POST', '/api/pair', { fingerprint_confirmed: true })).status, 403, 'the abandoned key gets the final answer');
});

test('the spent-code alarm: the same code a second time removes an unconfirmed phone, and only warns about a confirmed one', async () => {
	{
		const { host } = makeHost();
		const { code } = await host.openPairing();
		assert.equal((await new Phone(host).pair(code)).status, 200);
		const second = await new Phone(host).pair(code);
		assert.equal(second.status, 404);
		assert.equal(host.device, null, 'the waiting phone is removed: two phones had the code');
		assert.equal((await host.status()).notice.kind, 'two-phones-removed');
	}
	{
		const { host } = makeHost();
		const { code } = await host.openPairing();
		const first = new Phone(host);
		await first.pair(code);
		await host.confirmOnMac(true);
		assert.equal((await new Phone(host).pair(code)).status, 404);
		assert.equal(host.device.id, first.deviceId, 'a confirmed phone is kept');
		assert.equal((await host.status()).notice.kind, 'two-phones-kept');
	}
});

test('the access page shows words only after a phone reaches the host, and they are the words that phone computes', async () => {
	for (const version of [1, 2]) {
		const { host } = makeHost({ pairingVersion: version });
		const { code } = await host.openPairing();
		assert.equal((await host.status()).words, null, `v${version}: no words before a phone arrives`);
		const phone = new Phone(host);
		const answer = await (await phone.pair(code)).json();
		const status = await host.status();
		// What the phone computes: v1 from the fingerprint it was sent; v2 from the origin it
		// dialed, that fingerprint and its own key (Sage F2).
		const { createHash } = await import('node:crypto');
		const point = Buffer.concat([Buffer.from([4]), Buffer.from(phone.key.jwk.x, 'base64url'), Buffer.from(phone.key.jwk.y, 'base64url')]);
		const phoneWords = version === 1 ? sixWords(answer.ca_fingerprint_sha256)
			: sixWords(createHash('sha256').update(`RICHCONNECT-PAIR-V2\n${phone.origin}\n${answer.ca_fingerprint_sha256}\n${point.toString('base64url')}`).digest('hex'));
		assert.deepEqual(status.words, phoneWords, `v${version}`);
		assert.equal(answer.capabilities.includes('pair-v2'), version === 2);
		assert.equal(answer.pairing_version, version === 2 ? 2 : undefined);
	}
});

test('v2 words change with the origin and with the key; v1 words do not', async () => {
	const mac = '55:A7:F7:36:2C:07:CD:F4:EE:17:5B:6A:47:D1:0A:0D:62:9B:E7:AF:5F:99:0C:15:B6:5A:88:D1:33:2D:63:87';
	const a = await pairingWords(2, 'https://review-a.example.com', mac, 'KEY_A');
	assert.notDeepEqual(await pairingWords(2, 'https://relay.example.com', mac, 'KEY_A'), a, 'a relay changes the words');
	assert.notDeepEqual(await pairingWords(2, 'https://review-a.example.com', mac, 'KEY_B'), a, 'an intruder key changes the words');
	assert.deepEqual(await pairingWords(1, 'https://relay.example.com', mac, 'KEY_B'), await pairingWords(1, 'https://review-a.example.com', mac, 'KEY_A'));
});

// ---- one phone per host, and hosts that never touch each other -----------------------------

test('a pairing link cannot be opened while a phone is paired; replacing is its own explicit action', async () => {
	const { host } = makeHost();
	const phone = await pairedPhone(host);
	assert.deepEqual(await host.openPairing(), { ok: false, reason: 'paired' });
	const replaced = await host.replacePhone();
	assert.equal(replaced.ok, true);
	assert.equal((await phone.signed('POST', '/api/messages', text('c1', 'x'))).status, 403, 'the replaced phone is told it was removed');
});

test('two review hosts are isolated: pairing, conversation, receipts and removal never cross', async () => {
	const now = clock();
	const a = makeHost({ hostname: 'review-a.example.com', now });
	const b = makeHost({ hostname: 'review-b.example.com', now });
	const key = freshKey();
	const onA = await pairedPhone(a.host, key, 'Apple reviewer iPhone');
	const onB = await pairedPhone(b.host, freshKey(), 'Google reviewer Android');
	// A's credential means nothing on B, even presented with a challenge B issued.
	const stray = new Phone(b.host, key);
	stray.deviceId = onA.deviceId;
	stray.challenge = onB.challenge;
	assert.equal((await stray.signed('POST', '/api/messages', text('c1', 'x'))).status, 404);
	// A conversation on A never appears on B.
	assert.equal((await onA.signed('POST', '/api/messages', text('same-id', 'only on A'))).status, 200);
	assert.ok(!(await b.host.rows('thr_review_welcome')).some((r) => r.text === 'only on A'));
	// The same client_id on B is a new message there, not a duplicate of A's.
	const onBSend = await onB.signed('POST', '/api/messages', text('same-id', 'only on B'));
	assert.equal((await onBSend.json()).duplicate, false);
	// Resetting A leaves B paired and B's conversation as it was.
	await a.host.reset();
	assert.equal(a.host.device, null);
	assert.equal(b.host.device.id, onB.deviceId);
	assert.ok((await b.host.rows('thr_review_welcome')).some((r) => r.text === 'only on B'));
	// No storage key is shared: each host writes only to its own storage object.
	assert.notEqual(a.storage, b.storage);
});

// ---- receipts ------------------------------------------------------------------------------

test('a retried send is a duplicate with the original answer; changed bytes under the same id are a conflict', async () => {
	const { host } = makeHost();
	const phone = await pairedPhone(host);
	const first = await (await phone.signed('POST', '/api/messages', text('r1', 'where are we?'))).json();
	const again = await (await phone.signed('POST', '/api/messages', text('r1', 'where are we?'))).json();
	assert.deepEqual({ ...again, duplicate: false }, first);
	assert.equal(again.duplicate, true);
	const changed = await phone.signed('POST', '/api/messages', text('r1', 'different'));
	assert.equal(changed.status, 409);
	assert.equal((await changed.json()).retry, false);
	assert.equal((await host.rows('thr_review_welcome')).filter((r) => r.client_id === 'r1').length, 1, 'one row, however many retries');
});

// ---- the demo reply ------------------------------------------------------------------------

test('every accepted message gets one demo reply, streamed in pieces, labeled, and playable as a chime', async () => {
	const { host, now } = makeHost();
	const phone = await pairedPhone(host);
	const stream = await phone.events('thread_id=thr_hiring');
	const answer = await (await phone.signed('POST', '/api/messages', text('d1', 'Schedule the final interviews.', 'thr_hiring'))).json();
	now.advance(REPLY_DELAY_MS - 1);
	await host.alarm();
	assert.equal((await host.rows('thr_hiring')).filter((r) => r.role === 'rich' && r.cursor > answer.cursor).length, 0, 'not before its time');
	now.advance(1);
	await host.alarm();
	const reply = (await host.rows('thr_hiring')).find((r) => r.role === 'rich' && r.cursor > answer.cursor);
	assert.ok(reply.text.startsWith(`${DEMO_PREFIX}: `));
	assert.match(reply.text, /Schedule the final interviews\./);
	const { text: wire, reader } = await readStream(stream, (s) => s.includes(`"id":"${reply.id}"`) && s.includes('"state":"complete","complete":true}\n\n'));
	await reader.cancel();
	assert.ok((wire.match(/event: delta/g) || []).length > 1);
	await host.alarm();
	assert.equal((await host.rows('thr_hiring')).filter((r) => r.role === 'rich' && r.cursor > answer.cursor).length, 1, 'one reply, however often the alarm runs');
	const audio = await phone.signed('GET', `/api/audio/${encodeURIComponent(reply.id)}?thread_id=thr_hiring`);
	assert.equal(audio.status, 200);
	assert.equal(audio.headers.get('content-type'), 'audio/wav');
	assert.deepEqual(new Uint8Array(await audio.arrayBuffer()), chime());
	const missing = await phone.signed('GET', '/api/audio/turn_999%3Atext%3A0');
	assert.equal(missing.status, 503);
});

test('a reply survives the host being evicted between the message and the alarm', async () => {
	const now = clock();
	const storage = memoryStorage();
	const first = makeHost({ now, storage });
	const phone = await pairedPhone(first.host);
	await phone.signed('POST', '/api/messages', text('e1', 'still there?'));
	// A new object over the same storage, as after a Durable Object eviction.
	const second = makeHost({ now, storage });
	now.advance(REPLY_DELAY_MS);
	await second.host.alarm();
	assert.ok((await second.host.rows('thr_review_welcome')).some((r) => r.role === 'rich' && r.text.includes('still there?')));
	// The phone's challenge also survived, so its next request needs no re-sign.
	phone.host = second.host;
	assert.equal((await phone.signed('POST', '/api/messages', text('e2', 'yes'))).status, 200);
});

// ---- limits ----------------------------------------------------------------------------------

test('the paired phone has its own 60-a-minute bucket; strangers cannot spend it', async () => {
	const { host } = makeHost();
	const phone = await pairedPhone(host);
	const stranger = new Phone(host, freshKey());
	stranger.deviceId = 'dev_000000000000';
	stranger.challenge = phone.challenge;
	for (let i = 0; i < RATE_LIMIT; i++) await stranger.signed('POST', '/api/messages', text('s' + i, 'x'));
	const refused = await stranger.signed('POST', '/api/messages', text('s', 'x'));
	assert.equal(refused.status, 429);
	assert.equal(refused.headers.get('retry-after'), '60');
	assert.equal((await phone.signed('POST', '/api/messages', text('p1', 'still fine'))).status, 200);
});

test('at most four streams at once, as on the Mac', async () => {
	const { host } = makeHost();
	const phone = await pairedPhone(host);
	const open = [];
	for (let i = 0; i < MAX_STREAMS; i++) open.push(await phone.events('thread_id=thr_review_welcome'));
	assert.ok(open.every((r) => r.status === 200));
	assert.equal((await phone.events('thread_id=thr_review_welcome')).status, 429);
	for (const r of open) await r.body.cancel();
	await host.forget();
});

test('a large body is refused unread unless it comes from the paired, active phone with a live challenge (Sage F3)', async () => {
	const { host } = makeHost();
	const phone = new Phone(host);
	const { code } = await host.openPairing();
	await phone.pair(code);
	const big = new Uint8Array(1024 * 1024);
	let pulled = 0;
	const body = new ReadableStream({ pull(c) { pulled += 1; c.enqueue(big); if (pulled > 3) c.close(); } });
	const request = new Request(`${host.origin}/api/messages?client_id=v&thread_id=thr_hiring&kind=voice`, {
		method: 'POST', body, duplex: 'half', headers: { 'content-type': 'audio/wav', authorization: phone.authorization('POST', '/api/messages?client_id=v&thread_id=thr_hiring&kind=voice', big) }
	});
	const { handlePhoneRequest } = await import('../src/phone.mjs');
	const response = await handlePhoneRequest(host, request);
	assert.equal(response.status, 404, 'an unconfirmed device may not send a large body');
	assert.ok(pulled <= 1, 'the body was not read');
});

test('a reset restores the sample conversations, removes the phone and keeps cursors rising', async () => {
	const { host } = makeHost();
	const phone = await pairedPhone(host);
	await phone.signed('POST', '/api/messages', text('x1', 'to be reset'));
	const before = host.meta.cursor;
	await host.reset();
	assert.equal(host.device, null);
	const rows = await host.rows('thr_review_welcome');
	assert.ok(!rows.some((r) => r.text === 'to be reset'));
	assert.ok(rows.every((r) => r.cursor > before), 'a phone that cached rows before the reset cannot confuse new ones with old');
});

test('forgetting the phone closes its open streams', async () => {
	const { host } = makeHost();
	const phone = await pairedPhone(host);
	const stream = await phone.events('thread_id=thr_review_welcome');
	await host.forget();
	const reader = stream.body.getReader();
	let done = false;
	for (let i = 0; i < 5 && !done; i++) ({ done } = await reader.read());
	assert.equal(done, true);
});
