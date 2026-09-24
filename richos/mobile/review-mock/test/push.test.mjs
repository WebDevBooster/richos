// Push from a review host through the REAL Connect Worker code (`mobile/service/connect-worker.mjs`)
// over a real SQLite copy of its D1 schema. Only the last hop, Apple and Google, is a fake: the
// senders the Worker hands each job to. So these tests prove the review host's signed control
// requests are accepted by the production handler, that a reply becomes exactly one job with a
// preview only the phone can open, and that no tunnel or DNS record is ever created (Sage M2).

import test from 'node:test';
import assert from 'node:assert/strict';
import { createRequire } from 'node:module';
import { generateKeyPairSync, createDecipheriv, createHash, randomBytes } from 'node:crypto';
import { makeHost, pairedPhone } from './helpers.mjs';
import { hostIdentity, connectClient, sealPreview } from '../src/push.mjs';
import { REPLY_DELAY_MS, PUSH_RETRY_MS } from '../src/host.mjs';

const require = createRequire(import.meta.url);
const { database } = require('../../test/connect-fixture.cjs');

const sha256hex = (s) => createHash('sha256').update(s).digest('hex');

function pkcs8() {
	const { privateKey } = generateKeyPairSync('ec', { namedCurve: 'P-256' });
	return privateKey.export({ format: 'der', type: 'pkcs8' }).toString('base64url');
}

/**
 * The Worker only checks that the FCM credential names its project and "contains a private key";
 * the senders are fakes, so nothing is ever signed with it. Built from words so it is plainly not
 * a key block.
 */
const FAKE_FCM_ACCOUNT = JSON.stringify({
	type: 'service_account', project_id: 'richconnect-test', client_email: 'push@richconnect-test.iam.gserviceaccount.com',
	private_key: ['placeholder, not a', 'PRIVATE', 'KEY'].join(' ')
});

async function connect(t, { admit = true } = {}) {
	const { Store } = await import('../../service/connect/store.mjs');
	const { handle } = await import('../../service/connect-worker.mjs');
	let time = 1_790_000_000_000;
	const db = database(t);
	const store = new Store(db, () => time);
	const sent = { apns: [], fcm: [] };
	let reachable = true;
	const provider = new Proxy({}, { get: () => () => { throw new Error('the review host must never provision a tunnel or DNS record'); } });
	const env = {
		DB: db, CF_API_TOKEN: 'server-only', CF_ACCOUNT_ID: 'a'.repeat(32), CF_ZONE_ID: 'b'.repeat(32), CONNECT_DOMAIN: 'example.com',
		HOST_CAPACITY: '10', ENROLLMENT_OPEN: 'false', REQUEST_LIMIT: { limit: async () => ({ success: true }) },
		APNS_TEAM_ID: 'A123456789', APNS_PRODUCTION_KEY_ID: 'B123456789', APNS_PRODUCTION_KEY: 'fixture', APNS_TOPICS: 'dev.richos.connect',
		FCM_PROJECT_ID: 'richconnect-test', FCM_APPS: 'dev.richos.connect', FCM_SERVICE_ACCOUNT: FAKE_FCM_ACCOUNT
	};
	const ports = {
		store, provider, now: () => time,
		apns: { send: async (binding, job) => { sent.apns.push({ binding, job }); return { outcome: 'sent' }; } },
		fcm: { send: async (binding, job) => { sent.fcm.push({ binding, job }); return { outcome: 'sent' }; } }
	};
	const identity = await hostIdentity(pkcs8());
	if (admit) await db.prepare('INSERT INTO allowed_hosts(id) VALUES (?)').bind(identity.id).run();
	const fetchImpl = async (request) => {
		if (!reachable) throw new TypeError('fetch failed');
		return handle(request, env, ports);
	};
	const control = connectClient({ origin: 'https://connect.example.com', identity, fetchImpl, now: () => time });
	const binding = (id) => db.prepare('SELECT * FROM push_bindings WHERE host_id=?').bind(id).first();
	return { db, identity, control, sent, binding, advance: (ms) => { time += ms; }, offline: (v) => { reachable = !v; } };
}

function open(previewKey, threadRef, eventRef, envelope) {
	const body = Buffer.from(envelope.body, 'base64url');
	const decipher = createDecipheriv('aes-256-gcm', previewKey, Buffer.from(envelope.nonce, 'base64url'));
	decipher.setAAD(Buffer.from(`richos-preview-v1\n${threadRef}\n${eventRef}`));
	decipher.setAuthTag(body.subarray(body.length - 16));
	return Buffer.concat([decipher.update(body.subarray(0, body.length - 16)), decipher.final()]).toString('utf8');
}

const text = (id, words, thread = 'thr_review_welcome') => ({ client_id: id, thread_id: thread, kind: 'text', text: words, sent_at: '2026-09-24T00:00:00.000Z' });
const APNS = { token: 'ab'.repeat(32), environment: 'production', topic: 'dev.richos.connect' };

