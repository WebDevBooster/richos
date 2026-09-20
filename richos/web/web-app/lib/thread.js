// THE THREAD, AS THE PHONE HOLDS IT — a VIEW of the ledger on his Mac, and never a second record.
//
// Plan §6, flatly: "A second conversation store on the phone ... The phone caches a view for offline
// reading and is never the source of truth for anything. A phone that can disagree with the Mac
// about what Rich said is worse than a phone that shows nothing."
//
// So the rules here are rules about who decides:
//
//   * ORDER COMES FROM THE MAC. Every row carries a `cursor` the Mac issued, and that is the only
//     thing this module sorts by (plan §4.2 (vi): "server-issued, never client-generated ordering").
//     The phone's own clock never orders anything — two devices' clocks disagree, and a conversation
//     that reorders itself when a phone's time is wrong is a bug nobody can reproduce.
//   * THE MAC OVERWRITES. A row that arrives again replaces the one held, whole. There is no merge
//     of fields, no "keep the local edit", nothing the phone can be right about and the Mac wrong.
//   * THE ONLY THING THE PHONE OWNS is the bubble for a message the Mac has not accepted yet, and it
//     owns it exactly until the Mac's own row for it arrives — matched on `client_id`, which is the
//     same de-duplication key the send used. That is what stops his message appearing twice in the
//     second between the acknowledgment and the row.
//
// Loads as a plain script (defines `globalThis.RichOSThread`) and as a CommonJS module.

