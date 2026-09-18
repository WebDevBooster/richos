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
		let oldestKnownCursor = null;
		let reachedTheBeginning = false;

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
				const server = Array.from(rows.values()).sort((a, b) => a.cursor - b.cursor);
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
				return server.concat(waiting);
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
				oldestKnownCursor = null;
				reachedTheBeginning = false;
				return this;
			}
		};
	}

	return { createThread };
});
