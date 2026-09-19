'use strict';

// The send queue. `node --test "test/*.test.js"`.
//
// Every test below is a user story from the plan, walked to its end:
//
//   he types on a train        -> it waits, visibly, and says why
//   he gets home               -> it goes, in the order he wrote it
//   the app is killed mid-send -> it is still there, and re-sending it is safe
//   his Mac forgot the phone   -> it stops, and says so, instead of hammering
//
// The storage port is a plain object here, which is the point of it being a port: the same state
// machine runs in Node against a Map and in the browser against IndexedDB, and the browser half is
// proved by the desktop harness driving a real reload.

const test = require('node:test');
const assert = require('node:assert');

const { createQueue, WAITING, BLOCKED } = require('../lib/queue.js');
const { createApi, ApiError, UNREACHABLE, REVOKED, REFUSED, FAULT } = require('../lib/api.js');

/// A `fetch` response in the shape `api.js` reads, so the last test below can drive the queue over
/// the real route module rather than over a hand-written stand-in for it.
function jsonResponse(status, body) {
	const text = JSON.stringify(body);
	const make = () => ({
		status,
		ok: status >= 200 && status < 300,
		headers: { get: () => null },
		text: async () => text,
		json: async () => JSON.parse(text),
		clone: () => make()
	});
	return make();
}

function memoryStorage(seed) {
	const map = new Map((seed || []).map((i) => [i.clientId, i]));
	return {
		map,
		// Stored as JSON round trips, exactly as IndexedDB would: an item that only works because
		// it shares an object identity with the caller is an item that does not survive a relaunch.
		async all() { return Array.from(map.values()).map((i) => JSON.parse(JSON.stringify(i))); },
		async put(item) { map.set(item.clientId, JSON.parse(JSON.stringify(item))); },
		async remove(clientId) { map.delete(clientId); }
	};
}

function macThatAccepts(log) {
	let cursor = 100;
	return {
		async sendText(item) { log.push(item.clientId); return { message_id: `m-${item.clientId}`, cursor: cursor++ }; },
		async sendVoice(item) { log.push(item.clientId); return { message_id: `m-${item.clientId}`, cursor: cursor++ }; }
	};
}

function macThatIsUnreachable() {
	return {
		async sendText() { throw new ApiError(UNREACHABLE, 'Load failed'); },
		async sendVoice() { throw new ApiError(UNREACHABLE, 'Load failed'); }
	};
}

test('an item is durable BEFORE enqueue resolves, not after a send fails', async () => {
	const storage = memoryStorage();
	const queue = createQueue({ storage });
	await queue.enqueue({ clientId: 'c-1', threadId: 't', kind: 'text', text: 'hello' });
	assert.strictEqual(storage.map.size, 1, 'the item was not on disk when enqueue returned');
	assert.strictEqual(storage.map.get('c-1').state, WAITING);
});

test('he types on a train: it waits, and the reason is recorded rather than guessed at later', async () => {
	const storage = memoryStorage();
	const queue = createQueue({ storage });
	await queue.enqueue({ clientId: 'c-1', threadId: 't', kind: 'text', text: 'where are we on the proposal?' });

	const result = await queue.flush(macThatIsUnreachable());
	assert.strictEqual(result.sent, 0);
	assert.strictEqual(result.waiting, 1);
	assert.strictEqual(result.reason, UNREACHABLE);
	assert.strictEqual(queue.all()[0].state, WAITING);
	assert.strictEqual(queue.all()[0].attempts, 1);
	assert.strictEqual(storage.map.get('c-1').lastReason, UNREACHABLE);
});

