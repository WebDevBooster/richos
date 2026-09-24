'use strict';

// "LOAD OLDER MESSAGES", AGAINST A STUB THAT IS AS STRICT AS THE SHIPPED MAC.
//
// `node --test "test/*.test.js"`.
//
// THE DEFECT THIS FILE EXISTS FOR. `GET /api/events` on the real Mac reads its credential from the
// QUERY and from nowhere else — `routes.rs:403-411`:
//
//     let Some(auth) = query_value(&request.query, "auth") else { return Outcome::NotFound };
//
// and `grep -n 'request.authorization' routes.rs` answers `:210`, `:304`, `:504` and nothing inside
// `events()`. `lib/api.js` `backfill()` went through `request()`, which puts the credential in the
// `Authorization` HEADER. So every "load older messages" scroll on a real Mac was a flat 404, and
// nothing in this repository could see it, because `test/stub-mac.js` accepted the header OR the
// query on every route — more permissive than the Mac it stands in for.
//
// THE FIX IS ON THE PHONE, NOT THE MAC. `/api/events` is one route with one contract and the stream
// already signs it in the query; the Mac does not grow a second way to be asked so that the
// backfill can keep its habit. And the stub is now strict per route, so this class of defect cannot
// hide again — `stub-mac.js` `authenticate()` takes a required `where`.
//
// This test drives the REAL `lib/api.js` over REAL TLS against that stub, with a real ECDSA P-256
// signature verified by `node:crypto` on the far side. `fetch` in Node cannot be handed a private
// certificate authority, so the `fetchImpl` here is `node:https` carrying the stub's own CA —
// which is the same trust decision his phone makes when it installs the profile.

const test = require('node:test');
const assert = require('node:assert');
const crypto = require('node:crypto');
const https = require('node:https');

const { createStubMac } = require('./stub-mac.js');
const { createApi, signingInput } = require('../lib/api.js');

/// `fetch`, in the shape `lib/api.js` uses it, over a certificate authority Node can be told about.
function httpsFetch(caPem) {
	return (url, init) => new Promise((resolve, reject) => {
		const req = https.request(url, {
			method: (init && init.method) || 'GET',
			headers: (init && init.headers) || {},
			ca: caPem
		}, (res) => {
			const chunks = [];
			res.on('data', (c) => chunks.push(c));
			res.on('end', () => {
				const text = Buffer.concat(chunks).toString('utf8');
				const make = () => ({
					status: res.statusCode,
					ok: res.statusCode >= 200 && res.statusCode < 300,
					headers: { get: (k) => res.headers[k.toLowerCase()] || null },
					text: async () => text,
					json: async () => JSON.parse(text),
					clone: () => make(),
					blob: async () => ({ size: text.length })
				});
				resolve(make());
			});
		});
		req.on('error', reject);
		if (init && init.body !== undefined && init.body !== null) req.write(init.body);
		req.end();
	});
}

function makeSigner() {
	const { privateKey, publicKey } = crypto.generateKeyPairSync('ec', { namedCurve: 'prime256v1' });
	return {
		publicJwk: publicKey.export({ format: 'jwk' }),
		async sign(input) {
			return crypto.sign('sha256', Buffer.from(input, 'utf8'),
				{ key: privateKey, dsaEncoding: 'ieee-p1363' }).toString('base64url');
		},
		async sha256Hex(bytes) {
			return crypto.createHash('sha256').update(bytes).digest('hex');
		}
	};
}

/// A stub Mac, listening, with this phone already paired to it.
async function pairedPhone(t) {
	const mac = createStubMac({ host: 'localhost', pairCode: 'harness-pair-code' });
	const port = await mac.listen(0);
	t.after(() => mac.close());

	const origin = `https://localhost:${port}`;
	const signer = makeSigner();
	const state = { apiBase: origin, challenge: null, deviceId: null };
	const api = createApi({ state, signer, origin, fetchImpl: httpsFetch(mac.caPem) });

	await api.pair('harness-pair-code', signer.publicJwk, 'the harness');
	assert.ok(state.deviceId, 'pairing did not come back with a device');
	// The phone's answer to the six words; the stub's default Mac presses They match with it
	// (Sage F1: nothing but that answer reaches a Mac until the press).
	await api.confirmFingerprint(true);
	return { mac, api, state, signer, origin, caPem: mac.caPem };
}

test('a v2 phone waits for the press on the Mac over the real wire, and is let in only after it', async (t) => {
	const mac = createStubMac({ host: 'localhost', pairCode: 'harness-pair-code', macPress: 'manual' });
	const port = await mac.listen(0);
	t.after(() => mac.close());
	const origin = `https://localhost:${port}`;
	const signer = makeSigner();
	const state = { apiBase: origin, challenge: null, deviceId: null };
	const api = createApi({ state, signer, origin, fetchImpl: httpsFetch(mac.caPem) });

	const answer = await api.pair('harness-pair-code', signer.publicJwk, 'the harness', { pairingVersion: 2 });
	assert.ok(answer.capabilities.includes('pair-v2'));
	const said = await api.confirmFingerprint(true);
	assert.strictEqual(said.awaiting_mac_confirmation, true, 'the Mac did not tell the phone to wait for its press');
	assert.strictEqual(await api.macConfirmed(null), false, 'the phone was let in on its own say-so');
	await assert.rejects(api.backfill(null, 0, 1), (err) => err.awaitingMac === true && err.retryable === true);
	mac.pressOnMac();
	assert.strictEqual(await api.macConfirmed(null), true, 'the press on the Mac did not let the phone in');

	// And the Mac's "They do not match" is the final answer the wait stops on.
	mac.refuseOnMac();
	await assert.rejects(api.macConfirmed(null), (err) => err.retryable === false);
});

