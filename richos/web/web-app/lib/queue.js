// THE ON-PHONE SEND QUEUE — slice A4, and the one regression §57 introduced.
//
// Under the design this replaced, a relay held a message while the Mac slept. There is no relay, so
// the message waits HERE, on his phone, and the plan says so in his own words (§2.4):
//
//     "His message goes into the phone's own queue, marked visibly 'waiting to send — your Mac
//      isn't reachable from here', and leaves the moment he is home with the app open."
//
// FIVE RULES, AND EACH ONE IS A FAILURE THIS FILE EXISTS TO PREVENT:
//
//  1. NOTHING IS LOST ON A RELAUNCH. An item is on disk before `enqueue` resolves, not after the
//     send fails. A queue that persists on failure loses the message the one time the app is killed
//     mid-send, which is exactly when he was least likely to be watching.
//
//  2. ORDER IS NEVER BROKEN. The flush is strictly first-in-first-out and STOPS at the first item
//     that could not go. Continuing past a stuck message would deliver his third sentence before his
//     first, and a conversation reordered by a network is worse than a conversation delayed by one.
//
//     ITS ONE LIMIT, AND IT IS NOT AN EXCEPTION TO THE RULE: the flush stops at a message that COULD
//     NOT GO, never at one that will NEVER go. A `BLOCKED` item leaves this queue in exactly two ways
//     — he discards it, or the phone is unpaired — so nothing is queued BEHIND it in any sense that
//     means anything; there is no turn for it to be taking. `flush` already knew that on every pass
//     after the first (line ~123, `if (item.state === BLOCKED) continue`) and forgot it on the pass
//     that did the blocking, which is the pass he is looking at. One voice note this build cannot
//     take would otherwise strand every text he typed afterwards (plan §2 A).


//
//  3. A RETRY IS SAFE BECAUSE THE SEND IS IDEMPOTENT. Every item carries its own `clientId`, which
//     is the de-duplication key the Mac keys on (CONTRACT-STUB.md §2(a), plan §4.2 (i)). An item
//     that was `sending` when the app died is re-sent on the next launch: the Mac either has it
//     already and says `duplicate`, or never saw it. The alternative — leaving it `sending` forever
//     to avoid a double — loses messages, and losing one is worse than sending one twice when
//     sending it twice is impossible by construction.
//
//  4. A FINAL ANSWER IS NOT RETRIED. A revoked device and a flat refusal are answers. Retrying them
//     is a phone hammering a Mac that has forgotten it, and it is the behavior that turns a quiet
//     bug into a loud one.
//
//  5. NOTHING RUNS IN THE BACKGROUND, BECAUSE NOTHING CAN. Safari has no Background Sync; a PWA
//     flushes when it is open and not otherwise (§2.4). This module never sets a timer of its own —
//     the app decides when to call `flush`, and `app.js` calls it on open, on the stream connecting,
//     and on his tap. That also keeps §6's "no polling loop that wakes the Mac".
//
//     **AND RULE 5 TURNED OUT TO BE THE SECOND HALF OF A THIRTY-SECOND SEND.** It is right about
//     the background and it was wrong about the foreground. This module set no timer AND owned no
//     retry policy, so a send that failed while he was looking at the screen waited for whatever
//     happened to call `flush` next — and the only thing that does so unprompted is `lib/link.js`
//     reconnecting the STREAM, on a backoff capped at 30 s. Every delay Ray measured on nightly
//     `.7` was therefore ≥30 s with a backoff's spread: 30.67 s, 54.47 s, 48.79 s. A send path
//     borrowing a transport's retry policy is the defect T3 Code's connection runtime names in
//     one sentence — *"Keeping retries and session lifetime here prevents competing reconnect
//     loops"* (`docs/internals/connection-runtime.md:5-7`). So the OUTBOX owns its own policy
//     now, below, and `app.js` owns exactly one timer for it. Nothing runs when the app is shut,
//     which is all rule 5 ever needed to say.
//
// ---------------------------------------------------------------------------------------------
// WHAT IS PORTED FROM T3 CODE, AND FROM WHERE (MIT, `pingdotgg/t3code` @ `8ebb6112`)
//
// The design, not the code — this file has no React, no atoms and no Effect schema, and the
// shapes below are ours. What was taken is the reasoning, and the two numbers:
//
//   * `apps/mobile/src/state/thread-outbox-model.ts:163-165` — `threadOutboxRetryDelayMs`:
//     `Math.min(1_000 * 2 ** Math.max(0, attempt - 1), 16_000)`. Re-derived rather than
//     quoted: attempt 1 waits 1,000 ms, then 2,000, 4,000, 8,000, 16,000, 16,000 … so a message
//     that fails is retried at t = 1 s, 3 s, 7 s, 15 s, 31 s and every 16 s after that, against
//     a first attempt that is immediate. Five attempts inside the first half-minute, where the
//     old path made ONE and then waited for a stream.
//   * `apps/mobile/src/state/thread-outbox-manager.ts:51-57, 164-177` — the monotonic per-message
//     write revision and `update(message, expectedRevision)` as a compare-and-set. Their comment
//     is the reason: *"a writer that captured a revision before slow work"* must not win against
//     a write accepted since. Ours had the same hole and it was reachable: `flush` awaits inside
//     `try`, and a `discard` or a `clear` that lands during that await was undone by the error
//     path's own `storage.put`, putting a message he had removed back on his phone.
//   * `docs/internals/connection-runtime.md:9-15` — *"Transient failures retry with capped
//     backoff. Offline states and authentication failures wait for a wakeup instead of spending
//     attempts on unchanged conditions."* `retryable` already split those; what was missing was
//     the second half, so an outbox that is offline now reports `waitingForWakeup` and the app
//     sets no timer until the platform says the network is back.
//
// Loads as a plain script (defines `globalThis.RichOSQueue`) and as a CommonJS module.