test('he gets home: everything goes, oldest first, and the queue empties', async () => {
	const storage = memoryStorage();
	const queue = createQueue({ storage, now: (() => { let n = 0; return () => `2026-09-18T10:00:0${n++}Z`; })() });
	await queue.enqueue({ clientId: 'c-1', threadId: 't', kind: 'text', text: 'first' });
	await queue.enqueue({ clientId: 'c-2', threadId: 't', kind: 'voice', seconds: 2 });
	await queue.enqueue({ clientId: 'c-3', threadId: 't', kind: 'text', text: 'third' });

	const order = [];
	const result = await queue.flush(macThatAccepts(order));
	assert.deepStrictEqual(order, ['c-1', 'c-2', 'c-3'], 'the order he wrote them in was not preserved');
	assert.strictEqual(result.sent, 3);
	assert.strictEqual(queue.count(), 0);
	assert.strictEqual(storage.map.size, 0, 'delivered items were left on the phone');
});

test('the flush STOPS at the first message that cannot go — his third sentence never overtakes his first', async () => {
	const storage = memoryStorage();
	const queue = createQueue({ storage, now: (() => { let n = 0; return () => `2026-09-18T10:00:0${n++}Z`; })() });
	await queue.enqueue({ clientId: 'c-1', threadId: 't', kind: 'text', text: 'first' });
	await queue.enqueue({ clientId: 'c-2', threadId: 't', kind: 'text', text: 'second' });
	await queue.enqueue({ clientId: 'c-3', threadId: 't', kind: 'text', text: 'third' });

	const attempted = [];
	const flaky = {
		async sendText(item) {
			attempted.push(item.clientId);
			if (item.clientId === 'c-2') throw new ApiError(UNREACHABLE, 'Load failed');
			return { message_id: 'm', cursor: 1 };
		},
		async sendVoice() { throw new Error('not used'); }
	};

	const result = await queue.flush(flaky);
	assert.deepStrictEqual(attempted, ['c-1', 'c-2'], 'it carried on past a message that could not go');
	assert.strictEqual(result.sent, 1);
	assert.strictEqual(result.waiting, 2);
	assert.deepStrictEqual(queue.all().map((i) => i.clientId), ['c-2', 'c-3']);
});

test('the app was killed mid-send: the item is still there, and it is re-sent rather than stranded', async () => {
	// Exactly what a relaunch finds: an item persisted in `sending` because the process ended
	// between the write and the response.
	const storage = memoryStorage([
		{ clientId: 'c-1', threadId: 't', kind: 'text', text: 'half-sent', state: 'sending', attempts: 1, queuedAt: '2026-09-18T10:00:00Z' }
	]);
	const queue = createQueue({ storage });
	const loaded = await queue.load();
	assert.strictEqual(loaded.count, 1);
	assert.strictEqual(loaded.resumed, 1, 'an interrupted send was left stranded');
	assert.strictEqual(queue.all()[0].state, WAITING);

	// And the re-send is safe because the Mac de-duplicates on the client id: this is the
	// `duplicate: true` path, and it counts as sent rather than as a second message.
	const result = await queue.flush({
		async sendText(item) { return { message_id: 'm-earlier', cursor: 42, duplicate: true }; },
		async sendVoice() { throw new Error('not used'); }
	});
	assert.strictEqual(result.sent, 1);
	assert.strictEqual(result.duplicates, 1);
	assert.strictEqual(queue.count(), 0);
});

test('his Mac forgot this phone: the queue stops and says so, and never retries it', async () => {
	const storage = memoryStorage();
	const queue = createQueue({ storage });
	await queue.enqueue({ clientId: 'c-1', threadId: 't', kind: 'text', text: 'anyone there?' });

	let attempts = 0;
	const forgetful = {
		async sendText() { attempts++; throw new ApiError(REVOKED, 'this phone was removed from your Mac'); },
		async sendVoice() { throw new Error('not used'); }
	};

	const first = await queue.flush(forgetful);
	assert.strictEqual(first.blocked, 1);
	assert.strictEqual(first.reason, REVOKED);
	assert.strictEqual(queue.all()[0].state, BLOCKED);

	const second = await queue.flush(forgetful);
	assert.strictEqual(attempts, 1, 'it tried a revoked device again');
	assert.strictEqual(second.blocked, 1);
});

