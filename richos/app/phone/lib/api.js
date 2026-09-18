// THE ONE PLACE THAT KNOWS THE ROUTES.
//
// `CONTRACT-STUB.md` in this directory says why this module exists as a module: the real route
// contract is Echo's and it was not in the tree when the phone was written, so every route, every
// header and every field name is behind this file. Reconciling with the real contract is an edit
// here and to `test/api.test.js`, and nothing above it moves.
//
// THREE THINGS IN HERE ARE LOAD-BEARING AND ARE NOT DETAILS:
//
//   1. THE API BASE IS DATA, THE ORIGIN IS IDENTITY (plan §10.7). Nothing in this file assumes the
//      Mac is at the address the app was loaded from. `state.apiBase` is read at EVERY request, it
//      starts as the origin, and it is replaced by whatever the Mac last advertised — in the stream's
//      `hello` or in a push payload. Without that seam a public address that changes orphans the
//      installed app, the push subscription and the cache, and no push can fix it because the push
//      is delivered TO the origin it is trying to replace. With it, every later way of reaching him
//      from away is an implementation of one interface.
//
//   2. THE SIGNATURE IS OVER THE SERVER'S OWN CHALLENGE. The device key is a non-extractable P-256
//      key (plan §2.7); the Mac issues the challenge; the phone replays the most recent one it was
//      given. Ordering is never client-generated, and neither is the thing being signed.
//
//   3. FAILURES ARE CLASSIFIED, because the whole honesty of the send queue rests on telling
//      "your Mac is not reachable from here" apart from "your Mac refused this". A `TypeError` from
//      `fetch` is unreachable; a 403 carrying `{"revoked":true}` is final and must never be retried;
//      a 404 is the flat refusal §2.5 specifies for an unauthorized caller and is also not a retry.
//      Everything else is a fault with a status attached.
//
// No dependencies, no framework, and no `EventSource` unless the platform gives one. Loads as a
// plain script (defines `globalThis.RichOSApi`) and as a CommonJS module.

