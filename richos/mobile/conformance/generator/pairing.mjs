// keys.json, pairing.json and fingerprint.json.

import { createPublicKey } from 'node:crypto';
import { mac as macVerdict } from './signing.mjs';
import { CAPABILITIES_FULL, PROTOCOL_VERSION, ATTACHMENT_LIMITS } from './native.mjs';
import { publicPoint } from './p256.mjs';
import { errorCase } from './transport.mjs';
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

async function pairExchange(name, script, options) {
	const { api, mac, signer, state } = makeApi({ script, state: { deviceId: null, challenge: null } });
	const jwk = keys().public_key_jwk;
	let refusedForMissingPairV2 = false;
	const call = api.pair('K7M2QX9H', jwk, 'Android phone', options).catch((error) => {
		refusedForMissingPairV2 = error && error.macNeedsUpdate === true;
		throw error;
	});
	const result = await outcome(call);
	return {
		name,
		...(options ? { pairing_version: options.pairingVersion } : {}),
		mac_answers: script,
		requests: transcript(mac, signer),
		outcome: result,
		...(options ? { refused_for_missing_pair_v2: refusedForMissingPairV2 } : {}),
		state_after: { device_id: state.deviceId ?? null, challenge: state.challenge ?? null, api_base: state.apiBase, api_base_refusal: state.apiBaseRefusal ? state.apiBaseRefusal.reason : null }
	};
}

// ---- pair-v2: the press on the Mac and the phone's bounded wait for it (Sage's review) ----------

/// The Mac's 409 for a device nobody has confirmed on the Mac, byte for byte as
/// `phone/routes.rs` `AWAITING_MAC_BODY` sends it (verifier/ holds the two together).
export const AWAITING_MAC_BODY = '{"awaiting_mac_confirmation":true,"reason":"Press They match on your Mac."}';

async function macConfirmation() {
	const A = load('api');
	const probe = async (name, reply) => {
		const c = challenge(name);
		const { api, mac: fake, signer } = makeApi({ script: [reply(c)], state: { challenge: c } });
		const result = await outcome(api.macConfirmed('thr_5c1e'));
		const requests = transcript(fake, signer).map((request) => ({ ...request, mac: macVerdict(request) }));
		return { name, mac_answer: reply(c), requests, outcome: result };
	};
	const schedule = [];
	for (let n = 0, t = 0; t + A.macWaitDelayMs(n) <= A.MAC_WAIT_WINDOW_MS; n++) {
		t += A.macWaitDelayMs(n);
		schedule.push({ attempt: n, delay_ms: A.macWaitDelayMs(n), asked_at_ms: t });
	}
	const confirmAwaiting = await (async () => {
		const c = challenge('confirm-awaiting');
		const { api, mac: fake, signer } = makeApi({ script: [answer(200, { ok: true, awaiting_mac_confirmation: true }, { 'X-RichOS-Challenge': c })], state: { challenge: c } });
		const result = await outcome(api.confirmFingerprint(true));
		return { name: 'they match on the phone, the Mac not yet pressed', requests: transcript(fake, signer).map((r) => ({ ...r, mac: macVerdict(r) })), outcome: result };
	})();
	return {
		source: 'web/web-app/lib/api.js macConfirmed, confirmFingerprint, macWaitDelayMs and macWaitBoundMs; the Mac side is phone/device.rs verify (AwaitingMacConfirmation) and phone/routes.rs AWAITING_MAC_BODY',
		rule: 'Until the person presses They match ON THE MAC, the Mac answers every signed request from the paired device 409 with awaiting_mac_confirmation (retryable, never final), except the phone\'s own fingerprint_confirmed answer, which is answered 200 with awaiting_mac_confirmation: true. The phone waits for the press on wait_schedule and on no other: only while the app is in the foreground, never past the bound, and it stops on the answer, on a refusal (final: the Mac forgot the device), or at the bound.',
		awaiting_body: AWAITING_MAC_BODY,
		wait_schedule_ms: schedule,
		wait_bound_ms: { from_answer_240_seconds: A.macWaitBoundMs({ confirm_within_seconds: 240 }), from_answer_9999_seconds: A.macWaitBoundMs({ confirm_within_seconds: 9999 }), when_the_mac_says_nothing: A.macWaitBoundMs({}) },
		max_requests_in_the_window: schedule.length,
		phone_answer_while_waiting: confirmAwaiting,
		// Sage: "A conformance case in pairing.json for the awaiting answer, so both native
		// classifiers wait rather than go to refused." The errors.json shape, through the same
		// api.js classification and queue.js flush.
		awaiting_answer_classification: await errorCase(
			'409 {"awaiting_mac_confirmation":true} (the Mac waits for its own press)',
			[answer(409, AWAITING_MAC_BODY, { 'Content-Type': 'application/json; charset=utf-8' })],
			null,
			'Authenticated, and the person has not pressed They match on the Mac yet. Retryable and never final (no retry:false); a message stays in the outbox. The pairing screen names the missing press and waits on wait_schedule_ms.'
		),
		probes: [
			await probe('the Mac still waits for its press', (c) => answer(409, AWAITING_MAC_BODY, { 'Content-Type': 'application/json; charset=utf-8', 'X-RichOS-Challenge': c })),
			await probe('the person pressed They match on the Mac', (c) => answer(200, { messages: [], more: false }, { 'Content-Type': 'application/json; charset=utf-8', 'X-RichOS-Challenge': c })),
			await probe('the person pressed They do not match on the Mac, or the window closed', (c) => answer(403, { revoked: true }, { 'Content-Type': 'application/json; charset=utf-8', 'X-RichOS-Challenge': c }))
		]
	};
}