test('a fault is retried on the outbox’s own clock, one second later — not on the stream’s thirty', async () => {
	// THIS TEST CHANGED, AND THE CHANGE IS THE FIX. It used to assert that a second `flush` sent
	// the message whenever one happened to be called — which was true, and was the defect: the
	// only thing that called one unprompted was `lib/link.js` reconnecting the stream, capped at
	// 30 s. Ray measured 30.67 s, 54.47 s and 48.79 s on nightly `.7` and one send that never
	// arrived at all. The outbox has its own policy now (T3 Code's `threadOutboxRetryDelayMs`),
	// and a test that cannot see time cannot tell the two apart — so the clock is injected.
	const storage = memoryStorage();
	let ms = 1_000_000;
	const queue = createQueue({ storage, clock: () => ms });
	await queue.enqueue({ clientId: 'c-1', threadId: 't', kind: 'text', text: 'try again' });

	let calls = 0;
	const sometimes = {
		async sendText() {
			calls++;
			if (calls === 1) throw new ApiError(FAULT, 'your Mac answered with 500', 500);
			return { message_id: 'm', cursor: 5 };
		},
		async sendVoice() { throw new Error('not used'); }
	};

	await queue.flush(sometimes);
	assert.strictEqual(queue.all()[0].state, WAITING);
	// It is owed another try in ONE SECOND, and a flush before then spends no attempt on a
	// condition that has not changed.
	assert.strictEqual(queue.dueInMs(), 1000);
	const tooSoon = await queue.flush(sometimes);
	assert.strictEqual(calls, 1, 'the backoff was ignored and an attempt was spent early');
	assert.strictEqual(tooSoon.deferred, 1);
	assert.strictEqual(tooSoon.sent, 0);

	ms += 1000;
	assert.strictEqual(queue.dueInMs(), 0);
	const second = await queue.flush(sometimes);
	assert.strictEqual(second.sent, 1);
	assert.strictEqual(calls, 2);
	assert.strictEqual(queue.dueInMs(), null, 'an empty outbox still claims to be owed a try');
});

test('the retry schedule doubles from a second and stops at sixteen — the arithmetic, not a sleep', async () => {
	// Ported from T3 Code (MIT, `pingdotgg/t3code` @ `8ebb6112`,
	// `apps/mobile/src/state/thread-outbox-model.ts:163-165`), and re-derived here rather than
	// quoted: attempt 1 waits 1,000 ms, so a message that keeps failing is tried again at
	// t = 1 s, 3 s, 7 s, 15 s, 31 s, and every 16 s after that — against a FIRST attempt that is
	// immediate. Five attempts inside the first half-minute, where the old path made one and
	// then waited for a stream whose ceiling is 30 s.
	const { retryDelayMs } = createQueue({ storage: memoryStorage() });
	assert.deepStrictEqual(
		[1, 2, 3, 4, 5, 6, 7].map(retryDelayMs),
		[1000, 2000, 4000, 8000, 16000, 16000, 16000]
	);
	// The cumulative schedule, which is the number a person would actually feel.
	let t = 0;
	const at = [1, 2, 3, 4, 5].map((n) => (t += retryDelayMs(n)));
	assert.deepStrictEqual(at, [1000, 3000, 7000, 15000, 31000]);
	// And it is BELOW the stream's own ceiling, which is the whole point of it being separate.
	assert.ok(retryDelayMs(99) < require('../lib/link.js').MAX_RETRY_MS);
});

test('the first attempt is immediate: a message he just typed is never held by a clock', async () => {
	const storage = memoryStorage();
	let ms = 5_000_000;
	const queue = createQueue({ storage, clock: () => ms });
	await queue.enqueue({ clientId: 'c-first', threadId: 't', kind: 'text', text: 'now' });
	assert.strictEqual(queue.dueInMs(), 0, 'a fresh message was put on a backoff it never earned');

	let sentAt = null;
	const mac = {
		async sendText() { sentAt = ms; return { message_id: 'm', cursor: 1 }; },
		async sendVoice() { throw new Error('not used'); }
	};
	const result = await queue.flush(mac);
	assert.strictEqual(result.sent, 1);
	assert.strictEqual(sentAt, 5_000_000);
});

