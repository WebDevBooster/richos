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

	/// `storage` is the durable half, and it is a port rather than IndexedDB directly so the whole
	/// state machine can be driven in Node. The browser adapter is in `lib/storage.js`.
	///   { all() -> Promise<item[]>, put(item) -> Promise, remove(clientId) -> Promise }
	function createQueue(options) {
		const opts = options || {};
		const storage = opts.storage;
		const now = opts.now || (() => new Date().toISOString());
		const onChange = opts.onChange || function () {};
		if (!storage) throw new Error('createQueue needs a storage port');

		let items = [];
		let flushing = null;

		function sorted() {
			// Ordered by when HE pressed send, which is the only order that means anything here. The
			// Mac's cursors order the conversation; they cannot order something the Mac has not seen.
			return items.slice().sort((a, b) => (a.queuedAt < b.queuedAt ? -1 : a.queuedAt > b.queuedAt ? 1 : 0));
		}

		function changed() { onChange(sorted()); }

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
						resumed++;
						await storage.put(item);
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
				items.push(item);
				changed();
				return item;
			},

			/// Try to hand the queue to the Mac, oldest first, stopping at the first one that cannot
			/// go. `sender` is the API module. Returns what happened, as data.
			///
			/// Concurrent calls collapse into the one in flight: the app flushes on visibility, on
			/// the stream opening and on a tap, and those three land together often enough that a
			/// second pass would re-send an item the first pass is still waiting on.
			async flush(sender) {
				if (flushing) return flushing;
				flushing = (async () => {
					const result = { sent: 0, waiting: 0, blocked: 0, reason: null, duplicates: 0 };
					for (const item of sorted()) {
						if (item.state === BLOCKED) { result.blocked++; continue; }

						item.state = SENDING;
						item.attempts++;
						await storage.put(item);
						changed();

						try {
							const response = item.kind === 'voice' ? await sender.sendVoice(item) : await sender.sendText(item);
							if (response && response.duplicate) result.duplicates++;
							items = items.filter((i) => i.clientId !== item.clientId);
							await storage.remove(item.clientId);
							result.sent++;
							changed();
						} catch (err) {
							const retryable = err && err.retryable;
							item.state = retryable ? WAITING : BLOCKED;
							item.lastReason = (err && err.reason) || 'fault';
							item.lastMessage = (err && err.message) || String(err);
							await storage.put(item);
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
				items = items.filter((i) => i.clientId !== clientId);
				await storage.remove(clientId);
				changed();
			},

			/// Used when the Mac says this phone was forgotten: there is nowhere for these to go and
			/// keeping them would be a queue that can never drain.
			async clear() {
				for (const item of items) await storage.remove(item.clientId);
				items = [];
				changed();
			},

			states: { WAITING, SENDING, BLOCKED }
		};
	}

	return { createQueue, WAITING, SENDING, BLOCKED };
});