/// SAGE F2's RELAY, AS A SCENARIO. The phone dials origin R; a relay at R forwards the pairing to
/// the Mac at M, which answers with its real hash. The phone derives over R and its key; the Mac
/// derives over M and the key it registered (the same key, relayed faithfully). The lines differ.
async function relayScenario() {
	const F = load('fingerprint');
	const RELAY = 'https://relay.example';
	const { api, mac: fake, signer } = makeApi({ script: [answer(200, PAIR_ANSWER)], origin: RELAY, state: { deviceId: null, challenge: null, apiBase: RELAY } });
	await api.pair('K7M2QX9H', keys().public_key_jwk, 'Android phone', { pairingVersion: 2 });
	const point = b64url(POINT);
	const phone = await F.wordsV2(RELAY, PAIR_ANSWER.ca_fingerprint_sha256, point);
	const mac = await F.wordsV2(ORIGIN, PAIR_ANSWER.ca_fingerprint_sha256, point);
	if (phone.join(' ') === mac.join(' ')) throw new Error('relay scenario: the phone and the Mac show the same words, so v2 does not bind the origin');
	return {
		name: 'the phone dials a relay; the relay forwards to the Mac; the two screens show different words',
		phone_dialed: RELAY,
		mac_origin: ORIGIN,
		ca_fingerprint_sha256: PAIR_ANSWER.ca_fingerprint_sha256,
		device_point_b64url: point,
		request: transcript(fake, signer, RELAY)[0],
		phone_words: phone,
		mac_words: mac
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
	// pair-v2 (Sage's pairing review §3, §3.5): the request says so, and a Mac without the
	// capability is refused rather than fallen back to. A section of its own rather than more
	// `pair_exchanges`, so the native suites that replay those keep describing today's apps until
	// their v2 step adopts these.
	const v2Exchanges = [
		await pairExchange('v2 phone pairs with a pair-v2 Mac', [answer(200, PAIR_ANSWER, { 'Content-Type': 'application/json; charset=utf-8', 'X-RichOS-Challenge': challenge('pair-answer') })], { pairingVersion: 2 }),
		await pairExchange('v2 phone refuses a Mac without pair-v2 and never falls back', [answer(200, { ...PAIR_ANSWER, capabilities: CAPABILITIES_FULL.filter((c) => c !== 'pair-v2'), pairing_version: undefined })], { pairingVersion: 2 })
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
		pair_v2: {
			rule: 'A v2 phone adds "pairing_version": 2 to the pairing body, shows the v2 words (fingerprint.json v2), and refuses a Mac whose answer does not list "pair-v2" in capabilities: it signs one fingerprint_confirmed:false so that Mac forgets the key, and tells the person to update RichOS on the Mac. It never falls back to v1 (Sage review section 3.5: a relay can strip a capability). Native v2 bodies are ["code","public_key_jwk","device_name","platform","pairing_version"].',
			native_v2_body_fields: ['code', 'public_key_jwk', 'device_name', 'platform', 'pairing_version'],
			exchanges: v2Exchanges,
			relay_scenario: await relayScenario()
		},
		fingerprint_confirmations: confirms,
		mac_confirmation: await macConfirmation()
	};
}

// ---- the six words ---------------------------------------------------------------------------

const macFormat = (digest) => digest.toString('hex').toUpperCase().match(/../g).join(':');

/// The v2 words (Sage's pairing review F2): each case names every input, the exact text that is
/// hashed, and the words the real `fingerprint.js` derives. `verifier/` runs the Mac's own
/// `phone/words.rs` over the same inputs and requires the same words.
async function fingerprintV2(F) {
	const macHash = macFormat(sha256(Buffer.from('conformance stand-in CA DER', 'utf8')));
	const point = b64url(POINT);
	const other = b64url(Buffer.from(keysOther().point));
	const inputs = [
		['tailnet origin, the corpus key', ORIGIN, macHash, point],
		['connect origin, the corpus key', CONNECT_ORIGIN, macHash, point],
		['the same key and Mac value through a relay origin: different words', 'https://relay.example', macHash, point],
		['the same origin and Mac value with another key (a device that paired first): different words', ORIGIN, macHash, other],
		['an origin written with capitals, the default port and a slash is normalized first', CONNECT_ORIGIN.toUpperCase().replace('HTTPS://', 'https://') + ':443/', macHash, point],
		['the Mac value is used byte for byte: lowercase bare hex is a different input', ORIGIN, macHash.replace(/:/g, '').toLowerCase(), point]
	];
	const cases = [];
	for (const [name, origin, ca, devicePoint] of inputs) {
		const words = await F.wordsV2(origin, ca, devicePoint);
		cases.push({ name, origin, ca_fingerprint_sha256: ca, device_point_b64url: devicePoint, input_utf8: F.v2Input(origin, ca, devicePoint), words, phrase: words.join(' ') });
	}
	const byName = (n) => cases.find((c) => c.name.startsWith(n)).phrase;
	if (byName('tailnet origin') === byName('the same key and Mac value through a relay')) throw new Error('v2 did not change with the origin');
	if (byName('tailnet origin') === byName('the same origin and Mac value with another key')) throw new Error('v2 did not change with the key');
	if (byName('connect origin') !== byName('an origin written with capitals')) throw new Error('origin normalization changed the words');
	return {
		source: 'web/web-app/lib/fingerprint.js wordsV2/v2Input/normalizeOrigin/pointFromJwk; the Mac: app/src-tauri/src/phone/words.rs v2',
		rule: 'input = "RICHCONNECT-PAIR-V2\\n" + origin + "\\n" + ca_fingerprint_sha256 + "\\n" + device_point_b64url; origin is the one the PHONE DIALED (the Mac: its own serving origin), written https://host[:port], lowercase, default port omitted, no trailing slash; ca_fingerprint_sha256 is the pair answer field byte for byte; device_point_b64url is the 65-byte uncompressed P-256 point, base64url without padding (the Mac: the key it registered). word[i] = WORDS[SHA-256(input)[i]] for i < 6.',
		label: F.PAIR_V2_LABEL,
		cases
	};
}

/// A second, test-only key: SHA-256 of a published seed, like the corpus key.
function keysOther() {
	const privateKey = sha256(Buffer.from('richos-phone-protocol-test-OTHER-key-v1', 'utf8'));
	return { point: publicPoint(privateKey) };
}

export async function fingerprint() {
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
		// `cases` above is the v1 rule, kept under its own name for the one release Sage's review
		// section 3.5 keeps v1 for (the preserved iPhone app). A v2 phone shows `v2` and never v1.
		cases_are: 'v1: the words of a Mac-stated hash alone. A v2 phone must NOT show these; see v2.',
		word_count: F.WORD_COUNT,
		wordlist_sha256_of_newline_joined: sha256hex(Buffer.from(words.join('\n'), 'utf8')),
		cases,
		v2: await fingerprintV2(F),
		wordlist: words
	};
}