test('a message he removes mid-send stays removed — the write that lost the race does not bring it back', async () => {
	// T3 Code's compare-and-set (`apps/mobile/src/state/thread-outbox-manager.ts:51-57, 164-177`):
	// *"a writer that captured a revision before slow work"* must lose to a write accepted since.
	// Ours had the same hole and it was reachable — `flush` awaits the network inside its `try`,
	// and the error path then wrote the item back over the top of a `discard` that had landed
	// during the await. What he saw was a message he had removed, back on his phone.
	const storage = memoryStorage();
	const queue = createQueue({ storage });
	await queue.enqueue({ clientId: 'c-gone', threadId: 't', kind: 'text', text: 'remove me' });

	const slow = {
		async sendText(item) {
			// He taps "Remove this message" while this request is in flight.
			await queue.discard(item.clientId);
			throw new ApiError(UNREACHABLE, 'Load failed');
		},
		async sendVoice() { throw new Error('not used'); }
	};

	await queue.flush(slow);
	assert.deepStrictEqual(queue.all(), [], 'the discarded message came back');
	assert.strictEqual(storage.map.size, 0, 'the discarded message is still on the phone');
	assert.strictEqual(queue.dueInMs(), null);
});

test('"Try again" means now, not when a backoff this app chose comes round', async () => {
	const storage = memoryStorage();
	let ms = 9_000_000;
	const queue = createQueue({ storage, clock: () => ms });
	await queue.enqueue({ clientId: 'c-tap', threadId: 't', kind: 'text', text: 'again' });

	let calls = 0;
	const mac = {
		async sendText() {
			calls++;
			if (calls === 1) throw new ApiError(FAULT, 'your Mac answered with 500', 500);
			return { message_id: 'm', cursor: 2 };
		},
		async sendVoice() { throw new Error('not used'); }
	};
	await queue.flush(mac);
	assert.strictEqual(queue.dueInMs(), 1000);

	// His tap. Nothing about the clock has changed and it must not matter.
	queue.retryEverythingNow();
	assert.strictEqual(queue.dueInMs(), 0);
	const result = await queue.flush(mac);
	assert.strictEqual(result.sent, 1);
	assert.strictEqual(calls, 2);
});

test('a launch that died mid-send starts over with no wait: the Mac’s client_id makes the repeat free', async () => {
	const storage = memoryStorage([
		{ clientId: 'c-crash', threadId: 't', kind: 'text', text: 'mid-flight', state: 'sending', attempts: 1, queuedAt: '2026-09-19T10:00:00.000Z', notBefore: 9_999_999_999_999 }
	]);
	const queue = createQueue({ storage, clock: () => 1_000_000 });
	const loaded = await queue.load();
	assert.strictEqual(loaded.resumed, 1);
	assert.strictEqual(queue.dueInMs(), 0, 'a resumed message was left sitting on a stale clock');
});

test('two flushes at once collapse into one, so an item is never sent twice by our own hand', async () => {
	const storage = memoryStorage();
	const queue = createQueue({ storage });
	await queue.enqueue({ clientId: 'c-1', threadId: 't', kind: 'text', text: 'once' });

	let inFlight = 0;
	let maxInFlight = 0;
	const slow = {
		async sendText() {
			inFlight++;
			maxInFlight = Math.max(maxInFlight, inFlight);
			await new Promise((r) => setTimeout(r, 20));
			inFlight--;
			return { message_id: 'm', cursor: 1 };
		},
		async sendVoice() { throw new Error('not used'); }
	};

	const [a, b] = await Promise.all([queue.flush(slow), queue.flush(slow)]);
	assert.strictEqual(maxInFlight, 1, 'two flushes ran over the same item');
	assert.strictEqual(a, b, 'the second flush did not join the first');
	assert.strictEqual(queue.count(), 0);
});

test('he can drop a message he no longer wants to send, and it goes from the phone too', async () => {
	const storage = memoryStorage();
	const queue = createQueue({ storage });
	await queue.enqueue({ clientId: 'c-1', threadId: 't', kind: 'text', text: 'never mind' });
	await queue.discard('c-1');
	assert.strictEqual(queue.count(), 0);
	assert.strictEqual(storage.map.size, 0);
});

