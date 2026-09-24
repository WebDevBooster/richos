// challenge.json, retry.json and errors.json: what the phone does with each answer the Mac gives.
//
// All three drive the real `api.js` (credential, re-sign-once rule, classification) and, where
// the question is "what happens to the message", the real `queue.js` behind it.

import { load, makeApi, answer, unreachable, transcript, outcome, challenge, sha256hex } from './harness.mjs';
import { mac } from './signing.mjs';

const JSON_TYPE = { 'Content-Type': 'application/json; charset=utf-8' };
const accepted = (n, extra = {}) => ({ message_id: `intake_${n}`, cursor: n, thread_id: 'thr_5c1e', accepted_at: '2026-09-22T13:00:00.412Z', duplicate: false, ...extra });
const item = (n, text = `message ${n}`) => ({ clientId: `01J8CONFORMANCERETRY00000${String(n).padStart(2, '0')}`, threadId: 'thr_5c1e', kind: 'text', text, sentAt: `2026-09-22T13:00:0${n}.000Z` });

function withMac(requests) {
	return requests.map((request) => (request.signed ? { ...request, mac: mac(request) } : request));
}

// ---- challenge refresh -----------------------------------------------------------------------

async function challengeCase(name, script, call = (api) => api.sendText(item(1)), start = 'held') {
	const { api, mac: fake, signer, state } = makeApi({ script, state: { challenge: challenge(start) } });
	const result = await outcome(call(api));
	if (result.ok && result.value && typeof result.value === 'object' && !('message_id' in result.value) && !('messages' in result.value)) result.value = null;
	return {
		name,
		challenge_held_before: challenge(start),
		mac_answers: script,
		requests: withMac(transcript(fake, signer)),
		outcome: result,
		challenge_held_after: state.challenge,
		stale_credential_retries: api.staleCredentialRetries()
	};
}

export async function challengeRefresh() {
	const fresh = challenge('fresh');
	const other = challenge('fresher');
	const cases = [
		await challengeCase('404 carrying a different challenge: re-sign once with it, then 200',
			[answer(404, '', { 'X-RichOS-Challenge': fresh }), answer(200, accepted(1), { ...JSON_TYPE, 'X-RichOS-Challenge': fresh })]),
		await challengeCase('404 carrying the same challenge: final, no second request',
			[answer(404, '', { 'X-RichOS-Challenge': challenge('held') })]),
		await challengeCase('404 carrying no challenge: final, no second request',
			[answer(404, '')]),
		await challengeCase('404, re-signed, 404 again: final after exactly two requests',
			[answer(404, '', { 'X-RichOS-Challenge': fresh }), answer(404, '', { 'X-RichOS-Challenge': other })]),
		await challengeCase('200 rotates the challenge the phone holds',
			[answer(200, accepted(1), { ...JSON_TYPE, 'X-RichOS-Challenge': fresh })]),
		await challengeCase('query credential (backfill): 404 with a different challenge is re-signed the same way',
			[answer(404, '', { 'X-RichOS-Challenge': fresh }), answer(200, { messages: [], more: false }, { ...JSON_TYPE, 'X-RichOS-Challenge': fresh })],
			(api) => api.backfill('thr_5c1e', 41, 50)),
		await challengeCase('probe GET /api/challenge: unsigned, status ignored, header taken',
			[answer(404, '', { 'X-RichOS-Challenge': fresh })], (api) => api.refreshChallenge(), 'expired'),
		await challengeCase('probe answered without a challenge header: fault',
			[answer(404, '')], (api) => api.refreshChallenge(), 'expired'),
		await challengeCase('probe cannot reach the Mac: unreachable',
			[unreachable()], (api) => api.refreshChallenge(), 'expired')
	];
	return {
		source: 'web/web-app/lib/api.js request/attempt (the once-only re-sign) and refreshChallenge',
		rule: 'A signed request answered 404 whose X-RichOS-Challenge differs from the challenge it signed is re-signed with the new challenge and sent ONCE more. A second 404 is final. Every response header challenge replaces the held one. The probe GET /api/challenge is unsigned and its status is ignored.',
		cases
	};
}

// ---- retry byte-identity ---------------------------------------------------------------------

function memoryStorage() {
	const rows = new Map();
	return { all: async () => [...rows.values()].map((r) => structuredClone(r)), put: async (r) => { rows.set(r.clientId, structuredClone(r)); }, remove: async (id) => { rows.delete(id); } };
}

