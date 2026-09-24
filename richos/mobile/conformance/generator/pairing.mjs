// keys.json, pairing.json and fingerprint.json.

import { createPublicKey } from 'node:crypto';
import { mac as macVerdict } from './signing.mjs';
import { CAPABILITIES_FULL, PROTOCOL_VERSION, ATTACHMENT_LIMITS } from './native.mjs';
import {
	load, sha256, sha256hex, b64url, makeApi, answer, unreachable, transcript, outcome,
	KEY_SEED, PRIVATE_KEY, POINT, DEVICE_ID, ORIGIN, CONNECT_ORIGIN, challenge
} from './harness.mjs';

export function keys() {
	const spki = createPublicKey({ key: { kty: 'EC', crv: 'P-256', x: b64url(POINT.subarray(1, 33)), y: b64url(POINT.subarray(33)) }, format: 'jwk' })
		.export({ format: 'der', type: 'spki' });
	if (!spki.subarray(26).equals(POINT)) throw new Error('SPKI does not end in the point');
	return {
		purpose: 'TEST ONLY. Never ship this key. Private scalar = SHA-256(seed). Identical to the test key in the 2026-09-22 phone protocol contract fixtures.',
		seed_utf8: KEY_SEED,
		test_only_private_scalar_hex: PRIVATE_KEY.toString('hex'),
		public_point_b64url: b64url(POINT),
		public_key_jwk: { kty: 'EC', crv: 'P-256', x: b64url(POINT.subarray(1, 33)), y: b64url(POINT.subarray(33)) },
		public_key_spki_b64url: b64url(spki),
		spki_prefix_hex: spki.subarray(0, 26).toString('hex'),
		device_id: DEVICE_ID,
		device_id_rule: '"dev_" + lowercase hex of the first 6 bytes of SHA-256(65-byte uncompressed point)',
		device_key_hash_hex: sha256hex(POINT)
	};
}

// ---- pairing ---------------------------------------------------------------------------------

const LINKS = [
	['tailnet route', `${ORIGIN}/#pair=K7M2QX9H`],
	['connect route', `${CONNECT_ORIGIN}/#pair=K7M2QX9H`],
	['no trailing slash before the fragment', `${ORIGIN}#pair=K7M2QX9H`],
	['default https port', 'https://mm1.tail1a2b3c.ts.net/#pair=K7M2QX9H'],
	['uppercase scheme and host are normalized', 'HTTPS://MM1.TAIL1A2B3C.TS.NET:8443/#pair=K7M2QX9H'],
	['percent-encoded code is decoded', `${ORIGIN}/#pair=K7M2%51X9H`],
	['plain http', 'http://mm1.tail1a2b3c.ts.net:8443/#pair=K7M2QX9H'],
	['a path', `${ORIGIN}/x#pair=K7M2QX9H`],
	['a query', `${ORIGIN}/?q=1#pair=K7M2QX9H`],
	['user info', 'https://user:pw@mm1.tail1a2b3c.ts.net:8443/#pair=K7M2QX9H'],
	['two codes', `${ORIGIN}/#pair=A&pair=B`],
	['an extra fragment key', `${ORIGIN}/#pair=K7M2QX9H&x=1`],
	['an empty code', `${ORIGIN}/#pair=`],
	['no fragment', `${ORIGIN}/`],
	['a space', `${ORIGIN}/#pair=K7M2 QX9H`],
	['a trailing newline', `${ORIGIN}/#pair=K7M2QX9H\n`],
	['a backslash', `${ORIGIN}\\#pair=K7M2QX9H`],
	['not a URL', 'K7M2QX9H'],
	['longer than 4096 characters', `${ORIGIN}/#pair=${'K'.repeat(4096)}`]
];

function linkCases() {
	const { pairingLink } = load('client');
	return LINKS.map(([name, input]) => {
		try {
			const parsed = pairingLink(input);
			return { name, input, accept: true, origin: parsed.origin, code: parsed.code };
		} catch (error) {
			return { name, input, accept: false, error: error.message };
		}
	});
}

const API_BASES = [
	['the paired origin', ORIGIN],
	['the paired origin with a trailing slash', ORIGIN + '/'],
	['a different host', 'https://evil.example:8443'],
	['a different port', 'https://mm1.tail1a2b3c.ts.net:9443'],
	['plain http', 'http://mm1.tail1a2b3c.ts.net:8443'],
	['a path', ORIGIN + '/api'],
	['a query', ORIGIN + '/?x=1'],
	['a fragment', ORIGIN + '/#x'],
	['credentials', 'https://a:b@mm1.tail1a2b3c.ts.net:8443'],
	['whitespace', ORIGIN + ' '],
	['not a URL', 'mm1.tail1a2b3c.ts.net'],
	['empty', '']
];

function apiBaseCases() {
	const { validateApiBase } = load('inbound');
	return API_BASES.map(([name, value]) => {
		const r = validateApiBase(value, ORIGIN);
		return r.ok ? { name, value, accept: true, api_base: r.value } : { name, value, accept: false, reason: r.reason };
	});
}

