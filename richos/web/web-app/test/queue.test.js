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
const { ApiError, UNREACHABLE, REVOKED, FAULT } = require('../lib/api.js');

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

test('a fault is retried on the next flush, because a fault might not repeat', async () => {
	const storage = memoryStorage();
	const queue = createQueue({ storage });
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
	const second = await queue.flush(sometimes);
	assert.strictEqual(second.sent, 1);
	assert.strictEqual(calls, 2);
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