test('an iPhone registration is accepted by the production Worker, and a demo reply becomes one sealed notification', async (t) => {
	const c = await connect(t);
	const { host, now } = makeHost({ push: { control: c.control } });
	const phone = await pairedPhone(host);
	const previewKey = randomBytes(32);
	const registration = { ...APNS, preview_key: previewKey.toString('base64url'), previews: true };
	const answer = await phone.signed('POST', '/api/pair', { native_push: registration });
	assert.equal(answer.status, 200);
	assert.deepEqual(await answer.json(), { host_id: c.identity.id, registered: true });
	const row = await c.binding(c.identity.id);
	assert.equal(row.token, registration.token);
	assert.equal(row.route, 'tailnet', 'a review host is never reached through a Connect tunnel');
	assert.equal(row.device_hash, sha256hex(Buffer.concat([Buffer.from([4]), Buffer.from(phone.key.jwk.x, 'base64url'), Buffer.from(phone.key.jwk.y, 'base64url')])));

	await phone.signed('POST', '/api/messages', text('p1', 'Send me the board deck.'));
	now.advance(REPLY_DELAY_MS);
	await host.alarm();
	assert.equal(c.sent.apns.length, 1, 'one reply, one notification');
	const { job } = c.sent.apns[0];
	const reply = (await host.rows('thr_review_welcome')).at(-1);
	assert.equal(job.event_ref, sha256hex(reply.id));
	assert.equal(job.thread_ref, sha256hex('thr_review_welcome'));
	const preview = open(previewKey, job.thread_ref, job.event_ref, JSON.parse(job.preview));
	assert.ok(preview.startsWith('Demo reply: '), 'the preview the phone decrypts is labeled a demo');
	assert.ok(Array.from(preview).length <= 240);
	assert.ok(!JSON.stringify(c.sent).includes('board deck'), 'no plaintext reaches the Worker or the sender');
	await host.alarm();
	assert.equal(c.sent.apns.length, 1, 'the alarm running again sends nothing new');
});

test('an Android registration goes to FCM through the same path', async (t) => {
	const c = await connect(t);
	const { host, now } = makeHost({ push: { control: c.control } });
	const phone = await pairedPhone(host, undefined, 'Android phone');
	const response = await phone.signed('POST', '/api/pair', { native_push: { platform: 'fcm', token: `${'d'.repeat(11)}:APA91b${'x-y_z'.repeat(28)}`, topic: 'dev.richos.connect' } });
	assert.equal(response.status, 200);
	assert.equal((await c.binding(c.identity.id)).platform, 'fcm');
	await phone.signed('POST', '/api/messages', text('a1', 'Hello from Android'));
	now.advance(REPLY_DELAY_MS);
	await host.alarm();
	assert.equal(c.sent.fcm.length, 1);
	assert.equal(c.sent.apns.length, 0);
	assert.equal(c.sent.fcm[0].job.preview, null, 'no preview key, no preview');
});

test('a review host that is not admitted is refused by the Worker; the phone is told to retry, not that it failed', async (t) => {
	const c = await connect(t, { admit: false });
	const { host } = makeHost({ push: { control: c.control } });
	const phone = await pairedPhone(host);
	const response = await phone.signed('POST', '/api/pair', { native_push: APNS });
	assert.equal(response.status, 503);
	const body = await response.json();
	assert.equal(body.reason, 'unreachable');
	assert.equal(body.retryable, true);
});

test('a notification that could not be delivered is retried by the alarm, and still sent only once', async (t) => {
	const c = await connect(t);
	const { host, now, wakes } = makeHost({ push: { control: c.control } });
	const phone = await pairedPhone(host);
	await phone.signed('POST', '/api/pair', { native_push: APNS });
	await phone.signed('POST', '/api/messages', text('o1', 'offline for a moment'));
	c.offline(true);
	now.advance(REPLY_DELAY_MS);
	await host.alarm();
	assert.equal(c.sent.apns.length, 0);
	assert.ok(wakes.some((at) => at >= now() + PUSH_RETRY_MS - 1), 'a retry is scheduled');
	c.offline(false);
	now.advance(PUSH_RETRY_MS);
	c.advance(PUSH_RETRY_MS);
	await host.alarm();
	assert.equal(c.sent.apns.length, 1);
	await host.alarm();
	assert.equal(c.sent.apns.length, 1);
});

test('forgetting the phone removes its registration at the Worker; nothing is sent afterwards', async (t) => {
	const c = await connect(t);
	const { host, now } = makeHost({ push: { control: c.control } });
	const phone = await pairedPhone(host);
	await phone.signed('POST', '/api/pair', { native_push: APNS });
	await phone.signed('POST', '/api/messages', text('f1', 'last one'));
	await host.forget();
	assert.equal((await c.binding(c.identity.id)).token, null);
	now.advance(REPLY_DELAY_MS);
	await host.alarm();
	assert.equal(c.sent.apns.length, 0);
});

test('the phone can unregister', async (t) => {
	const c = await connect(t);
	const { host } = makeHost({ push: { control: c.control } });
	const phone = await pairedPhone(host);
	await phone.signed('POST', '/api/pair', { native_push: APNS });
	assert.equal((await c.binding(c.identity.id)).token, APNS.token);
	const off = await phone.signed('POST', '/api/pair', { native_push: null });
	assert.deepEqual(await off.json(), { host_id: c.identity.id, registered: false });
	assert.equal((await c.binding(c.identity.id)).token, null);
});

test('a host without push configured offers no push and says so', async () => {
	const { host } = makeHost();
	const phone = await pairedPhone(host);
	const response = await phone.signed('POST', '/api/pair', { native_push: APNS });
	assert.equal(response.status, 422);
	assert.deepEqual(await response.json(), { reason: 'unsupported', retryable: false });
	assert.ok(!host.capabilities().includes('native-push'));
});

test('the preview envelope is the Mac format: version 1, a 96-bit nonce, at most 240 characters sealed', async () => {
	const key = randomBytes(32);
	const envelope = await sealPreview(key.toString('base64url'), 't'.repeat(64), 'e'.repeat(64), 'word '.repeat(200));
	assert.equal(envelope.v, 1);
	assert.equal(Buffer.from(envelope.nonce, 'base64url').length, 12);
	assert.equal(open(key, 't'.repeat(64), 'e'.repeat(64), envelope).length, 240);
	assert.throws(() => open(key, 't'.repeat(64), 'x'.repeat(64), envelope), 'bound to the references');
});