test('a voice note is queued whole — the bytes survive, not just the fact that there were bytes', async () => {
	const storage = memoryStorage();
	const queue = createQueue({ storage });
	const bytes = new Uint8Array([0x52, 0x49, 0x46, 0x46, 9, 8, 7]);
	await queue.enqueue({ clientId: 'c-1', threadId: 't', kind: 'voice', bytes: Array.from(bytes), seconds: 1.5 });

	const reloaded = createQueue({ storage });
	await reloaded.load();
	const item = reloaded.all()[0];
	assert.strictEqual(item.kind, 'voice');
	assert.deepStrictEqual(item.bytes, [0x52, 0x49, 0x46, 0x46, 9, 8, 7], 'the audio did not survive the round trip');
	assert.strictEqual(item.seconds, 1.5);
});

test('the change callback fires on every transition, so the screen can never be stale', async () => {
	const storage = memoryStorage();
	const seen = [];
	const queue = createQueue({ storage, onChange: (items) => seen.push(items.map((i) => i.state)) });
	await queue.enqueue({ clientId: 'c-1', threadId: 't', kind: 'text', text: 'x' });
	await queue.flush(macThatIsUnreachable());
	assert.deepStrictEqual(seen, [['waiting'], ['sending'], ['waiting']]);
});

// ---------------------------------------------------------------------------------------------
// RULE 2 HAS A LIMIT, AND THIS IS IT (plan §2 A)
// ---------------------------------------------------------------------------------------------
//
// The flush stops at the first message that COULD NOT GO, because his third sentence must never
// overtake his first. It does NOT stop at a message that will NEVER go. A blocked item leaves this
// queue in exactly two ways — he discards it, or the phone is unpaired — so nothing behind it is
// waiting its turn; it is waiting for a turn that does not exist. `flush` already knew that on
// every pass after the first (`if (item.state === BLOCKED) continue`) and forgot it on the pass
// that did the blocking, which is the pass he is looking at.
//
// The story: he records a voice note in his first minute with the app. This build cannot take one.
// Then he types. If the refusal held the queue, his typing would sit behind a recording that is
// never going anywhere, under "Waiting to send — your Mac isn't reachable from here", while the Mac
// two rooms away is answering every request it is given.

test('a refusal that is FINAL does not hold the queue: the text he typed after the voice note still goes', async () => {
	const storage = memoryStorage();
	const queue = createQueue({ storage, now: (() => { let n = 0; return () => `2026-09-19T09:00:0${n++}Z`; })() });
	await queue.enqueue({ clientId: 'c-voice', threadId: 't', kind: 'voice', bytes: [1, 2, 3], seconds: 2 });
	await queue.enqueue({ clientId: 'c-text', threadId: 't', kind: 'text', text: 'and here is the thing I actually wanted to say' });

	const attempted = [];
	const macWithoutVoice = {
		async sendText(item) { attempted.push(item.clientId); return { message_id: 'm', cursor: 7 }; },
		async sendVoice(item) {
			attempted.push(item.clientId);
			// The fourth argument is `aboutThisMessage`, and it is exactly what `api.js` sets when
			// the Mac answers `"retry": false` — see the end-to-end test below, which asserts the
			// same behavior with nothing hand-built between the queue and the bytes.
			throw new ApiError(REFUSED, 'Voice notes are not switched on yet. Your recording is still on your phone.', 503, true);
		}
	};

	const result = await queue.flush(macWithoutVoice);
	assert.deepStrictEqual(attempted, ['c-voice', 'c-text'], 'the text behind a message that can never go was never even tried');
	assert.strictEqual(result.sent, 1, 'his text did not reach the Mac');
	assert.strictEqual(result.blocked, 1);
	assert.strictEqual(result.waiting, 0, 'something was left waiting that nothing is waiting for');
	assert.deepStrictEqual(queue.all().map((i) => i.clientId), ['c-voice'], 'the text is still on the phone');
	assert.strictEqual(queue.all()[0].state, BLOCKED);
	// The banner counts, and the sentence he reads, are computed from these two.
	assert.strictEqual(queue.blocked().length, 1);
	assert.strictEqual(queue.waitingCount(), 0);
	// The Mac's own words are kept, because they are the only explanation of a refusal that exists.
	assert.match(storage.map.get('c-voice').lastMessage, /Voice notes are not switched on yet/);
});