const PAIR_ANSWER = {
	device_id: DEVICE_ID,
	ca_fingerprint_sha256: sha256(Buffer.from('conformance stand-in CA DER', 'utf8')).toString('hex').toUpperCase().match(/../g).join(':'),
	vapid_public_key: 'BExampleVapidKeyOnlyTheWebPushClientUsesIt',
	challenge: challenge('pair-answer'),
	api_base: ORIGIN,
	thread_id: 'thr_5c1e',
	thread_title: 'the proposal',
	threads: [{ id: 'thr_5c1e', title: 'the proposal' }, { id: 'thr_77aa', title: 'hiring' }],
	// Additive on a Mac with the native-app additions (194fcb75); the hello repeats all four.
	protocol_version: PROTOCOL_VERSION,
	capabilities: CAPABILITIES_FULL,
	// Sage's pairing review section 3.1 step 3: the answer is unchanged, plus the derivation the Mac
	// uses (phone/routes.rs complete_pairing).
	pairing_version: 2,
	attachment_limits: ATTACHMENT_LIMITS,
	build: '1.2.0'
};

async function pairExchange(name, script) {
	const { api, mac, signer, state } = makeApi({ script, state: { deviceId: null, challenge: null } });
	const jwk = keys().public_key_jwk;
	const result = await outcome(api.pair('K7M2QX9H', jwk, 'Android phone'));
	return {
		name,
		mac_answers: script,
		requests: transcript(mac, signer),
		outcome: result,
		state_after: { device_id: state.deviceId ?? null, challenge: state.challenge ?? null, api_base: state.apiBase, api_base_refusal: state.apiBaseRefusal ? state.apiBaseRefusal.reason : null }
	};
}

export async function pairing() {
	const exchanges = [
		await pairExchange('paired', [answer(200, PAIR_ANSWER, { 'Content-Type': 'application/json; charset=utf-8', 'X-RichOS-Challenge': challenge('pair-answer') })]),
		await pairExchange('api_base on another origin is refused, pairing still completes', [answer(200, { ...PAIR_ANSWER, api_base: 'https://evil.example:8443' })]),
		await pairExchange('wrong or expired code', [answer(404, '', { 'X-RichOS-Challenge': challenge('pair-404') })]),
		await pairExchange('rate limited', [answer(429, '', { 'Retry-After': '60' })]),
		await pairExchange('Mac unreachable', [unreachable()])
	];
	const confirms = [];
	for (const [name, matched] of [['they match', true], ['they do not match', false]]) {
		const { api, mac: fake, signer } = makeApi({ script: [answer(200, { ok: true }, { 'X-RichOS-Challenge': challenge('confirm') })], state: { challenge: challenge('confirm') } });
		const result = await outcome(api.confirmFingerprint(matched));
		confirms.push({ name, requests: transcript(fake, signer).map((request) => ({ ...request, mac: macVerdict(request) })), outcome: result });
	}
	const code = { alphabet: '23456789ABCDEFGHJKMNPQRSTVWXYZ', length: 8 };
	return {
		source: 'mobile/core/client.js pairingLink; web/web-app/lib/api.js pair and confirmFingerprint; web/web-app/lib/inbound.js validateApiBase',
		link_format: '<origin>/#pair=<code>',
		code,
		links: linkCases(),
		api_base_validation: { paired_origin: ORIGIN, cases: apiBaseCases() },
		pair_exchanges: exchanges,
		platform_field: {
			rule: 'Native apps add "platform": "ios" | "android" to the pairing body (contract section 2.3, phone/routes.rs:411-415). The shipped client above does not send it; the Mac falls back to reading device_name.',
			android_body_fields: ['code', 'public_key_jwk', 'device_name', 'platform']
		},
		fingerprint_confirmations: confirms
	};
}

// ---- the six words ---------------------------------------------------------------------------

const macFormat = (digest) => digest.toString('hex').toUpperCase().match(/../g).join(':');

export function fingerprint() {
	const F = load('fingerprint');
	const words = load('wordlist').WORDS;
	const digest = (label) => sha256(Buffer.from(label, 'utf8'));
	const inputs = [
		['the Mac format: uppercase hex pairs joined by colons', macFormat(digest('conformance stand-in CA DER'))],
		['the stand-in vector from the phone protocol contract fixtures',macFormat(digest('fixture: stands in for the Mac root certificate DER'))],
		['first bytes 00 and FF (word list ends)', '00:FF:00:FF:80:7F:' + macFormat(digest('ends')).slice(18)],
		['bare lowercase hex', digest('lowercase').toString('hex')],
		['a SHA-256 label in front', 'SHA-256: ' + macFormat(digest('label'))],
		['spaces between pairs', macFormat(digest('spaces')).replace(/:/g, ' ')],
		['dashes between pairs', macFormat(digest('dashes')).replace(/:/g, '-')],
		['exactly six bytes', 'A1:B2:C3:D4:E5:F6'],
		['five bytes is refused', 'A1:B2:C3:D4:E5'],
		['an odd number of hex digits is refused', 'A1:B2:C3:D4:E5:F6:7'],
		['non-hex is refused', 'ZZ:B2:C3:D4:E5:F6'],
		['empty is refused', '']
	];
	const cases = inputs.map(([name, input]) => {
		try {
			const w = F.wordsFromHex(input);
			return { name, input, accept: true, bytes_hex: Buffer.from(F.bytesFromHex(input).subarray(0, 6)).toString('hex'), words: w, phrase: F.phraseFromHex(input) };
		} catch (error) {
			return { name, input, accept: false, error: error.message };
		}
	});
	return {
		source: 'web/web-app/lib/fingerprint.js wordsFromHex/phraseFromHex; web/web-app/lib/wordlist.js WORDS',
		rule: 'strip an optional "SHA-256" label, then spaces, colons and dashes; parse hex; word[i] = WORDS[byte[i]] for the first 6 bytes; join with single spaces',
		word_count: F.WORD_COUNT,
		wordlist_sha256_of_newline_joined: sha256hex(Buffer.from(words.join('\n'), 'utf8')),
		cases,
		wordlist: words
	};
}