/// A `GET` made by hand, so the credential can be put somewhere `lib/api.js` would not put it.
function rawStatus(origin, caPem, path, headers) {
	return new Promise((resolve, reject) => {
		const req = https.request(`${origin}${path}`, { method: 'GET', headers: headers || {}, ca: caPem }, (res) => {
			res.resume();
			res.on('end', () => resolve(res.statusCode));
		});
		req.on('error', reject);
		req.end();
	});
}

/// The `RichOS-Device …` value for a path, built the way `lib/api.js` builds it: over the path
/// WITHOUT the credential, with an empty body hash.
async function credentialFor(state, signer, pathWithQuery) {
	const signature = await signer.sign(signingInput(state.challenge, 'GET', pathWithQuery, ''));
	return `RichOS-Device ${state.deviceId}.${state.challenge}.${signature}`;
}

// --------------------------------------------------------------------------------------------
// THE COMPLETION CRITERION
// --------------------------------------------------------------------------------------------

test('he scrolls up and older messages arrive — against a stub that refuses what the Mac refuses', async (t) => {
	const { api, mac } = await pairedPhone(t);

	// The stub seeds 60 messages at cursors 1..60. Ask for twenty of what is before 41: that is
	// cursors 21..40, with twenty more behind them, so `more` has something true to say.
	const page = await api.backfill(mac.threadId, 41, 20);

	assert.strictEqual(page.messages.length, 20, 'no older messages came back');
	assert.strictEqual(page.messages[0].cursor, 21, 'the page did not start where it should');
	assert.strictEqual(page.messages[19].cursor, 40, 'the page ran past the cursor it was asked about');
	for (const row of page.messages) {
		assert.ok(row.cursor < 41, `a row at cursor ${row.cursor} is not older than 41`);
	}
	assert.strictEqual(page.more, true, 'the thread has twenty more behind this page and said it did not');

	// And the beginning of the thread is a real end, not an endless scroll into nothing.
	const first = await api.backfill(mac.threadId, 21, 40);
	assert.strictEqual(first.messages.length, 20);
	assert.strictEqual(first.more, false);
});

test('the credential travels the way the stream sends it, because `/api/events` is one route', async (t) => {
	const { api, mac, state, signer, origin, caPem } = await pairedPhone(t);

	const path = `/api/events?thread_id=${encodeURIComponent(mac.threadId)}&before=40&limit=5`;

	// A perfectly valid credential in the `Authorization` HEADER — the way `backfill()` used to
	// send it — gets the flat 404 `routes.rs:403-411` would give it, because `events()` never reads
	// that header. This is the assertion that was impossible to write before the stub got strict.
	const headerOnly = await credentialFor(state, signer, path);
	assert.strictEqual(
		await rawStatus(origin, caPem, path, { Authorization: headerOnly }), 404,
		'the stub accepted a header-only `events()` request that the shipped Mac refuses'
	);

	// THE POSITIVE CONTROL: the SAME credential, moved into the query, is 200. Without this, the
	// check above passes against a stub that refuses everything.
	const queryOnly = await credentialFor(state, signer, path);
	assert.strictEqual(
		await rawStatus(origin, caPem, `${path}&auth=${encodeURIComponent(queryOnly)}`, {}), 200,
		'the same credential in the query was refused too — the check above proves nothing'
	);

	// And the module under test takes the second road on its own.
	const page = await api.backfill(mac.threadId, 40, 5);
	assert.strictEqual(page.messages.length, 5);
});

test('the backfill signs the path WITHOUT the credential it appends, exactly as the stream does', async (t) => {
	// The Mac strips `auth` before it verifies (`routes.rs:572-586` `signed_path`), so a phone that
	// signed the full URL would fail authentication for a reason nobody would find quickly. The
	// stub does the same stripping and verifies a real signature, so a 200 here IS that assertion —
	// but the URL is inspected as well, because "it worked" and "it worked for the right reason"
	// are different claims.
	const { api, mac, signer } = await pairedPhone(t);
	const signed = [];
	const original = signer.sign.bind(signer);
	signer.sign = async (input) => { signed.push(input); return original(input); };

	await api.backfill(mac.threadId, 30, 10);

	const last = signed[signed.length - 1];
	const [, method, pathWithQuery, bodyHash] = last.split('\n');
	assert.strictEqual(method, 'GET');
	assert.strictEqual(bodyHash, '', 'a GET with no body signed something as its body');
	assert.ok(pathWithQuery.startsWith('/api/events?'), pathWithQuery);
	assert.strictEqual(pathWithQuery.includes('auth='), false, 'the signature covered its own credential');
	assert.ok(pathWithQuery.includes('before=30'), pathWithQuery);
});