test('a message that CAN still go is still held behind: a final refusal did not loosen the ordering rule', async () => {
	const storage = memoryStorage();
	const queue = createQueue({ storage, now: (() => { let n = 0; return () => `2026-09-19T09:00:0${n++}Z`; })() });
	await queue.enqueue({ clientId: 'c-voice', threadId: 't', kind: 'voice', bytes: [1], seconds: 1 });
	await queue.enqueue({ clientId: 'c-1', threadId: 't', kind: 'text', text: 'first' });
	await queue.enqueue({ clientId: 'c-2', threadId: 't', kind: 'text', text: 'second' });

	const attempted = [];
	const macWithoutVoiceAndOffline = {
		async sendText(item) { attempted.push(item.clientId); throw new ApiError(UNREACHABLE, 'Load failed'); },
		async sendVoice(item) { attempted.push(item.clientId); throw new ApiError(REFUSED, 'not switched on yet', 503, true); }
	};

	const result = await queue.flush(macWithoutVoiceAndOffline);
	assert.deepStrictEqual(attempted, ['c-voice', 'c-1'], 'his second sentence was allowed to overtake his first');
	assert.strictEqual(result.blocked, 1);
	assert.strictEqual(result.waiting, 2);
	// The reason the SCREEN shows is the one that is actually holding things up, not the one that
	// was merely first. "Waiting to send" is true of two messages here; "not sent" is true of one.
	assert.strictEqual(result.reason, UNREACHABLE);
});

test('a refusal about the PHONE still stops everything — rule 4 survived rule 2 gaining a limit', async () => {
	// The counterweight to the two tests above, and the reason the flush cannot simply carry on
	// past everything non-retryable. A Mac that has forgotten this phone will refuse the second
	// message for the same reason it refused the first, and walking the queue to find that out
	// three more times is rule 4's "a phone hammering a Mac that has forgotten it".
	for (const [reason, note] of [[REVOKED, 'a forgotten phone'], [REFUSED, 'a flat 404 for a phone this Mac does not know']]) {
		const storage = memoryStorage();
		const queue = createQueue({ storage, now: (() => { let n = 0; return () => `2026-09-19T09:00:0${n++}Z`; })() });
		await queue.enqueue({ clientId: 'c-1', threadId: 't', kind: 'text', text: 'one' });
		await queue.enqueue({ clientId: 'c-2', threadId: 't', kind: 'text', text: 'two' });
		await queue.enqueue({ clientId: 'c-3', threadId: 't', kind: 'text', text: 'three' });

		let attempts = 0;
		// No fourth argument: this refusal is about the phone, not about the message.
		const forgetful = {
			async sendText() { attempts++; throw new ApiError(reason, note, 404); },
			async sendVoice() { throw new Error('not used'); }
		};

		const result = await queue.flush(forgetful);
		assert.strictEqual(attempts, 1, `${note}: the queue was walked against a Mac that had already answered`);
		assert.strictEqual(result.blocked, 1);
		assert.strictEqual(result.reason, reason);
		assert.strictEqual(queue.count(), 3, `${note}: a message was dropped rather than kept for him`);
	}
});

