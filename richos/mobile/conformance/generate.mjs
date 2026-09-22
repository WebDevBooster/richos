#!/usr/bin/env node
// THE CONFORMANCE CORPUS GENERATOR — both native RichOS apps must pass every vector it writes.
//
//   node richos/mobile/conformance/generate.mjs           write vectors/*.json
//   node richos/mobile/conformance/generate.mjs --check   regenerate in memory; exit 1 on any
//                                                          byte difference from what is on disk
//
// No dependencies, no network, about a second. Every expected value is produced by the REAL
// client modules (`web/web-app/lib/*.js`, `mobile/core/*.js`, `mobile/platform/native.js`)
// driven against a scripted Mac (`generator/harness.mjs`); none is typed by hand. Signatures
// are deterministic (RFC 6979, `generator/p256.mjs`), verified here with `node:crypto`, and
// verified again by the Mac's own Rust verifier in `verifier/` (`cargo test`).
//
// The corpus layout, its schema and how a Swift or Kotlin suite consumes it: README.md.

import { readFileSync, writeFileSync, mkdirSync, readdirSync, rmSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { selfTest } from './generator/p256.mjs';
import { SOURCES } from './generator/harness.mjs';
import { keys, pairing, fingerprint } from './generator/pairing.mjs';
import { validCases, invalidCases, tolerated, mac } from './generator/signing.mjs';
import { challengeRefresh, retry, errors } from './generator/transport.mjs';
import { events } from './generator/events.mjs';
import { voice } from './generator/voice.mjs';

const SCHEMA = 1;
const here = dirname(fileURLToPath(import.meta.url));
const VECTORS = join(here, 'vectors');

function placeholder(area, awaiting, covers) {
	return {
		status: 'placeholder',
		area,
		awaiting,
		will_cover: covers,
		cases: []
	};
}

async function signing() {
	const valid = await validCases();
	const describe = (list, expected) => list.map(({ name, request }) => {
		const verdict = mac(request);
		if (expected && verdict.verdict !== expected) throw new Error(`signing case "${name}" was expected to be ${expected} by the Mac, and node:crypto says ${verdict.verdict}`);
		if (expected === 'accepted' && verdict.signing_string !== request.signed.signing_string) throw new Error(`signing case "${name}": the client signed a different string than the Mac computes`);
		return { name, request, mac: verdict };
	});
	return {
		source: 'web/web-app/lib/api.js (every valid request is one real call); invalid requests are one mutation of a valid one',
		canonical_string: '<challenge>\\n<METHOD uppercased>\\n<path?query as sent, minus the auth parameter>\\n<lowercase hex SHA-256 of the body bytes, or EMPTY when there is no body>',
		signature: 'ECDSA P-256 over SHA-256 of the UTF-8 canonical string; raw r||s, 64 bytes, base64url without padding',
		authorization: 'RichOS-Device <device_id>.<challenge>.<signature>; in the Authorization header, except GET /api/events where it is the LAST query parameter auth=<percent-encoded value>',
		signatures_are_deterministic: 'RFC 6979. A native client VERIFIES these signatures and reproduces signing_string; its own signatures will differ (randomized) and must verify the same way.',
		valid: describe(valid, 'accepted'),
		invalid: describe(invalidCases(valid), 'refused'),
		accepted_by_the_mac_though_unusual: describe(tolerated(valid))
	};
}

function count(file, body) {
	const n = (x) => (Array.isArray(x) ? x.length : 0);
	switch (file) {
		case 'keys.json': return 1;
		case 'pairing.json': return n(body.links) + n(body.api_base_validation.cases) + n(body.pair_exchanges) + n(body.fingerprint_confirmations);
		case 'fingerprint.json': return n(body.cases);
		case 'signing.json': return n(body.valid) + n(body.invalid) + n(body.accepted_by_the_mac_though_unusual);
		case 'events.json': return n(body.wire_cases) + n(body.thread_cases) + n(body.hello_cases) + 1;
		case 'voice.json': return n(body.uploads);
		default: return n(body.cases);
	}
}

export async function build() {
	selfTest();
	const files = {
		'keys.json': keys(),
		'pairing.json': await pairing(),
		'fingerprint.json': fingerprint(),
		'signing.json': await signing(),
		'challenge.json': await challengeRefresh(),
		'retry.json': await retry(),
		'errors.json': await errors(),
		'events.json': await events(),
		'voice.json': await voice(),
		'attachments.json': placeholder('attachments', 'Echo (echo-opus-m1) publishing the Mac attachment intake route (build plan section 5.1, stream M item 1)',
			['upload request and its signed canonical string', 'size, type and time limits', 'idempotency on client_id', 'the message row shape that carries an attachment']),
		'push-registration-fcm.json': placeholder('push-registration-fcm', 'Echo (echo-opus-m1) publishing the FCM variant of the native push registration (build plan section 5.1, stream M item 2)',
			['the {platform:"fcm", token} registration body', 'refusals for malformed tokens', 'unregistration', 'the unchanged APNs shape still accepted'])
	};
	const out = {};
	for (const [name, body] of Object.entries(files)) out[name] = { schema: SCHEMA, file: name, ...body };
	out['index.json'] = {
		schema: SCHEMA,
		file: 'index.json',
		purpose: 'The RichOS phone protocol conformance corpus. Both native apps (Swift, Kotlin) load these files in their fast logic tests and must pass every case. See README.md.',
		generated_by: 'richos/mobile/conformance/generate.mjs',
		generated_from: Object.values(SOURCES),
		verified_by: ['node:crypto (every signature, at generation)', 'richos/mobile/conformance/verifier (the Mac production Rust verifier, cargo test)'],
		files: Object.keys(files).map((name) => ({ file: name, cases: count(name, files[name]), status: files[name].status || 'generated' }))
	};
	const text = {};
	for (const [name, body] of Object.entries(out)) text[name] = JSON.stringify(body, null, 2) + '\n';
	return text;
}

async function main() {
	const check = process.argv.includes('--check');
	const started = performance.now();
	const text = await build();
	if (check) {
		const onDisk = new Set(readdirSync(VECTORS).filter((f) => f.endsWith('.json')));
		const drift = [];
		for (const [name, body] of Object.entries(text)) {
			let current = null;
			try { current = readFileSync(join(VECTORS, name), 'utf8'); } catch { /* missing */ }
			if (current !== body) drift.push(current === null ? `${name} (missing)` : name);
			onDisk.delete(name);
		}
		for (const stray of onDisk) drift.push(`${stray} (not produced by the generator)`);
		const ms = Math.round(performance.now() - started);
		if (drift.length) {
			console.error(`conformance corpus is STALE: ${drift.join(', ')}.\nRegenerate with: node richos/mobile/conformance/generate.mjs (then review the diff: a changed vector is a changed protocol).`);
			console.log(JSON.stringify({ ok: false, files: Object.keys(text).length, drift, ms }));
			process.exit(1);
		}
		console.log(JSON.stringify({ ok: true, files: Object.keys(text).length, ms }));
		return;
	}
	mkdirSync(VECTORS, { recursive: true });
	for (const f of readdirSync(VECTORS)) if (f.endsWith('.json') && !(f in text)) rmSync(join(VECTORS, f));
	for (const [name, body] of Object.entries(text)) writeFileSync(join(VECTORS, name), body);
	console.log(JSON.stringify({ ok: true, wrote: Object.keys(text).length, ms: Math.round(performance.now() - started) }));
}

if (process.argv[1] === fileURLToPath(import.meta.url)) await main();