async function retryCase(name, items, script, flushes) {
	const { createQueue } = load('queue');
	let clock = 1_000_000;
	const { api, mac: fake, signer } = makeApi({ script, state: { challenge: challenge('retry') } });
	const storage = memoryStorage();
	const queue = createQueue({ storage, clock: () => clock, now: () => new Date(clock).toISOString() });
	for (const i of items) await queue.enqueue(i);
	const passes = [];
	for (const advance of flushes) {
		clock += advance;
		const r = await queue.flush(api);
		passes.push({ at_ms: clock - 1_000_000, sent: r.sent, waiting: r.waiting, blocked: r.blocked, duplicates: r.duplicates, reason: r.reason, due_in_ms: queue.dueInMs() });
	}
	const requests = withMac(transcript(fake, signer));
	const bodies = requests.map((r) => r.body && r.body.sha256_hex);
	return {
		name,
		items,
		mac_answers: script,
		passes,
		requests,
		body_bytes_identical_across_attempts: bodies.every((b) => b === bodies[0]),
		whole_request_identical_across_attempts: requests.every((r) => JSON.stringify(r) === JSON.stringify(requests[0]))
	};
}

export async function retry() {
	const fresh = challenge('rotated');
	const wav = Array.from(new Uint8Array(load('pcm').encodeWav(Float32Array.from({ length: 80 }, (_, i) => (i % 8) / 8 - 0.5), 16000)));
	const voice = { clientId: '01J8CONFORMANCERETRYVOICE01', threadId: 'thr_5c1e', kind: 'voice', bytes: wav, seconds: 0.005, codec: 'wav16k', sampleRate: 16000, sentAt: '2026-09-22T13:00:09.000Z', text: 'Voice message' };
	const cases = [
		await retryCase('Mac unreachable, then accepted: the retry is the same bytes under the same challenge',
			[item(1)], [unreachable(), answer(200, accepted(1), JSON_TYPE)], [0, 1000]),
		await retryCase('503 {"accepted":false} with a rotated challenge: same body bytes, re-signed',
			[item(1)], [answer(503, { accepted: false, reason: 'could not write the receipt' }, { ...JSON_TYPE, 'X-RichOS-Challenge': fresh }), answer(200, accepted(1), { ...JSON_TYPE, 'X-RichOS-Challenge': fresh })], [0, 1000]),
		await retryCase('the retry is answered duplicate:true: the message is delivered once',
			[item(1)], [unreachable(), answer(200, accepted(1, { duplicate: true }), JSON_TYPE)], [0, 1000]),
		await retryCase('voice: unreachable, then accepted: the WAV and its signed query are resent unchanged',
			[voice], [unreachable(), answer(200, accepted(1, { text_sha256: sha256hex(Buffer.from('voice transcript')) }), JSON_TYPE)], [0, 1000]),
		await retryCase('backoff: 1 s doubling, capped at 16 s; a pass before the item is due sends nothing',
			[item(1)], [unreachable(), unreachable(), unreachable(), unreachable(), unreachable(), unreachable(), answer(200, accepted(1), JSON_TYPE)],
			[0, 999, 1, 2000, 4000, 8000, 16000, 16000])
	];
	return {
		source: 'web/web-app/lib/queue.js flush/retryDelayMs over web/web-app/lib/api.js sendText/sendVoice',
		rule: 'A retry of a message resends the exact body bytes of the first attempt. The Mac keys receipts on (device_id, client_id) plus SHA-256 of the body, so different bytes under the same client_id are a 409 (contract section 5.2). Persist the bytes, not the fields.',
		retry_delay_ms: [1, 2, 3, 4, 5, 6].map((attempt) => ({ attempt, delay_ms: load('queue').createQueue({ storage: memoryStorage() }).retryDelayMs(attempt) })),
		cases
	};
}

// ---- error statuses and the action each requires ---------------------------------------------

const ERRORS = [
	['200 accepted', [answer(200, accepted(1), JSON_TYPE)]],
	['200 duplicate', [answer(200, accepted(1, { duplicate: true }), JSON_TYPE)]],
	['transport failure (Mac unreachable)', [unreachable()]],
	['403 {"revoked":true}', [answer(403, { revoked: true }, JSON_TYPE)]],
	['403 without revoked', [answer(403, { other: true }, JSON_TYPE)]],
	['404 empty (no new challenge)', [answer(404, '')]],
	['409 {"retry":false} (client_id reused with different bytes)', [answer(409, { retry: false, reason: 'that client_id was used for a different message' }, JSON_TYPE)]],
	['413 empty (body too large or too slow)', [answer(413, '')]],
	['422 {"retry":false} (this item can never be taken)', [answer(422, { accepted: false, retry: false, reason: 'no speech' }, JSON_TYPE)]],
	['422 {"retryable":false} (native push refusal key)', [answer(422, { reason: 'unsupported', retryable: false }, JSON_TYPE)]],
	['429 with Retry-After: 60', [answer(429, '', { 'Retry-After': '60' })]],
	['500 empty', [answer(500, '')]],
	['503 {"retry":false} (uncertain intake)', [answer(503, { retry: false, reason: 'your Mac may already have this message' }, JSON_TYPE)]],
	['503 {"accepted":false} (receipt not written)', [answer(503, { accepted: false, reason: 'could not write the receipt' }, JSON_TYPE)]],
	['503 {"reason":"unreachable","retryable":true}', [answer(503, { reason: 'unreachable', retryable: true, message: 'push service unreachable' }, JSON_TYPE)]]
];

