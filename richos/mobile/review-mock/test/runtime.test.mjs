// The bundled review Worker inside workerd, the runtime Cloudflare runs. Skipped, with the reason,
// where no local runtime is installed. What it proves beyond the Node tests: the bundle builds
// (including the CommonJS QR encoder and word list it imports read-only), and workerd's WebCrypto,
// Durable Object storage and streaming behave as the review host needs.

import test from 'node:test';
import assert from 'node:assert/strict';
import { generateKeyPairSync, sign as nodeSign, createHash } from 'node:crypto';
import { locateWrangler, startLocalReview } from '../dev/local.mjs';
import { hashPassword } from '../src/session.mjs';
import { b64url } from '../src/codec.mjs';

const ACCESS = 'review.example.com';
const HOST = 'review-a.example.com';

test('workerd: sign in, get a link, pair, press They match, send a message and open the stream', { timeout: 120_000 }, async (t) => {
	const wrangler = locateWrangler();
	if (!wrangler) return t.skip('Cloudflare local runtime not installed (no Wrangler with Miniflare and esbuild on PATH; set RICHOS_WRANGLER_DIR)');
	const password = 'runtime check password';
	const local = await startLocalReview({
		ACCESS_HOSTNAME: ACCESS,
		REVIEW_HOSTS: JSON.stringify([{ hostname: HOST, label: 'Runtime check', username: 'runtime' }]),
		REVIEW_PASSWORD_HASHES: JSON.stringify({ runtime: await hashPassword(password) }),
		SESSION_KEY: b64url(new Uint8Array(32).fill(3))
	}, wrangler);
	t.after(() => local.dispose());
	t.diagnostic(`workerd compatibility date ${local.compatibilityDate}; bundle ${local.bytes} bytes`);

	const health = await local.fetch(`https://${ACCESS}/healthz`);
	assert.equal(health.status, 200, await health.clone().text());
	assert.equal((await health.json()).ready, true);

	// PBKDF2 at 100,000 iterations inside workerd, and the session cookie.
	const origin = `https://${ACCESS}`;
	const form = { 'content-type': 'application/x-www-form-urlencoded', origin };
	const login = await local.fetch(`${origin}/login`, { method: 'POST', headers: form, body: `username=runtime&password=${encodeURIComponent(password)}`, redirect: 'manual' });
	assert.equal(login.status, 303);
	const cookie = login.headers.get('set-cookie').split(';')[0];
	const link = await local.fetch(`${origin}/link`, { method: 'POST', headers: { ...form, cookie }, body: '', redirect: 'manual' });
	assert.equal(link.status, 303);
	await link.arrayBuffer();
	const page = await (await local.fetch(`${origin}/`, { headers: { cookie } })).text();
	const code = page.match(/#pair=([A-Z0-9]{8})/)[1];
	assert.match(page, /<svg[^>]+aria-label="QR code for the pairing link"/, 'the QR encoder bundled and ran');

	// A phone pairs at the review host, inside its Durable Object.
	const { privateKey, publicKey } = generateKeyPairSync('ec', { namedCurve: 'P-256' });
	const { x, y } = publicKey.export({ format: 'jwk' });
	const pair = await local.fetch(`https://${HOST}/api/pair`, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ code, public_key_jwk: { kty: 'EC', crv: 'P-256', x, y }, device_name: 'iPhone', platform: 'ios' }) });
	assert.equal(pair.status, 200);
	const answer = await pair.json();
	assert.equal(answer.api_base, `https://${HOST}`);
	let challenge = answer.challenge;
	const signed = async (method, target, body) => {
		const bytes = body ? Buffer.from(JSON.stringify(body)) : null;
		const input = `${challenge}\n${method}\n${target}\n${bytes ? createHash('sha256').update(bytes).digest('hex') : ''}`;
		const signature = nodeSign('sha256', Buffer.from(input), { key: privateKey, dsaEncoding: 'ieee-p1363' }).toString('base64url');
		const response = await local.fetch(`https://${HOST}${target}`, { method, headers: { authorization: `RichOS-Device ${answer.device_id}.${challenge}.${signature}`, ...(bytes ? { 'content-type': 'application/json' } : {}) }, body: bytes });
		challenge = response.headers.get('x-richos-challenge') || challenge;
		return response;
	};
	assert.equal((await signed('POST', '/api/messages', { client_id: 'rt-0', kind: 'text', text: 'before the press' })).status, 409);
	const words = await (await local.fetch(`${origin}/`, { headers: { cookie } })).text();
	assert.match(words, /class="words"/);
	const confirm = await local.fetch(`${origin}/confirm`, { method: 'POST', headers: { ...form, cookie }, body: 'match=yes', redirect: 'manual' });
	assert.equal(confirm.status, 303);
	await confirm.arrayBuffer();

	// WebCrypto P-256 verification of a real signature in workerd, and the receipt.
	const sent = await signed('POST', '/api/messages', { client_id: 'rt-1', kind: 'text', text: 'hello from workerd', thread_id: 'thr_review_welcome' });
	assert.equal(sent.status, 200, await sent.clone().text());
	assert.equal((await sent.json()).duplicate, false);

	// The stream opens with hello from the same object.
	const target = '/api/events?thread_id=thr_review_welcome';
	const input = `${challenge}\nGET\n${target}\n`;
	const signature = nodeSign('sha256', Buffer.from(input), { key: privateKey, dsaEncoding: 'ieee-p1363' }).toString('base64url');
	const stream = await local.fetch(`https://${HOST}${target}&auth=${encodeURIComponent(`RichOS-Device ${answer.device_id}.${challenge}.${signature}`)}`);
	assert.equal(stream.status, 200);
	assert.equal(stream.headers.get('content-type'), 'text/event-stream');
	const reader = stream.body.getReader();
	let text = '';
	while (!text.includes('\n\n')) text += new TextDecoder().decode((await reader.read()).value);
	await reader.cancel();
	assert.match(text, /^id: \d+\nevent: hello\ndata: \{/);
	assert.match(text, /hello from workerd/);

	// Another hostname is not served.
	assert.equal((await local.fetch('https://elsewhere.example.com/')).status, 404);
});
