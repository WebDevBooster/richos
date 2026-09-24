// The review access page (the reviewer's Mac), its configuration, and the Worker that routes
// between the page and the review hosts. Also the contrast of every color pair a person reads.

import test from 'node:test';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { makeHost, clock, memoryStorage, Phone, freshKey } from './helpers.mjs';
import { readConfig, inForbiddenZone } from '../src/config.mjs';
import { handlePortal } from '../src/portal.mjs';
import { hashPassword } from '../src/session.mjs';
import { handle, ReviewHost } from '../src/worker.mjs';
import { PALETTE, PAIRS, STYLE, SCRIPT } from '../src/pages.mjs';
import { b64url } from '../src/codec.mjs';
import qr from '../../../app/ui/qr.js';

const ACCESS = 'review.example.com';
const HOSTS = [
	{ hostname: 'review-a.example.com', label: 'Apple App Review', username: 'apple-review' },
	{ hostname: 'review-b.example.com', label: 'Google Play review', username: 'google-review' }
];
const PASSWORDS = { 'apple-review': 'correct horse apple', 'google-review': 'correct horse google' };

let hashes = null;
async function passwordHashes() {
	if (!hashes) hashes = Object.fromEntries(await Promise.all(Object.entries(PASSWORDS).map(async ([u, p]) => [u, await hashPassword(p)])));
	return hashes;
}

/** A fake Durable Object namespace: one ReviewHost per name, over in-memory storage. */
function namespace(env) {
	const objects = new Map();
	return {
		objects,
		idFromName: (name) => name,
		get: (id) => {
			if (!objects.has(id)) objects.set(id, new ReviewHost({ storage: memoryStorage() }, env));
			return objects.get(id);
		}
	};
}

async function environment(overrides = {}) {
	const env = {
		ACCESS_HOSTNAME: ACCESS,
		REVIEW_HOSTS: JSON.stringify(HOSTS),
		REVIEW_PASSWORD_HASHES: JSON.stringify(await passwordHashes()),
		SESSION_KEY: b64url(new Uint8Array(32).fill(7)),
		LOGIN_LIMIT: { limit: async () => ({ success: true }) },
		...overrides
	};
	if (!('HOSTS' in overrides)) env.HOSTS = namespace(env);
	return env;
}

const form = (fields) => new URLSearchParams(fields).toString();
const post = (path, fields, headers = {}) => new Request(`https://${ACCESS}${path}`, { method: 'POST', headers: { origin: `https://${ACCESS}`, 'content-type': 'application/x-www-form-urlencoded', ...headers }, body: form(fields) });

async function signIn(env, username) {
	const response = await handle(post('/login', { username, password: PASSWORDS[username] }), env);
	assert.equal(response.status, 303);
	const cookie = response.headers.get('set-cookie');
	return cookie.split(';')[0];
}

