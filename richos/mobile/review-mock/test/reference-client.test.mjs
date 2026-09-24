// The whole review, end to end, with the REAL reference phone client (`web/web-app/lib/api.js`,
// the module the conformance corpus is generated from) in place of the phone: pair, confirm on the
// phone and on the access page, stream, text, voice, a demo reply streamed in pieces, the spoken
// reply, backfill and a push registration. The client's key is a WebCrypto key, as on a phone.

import test from 'node:test';
import assert from 'node:assert/strict';
import { createRequire } from 'node:module';
import { makeHost } from './helpers.mjs';
import { handlePhoneRequest } from '../src/phone.mjs';
import { REPLY_DELAY_MS } from '../src/host.mjs';
import { b64url } from '../src/codec.mjs';

const require = createRequire(import.meta.url);
const { createApi, FAULT } = require('../../../web/web-app/lib/api.js');
const { sseParser } = require('../../platform/native.js');
const { encodeWav } = require('../../../web/web-app/lib/pcm.js');
const { createThread } = require('../../../web/web-app/lib/thread.js');

async function webCryptoPhone() {
	const keys = await crypto.subtle.generateKey({ name: 'ECDSA', namedCurve: 'P-256' }, true, ['sign', 'verify']);
	const { kty, crv, x, y } = await crypto.subtle.exportKey('jwk', keys.publicKey);
	const signer = {
		async sign(input) { return b64url(new Uint8Array(await crypto.subtle.sign({ name: 'ECDSA', hash: 'SHA-256' }, keys.privateKey, new TextEncoder().encode(input)))); },
		async sha256Hex(payload) {
			const bytes = typeof payload === 'string' ? new TextEncoder().encode(payload) : payload;
			return Array.from(new Uint8Array(await crypto.subtle.digest('SHA-256', bytes)), (b) => b.toString(16).padStart(2, '0')).join('');
		}
	};
	return { jwk: { kty, crv, x, y }, signer };
}

/** An EventSource over the review host's real stream, parsed by the preserved app's parser. */
function eventSourceFor(fetchImpl, opened) {
	return class {
		constructor(url) {
			this.listeners = {};
			this.closed = false;
			opened.push(this);
			this.ready = (async () => {
				const response = await fetchImpl(url, {});
				this.status = response.status;
				if (response.status !== 200) { if (this.onerror) this.onerror(); return; }
				this.reader = response.body.getReader();
				const feed = sseParser((event, data) => (this.listeners[event] || []).forEach((fn) => fn({ data })));
				const decoder = new TextDecoder();
				while (!this.closed) {
					const { value, done } = await this.reader.read();
					if (done) break;
					feed(decoder.decode(value, { stream: true }));
				}
			})();
		}
		addEventListener(name, fn) { (this.listeners[name] ||= []).push(fn); }
		close() { this.closed = true; if (this.reader) this.reader.cancel().catch(() => {}); }
	};
}

const settle = () => new Promise((r) => setTimeout(r, 5));

test('the reference client reviews the whole app against a review host', async () => {
	const pushCalls = [];
	const control = { async call(method, path, body) { pushCalls.push(path); return path === '/v1/push/events' ? { status: 202, value: {} } : { status: 200, value: { hostId: 'c'.repeat(32), generation: 1 } }; } };
	const { host, now } = makeHost({ hostname: 'review-a.example.com', push: { control } });
	const origin = host.origin;
	const fetchImpl = (url, init = {}) => handlePhoneRequest(host, new Request(url, { method: init.method, headers: init.headers, body: init.body }));
	const opened = [];
	const { jwk, signer } = await webCryptoPhone();
	const state = { apiBase: origin, deviceId: null, challenge: null };
	const api = createApi({ state, signer, fetchImpl, origin, nativeClient: true, eventSourceImpl: eventSourceFor(fetchImpl, opened) });

	// Pair with a fresh link from the access page.
	const { code } = await host.openPairing();
	const answer = await api.pair(code, jwk, 'iPhone');
	assert.equal(state.deviceId, answer.device_id);
	assert.equal(state.apiBase, origin, 'the advertised api_base is the paired origin and is accepted');
	assert.equal(state.apiBaseRefusal, undefined);

	// Before the press on the access page, a send is a temporary fault: the queue keeps it.
	await assert.rejects(api.sendText({ clientId: 'early', threadId: 'thr_board_prep', text: 'too early', sentAt: new Date().toISOString() }), (e) => e.reason === FAULT);
	// The Mac's own answer while it waits for the press (`routes.rs`): the phone is told to wait.
	assert.deepEqual(await api.confirmFingerprint(true), { ok: true, awaiting_mac_confirmation: true });
	await host.confirmOnMac(true);

	// The stream opens with hello, which sets the challenge and the capabilities.
	const seen = [];
	const model = createThread();
	await api.openEvents('thr_board_prep', null, {
		hello: (d) => { seen.push('hello'); model.merge(d.messages); },
		message: (d) => { seen.push('message'); if (d.thread_id === 'thr_board_prep') model.merge(d); },
		delta: (d) => { seen.push('delta'); if (d.thread_id === 'thr_board_prep') model.applyDelta(d); }
	});
	await settle();
	assert.equal(seen[0], 'hello');
	for (const name of ['text', 'voice', 'audio', 'attachments', 'native-push', 'native-push-fcm']) assert.ok(api.offers(name), `offers ${name}`);

	// Text, and its demo reply streamed in pieces.
	const sent = await api.sendText({ clientId: 'rc-1', threadId: 'thr_board_prep', text: 'Can you add the churn numbers?', sentAt: new Date().toISOString() });
	assert.equal(sent.duplicate, false);
	now.advance(REPLY_DELAY_MS);
	await host.alarm();
	await settle();
	assert.ok(seen.filter((s) => s === 'delta').length > 1);
	const last = model.view([]).at(-1);
	assert.match(last.text, /^Demo reply: your message arrived: “Can you add the churn numbers\?”/);
	assert.equal(last.complete, true);

	// The spoken reply.
	const blob = await api.fetchAudio(last.id, 'thr_board_prep');
	const audio = new Uint8Array(await blob.arrayBuffer());
	assert.equal(String.fromCharCode(...audio.subarray(0, 4)), 'RIFF');

	// A voice note, encoded by the reference recorder's WAV encoder.
	const wav = new Uint8Array(encodeWav(Float32Array.from({ length: 16000 * 2 }, (_, i) => Math.sin(i / 8) * 0.2), 16000));
	const voice = await api.sendVoice({ clientId: 'rc-v1', threadId: 'thr_board_prep', bytes: wav, seconds: 2, sentAt: new Date().toISOString() });
	assert.equal(voice.duration_ms, 2000);

	// Scrolling back, and push.
	const page = await api.backfill('thr_board_prep', sent.cursor, 2);
	assert.equal(page.messages.length, 2);
	assert.equal(page.more, true);
	const registered = await api.registerNativePush({ token: 'ab'.repeat(32), environment: 'production', topic: 'dev.richos.connect' });
	assert.deepEqual(registered, { host_id: 'c'.repeat(32), registered: true });
	assert.deepEqual(pushCalls, ['/v1/push/hosts', '/v1/push/device']);

	for (const source of opened) source.close();
	await host.forget();
	assert.equal(api.staleCredentialRetries(), 0, 'the client never had to re-sign for a challenge the host dropped');
});