test('the whole chain, from the Mac\'s bytes: a 503 marked final blocks that item and nothing else', async () => {
	// Nothing is stubbed between the queue and the wire except `fetch` itself, because the defect
	// this pair of tests is about lived in the JOIN of the two modules and in neither of them.
	const storage = memoryStorage();
	const queue = createQueue({ storage, now: (() => { let n = 0; return () => `2026-09-19T09:00:0${n++}Z`; })() });
	await queue.enqueue({ clientId: 'c-voice', threadId: 't', kind: 'voice', bytes: [0x52, 0x49, 0x46, 0x46], seconds: 1 });
	await queue.enqueue({ clientId: 'c-text', threadId: 't', kind: 'text', text: 'morning' });

	const urls = [];
	const api = createApi({
		state: { apiBase: 'https://mm1.tail9a3b2.ts.net:8443', challenge: 'ch', deviceId: 'd' },
		signer: {
			deviceId: 'd',
			async sign() { return 'signature'; },
			async sha256Hex() { return '0'.repeat(64); }
		},
		fetchImpl: async (url) => {
			urls.push(url);
			// Exactly what `routes.rs` answers a voice note in this build, byte for byte.
			if (url.includes('kind=voice')) {
				return jsonResponse(503, {
					accepted: false,
					retry: false,
					reason: 'Voice notes are not switched on yet. Your recording is still on your phone.'
				});
			}
			return jsonResponse(200, { message_id: 'm-1', cursor: 12 });
		},
		eventSourceImpl: null
	});

	const result = await queue.flush(api);
	assert.strictEqual(urls.length, 2, 'the text was never put on the wire');
	assert.strictEqual(result.sent, 1);
	assert.strictEqual(result.blocked, 1);
	assert.strictEqual(queue.all().map((i) => i.clientId).join(','), 'c-voice');
	assert.strictEqual(queue.all()[0].lastReason, REFUSED);

	// And it stays blocked: a second flush does not put the recording back on the wire.
	const again = await queue.flush(api);
	assert.strictEqual(urls.length, 2, 'a refusal that will never change was sent again');
	assert.strictEqual(again.blocked, 1);
});

// ---------------------------------------------------------------------------------------------
// THE WHOLE OF RAY'S FOURTH SEND, ACROSS BOTH HALVES OF THE FIX, over the real route module.
//
// A page load empties the Mac's live-challenge set (`phone/device.rs` `issue_challenge`, and
// `sw.js` reloads a nineteen-entry shell on install), so the credential this phone is holding is
// refused with a flat 404. On nightly `.7` that was REFUSED, REFUSED is not retryable, and the
// message was BLOCKED: `Not sent.` beside it, and never delivered at all.
// ---------------------------------------------------------------------------------------------

test('a send refused because the Mac replaced the challenge is delivered on the same flush, not blocked', async () => {
	const storage = memoryStorage();
	const queue = createQueue({ storage, clock: () => 1_000_000 });
	await queue.enqueue({ clientId: 'c-ray4', threadId: 't', kind: 'text', text: 'ray r3 pass three' });

	let n = 0;
	const state = { apiBase: 'https://mm1.tail9a3b2.ts.net:8443', challenge: 'evicted', deviceId: 'd' };
	const api = createApi({
		state,
		origin: 'https://mm1.tail9a3b2.ts.net:8443',
		signer: { deviceId: 'd', async sign() { return 'signature'; }, async sha256Hex() { return '0'.repeat(64); } },
		fetchImpl: async () => {
			n += 1;
			// The Mac's flat refusal, with the fresh challenge every answer on that port carries.
			if (n === 1) {
				const r = jsonResponse(404, {});
				r.headers = { get: (k) => (k === 'X-RichOS-Challenge' ? 'live' : null) };
				return r;
			}
			const ok = jsonResponse(200, { message_id: 'intake_9', cursor: 12 });
			ok.headers = { get: (k) => (k === 'X-RichOS-Challenge' ? 'newer' : null) };
			return ok;
		},
		eventSourceImpl: null
	});

	const result = await queue.flush(api);
	assert.strictEqual(result.sent, 1, 'the message was blocked instead of being re-signed and sent');
	assert.strictEqual(result.blocked, 0);
	assert.strictEqual(n, 2, 'the stale credential was not retried inside the one flush');
	assert.deepStrictEqual(queue.all(), [], 'a delivered message is still on the phone');
	assert.strictEqual(state.challenge, 'newer');
	// And it did not cost a wait: nothing is left owed a try.
	assert.strictEqual(queue.dueInMs(), null);
});
