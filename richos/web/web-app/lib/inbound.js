// THE TWO VALUES THAT ARRIVE FROM OUTSIDE THIS APP, AND WHAT MAKES ONE ACCEPTABLE.
//
// Everything else the phone acts on it either typed, computed or signed for. These two it is
// TOLD — by a push payload the Mac encrypted and by the `hello` frame at the top of the stream —
// and a told value is an instruction from whoever is speaking, which on a bad day is not the Mac.
//
//   * `navigate` goes to `clients.openWindow()` and to the page. An `openWindow` will open a
//     cross-origin URL, so an unchecked value is "open this address" with the app's own icon on it.
//   * `api_base` becomes the prefix of EVERY later request (`api.js` `joinBase`). An unchecked
//     value redirects the whole conversation, the send queue and the signed credential at it.
//
// Both are behind RFC 8291 encryption and VAPID today, so this is defense in depth rather than a
// live hole (plan §2 C). It is here now because it is two hours now and three call sites across
// two clients later.
//
// THE RULES ARE T3 CODE'S, COPIED RATHER THAN REINVENTED — `notificationPayload.ts:37-70`, by way
// of `richos-hq/docs/research/t3code-mobile-vs-richos-phone-2026-09-18.md:40`: reject a value with
// a leading `//`, a `?`, a `#`, untrimmed whitespace or the wrong part count, then re-encode.
//
// ONE OF THOSE FIVE IS DELIBERATELY NOT COPIED LITERALLY, AND IT IS SAID HERE RATHER THAN
// DISCOVERED LATER. **"Reject a `#`" would reject the Mac's own link.** T3 Code's deep link is a
// path, `/threads/<env>/<id>`; this app is one page and its deep link is a FRAGMENT — the Mac
// sends `/#thread=<thread_id>&at=<message_id>` and nothing else (`app/src-tauri/src/phone/
// mod.rs:553`). So the fragment is not rejected, it is PARSED against the one grammar the Mac
// issues, and anything else is refused. That is strictly stronger than rejecting two characters:
// a whitelist of two keys also refuses `/#pair=<code>`, which matters because the page reads
// exactly that out of `location.hash` to start pairing (`app.js:119`), and a push that could put a
// pairing code in front of him is the interesting version of this attack rather than the shape of
// it. T3's "part count ≠ 4" maps to the same rule one level up: their path has four parts and
// ours has two, because ours is `/`.
//
// EVERY REFUSAL CARRIES A REASON, and the caller stores it. Plan §2 C: "refusing anything else
// with a reason ... is what makes the seam degrade honestly instead of breaking every request
// silently." A value that is dropped without a trace is a phone that stops working for a cause
// nobody can name.
//
// No dependencies, no DOM, no `window` — the service worker imports this file too. Loads as a
// plain script (defines `globalThis.RichOSInbound`) and as a CommonJS module.