// WHERE THE REFERENCE AND THE CONTRACT DISAGREE, THE CONTRACT WINS, and each such case is
// declared here with its section rather than hidden in a JSON edit. `reference` is always what
// the shipped modules did; `required` is what a native client must do. Every other case
// requires exactly the reference's behavior.
const CONTRACT = {
	'413 empty (body too large or too slow)': {
		required: { client_action: 'final_for_this_item_queue_continues', retry_after_ms: null },
		because: 'Contract section 4.2: 413 is final for that exact request. The same bytes will be refused again, and the reference retries them forever on its 1 s to 16 s backoff, holding the queue behind them.'
	},
	'429 with Retry-After: 60': {
		required: { client_action: 'retry_same_bytes_after_backoff', retry_after_ms: 60000 },
		because: 'Contract sections 3.5 and 4.2: wait Retry-After seconds. The reference ignores the header and retries after 1 s, which spends the rolling 60-per-minute budget it was just refused for.'
	},
	'422 {"retryable":false} (native push refusal key)': {
		required: { client_action: 'final_for_this_item_queue_continues', retry_after_ms: null },
		because: 'Contract sections 4.2 and 11 item 7: this body is final. api.js reads only "retry" === false and so calls it a retryable fault. The shipped Mac bridge never returns it today.'
	}
};
const NOTES = {
	'403 {"revoked":true}': 'core/app.js sets paired = false on reason "revoked"; the client then forgets the key and offers to pair again (contract section 4.2). Contract section 4.4: a forgotten phone usually sees an unreachable Mac instead, so do not wait for this 403 before offering to pair again.'
};

function action(result, a) {
	if (a.state === 'sent') return 'delivered';
	if (a.state === 'waiting') return 'retry_same_bytes_after_backoff';
	if (result.reason === 'revoked') return 'phone_forgotten_stop_queue_and_unpair';
	return a.attemptedNext ? 'final_for_this_item_queue_continues' : 'final_stop_queue';
}

/// One Mac answer through the real api.js classification and queue.js flush, with two messages
/// queued: the shape of every errors.json case. Exported so pairing.json can carry the one case
/// that belongs to pairing (the Mac waiting for its own press) in exactly the same shape.
export async function errorCase(name, first, override, note) {
	const { createQueue } = load('queue');
	let clock = 1_000_000;
	const script = [...first, answer(200, accepted(2), JSON_TYPE)];
	const { api, mac: fake, signer } = makeApi({ script, state: { challenge: challenge('errors') } });
	const direct = await outcome(makeApi({ script: first, state: { challenge: challenge('errors') } }).api.sendText(item(1)));
	const queue = createQueue({ storage: memoryStorage(), clock: () => clock, now: () => new Date(clock).toISOString() });
	await queue.enqueue(item(1));
	await queue.enqueue(item(2));
	const r = await queue.flush(api);
	const left = queue.all().find((i) => i.clientId === item(1).clientId);
	const attemptedNext = fake.sent.some((s) => s.bytes && s.bytes.toString('utf8').includes(item(2).clientId));
	const a = { state: left ? left.state : 'sent', attemptedNext };
	const reference = {
		classification: direct.ok ? null : direct.error,
		message_state_after: a.state,
		retry_after_ms: left && left.state === 'waiting' ? left.notBefore - clock : null,
		next_message_attempted: attemptedNext,
		queue_reason: r.reason,
		client_action: action(r, a),
		requests: transcript(fake, signer).map((q) => ({ method: q.method, target: q.target, client_id: JSON.parse(q.body.utf8).client_id }))
	};
	return {
		name,
		mac_answer: first[0],
		required: override ? override.required : { client_action: reference.client_action, retry_after_ms: reference.retry_after_ms },
		required_source: override ? 'contract' : 'reference',
		...(override ? { required_because: override.because } : {}),
		...(note ? { note } : {}),
		reference
	};
}

export async function errors() {
	for (const name of [...Object.keys(CONTRACT), ...Object.keys(NOTES)]) {
		if (!ERRORS.some(([n]) => n === name)) throw new Error(`errors: a contract override names no case: ${name}`);
	}
	const cases = [];
	for (const [name, first] of ERRORS) cases.push(await errorCase(name, first, CONTRACT[name], NOTES[name]));
	return {
		source: 'web/web-app/lib/api.js classification (ApiError reason/retryable/aboutThisMessage) and web/web-app/lib/queue.js flush, with two messages queued',
		client_actions: {
			delivered: 'remove from the outbox; keep the stand-in bubble until the Mac row arrives',
			retry_same_bytes_after_backoff: 'keep the message waiting and resend the SAME bytes when retry_after_ms has passed; nothing behind it goes first',
			final_for_this_item_queue_continues: 'block this message (show it to the person with a way to discard) and carry on with the rest of the queue',
			final_stop_queue: 'block this message and stop the queue: the refusal is about the phone, not the message',
			phone_forgotten_stop_queue_and_unpair: 'the Mac forgot this phone: stop, delete the key and pairing, clear the outbox, offer to pair again'
		},
		cases
	};
}