(function (root, factory) {
	const api = factory();
	if (typeof module === 'object' && module.exports) module.exports = api;
	root.RichOSApi = api;
})(typeof globalThis !== 'undefined' ? globalThis : this, function () {
	'use strict';

	// The reasons a request can fail, as data. The UI matches on these and never on a message
	// string, so the sentence he reads can be rewritten without changing behavior.
	const UNREACHABLE = 'unreachable';
	const REVOKED = 'revoked';
	const REFUSED = 'refused';
	const FAULT = 'fault';

	class ApiError extends Error {
		constructor(reason, message, status) {
			super(message);
			this.name = 'ApiError';
			this.reason = reason;
			this.status = status || 0;
			// The only two reasons worth trying again: the Mac was not reachable, or it faulted in a
			// way that might not repeat. A revoked device and a flat refusal are answers, not
			// accidents, and retrying them is how a phone hammers a Mac that has forgotten it.
			this.retryable = reason === UNREACHABLE || reason === FAULT;
		}
	}

	function joinBase(base, path) {
		if (!base) throw new ApiError(FAULT, 'no address for your Mac is stored yet');
		return base.replace(/\/+$/, '') + path;
	}

	// The string that gets signed. Written once, here, because the Mac has to build the identical
	// one and a difference of a newline is a day of two people being sure they are right.
	function signingInput(challenge, method, pathWithQuery, bodyHashHex) {
		return `${challenge}\n${method.toUpperCase()}\n${pathWithQuery}\n${bodyHashHex || ''}`;
	}

	/// `signer` is the only thing this module needs from the platform's crypto:
	///   { deviceId, sign(utf8String) -> Promise<base64url string>, sha256Hex(bytesOrString) -> Promise<hex> }
	/// The browser implements it over WebCrypto with the non-extractable key; the tests implement it
	/// over `node:crypto` with a key the test owns. Same code path, both times.
	function createApi(options) {
		const opts = options || {};
		const fetchImpl = opts.fetchImpl || (typeof fetch === 'function' ? fetch.bind(globalThis) : null);
		const EventSourceImpl = opts.eventSourceImpl || (typeof EventSource === 'function' ? EventSource : null);
		const state = opts.state;              // { apiBase, challenge, deviceId }
		const signer = opts.signer || null;
		const onState = opts.onState || function () {};

		if (!state) throw new Error('createApi needs a state object');

		function setChallenge(next) {
			if (next && next !== state.challenge) {
				state.challenge = next;
				onState(state);
			}
		}

		function setApiBase(next) {
			if (next && next !== state.apiBase) {
				state.apiBase = next;
				onState(state);
			}
		}

		async function authorization(method, pathWithQuery, bodyHashHex) {
			if (!signer || !state.deviceId || !state.challenge) return null;
			const signature = await signer.sign(signingInput(state.challenge, method, pathWithQuery, bodyHashHex));
			return `RichOS-Device ${state.deviceId}.${state.challenge}.${signature}`;
		}

		async function request(method, pathWithQuery, body, contentType) {
			if (!fetchImpl) throw new ApiError(FAULT, 'this browser has no fetch');
			const url = joinBase(state.apiBase, pathWithQuery);
			const headers = {};
			let payload;
			if (body !== undefined && body !== null) {
				payload = typeof body === 'string' || body instanceof Uint8Array || body instanceof ArrayBuffer
					? body
					: JSON.stringify(body);
				headers['Content-Type'] = contentType || 'application/json';
			}
			const bodyHash = payload === undefined ? '' : await signer.sha256Hex(payload);
			const auth = await authorization(method, pathWithQuery, bodyHash);
			if (auth) headers.Authorization = auth;

			let response;
			try {
				response = await fetchImpl(url, { method, headers, body: payload, mode: 'cors', cache: 'no-store' });
			} catch (err) {
				// This is the branch the queue exists for. A `fetch` that throws did not reach the
				// Mac at all — wrong network, Mac asleep, name not resolving here.
				throw new ApiError(UNREACHABLE, String((err && err.message) || err));
			}

			setChallenge(response.headers && response.headers.get ? response.headers.get('X-RichOS-Challenge') : null);

			if (response.status === 403) {
				let revoked = false;
				try { revoked = (await response.clone().json()).revoked === true; } catch { /* not JSON */ }
				if (revoked) throw new ApiError(REVOKED, 'this phone was removed from your Mac');
				throw new ApiError(REFUSED, 'your Mac refused this', 403);
			}
			// §2.5 item 4: an unauthorized caller learns nothing, not even that it guessed a real
			// path. So a 404 here means "not for you", never "this route is missing".
			if (response.status === 404) throw new ApiError(REFUSED, 'your Mac did not accept this phone', 404);
			if (!response.ok) throw new ApiError(FAULT, `your Mac answered with ${response.status}`, response.status);
			return response;
		}

		async function json(method, pathWithQuery, body, contentType) {
			const response = await request(method, pathWithQuery, body, contentType);
			const text = await response.text();
			if (!text) return {};
			try {
				return JSON.parse(text);
			} catch {
				throw new ApiError(FAULT, 'your Mac sent something this app could not read');
			}
		}

		function query(params) {
			const search = new URLSearchParams();
			Object.keys(params).forEach((k) => {
				if (params[k] !== undefined && params[k] !== null) search.set(k, String(params[k]));
			});
			const s = search.toString();
			return s ? `?${s}` : '';
		}

		return {
			state,
			setApiBase,
			setChallenge,
			signingInput,

			// ---- (a) post a message -------------------------------------------------------------
			//
			// Idempotent on `client_id`: the phone's own de-duplication key, which is what makes the
			// queue safe to retry after a failure it could not classify. A repeat returns the
			// original message with `duplicate: true` rather than a second message.
			async sendText(item) {
				return json('POST', '/api/messages', {
					client_id: item.clientId,
					thread_id: item.threadId,
					kind: 'text',
					text: item.text,
					sent_at: item.sentAt
				});
			},

			// The WAV goes as bytes, not base64: a 20-second note is about 640 KB (plan §3.3) and
			// base64 would make it 850 KB to say the same thing. `codec` is explicit and always
			// sent, so native can send `opus` later against this same contract.
			async sendVoice(item) {
				const path = '/api/messages' + query({
					client_id: item.clientId,
					thread_id: item.threadId,
					kind: 'voice',
					codec: item.codec || 'wav16k',
					sample_rate: item.sampleRate || 16000,
					seconds: item.seconds,
					sent_at: item.sentAt
				});
				return json('POST', path, item.bytes, 'audio/wav');
			},

			// ---- (b) the stream, and the backfill behind infinite scroll ------------------------
			async backfill(threadId, beforeCursor, limit) {
				return json('GET', '/api/events' + query({
					thread_id: threadId, before: beforeCursor, limit: limit || 40
				}));
			},

			/// The live stream. `EventSource` cannot carry a header, so the stream — and only the
			/// stream — puts its credential in the query string; CONTRACT-STUB.md §2(b) names that as
			/// a real weakening and says what makes it tolerable. Returns a handle with `close()`.
			async openEvents(threadId, sinceCursor, handlers) {
				if (!EventSourceImpl) throw new ApiError(FAULT, 'this browser has no event stream');
				const path = '/api/events' + query({ thread_id: threadId, since: sinceCursor });
				const auth = await authorization('GET', path, '');
				const url = joinBase(state.apiBase, path) + (auth ? `&auth=${encodeURIComponent(auth)}` : '');
				const source = new EventSourceImpl(url, { withCredentials: false });

				const wire = (name) => {
					source.addEventListener(name, (event) => {
						let data = {};
						try { data = event.data ? JSON.parse(event.data) : {}; } catch { data = {}; }
						if (name === 'hello') {
							setChallenge(data.challenge);
							setApiBase(data.api_base);
						}
						if (handlers[name]) handlers[name](data);
					});
				};
				['hello', 'message', 'delta', 'state', 'heartbeat'].forEach(wire);
				source.onopen = () => { if (handlers.open) handlers.open(); };
				// An `EventSource` reconnects by itself, so this is a report rather than a command to
				// reconnect. Two reconnect loops fighting each other is a phone that hammers a Mac.
				source.onerror = () => { if (handlers.error) handlers.error(); };
				return source;
			},

			// ---- (c) one audio blob, by an id the Mac minted ------------------------------------
			//
			// Fetched rather than handed to an <audio src>, for two reasons that both matter: the
			// element cannot send the authorization header, and a failure here has to be a sentence
			// he can read rather than a silent control that does nothing.
			async fetchAudio(messageId) {
				const response = await request('GET', `/api/audio/${encodeURIComponent(messageId)}`);
				return response.blob ? response.blob() : response.arrayBuffer();
			},

			// ---- (d) pairing, and the device record ---------------------------------------------
			async pair(code, publicKeyJwk, deviceName) {
				// No signature: this is the request that establishes the credential.
				const response = await fetchImpl(joinBase(state.apiBase, '/api/pair'), {
					method: 'POST',
					headers: { 'Content-Type': 'application/json' },
					mode: 'cors',
					cache: 'no-store',
					body: JSON.stringify({ code, public_key_jwk: publicKeyJwk, device_name: deviceName })
				}).catch((err) => { throw new ApiError(UNREACHABLE, String((err && err.message) || err)); });

				if (response.status === 404 || response.status === 403) {
					throw new ApiError(REFUSED, 'your Mac did not accept that pairing code', response.status);
				}
				if (!response.ok) throw new ApiError(FAULT, `your Mac answered with ${response.status}`, response.status);
				const body = await response.json();
				state.deviceId = body.device_id;
				setChallenge(body.challenge);
				setApiBase(body.api_base);
				onState(state);
				return body;
			},

			async registerPush(subscription) {
				return json('POST', '/api/pair', {
					device_id: state.deviceId,
					push_transport: 'web-push',
					push: subscription
				});
			}
		};
	}

	return { createApi, ApiError, signingInput, UNREACHABLE, REVOKED, REFUSED, FAULT };
});