(function (root, factory) {
	const api = factory();
	if (typeof module === 'object' && module.exports) module.exports = api;
	root.RichOSInbound = api;
})(typeof globalThis !== 'undefined' ? globalThis : this, function () {
	'use strict';

	/// Where a push with no usable link lands him: the app, at the top of whatever thread he was
	/// last in. Never an error, never a blank page — he tapped a notification and the app opens.
	const NAVIGATE_FALLBACK = '/';

	/// The only fragment keys the Mac issues (`mod.rs:553`). A whitelist rather than a blacklist,
	/// so a key nobody has thought of yet is refused by construction rather than by foresight.
	const NAVIGATE_KEYS = ['thread', 'at'];

	function refuse(reason) {
		return { ok: false, value: null, reason };
	}

	function accept(value) {
		return { ok: true, value, reason: null };
	}

	/// A push payload's `navigate`, validated and re-encoded.
	///
	/// Returns `{ ok, value, reason }`. On `ok` the value is SAFE TO USE AND IS NOT THE INPUT: it
	/// is rebuilt from the parts that were understood, so a character that survives one parser and
	/// not another cannot reach `openWindow` unchanged. On a refusal the caller uses
	/// [`NAVIGATE_FALLBACK`] and records the reason.
	function validateNavigate(value) {
		if (typeof value !== 'string' || value.length === 0) return refuse('not a link');

		// T3's "untrimmed whitespace", widened by one notch on purpose: a tab or a newline ANYWHERE
		// inside a URL is stripped by the browser's own parser before it is resolved, so
		// `/\t\t//evil.example` and `//evil.example` are the same address to `openWindow` and are
		// two different strings to a check that only looks at the ends.
		if (/\s/.test(value)) return refuse('whitespace in the link');

		// A backslash is a forward slash to every URL parser that ships in a browser, so
		// `/\evil.example` is the protocol-relative form wearing a different character.
		if (value.indexOf('\\') !== -1) return refuse('a backslash in the link');

		// Root-relative and nothing else. This one rule also refuses `https://elsewhere.example`,
		// `javascript:…` and `data:…`, because none of them start with a slash.
		if (value.charAt(0) !== '/') return refuse('not a root-relative path');

		// T3's rule, verbatim: `//host` is an absolute URL to another host wearing a path's clothes.
		if (value.slice(0, 2) === '//') return refuse('a leading //');

		// T3's rule, verbatim. This app's links carry no query string; the Mac sends none.
		if (value.indexOf('?') !== -1) return refuse('a query string');

		const hash = value.indexOf('#');
		if (hash !== -1 && value.lastIndexOf('#') !== hash) return refuse('more than one #');

		const path = hash === -1 ? value : value.slice(0, hash);
		const fragment = hash === -1 ? '' : value.slice(hash + 1);

		// T3's "part count ≠ 4", at this app's own grammar. `'/'.split('/')` is `['', '']` — two
		// parts, both empty — and this app has exactly one page, so anything else is a route it
		// does not have.
		const parts = path.split('/');
		if (parts.length !== 2 || parts[0] !== '' || parts[1] !== '') {
			return refuse('a path this app has no page for');
		}

		if (fragment === '') return accept(NAVIGATE_FALLBACK);

		// The fragment, parsed rather than pattern-matched: `URLSearchParams` is the same parser
		// the page uses on the way back out, so what is checked here is what is read there.
		const given = new URLSearchParams(fragment);
		const keys = [...given.keys()];
		if (keys.length === 0) return refuse('a fragment with nothing in it');
		for (const key of keys) {
			if (NAVIGATE_KEYS.indexOf(key) === -1) return refuse(`a fragment key this app does not issue: ${key}`);
			if (given.getAll(key).length !== 1) return refuse(`the fragment repeats ${key}`);
		}
		const thread = given.get('thread');
		if (!thread) return refuse('a fragment with no thread in it');
		const at = given.get('at');

		// RE-ENCODED, which is T3's last step and the step that makes the first ones hold: the
		// value handed back is built here out of two parsed fields, so nothing that arrived can
		// pass through as itself.
		const rebuilt = `/#thread=${encodeURIComponent(thread)}`;
		return accept(at ? `${rebuilt}&at=${encodeURIComponent(at)}` : rebuilt);
	}

	/// The address the Mac says it can currently be reached at, validated against the page's own
	/// origin.
	///
	/// Returns `{ ok, value, reason }`, and on `ok` the value is normalized to the bare origin —
	/// which is what the Mac advertises and all it ever advertises
	/// (`app/src-tauri/src/phone/api_base.rs:13`: "the origin is `https://<name>.local:8443`
	/// forever").
	///
	/// **THE SAME-ORIGIN CLAUSE IS TEMPORARY AND IS NOT A CLAIM THAT THE SEAM IS DEAD.** Plan
	/// §10.7 is unchanged: the API base is DATA and the origin is identity, `api.js` still reads
	/// the base at every request, and the day a real remote address exists it arrives here as a
	/// value this function is taught to accept. What plan §2 C rules today is that there is no
	/// CORS on the Mac's listener yet, so an `api_base` on another origin produces a fetch the
	/// browser blocks — every request failing for a reason the phone would report as "your Mac is
	/// not reachable". Refusing it HERE, with a reason, is the honest version of the same outcome.
	function validateApiBase(value, pageOrigin) {
		if (typeof value !== 'string' || value.length === 0) return refuse('not an address');
		if (/\s/.test(value)) return refuse('whitespace in the address');

		let url;
		try {
			url = new URL(value);
		} catch {
			return refuse('not an absolute URL');
		}

		// The phone channel is TLS-only and the app is on an `https` origin, so an `http:` base is
		// both a downgrade and a request the page would be refused anyway.
		if (url.protocol !== 'https:') return refuse('not an https address');

		// `https://someone:something@his-mac.local:8443` — credentials in a URL are a phishing
		// primitive and nothing in this product ever sends them.
		if (url.username || url.password) return refuse('credentials in the address');

		if (url.search) return refuse('a query string in the address');
		if (url.hash) return refuse('a fragment in the address');
		if (url.pathname !== '/') return refuse('a path in the address');

		// Nothing to compare against is a refusal, not a pass. A same-origin rule that is skipped
		// when the origin is unknown is a same-origin rule that is off whenever it matters.
		if (typeof pageOrigin !== 'string' || pageOrigin.length === 0) {
			return refuse('no page origin to compare it against');
		}
		if (url.origin !== pageOrigin) return refuse('a different origin from the app');

		return accept(url.origin);
	}

	/// The origin this app was loaded from, wherever it is asked — `window` in the page,
	/// `self` in the service worker, and nothing in Node, where the caller passes one explicitly.
	function pageOrigin() {
		const here = typeof globalThis !== 'undefined' ? globalThis : null;
		if (here && here.location && typeof here.location.origin === 'string') return here.location.origin;
		return null;
	}

	return { validateNavigate, validateApiBase, pageOrigin, NAVIGATE_FALLBACK, NAVIGATE_KEYS };
});
