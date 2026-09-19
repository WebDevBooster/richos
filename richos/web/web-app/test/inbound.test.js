'use strict';

// THE TWO VALUES THAT ARRIVE FROM OUTSIDE, AND THE TABLE OF WHAT IS REFUSED.
//
// `node --test "test/*.test.js"`.
//
// Table-driven on purpose. The point of copying T3 Code's rules (`notificationPayload.ts:37-70`)
// was that the validation is copied EXACTLY, and a rule that is written but not exercised is a
// rule nobody knows is gone. So every hostile form gets a row, every row names which rule refuses
// it, and the ordinary link the Mac actually sends is in the same table as a positive control —
// because a validator that refuses everything passes every negative test ever written.

const test = require('node:test');
const assert = require('node:assert');

const { validateNavigate, validateApiBase, NAVIGATE_FALLBACK } = require('../lib/inbound.js');

// --------------------------------------------------------------------------------------------
// `navigate` — what a push can put in front of `clients.openWindow()`
// --------------------------------------------------------------------------------------------

/// THE LINK THE MAC ACTUALLY SENDS, re-derived from the source rather than imagined:
/// `app/src-tauri/src/phone/mod.rs:553` builds
/// `format!("/#thread={thread_id}&at={}", last["id"])`. A thread id off the bridge looks like
/// `thr_5c1e` and a message id like `i4` (`phone/rows.rs:224-242`).
const ORDINARY = '/#thread=thr_5c1e&at=i4';

const REFUSED_NAVIGATE = [
	// T3's five rules, each with the form it exists to stop.
	['//evil.example/path', 'a leading //', 'protocol-relative: an absolute URL to another host wearing a path'],
	['//evil.example', 'a leading //', 'the bare protocol-relative host'],
	['/#thread=a?x=1', 'a query string', 'T3 rejects a `?` outright and so does this'],
	['/?next=https://evil.example', 'a query string', 'a query on the path itself'],
	[' /#thread=a', 'whitespace in the link', 'leading space — T3\'s "untrimmed whitespace"'],
	['/#thread=a ', 'whitespace in the link', 'trailing space'],
	['/\t\t//evil.example', 'whitespace in the link', 'a tab the browser strips before it resolves the URL'],
	['/\n//evil.example', 'whitespace in the link', 'a newline, same trick'],
	['/threads/prod/abc', 'a path this app has no page for', 'the wrong part count: this app has one page'],
	['/x', 'a path this app has no page for', 'any other path'],
	['/#thread=a#at=b', 'more than one #', 'a second fragment marker'],

	// The forms that are about THIS app rather than about T3's.
	['https://evil.example/', 'not a root-relative path', 'an absolute URL'],
	['javascript:alert(1)', 'not a root-relative path', 'a script URL — `openWindow` would take it'],
	['data:text/html,<script>1</script>', 'not a root-relative path', 'a data URL'],
	['\\\\evil.example', 'a backslash in the link', 'the backslash form of protocol-relative'],
	['/\\evil.example', 'a backslash in the link', 'a backslash the URL parser folds to a slash'],
	['', 'not a link', 'the empty string'],
	[null, 'not a link', 'nothing at all'],
	[{ toString: () => '/' }, 'not a link', 'an object that would stringify into something valid'],

	// THE ONE THIS WHITELIST EXISTS FOR. The page reads `pair=` straight out of `location.hash`
	// to start pairing (`app.js:119`), so a push that could set it would be a push that puts a
	// pairing code in front of him. T3 gets this for free by rejecting `#`; this app cannot,
	// because its own link IS a fragment — so the two keys the Mac issues are a whitelist.
	['/#pair=K7QF2M9X', 'a fragment key this app does not issue: pair', 'a pairing code in a push'],
	['/#thread=a&pair=K7QF2M9X', 'a fragment key this app does not issue: pair', 'smuggled in beside a real key'],
	['/#at=i4', 'a fragment with no thread in it', '`at` is a real key, but a link to no thread is not a link'],
	['/#thread=a&thread=b', 'the fragment repeats thread', 'a repeated key, where two parsers could disagree'],
	['/#thread=', 'a fragment with no thread in it', 'a thread key with nothing behind it'],
	['/#&', 'a fragment with nothing in it', 'separators and no keys — a fragment that parses to nothing']
];

test('every hostile `navigate` is refused, by the rule that refuses it', () => {
	for (const [value, reason, why] of REFUSED_NAVIGATE) {
		const got = validateNavigate(value);
		assert.strictEqual(got.ok, false, `${JSON.stringify(value)} was ACCEPTED — ${why}`);
		assert.strictEqual(got.reason, reason, `${JSON.stringify(value)} was refused for the wrong reason (${why})`);
		assert.strictEqual(got.value, null, `${JSON.stringify(value)} was refused and still handed back a value`);
	}
});

// THE POSITIVE CONTROLS. Without these the table above is satisfied by `return false`.
test('the ordinary link the Mac sends passes, unchanged', () => {
	const got = validateNavigate(ORDINARY);
	assert.strictEqual(got.ok, true, got.reason);
	assert.strictEqual(got.value, ORDINARY, 're-encoding altered the Mac\'s own link');
	assert.strictEqual(got.reason, null);
});

