# RichOS streaming event contract (spine → UI)

The spine streams Rich's reply **live** to the web UI via **Tauri events** while a turn
runs. The `send_message` command still returns the final reconciled message list, but the
UI should render deltas from the events below so Rich's reply appears token-by-token and a
calm "Rich is working" state is shown.

This is the whole contract the UI needs — **no Rust reading required.** The Rust source of
truth is `app/crates/richos-core/src/stream.rs` (event names as constants) +
`app/src-tauri/src/main.rs` (`TauriEmitter`). Clean output is guaranteed by the spine:
**only assistant-message text is ever emitted on the events below** — never tool calls,
worker chatter, shell, or hook output.

That guarantee is **structural, not a convention**: machinery is not a `StreamEvent` at
all. It is a second, separate family on its own event name — see
[Machinery: `rich://machinery`](#machinery-richmachinery) at the end of this document. **A
UI that does not subscribe to it cannot accidentally render machinery**, and the default
calm view does not subscribe. Do not add it to the default subscription list.

## Events

All events are keyed to `threadId` + `turnId` so the UI can scope live state to the exact
turn (and ignore anything for a thread it isn't showing). Timestamps `at` are epoch millis.

| Event name | When | Payload |
|---|---|---|
| `rich://turn-started`   | Rich accepted the turn and started working. Show the "Rich is working" affordance. | `{ threadId, turnId, at }` |
| `rich://chunk`          | One assistant-text delta arrived. Append `textDelta` to the live bubble for `turnId`. | `{ threadId, turnId, seq, textDelta, at }` |
| `rich://turn-completed` | The turn ended cleanly. Finalize the bubble; clear the working state. | `{ threadId, turnId, stopReason, at }` |
| `rich://turn-error`     | The turn ended by error/interrupt (e.g. the compute lease died). Show a calm, Rich-voiced failure; clear the working state. | `{ threadId, turnId, reason, at }` |

### Ordering & guarantees

- For one turn the UI receives **exactly one** `rich://turn-started`, then **zero or more**
  `rich://chunk` events, then **exactly one** terminal event (`rich://turn-completed` **or**
  `rich://turn-error`) — never both.
- `seq` is a **strictly increasing** per-turn counter starting at 0. Concatenating
  `textDelta` in `seq` order reproduces the full reply that the ledger holds for that turn
  — so a UI that missed the stream can fall back to `get_messages` (or `send_message`'s
  return) and get the identical text.
- **`seq` is NOT contiguous.** As of the machinery routing commit it is ONE counter per
  turn, shared with `rich://machinery`, so that the true order of "text, then a tool call,
  then more text" is reconstructible from a single sequence. If Rich runs a tool between
  two sentences you will see `seq` 3 then `seq` 7. **Never treat a gap as a lost chunk, and
  never use `seq` as an array index.** Order by it; do not count with it.
- `rich://turn-error` may still be preceded by `rich://chunk` events — a partial reply that
  streamed before the failure. Those partials are already durable in the ledger.
- Events are **best-effort from the spine's view**: the ledger, not the UI, is the source
  of truth. A UI that isn't listening never stalls or fails a turn.

## Consuming (web UI)

```js
const { listen } = window.__TAURI__.event;

// buffers keyed by turnId -> accumulated text
const live = new Map();

listen("rich://turn-started", ({ payload }) => {
  live.set(payload.turnId, "");
  showWorking(payload.threadId, true); // "Rich is working"
});

listen("rich://chunk", ({ payload }) => {
  const acc = (live.get(payload.turnId) || "") + payload.textDelta;
  live.set(payload.turnId, acc);
  renderLiveAssistant(payload.threadId, payload.turnId, acc); // token-by-token
});

listen("rich://turn-completed", ({ payload }) => {
  finalizeAssistant(payload.threadId, payload.turnId, live.get(payload.turnId));
  live.delete(payload.turnId);
  showWorking(payload.threadId, false);
});

listen("rich://turn-error", ({ payload }) => {
  showRichVoicedError(payload.threadId, payload.turnId); // never a stack trace
  live.delete(payload.turnId);
  showWorking(payload.threadId, false);
});
```

`send_message({ text })` still resolves with the final `Message[]` for the active thread;
treat it as the reconciled snapshot, not the primary render path.

---

## Machinery: `rich://machinery`

**The default conversation view does NOT subscribe to this event, and must not.** It is a
separate family carrying every non-text ACP update — tool calls, thoughts, permission
requests — for the opt-in technical view. Contract:
`docs/plans/richos-techy-mode-2026-08-26.md`; Rust source of truth:
`app/crates/richos-core/src/machinery.rs`.

| Event name | When | Payload |
|---|---|---|
| `rich://machinery` | Rich's session emitted something that is not assistant text. | one `MachineryRecord` (below) |

```jsonc
{
  "machineryId": "mach_1f2e…",   // ours; the vendor gives none for thoughts
  "threadId": "thr_…",
  "turnId": "turn_…",            // null for re-prime / between-turn traffic
  "sessionId": "…",              // which compute lease produced it
  "seq": 7,                      // THE ordering key, shared with rich://chunk
  "at": 1756425600000,           // a LABEL, never the ordering key
  "kind": "tool_call",           // tool_call | thought | permission_requested
                                 //   | client_fs_call | unknown
  "toolCallId": "toolu_…",       // the merge key: later updates MERGE into this row
  "status": "completed",         // pending | in_progress | completed | failed | (verbatim other)
  "title": "cat engine/VERSION",
  "summary": "1.0.0",            // bounded, ≤84 chars
  "locations": ["/abs/path.rs"],
  "internal": false,             // true ⇒ NEVER render this in a thread view
  "payload": { },                // the raw ACP update; absent once the raw window expires
  "truncated": false
}
```

Five rules for whoever renders this:

1. **Order by `(turnId, seq)`. Never by `at`.** Millisecond timestamps collide inside a
   streaming turn.
2. **Merge by `toolCallId`, last-write-wins per field PRESENT.** A tool call arrives as
   several events: the first has a placeholder title (`"Terminal"`) and no arguments, and
   most later ones carry no `status` at all. One `toolCallId` is ONE row, never two — and
   a whole-record overwrite would blank the status you already had.
3. **`internal: true` is never rendered in a thread.** It is re-prime and rotation
   machinery, retained for debugging. Rich never reveals that a rotation happened.
4. **`payload` may be absent** on an older record whose raw window has expired. The record
   still renders — title, status, paths, summary — and the raw pane should say so
   honestly rather than showing a blank.
5. **`kind: "unknown"` is not an error.** It is a kind that has no typed route yet; the
   vendor's own kind name is in `title`. Render it as one dim line.

**Retroactivity, stated honestly:** retention began at the routing commit. A thread that
ran before it has no machinery at all, and the honest empty state is *"nothing was
recorded for this conversation."* — not an error, and not a blank pane.