(function (root, factory) {
	const api = factory();
	if (typeof module === 'object' && module.exports) module.exports = api;
	root.RichOSQueue = api;
})(typeof globalThis !== 'undefined' ? globalThis : this, function () {
	'use strict';

	const WAITING = 'waiting';     // on the phone, not yet accepted by the Mac
	const SENDING = 'sending';     // in flight right now
	const BLOCKED = 'blocked';     // the Mac gave a final answer; this needs him, not a retry

	// THE OUTBOX'S OWN RETRY POLICY. Ported from T3 Code's `threadOutboxRetryDelayMs`
	// (`apps/mobile/src/state/thread-outbox-model.ts:163-165`, MIT, `pingdotgg/t3code` @
	// `8ebb6112`) with their two numbers kept: double from one second, cap at sixteen.
	//
	// SIXTEEN AND NOT THIRTY, and the difference is the whole defect. `lib/link.js` caps the
	// STREAM's backoff at 30 s, which is right for a transport that is trying to stay open all
	// day against a Mac that may be off. It is wrong for a sentence he has just typed and is
	// watching for. These are two different questions and they now have two different owners.
	const FIRST_RETRY_MS = 1000;
	const MAX_RETRY_MS = 16000;

	function retryDelayMs(attempt) {
		return Math.min(FIRST_RETRY_MS * Math.pow(2, Math.max(0, attempt - 1)), MAX_RETRY_MS);
	}

	/// `storage` is the durable half, and it is a port rather than IndexedDB directly so the whole
	/// state machine can be driven in Node. The browser adapter is in `lib/storage.js`.
	///   { all() -> Promise<item[]>, put(item) -> Promise, remove(clientId) -> Promise }
	function createQueue(options) {
		const opts = options || {};
		const storage = opts.storage;
		const now = opts.now || (() => new Date().toISOString());
		// The MONOTONIC clock, in milliseconds, for the retry schedule only. Separate from `now`
		// above, which stamps `queuedAt` and is an ISO string because that is what orders his
		// messages. A test drives both.
		const clock = opts.clock || (() => Date.now());
		const onChange = opts.onChange || function () {};
		if (!storage) throw new Error('createQueue needs a storage port');

		let items = [];
		let flushing = null;

		// THE WRITE REVISION, PER MESSAGE — T3 Code's `thread-outbox-manager.ts:51-57`, and their
		// comment names the failure exactly: *"a writer that captured a revision before slow work"*
		// must lose to a write accepted since. Every accepted write bumps it.
		const revisions = new Map();
		function bump(clientId) {
			const next = (revisions.get(clientId) || 0) + 1;
			revisions.set(clientId, next);
			return next;
		}
		function revisionOf(clientId) { return revisions.get(clientId) || 0; }

		/// Write an item back, UNLESS something else was accepted for it since `expected` was
		/// read. Returns false when it was refused, which the caller treats as "this message is
		/// no longer mine to write" and never as a failure.
		///
		/// The hole this closes was reachable and not theoretical: `flush` awaits the network
		/// inside its `try`, and a `discard` landing during that await used to be undone by the
		/// error path's own `storage.put` — a message he had removed, back on his phone.
		async function write(item, expected) {
			if (expected !== undefined && revisionOf(item.clientId) !== expected) return false;
			if (!items.some((i) => i.clientId === item.clientId)) return false;
			await storage.put(item);
			bump(item.clientId);
			return true;
		}

		function sorted() {
			// Ordered by when HE pressed send, which is the only order that means anything here. The
			// Mac's cursors order the conversation; they cannot order something the Mac has not seen.
			return items.slice().sort((a, b) => (a.queuedAt < b.queuedAt ? -1 : a.queuedAt > b.queuedAt ? 1 : 0));
		}

		function changed() { onChange(sorted()); }

		/// Is this item allowed to go right now? A message that has never been tried always is —
		/// T3's *"resolving an endpoint and opening an RPC session are single attempts"* applied
		/// to a send: the FIRST attempt is immediate, and only a failure buys a wait.
		function dueNow(item, at) {
			return !item.notBefore || item.notBefore <= at;
		}

		return {
			/// Read the queue back off the phone. Anything left `sending` by a launch that ended
			/// mid-flight becomes `waiting` again — see rule 3.
			async load() {
				items = (await storage.all()) || [];
				let resumed = 0;
				for (const item of items) {
					if (item.state === SENDING) {
						item.state = WAITING;
						item.resumedAfterInterruptedSend = true;
						// A launch that died mid-send is not a failure this message has to wait out:
						// he opened the app, and the whole reason rule 3 re-sends is that the Mac's
						// `client_id` makes it free. The clock starts again from nothing.
						item.notBefore = 0;
						resumed++;
						await storage.put(item);
						bump(item.clientId);
					}
				}
				changed();
				return { count: items.length, resumed };
			},

			all() { return sorted(); },

			count() { return items.length; },

			waitingCount() { return items.filter((i) => i.state === WAITING || i.state === SENDING).length; },

			blocked() { return items.filter((i) => i.state === BLOCKED); },

			/// Durable BEFORE it resolves. The caller may show an optimistic bubble the moment this
			/// returns, and the bubble is then backed by something that survives the app dying.
			async enqueue(draft) {
				const item = Object.assign({
					state: WAITING,
					attempts: 0,
					queuedAt: now(),
					lastReason: null
				}, draft);
				if (!item.clientId) throw new Error('every queued item needs its own clientId');
				if (items.some((i) => i.clientId === item.clientId)) return item;
				await storage.put(item);
				bump(item.clientId);
				items.push(item);
				changed();
				return item;
			},

			/// **HOW LONG UNTIL SOMETHING IN HERE IS OWED A TRY**, in milliseconds, and it is the
			/// whole of what this module asks the app for. `0` means now, and `null` means nothing
			/// is waiting — so `app.js` owns exactly ONE timer and this module still sets none,
			/// which is rule 5 kept as written rather than bent.
			///
			/// A `blocked` item is never counted: it is waiting for HIM, not for a clock.
			dueInMs() {
				const at = clock();
				let soonest = null;
				for (const item of items) {
					if (item.state === BLOCKED) continue;
					const owed = Math.max(0, (item.notBefore || 0) - at);
					if (soonest === null || owed < soonest) soonest = owed;
				}
				return soonest;
			},

			/// The schedule itself, exposed so the harness asserts the arithmetic rather than
			/// inferring it from sleeping. Ported from T3 Code — see the header.
			retryDelayMs,

			/// The write revision for one message, for a caller that wants to read it before slow
			/// work and hand it back afterwards. T3 Code's `threadOutboxRevision`.
			revisionOf,

			/// Try to hand the queue to the Mac, oldest first, stopping at the first one that cannot
			/// go. `sender` is the API module. Returns what happened, as data.
			///
			/// Concurrent calls collapse into the one in flight: the app flushes on visibility, on
			/// the stream opening and on a tap, and those three land together often enough that a
			/// second pass would re-send an item the first pass is still waiting on.
			async flush(sender) {
				if (flushing) return flushing;
				flushing = (async () => {
					// `accepted` carries the Mac's OWN answer for each item it took — `message_id`,
					// `cursor`, `accepted_at`. Without it the answer died here, and with it died
					// the only thing on the phone that knew where his message had gone: the item
					// is dropped on success (rule 3), no live frame in this build carries a CEO
					// turn (`phone/rows.rs:115-173`), and the projected row waits for the next
					// `hello`. So the caller hands each one to `thread.confirm` and his message
					// stays on the screen it was typed on.
					const result = {
						sent: 0, waiting: 0, blocked: 0, reason: null, duplicates: 0, accepted: [],
						// SOMETHING IS QUEUED AND ITS RETRY CLOCK HAS NOT COME ROUND YET. The caller
						// reads it to decide whether to leave the screen's wording alone: a message
						// that is merely between attempts has not failed, and saying so would be the
						// app fidgeting at him.
						deferred: 0
					};
					const at = clock();
					for (const item of sorted()) {
						if (item.state === BLOCKED) { result.blocked++; continue; }
						// THE OUTBOX'S OWN CLOCK, AND THE FIRST ATTEMPT IS NEVER ON IT. A message that
						// has never been tried has no `notBefore`, so it goes the instant he presses
						// Send; only a failure buys a wait. Rule 2 still holds — this STOPS rather
						// than skipping, because a message that is waiting out its backoff is still
						// ahead of everything he typed after it.
						if (!dueNow(item, at)) {
							result.deferred = items.filter((i) => i.state === WAITING).length;
							result.waiting = result.deferred;
							result.reason = item.lastReason;
							return result;
						}

						// The revision as it stands BEFORE the network, which is the slow work T3's
						// comment is about. Every write below is a compare-and-set against it, so a
						// `discard` or a `clear` that lands mid-send wins and this pass writes nothing.
						item.state = SENDING;
						item.attempts++;
						if (!(await write(item, revisionOf(item.clientId)))) continue;
						const mine = revisionOf(item.clientId);
						changed();

						try {
							const response = item.kind === 'voice' ? await sender.sendVoice(item) : await sender.sendText(item);
							if (response && response.duplicate) result.duplicates++;
							if (revisionOf(item.clientId) !== mine) continue;
							items = items.filter((i) => i.clientId !== item.clientId);
							await storage.remove(item.clientId);
							bump(item.clientId);
							result.sent++;
							if (response) result.accepted.push({ item, answer: response });
							changed();
						} catch (err) {
							const retryable = err && err.retryable;
							item.state = retryable ? WAITING : BLOCKED;
							item.lastReason = (err && err.reason) || 'fault';
							item.lastMessage = (err && err.message) || String(err);
							// WHEN THIS ONE IS OWED ANOTHER TRY. Doubling from a second, capped at
							// sixteen — the outbox's own policy and not the stream's thirty. An
							// UNREACHABLE phone is T3's *"offline states ... wait for a wakeup instead
							// of spending attempts on unchanged conditions"*: the schedule is still
							// written down so nothing is stranded if no wakeup ever comes.
							item.notBefore = clock() + retryDelayMs(item.attempts);
							if (!(await write(item, mine))) continue;
							changed();
							if (retryable) {
								// Rule 2: everything behind this one stays where it is.
								result.waiting = items.filter((i) => i.state === WAITING).length;
								result.reason = item.lastReason;
								return result;
							}
							result.blocked++;
							// Whoever is actually holding the queue up gets to name the reason, so a
							// message that is merely FIRST does not get to describe a queue it is no
							// longer part of. A retryable stop below overwrites this on its way out.
							if (!result.reason) result.reason = item.lastReason;
							// Rule 2's limit. `aboutThisMessage` is set only where the Mac gave a
							// final answer about THIS item (`api.js`, a refusal carrying
							// `"retry": false`). Every other final answer — a forgotten phone, a flat
							// 404 — is about the PHONE, applies identically to everything behind it,
							// and retrying the rest is rule 4's "hammering a Mac that has forgotten
							// it". So one continues and the other stops, and the difference is which
							// of the two the failure was about.
							if (err && err.aboutThisMessage) continue;
							return result;
						}
					}
					result.waiting = items.filter((i) => i.state === WAITING).length;
					return result;
				})().finally(() => { flushing = null; });
				return flushing;
			},

			/// He asked for it to stop trying. The message is his, so it is dropped rather than
			/// hidden — and the control that does this is rendered beside the state it changes.
			async discard(clientId) {
				// BUMPED FIRST, and that is the point of the counter. A send for this message may
				// be awaiting the network right now; bumping here makes its own write a losing
				// compare-and-set, so the message he just removed cannot be written back.
				bump(clientId);
				items = items.filter((i) => i.clientId !== clientId);
				await storage.remove(clientId);
				changed();
			},

			/// **HE ASKED FOR IT TO BE TRIED AGAIN**, so it goes NOW and not when a backoff this
			/// module chose happens to come round. Anything the Mac gave a final answer about is
			/// put back in the queue and every retry clock is cleared.
			///
			/// It exists because `app.js` used to reach in and set `item.state` itself, which left
			/// `notBefore` where it was — so his tap would have been answered with a wait.
			retryEverythingNow() {
				for (const item of items) {
					if (item.state === BLOCKED) item.state = WAITING;
					item.notBefore = 0;
				}
				changed();
			},

			/// Used when the Mac says this phone was forgotten: there is nowhere for these to go and
			/// keeping them would be a queue that can never drain.
			async clear() {
				for (const item of items) {
					bump(item.clientId);
					await storage.remove(item.clientId);
				}
				items = [];
				changed();
			},

			states: { WAITING, SENDING, BLOCKED }
		};
	}

	return { createQueue, WAITING, SENDING, BLOCKED };
});