test('the ordinary shapes around it pass too, and are normalized rather than refused', () => {
	// `mod.rs:553` interpolates `last["id"]` with `""` as its fallback, so an empty `at` is a
	// real frame the Mac can send — and it means "no particular message", not "refuse this".
	assert.deepStrictEqual(validateNavigate('/#thread=thr_5c1e&at='),
		{ ok: true, value: '/#thread=thr_5c1e', reason: null });
	// The app, with no thread named. This is what a payload that carries no link falls back to.
	assert.deepStrictEqual(validateNavigate('/'),
		{ ok: true, value: '/', reason: null });
	// A bare `#` is that same link with a stray marker on the end, not an attack. It is
	// normalized to `/` rather than refused, which is the difference between a validator and a
	// tripwire.
	assert.deepStrictEqual(validateNavigate('/#'),
		{ ok: true, value: '/', reason: null });
	assert.strictEqual(NAVIGATE_FALLBACK, '/');
});

test('what comes back is RE-ENCODED, so nothing that arrived passes through as itself', () => {
	// T3's last step. A thread id carrying a character that one parser reads and another does not
	// comes back percent-encoded, which is the form every parser agrees on.
	const got = validateNavigate('/#thread=a%20b&at=c%26d');
	assert.strictEqual(got.ok, true, got.reason);
	assert.strictEqual(got.value, '/#thread=a%20b&at=c%26d');
	// And the proof that it was rebuilt rather than echoed: `+` is a space to `URLSearchParams`,
	// and it comes back as the encoding of a space rather than as a `+`.
	assert.strictEqual(validateNavigate('/#thread=a+b').value, '/#thread=a%20b');
});

// --------------------------------------------------------------------------------------------
// `api_base` — what becomes the prefix of every later request
// --------------------------------------------------------------------------------------------

const PAGE = 'https://mm1.tail9a3b2.ts.net:8443';

const REFUSED_BASE = [
	['https://198.51.100.7:8443', 'a different origin from the app', 'another host — the §2 C clause, until the Mac speaks CORS'],
	['https://mm1.tail9a3b2.ts.net:9443', 'a different origin from the app', 'the same host on another port is another origin'],
	['https://mm1.tail9a3b2.ts.net', 'a different origin from the app', 'the same host with no port is another origin'],
	['http://mm1.tail9a3b2.ts.net:8443', 'not an https address', 'a downgrade to cleartext'],
	['https://someone:secret@mm1.tail9a3b2.ts.net:8443', 'credentials in the address', 'credentials in a URL are a phishing primitive'],
	['https://mm1.tail9a3b2.ts.net:8443/?x=1', 'a query string in the address', 'the Mac advertises a bare origin'],
	['https://mm1.tail9a3b2.ts.net:8443/#x', 'a fragment in the address', 'same'],
	['https://mm1.tail9a3b2.ts.net:8443/api', 'a path in the address', 'a path would silently re-root every route'],
	['//mm1.tail9a3b2.ts.net:8443', 'not an absolute URL', 'protocol-relative is not absolute'],
	['/api', 'not an absolute URL', 'a bare path'],
	['not a url', 'whitespace in the address', 'whitespace is caught before the parser sees it'],
	['https://mm1.tail9a3b2.ts.net:8443 ', 'whitespace in the address', 'a trailing space'],
	['', 'not an address', 'the empty string'],
	[null, 'not an address', 'nothing at all'],
	[42, 'not an address', 'a number']
];

test('every unusable `api_base` is refused, by the rule that refuses it', () => {
	for (const [value, reason, why] of REFUSED_BASE) {
		const got = validateApiBase(value, PAGE);
		assert.strictEqual(got.ok, false, `${JSON.stringify(value)} was ACCEPTED — ${why}`);
		assert.strictEqual(got.reason, reason, `${JSON.stringify(value)} was refused for the wrong reason (${why})`);
	}
});

// THE POSITIVE CONTROL for the whole table above.
test('the same-origin address the Mac really advertises is stored', () => {
	// `api_base.rs`: the origin is fixed for the life of an installed phone app, and since CEO
	// §61 it is the Mac's tailnet name.
	assert.deepStrictEqual(validateApiBase(PAGE, PAGE), { ok: true, value: PAGE, reason: null });
	// Normalized to the bare origin, so a trailing slash is not a second spelling of the same Mac.
	assert.deepStrictEqual(validateApiBase(`${PAGE}/`, PAGE), { ok: true, value: PAGE, reason: null });
});

test('an unknown page origin refuses everything rather than passing everything', () => {
	// A same-origin rule that switches itself off when it cannot find the origin is a same-origin
	// rule that is off in exactly the situation it exists for.
	for (const origin of [null, undefined, '']) {
		const got = validateApiBase(PAGE, origin);
		assert.strictEqual(got.ok, false, `an origin of ${JSON.stringify(origin)} let an address through`);
		assert.strictEqual(got.reason, 'no page origin to compare it against');
	}
});
