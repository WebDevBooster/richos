# RichOS streaming event contract (spine → UI)

The spine streams Rich's reply **live** to the web UI via **Tauri events** while a turn
runs. The `send_message` command still returns the final reconciled message list, but the
UI should render deltas from the events below so Rich's reply appears token-by-token and a
calm "Rich is working" state is shown.

This is the whole contract the UI needs — **no Rust reading required.** The Rust source of
truth is `app/crates/richos-core/src/stream.rs` (event names as constants) +
`app/src-tauri/src/main.rs` (`TauriEmitter`). Clean output is guaranteed by the spine:
**only assistant-message text is ever emitted** — never tool calls, worker chatter, shell,
or hook output.

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
- `seq` is a **0-based, strictly increasing** per-turn counter. Concatenating `textDelta`
  in `seq` order reproduces the full reply that the ledger holds for that turn — so a UI
  that missed the stream can fall back to `get_messages` (or `send_message`'s return) and
  get the identical text.
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