(function (root, factory) {
	const api = factory();
	if (typeof module === 'object' && module.exports) module.exports = api;
	root.RichOSThread = api;
})(typeof globalThis !== 'undefined' ? globalThis : this, function () {
	'use strict';

	function createThread() {
		// id -> row. A Map because insertion order is irrelevant: the cursor orders everything.
		const rows = new Map();
		// Every `client_id` the Mac has confirmed it holds, so a pending bubble for it can go.
		const acknowledgedClientIds = new Set();
		// clientId -> the row for a message the Mac has ACCEPTED and not yet projected back.
		// See `confirm` for why this exists and for the one rule that retires it.
		const confirmedByClientId = new Map();
		let oldestKnownCursor = null;
		let reachedTheBeginning = false;

		/// Is this row the Mac's stand-in for a sentence it has taken but not yet turned into a
		/// turn? Its id is the intake id — `intake_<n>`, the id `POST /api/messages` answers a
		/// phone with, and the id the Mac announces a DESK message under before the spine has
		/// been asked for anything (`app/src-tauri/src/phone/stream.rs` `announce_his_words`).
		function isAStandIn(row) {
			return Boolean(row) && row.role === 'ceo' && typeof row.id === 'string' && row.id.indexOf('intake_') === 0;
		}

		function remember(row) {
			if (!row || !row.id) return;
			if (typeof row.cursor !== 'number') {
				// A row with no cursor cannot be placed. Dropping it is right: the alternative is
				// inventing a position for it, which is the one thing this module must never do.
				return;
			}
			const existing = rows.get(row.id);
			rows.set(row.id, existing ? Object.assign({}, existing, row) : Object.assign({}, row));
			if (row.client_id) acknowledgedClientIds.add(row.client_id);
			if (oldestKnownCursor === null || row.cursor < oldestKnownCursor) oldestKnownCursor = row.cursor;

			// **THE STAND-IN RETIRES ON THE MAC'S OWN ROW, AND THE MATCH IS THE TEXT** — the same
			// rule `confirm`/`view` have used for a phone's pending bubble since the send queue
			// was written, and for the same reason: the projected row carries `client_id: null`
			// and the id it carries is the projection's (`{turn}:user`), so his words are the
			// only thing the two have in common.
			//
			// Both rows are the Mac's, which is what makes this a repaint rather than a
			// reconciliation: the stand-in came from a record the Mac had already fsynced, and
			// the row replacing it is that record having become a turn.
			//
			// TWO IDENTICAL MESSAGES IN A ROW retire together on the first of the two and the
			// second reappears with the next merge — a repaint, never a loss. Said here rather
			// than discovered, exactly as `confirm` says it.
			if (row.role === 'ceo' && !isAStandIn(row)) {
				rows.forEach((held, id) => {
					if (isAStandIn(held) && (held.text || '') === (row.text || '')) rows.delete(id);
				});
			}
		}

		return {
			merge(rowOrRows) {
				const list = Array.isArray(rowOrRows) ? rowOrRows : [rowOrRows];
				list.forEach(remember);
				return this;
			},

			/// A streamed reply, arriving in pieces while he watches. The row may not exist yet — a
			/// delta can beat its own message row through the stream — so one is opened for it
			/// rather than dropping his answer on the floor.
			applyDelta(delta) {
				if (!delta || !delta.message_id) return this;
				const existing = rows.get(delta.message_id);
				if (existing) {
					existing.text = (existing.text || '') + (delta.text || '');
					existing.complete = false;
					return this;
				}
				if (typeof delta.cursor !== 'number') return this;
				remember({
					id: delta.message_id, cursor: delta.cursor, role: 'rich', kind: 'text',
					text: delta.text || '', complete: false
				});
				return this;
			},

			applyState(update) {
				if (!update || !update.message_id) return this;
				const existing = rows.get(update.message_id);
				if (!existing) return this;
				if (update.state !== undefined) existing.state = update.state;
				if (update.complete !== undefined) existing.complete = update.complete;
				return this;
			},

			/// HIS OWN MESSAGE, FROM THE MAC'S OWN ANSWER TO THE SEND — and the narrow reason it
			/// is not just the pending bubble.
			///
			/// The Mac answers `POST /api/messages` with `{message_id, cursor, thread_id,
			/// accepted_at}` (`app/src-tauri/src/phone/routes.rs:370-376`) and the send queue then
			/// drops the item, because the Mac has it and nothing durable is owed any more
			/// (`queue.js`, rule 3). Until this existed, that left NOTHING on the screen where his
			/// message had been.
			///
			/// **THE REASON GIVEN HERE WAS TRUE UNTIL `102b7c07` AND IS NOT ANY MORE, so it is
			/// corrected rather than left to be read as current.** It said: *"the Mac's own row
			/// for it does not arrive on the live stream — `event_from_live` translates
			/// `rich://message-*` and nothing else, so no live frame in this build carries a CEO
			/// turn"*. `rich://ceo-message` exists now (`phone/rows.rs` `event_from_live`'s first
			/// arm, `opens_a_row`), and it is emitted for BOTH roads a CEO utterance can take —
			/// the desk (`spine.rs`'s `accept_prompt`) and the intake log the phone writes to
			/// (`spine.rs`'s `drain_intake`). So his own row now arrives live, with the
			/// projection's own id.
			///
			/// **This stand-in is therefore SHORTER-LIVED and is still not redundant.** It covers
			/// the window between the Mac accepting the POST and the turn being drained, which is
			/// a real window: the drain runs on its own thread and needs the spine, and a phone
			/// with nothing on the screen in it is the defect this was written for.
			///
			/// So this is the bubble AFTER the Mac has taken it: ordered by the cursor the Mac
			/// itself promised, so it sits where his message will sit rather than at the bottom.
			///
			/// **IT RETIRES ON THE MAC'S OWN ROW, AND THE MATCH IS THE TEXT.** The de-duplication
			/// key the contract names is `client_id`, and the Mac's projected rows carry
			/// `client_id: null` for every row (`phone/rows.rs:82`, `:97`) because the id never
			/// reaches the ledger — so there is nothing to match on but his words, and his words
			/// are what is on the screen. **A CEO row in this thread is always the Mac's**, and
			/// that is unchanged by the correction above — a live `role: "ceo"` row is minted by
			/// `Spine` out of the ledger's own turn, so every road into `rows` (the live stream,
			/// a `hello`, a backfill, a push) is the projection and none of them is the phone.
			/// Two identical messages in a row therefore retire together on the first of the two
			/// rows and the second reappears with the next merge — a repaint, never a loss, and
			/// said here rather than discovered.
			confirm(item, answer) {
				if (!item || !item.clientId || !answer) return this;
				if (typeof answer.cursor !== 'number') return this;
				confirmedByClientId.set(item.clientId, {
					id: `confirmed:${item.clientId}`,
					clientId: item.clientId,
					cursor: answer.cursor,
					role: 'ceo',
					kind: item.kind === 'voice' ? 'voice' : 'text',
					text: item.text || '',
					seconds: item.seconds,
					created_at: answer.accepted_at || null,
					state: 'sent',
					complete: true,
					confirmed: true
				});
				return this;
			},

			/// Older messages, fetched behind a scroll to the top. `more === false` means the
			/// beginning of the thread, which is a real end and is rendered as one.
			prependOlder(page) {
				const list = (page && page.messages) || [];
				list.forEach(remember);
				if (page && page.more === false) reachedTheBeginning = true;
				return this;
			},

			/// What the screen renders: the Mac's rows in the Mac's order, then anything still
			/// waiting on the phone, in the order he sent it. Pending items whose `client_id` the Mac
			/// has confirmed are dropped here rather than in the caller, so no screen can show his
			/// message twice.
			view(pending) {
				const server = Array.from(rows.values());
				// The words the Mac has actually projected back as HIS. See `confirm`.
				const projected = new Set(
					server.filter((row) => row.role === 'ceo').map((row) => row.text || '')
				);
				const standIns = [];
				confirmedByClientId.forEach((row, clientId) => {
					if (acknowledgedClientIds.has(clientId)) return;
					if (projected.has(row.text || '')) return;
					standIns.push(row);
				});
				const settled = server.concat(standIns).sort((a, b) => a.cursor - b.cursor);
				const waiting = (pending || [])
					.filter((item) => !acknowledgedClientIds.has(item.clientId))
					.map((item) => ({
						id: `pending:${item.clientId}`,
						pending: true,
						clientId: item.clientId,
						role: 'ceo',
						kind: item.kind,
						text: item.text || '',
						seconds: item.seconds,
						queuedAt: item.queuedAt,
						sendState: item.state,
						reason: item.lastReason,
						attempts: item.attempts
					}));
				return settled.concat(waiting);
			},

			get(id) { return rows.get(id) || null; },
			size() { return rows.size; },
			latestCursor() {
				let latest = null;
				rows.forEach((row) => { if (latest === null || row.cursor > latest) latest = row.cursor; });
				return latest;
			},
			oldestCursor() { return oldestKnownCursor; },
			atTheBeginning() { return reachedTheBeginning; },
			knowsClientId(clientId) { return acknowledgedClientIds.has(clientId); },

			/// Used when he switches threads, and when the Mac says this phone was forgotten.
			reset() {
				rows.clear();
				acknowledgedClientIds.clear();
				confirmedByClientId.clear();
				oldestKnownCursor = null;
				reachedTheBeginning = false;
				return this;
			}
		};
	}

	return { createThread };
});
