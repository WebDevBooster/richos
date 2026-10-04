// Signing in on the access page with a real browser. Node tests that send an explicit `Origin`
// header cannot see what a browser sends: under `Referrer-Policy: no-referrer` Chromium sends
// `Origin: null` on a same-site form POST, and the page's own forgery check then refused every
// real sign-in ("Not allowed. This form must be sent from the review access page itself.").
//
// This drives headless Chromium against the bundled Worker in workerd (`dev/local.mjs`). The
// browser's requests to the access name are answered by the local Worker through Playwright's
// request interception, with the headers the browser actually computed passed through untouched.
// Skipped, with the reason, where Playwright or Wrangler is not installed.

import test from 'node:test';
import assert from 'node:assert/strict';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';
import { locateWrangler, startLocalReview } from '../dev/local.mjs';
import { locatePlaywright } from '../dev/playwright.mjs';
import { hashPassword } from '../src/session.mjs';
import { b64url } from '../src/codec.mjs';

const ACCESS = 'review.example.com';
const HOST = 'review-a.example.com';

async function until(read, ms = 15_000) {
	for (const end = Date.now() + ms; Date.now() < end;) {
		const value = read();
		if (value) return value;
		await new Promise((done) => setTimeout(done, 50));
	}
	throw new Error('the browser never sent the sign-in form');
}

test('a real browser signs in on the access page and reaches the pairing view', { timeout: 120_000 }, async (t) => {
	const wrangler = locateWrangler();
	if (!wrangler) return t.skip('Cloudflare local runtime not installed (no Wrangler with Miniflare and esbuild on PATH; set RICHOS_WRANGLER_DIR)');
	const playwrightDir = locatePlaywright();
	if (!playwrightDir) return t.skip('Playwright not installed (set RICHOS_PLAYWRIGHT_DIR to its package directory)');
	const { chromium } = await import(pathToFileURL(join(playwrightDir, 'index.mjs')).href);

	const password = 'browser check password';
	const local = await startLocalReview({
		ACCESS_HOSTNAME: ACCESS,
		REVIEW_HOSTS: JSON.stringify([{ hostname: HOST, label: 'Browser check', username: 'browser' }]),
		REVIEW_PASSWORD_HASHES: JSON.stringify({ browser: await hashPassword(password) }),
		SESSION_KEY: b64url(new Uint8Array(32).fill(5))
	}, wrangler);
	t.after(() => local.dispose());

	const browser = await chromium.launch();
	t.after(() => browser.close());
	const page = await browser.newPage();

	const seen = [];
	await page.route(`https://${ACCESS}/**`, async (route) => {
		const request = route.request();
		const headers = { ...request.headers() };
		delete headers.host;
		delete headers['content-length'];
		const entry = { method: request.method(), path: new URL(request.url()).pathname, origin: headers.origin };
		seen.push(entry);
		let response = await local.fetch(request.url(), { method: request.method(), headers, body: request.postDataBuffer(), redirect: 'manual' });
		entry.status = response.status;
		// Playwright sends a redirect it fulfilled to the real network, not back through this handler,
		// so the redirect is followed here, carrying the cookie the Worker set, as a browser would.
		const cookies = [];
		for (let hops = 0; response.status >= 300 && response.status < 400 && hops < 3; hops++) {
			const set = response.headers.get('set-cookie');
			if (set) cookies.push(set);
			const next = new URL(response.headers.get('location'), request.url()).href;
			await response.arrayBuffer();
			response = await local.fetch(next, { headers: { ...headers, cookie: cookies.map((c) => c.split(';')[0]).join('; ') }, redirect: 'manual' });
		}
		const out = {};
		response.headers.forEach((value, key) => { out[key] = value; });
		if (cookies.length) out['set-cookie'] = cookies[0];
		await route.fulfill({ status: response.status, headers: out, body: Buffer.from(await response.arrayBuffer()) });
	});

	await page.goto(`https://${ACCESS}/`);
	await page.fill('input[name=username]', 'browser');
	await page.fill('input[name=password]', password);
	await page.click('button[type=submit], input[type=submit]');
	await until(() => seen.find((r) => r.path === '/login' && r.status));
	// Either the pairing view or the refusal page arrives; wait for whichever heading comes first.
	await page.locator('h2, h1:has-text("Not allowed")').first().waitFor({ timeout: 15_000 });

	const body = await page.locator('body').innerText();
	const post = seen.find((r) => r.method === 'POST' && r.path === '/login');
	assert.ok(post, 'the browser sent the sign-in form');
	assert.doesNotMatch(body, /Not allowed/, `the browser's own sign-in was refused (it sent Origin: ${post.origin})`);
	assert.equal(post.origin, `https://${ACCESS}`, 'the browser names the access page as the origin of its form post');
	assert.match(body, /Pair your phone/i, 'signed in, the reviewer sees the pairing view');
});