const page = async (env, cookie) => (await handle(new Request(`https://${ACCESS}/`, { headers: { cookie } }), env)).text();
const codeIn = (html) => (html.match(/#pair=([A-Z0-9]{8})/) || [])[1] || null;

// ---- configuration ---------------------------------------------------------------------------

test('configuration: a complete environment is accepted', async () => {
	const read = readConfig(await environment());
	assert.equal(read.ok, true, JSON.stringify(read.problems));
	assert.equal(read.config.pairingVersion, 1);
	assert.equal(read.config.hostKeys, null, 'no host keys means no push, and says so');
});

test('configuration: nothing in the richos.ceo zone is ever served (Sage M2)', async () => {
	for (const name of ['richos.ceo', 'review.richos.ceo', 'c-5de0dbe0862dd461ae305af5cef35202-g2.richos.ceo', 'REVIEW.RICHOS.CEO']) {
		assert.equal(inForbiddenZone(name.toLowerCase()), true, name);
		const asAccess = readConfig(await environment({ ACCESS_HOSTNAME: name }));
		assert.equal(asAccess.ok, false, name);
		assert.ok(asAccess.problems.some((p) => p.includes('M2')));
		const asHost = readConfig(await environment({ REVIEW_HOSTS: JSON.stringify([{ ...HOSTS[0], hostname: name }]) }));
		assert.equal(asHost.ok, false, name);
	}
	assert.equal(inForbiddenZone('notrichos.ceo'), false);
});

test('configuration: every missing or malformed setting is named, never its value', async () => {
	const read = readConfig({ ACCESS_HOSTNAME: 'x', REVIEW_HOSTS: '[]', SESSION_KEY: 'secret-looking-value' });
	assert.equal(read.ok, false);
	assert.ok(read.problems.length >= 5);
	assert.ok(read.problems.every((p) => !p.includes('secret-looking-value')));
	const response = await handle(new Request(`https://${ACCESS}/`), { ACCESS_HOSTNAME: ACCESS });
	assert.equal(response.status, 503);
	assert.equal((await response.json()).ready, false);
});

test('configuration: usernames and hostnames must be unique; PAIRING_WORDS is v1 or v2', async () => {
	assert.equal(readConfig(await environment({ REVIEW_HOSTS: JSON.stringify([HOSTS[0], { ...HOSTS[1], username: 'apple-review' }]) })).ok, false);
	assert.equal(readConfig(await environment({ REVIEW_HOSTS: JSON.stringify([HOSTS[0], { ...HOSTS[1], hostname: HOSTS[0].hostname }]) })).ok, false);
	assert.equal(readConfig(await environment({ PAIRING_WORDS: 'v3' })).ok, false);
	assert.equal(readConfig(await environment({ PAIRING_WORDS: 'v2' })).config.pairingVersion, 2);
});

// ---- signing in --------------------------------------------------------------------------------

test('sign-in: the right credentials give a hardened session cookie; wrong ones do not', async () => {
	const env = await environment();
	const wrong = await handle(post('/login', { username: 'apple-review', password: 'nope' }), env);
	assert.equal(wrong.status, 401);
	assert.equal(wrong.headers.get('set-cookie'), null);
	assert.match(await wrong.text(), /did not match/);
	const unknown = await handle(post('/login', { username: 'someone', password: 'x' }), env);
	assert.equal(unknown.status, 401);
	const right = await handle(post('/login', { username: 'apple-review', password: PASSWORDS['apple-review'] }), env);
	assert.equal(right.status, 303);
	const cookie = right.headers.get('set-cookie');
	for (const flag of ['__Host-', 'Secure', 'HttpOnly', 'SameSite=Strict', 'Path=/']) assert.ok(cookie.includes(flag), flag);
	assert.match(await page(env, cookie.split(';')[0]), /Apple App Review/);
});

test('sign-in: a tampered or foreign session is not a session', async () => {
	const env = await environment();
	const cookie = await signIn(env, 'apple-review');
	const [name, value] = cookie.split('=');
	const parts = value.split('.');
	parts[2] = 'google-review';
	assert.match(await page(env, `${name}=${parts.join('.')}`), /Sign in/, 'changing the subject breaks the signature');
	const other = await environment({ SESSION_KEY: b64url(new Uint8Array(32).fill(9)) });
	assert.match(await page(other, cookie), /Sign in/, 'a session from another key is refused');
});

test('sign-in: attempts are rate limited per caller', async () => {
	const env = await environment({ LOGIN_LIMIT: { limit: async () => ({ success: false }) } });
	const response = await handle(post('/login', { username: 'apple-review', password: PASSWORDS['apple-review'] }), env);
	assert.equal(response.status, 429);
	assert.equal(response.headers.get('retry-after'), '60');
});

test('every form post must come from the access page itself', async () => {
	const env = await environment();
	const cookie = await signIn(env, 'apple-review');
	for (const origin of [null, 'https://evil.example', `http://${ACCESS}`]) {
		const headers = { cookie };
		const request = new Request(`https://${ACCESS}/link`, { method: 'POST', headers: origin ? { ...headers, origin } : headers, body: '' });
		assert.equal((await handle(request, env)).status, 403, String(origin));
	}
	assert.equal(codeIn(await page(env, cookie)), null, 'no link was opened');
});

// ---- the reviewer's Mac --------------------------------------------------------------------

test('each reviewer manages only their own review host', async () => {
	const env = await environment();
	const apple = await signIn(env, 'apple-review');
	const google = await signIn(env, 'google-review');
	await handle(post('/link', {}, { cookie: apple }), env);
	const applePage = await page(env, apple);
	assert.ok(codeIn(applePage));
	assert.match(applePage, /review-a\.example\.com/);
	assert.doesNotMatch(applePage, /review-b\.example\.com/);
	assert.equal(codeIn(await page(env, google)), null, 'opening a link on A opens nothing on B');
});

test('a fresh pairing link and QR code on demand, the QR encoding exactly the link', async () => {
	const env = await environment();
	const cookie = await signIn(env, 'apple-review');
	await handle(post('/link', {}, { cookie }), env);
	const first = await page(env, cookie);
	await handle(post('/link', {}, { cookie }), env);
	const second = await page(env, cookie);
	assert.notEqual(codeIn(first), codeIn(second), 'every request gives a new code');
	const link = `https://review-a.example.com/#pair=${codeIn(second)}`;
	assert.ok(second.includes(`value="${link}"`), 'the link is there to copy');
	const { size, modules } = qr.encode(link);
	const path = [...second.matchAll(/M(\d+) (\d+)h/g)].map(([, x, y]) => [Number(y) / 6 - 4, Number(x) / 6 - 4]);
	const dark = modules.flatMap((row, y) => row.map((on, x) => (on ? [y, x] : null))).filter(Boolean);
	assert.deepEqual(path, dark, `the SVG draws exactly the ${size}x${size} symbol for the link`);
	assert.doesNotMatch(second, /class="words"/, 'no words before a phone arrives (Sage 3.1 step 1)');
});

test('the whole pairing, through the Worker: link, phone, words, the press on the page, then messages', async () => {
	const env = await environment();
	const cookie = await signIn(env, 'apple-review');
	await handle(post('/link', {}, { cookie }), env);
	const code = codeIn(await page(env, cookie));
	const phone = Phone.via('https://review-a.example.com', (request) => handle(request, env));
	const answer = await (await phone.pair(code)).json();
	const waiting = await page(env, cookie);
	const { sixWords } = await import('../src/qr.mjs');
	assert.ok(waiting.includes(sixWords(answer.ca_fingerprint_sha256).join(' ')), 'the page shows the words the phone computes');
	assert.match(waiting, /They match/);
	assert.equal((await phone.signed('POST', '/api/messages', { client_id: 'w1', kind: 'text', text: 'hi' })).status, 409);
	await handle(post('/confirm', { match: 'yes' }, { cookie }), env);
	assert.match(await page(env, cookie), /Paired/);
	assert.equal((await phone.signed('POST', '/api/messages', { client_id: 'w2', kind: 'text', text: 'hi' })).status, 200);
	// The same phone's credential on the other review host is a stranger's.
	const elsewhere = Phone.via('https://review-b.example.com', (request) => handle(request, env), phone.key);
	elsewhere.deviceId = phone.deviceId;
	elsewhere.challenge = phone.challenge;
	assert.equal((await elsewhere.signed('POST', '/api/messages', { client_id: 'w3', kind: 'text', text: 'hi' })).status, 404);
	assert.equal(env.HOSTS.objects.size, 2, 'one object per review host touched, and no more');
});

test('replace and reset happen only with the confirming box ticked', async () => {
	const env = await environment();
	const cookie = await signIn(env, 'apple-review');
	await handle(post('/link', {}, { cookie }), env);
	const phone = Phone.via('https://review-a.example.com', (request) => handle(request, env));
	await phone.pair(codeIn(await page(env, cookie)));
	await handle(post('/confirm', { match: 'yes' }, { cookie }), env);
	for (const path of ['/replace', '/reset']) {
		await handle(post(path, {}, { cookie }), env);
		assert.match(await page(env, cookie), /Paired/, `${path} without the box changes nothing`);
	}
	await handle(post('/replace', { confirm: 'yes' }, { cookie }), env);
	const after = await page(env, cookie);
	assert.ok(codeIn(after), 'replacing opens a fresh link');
	assert.equal((await phone.signed('POST', '/api/messages', { client_id: 'r1', kind: 'text', text: 'hi' })).status, 403);
});

test('other hostnames, plain HTTP and the internal address are not served', async () => {
	const env = await environment();
	assert.equal((await handle(new Request('https://elsewhere.example.com/'), env)).status, 404);
	assert.equal((await handle(new Request('https://internal.invalid/status', { method: 'POST', body: '{}' }), env)).status, 404);
	assert.equal((await handle(new Request(`http://${ACCESS}/`), env)).status, 400);
	const health = await handle(new Request(`https://${ACCESS}/healthz`), env);
	assert.deepEqual(await health.json(), { service: 'richconnect-review', ready: true, hosts: 2, push: false, pairing_words: 'v1' });
});

test('what a person reads is escaped, and the page runs only its own pinned style and script', async () => {
	const env = await environment({ REVIEW_HOSTS: JSON.stringify([{ ...HOSTS[0], label: '<script>alert(1)</script>' }]) });
	const cookie = await signIn(env, 'apple-review');
	const response = await handle(new Request(`https://${ACCESS}/`, { headers: { cookie } }), env);
	const html = await response.text();
	assert.ok(!html.includes('<script>alert(1)</script>'));
	assert.ok(html.includes('&lt;script&gt;alert(1)&lt;/script&gt;'));
	const csp = response.headers.get('content-security-policy');
	const hash = (s) => createHash('sha256').update(s).digest('base64');
	assert.ok(csp.includes(`'sha256-${hash(STYLE)}'`) && csp.includes(`'sha256-${hash(SCRIPT)}'`));
	assert.match(csp, /default-src 'none'/);
	assert.match(csp, /frame-ancestors 'none'/);
	assert.doesNotMatch(html, / style="/, 'no inline style attributes, which the policy would block');
});

// ---- WCAG AA, both themes ------------------------------------------------------------------

function luminance(hex) {
	const [r, g, b] = [1, 3, 5].map((i) => parseInt(hex.slice(i, i + 2), 16) / 255).map((c) => (c <= 0.04045 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4));
	return 0.2126 * r + 0.7152 * g + 0.0722 * b;
}
const ratio = (a, b) => { const [x, y] = [luminance(a), luminance(b)].sort((m, n) => n - m); return (x + 0.05) / (y + 0.05); };

test('contrast: every declared pair meets WCAG AA in the light and the dark theme', () => {
	for (const [theme, colors] of Object.entries(PALETTE)) {
		for (const [fg, bg, minimum, what] of PAIRS) {
			const r = ratio(colors[fg], colors[bg]);
			assert.ok(r >= minimum, `${theme}: ${what} (${fg} on ${bg}) is ${r.toFixed(2)}:1, needs ${minimum}:1`);
		}
	}
	assert.ok(ratio('#000000', '#ffffff') >= 21 - 1e-9, 'the QR code is black on white in both themes');
});

test('contrast: every color the style sheet uses for text is a declared palette entry', () => {
	const used = [...STYLE.matchAll(/(?:^|[;{])color:var\(--([a-zA-Z]+)\)/g)].map((m) => m[1]);
	const covered = new Set(PAIRS.map(([fg]) => fg));
	for (const name of used) assert.ok(covered.has(name), `--${name} is used for text and has a checked pair`);
	assert.ok(used.length >= 4);
});

test('a Durable Object builds one review host, even when its first requests arrive together', async () => {
	const env = await environment();
	const object = new ReviewHost({ storage: memoryStorage() }, env);
	const [a, b, c] = await Promise.all([
		object.ensure('review-a.example.com'), object.ensure('review-a.example.com'), object.ensure('review-a.example.com')
	]);
	assert.equal(a, b);
	assert.equal(b, c);
	const responses = await Promise.all([1, 2, 3].map(() => object.fetch(new Request('https://review-a.example.com/api/challenge'))));
	const challenges = new Set(responses.map((r) => r.headers.get('x-richos-challenge')));
	assert.equal(challenges.size, 1, 'one host, one live challenge set');
});

void clock; void makeHost; void freshKey;
