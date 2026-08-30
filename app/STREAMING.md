# RichOS streaming event contract (spine → UI)

The spine streams Rich's reply **live** to the web UI via **Tauri events** while a turn
runs. The `send_message` command still returns the final reconciled message list, but the
UI should render deltas from the events below so Rich's reply appears token-by-token and a
calm "Rich is working" state is shown.

This is the whole contract the UI needs — **no Rust reading required.** The Rust source of
truth is `app/crates/richos-core/src/stream.rs` (event names as constants) +
`app/src-tauri/src/main.rs` (`TauriEmitter`).

> **FIVE FAMILIES, and this document covers all five.** The five events below are the
> shipping calm view and are **unchanged**. `rich://machinery` (further down) is the
> opt-in technical family. [The additive live-work family](#the-additive-live-work-family-13)
> — seven typed §13 events — was added on 2026-08-29 and is what a Codex-style timeline
> renderer should be written against. [Voice mode](#voice-mode-richvoice-) is the fourth,
> emitted by a different crate and subscribed only while the mic is open, and
> [the staging desk](#the-staging-desk-richcorrection-staged) is the fifth. **A UI that
> subscribes only to the events below keeps working exactly as it does today**, asserted
> byte-for-byte by `crates/richos-core/tests/live_event_tests.rs`. Clean output is
> guaranteed by the spine:
**only assistant-message text is ever emitted on the events below** — never tool calls,
worker chatter, shell, or hook output.

*(Every count in that paragraph has been wrong at some point — "three families" and "six
typed events" until 2026-08-30, each written when it was true and left behind by the commit
that changed it, with the voice family never mentioned at all.
`app/ui/tests/docs-claims.js` now joins this document's event names to the
`pub const … = "rich://…"` the Rust source declares, and it earned its keep immediately: it
caught `rich://correction-staged` the same day the staging desk landed, before anybody had
to notice.)*

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
| `rich://proactive-message` | **Rich spoke unprompted.** A proactive turn was written to the ledger atomically — there is no `turn-started` and there are no chunks. Re-read the thread (`get_messages` / the typed timeline); do not try to assemble it from a stream that never happened. | `{ threadId, turnId, tier, at }` |

`tier` is `interrupt_now | digest | silent` (`AttentionTier`, `ledger.rs`). §5.1 of the
front-end UX direction governs what each one may do: `interrupt_now` is rare and may notify;
`digest` is the normal batched message; **`silent` never appears in the conversation and
never notifies** — it exists in the ledger for a CEO who goes looking, and there is no
activity view for it yet.

**This event was undocumented here until 2026-08-30**, while this page called itself the
whole contract the UI needs. It has been declared in `stream.rs` beside the other four since
the proactive seam landed, and `app/ui/main.js` has always subscribed to it. Nothing was
broken by the omission; a second UI written from this page alone would simply never have
heard Rich speak first.

### Ordering & guarantees

- For one turn the UI receives **exactly one** `rich://turn-started`, then **zero or more**
  `rich://chunk` events, then **exactly one** terminal event (`rich://turn-completed` **or**
  `rich://turn-error`) — never both. **A proactive turn is the one exception and is not a
  stream at all**: it is written atomically and announces itself with a single
  `rich://proactive-message`, with no started, chunk or terminal event of its own.
- `seq` is a **strictly increasing** per-turn counter starting at 0. Concatenating
  `textDelta` in `seq` order reproduces the full reply that the ledger holds for that turn
  — so a UI that missed the stream can fall back to `get_messages` (or `send_message`'s
  return) and get the identical text.
- **`seq` is NOT contiguous.** As of the machinery routing commit it is ONE counter per
  turn, shared with `rich://machinery`, so that the true order of "text, then a tool call,
  then more text" is reconstructible from a single sequence. If Rich runs a tool between
  two sentences you will see `seq` 3 then `seq` 7. **Never treat a gap as a lost chunk, and
  never use `seq` as an array index.** Order by it; do not count with it.
- **`seq` is now durable, and retroactivity is the same story as machinery's.** Each
  `rich://chunk`'s position is persisted with its delta (`AssistantDelta.seq`), so the
  interleaving of text and tool calls can be rebuilt after a restart instead of only being
  visible live. A delta written before that commit has **no** recorded position: the text
  is intact, its place in the turn is unknown, and it is reported as unknown (`null`)
  rather than as position 0. A consumer rebuilding a past turn must expect an unpositioned
  run and must not assume it came first.
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
`richos-hq/docs/plans/richos-techy-mode-2026-08-26.md`; Rust source of truth:
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

---

## The additive live-work family (§13)

Added 2026-08-29 (UX brief §13, slice 3 of §24). **Strictly additive**: nothing above
changed — same names, same payload keys, same ordering, same shared `seq`. Rust source of
truth: `app/crates/richos-core/src/live.rs` (event names as constants, payloads, the
gate); relay: `app/src-tauri/src/events.rs`.

### What is live, and what is deferred

§13 lists eleven events. **Seven are emitted. Four are not, and are not emitted at all** —
not as an empty or "unknown" version, because for those the arrival of the event would
itself be the claim. §22: *"If the source signal does not exist, build the signal first or
show unknown."*

| Event | Status | Payload / why not |
|---|---|---|
| `rich://turn-status` | **LIVE** | `{…fence, status, startedAt, activeDurationMs, supersedesTurnId?, visibility, at}` |
| `rich://message-started` | **LIVE** | `{…fence, messageId, phase, seq, visibility, at}` |
| `rich://message-delta` | **LIVE** | `{…fence, messageId, seq, textDelta, visibility, at}` |
| `rich://message-completed` | **LIVE** | `{…fence, messageId, phase, text, visibility, at}` |
| `rich://activity-upserted` | **LIVE** | one timeline activity record + `at` (below) |
| `rich://thread-summary-updated` | **LIVE** | `{…fence, title, messageCount, lastActivity, status, visibility, at}` |
| `rich://worker-upserted` | **LIVE** (2026-08-29) | one timeline `worker_activity` record + `at` (below) |
| `rich://plan-updated` | **DEFERRED** | `plan` updates are retained as untyped machinery; their entries live **only** in the evictable Tier-B raw payload, so a plan projected from them would silently empty out after the retention window. |
| `rich://approval-requested` | **DEFERRED** | Nothing in this runtime asks the CEO to approve anything. The permission requests that do happen are auto-approved by the ACP client and recorded as a fact — they arrive as `activity-upserted` with `activityType: "approval"`, `state: "completed"`: a thing that happened, not a decision awaiting you. |
| `rich://approval-resolved` | **DEFERRED** | Same. |
| `rich://artifact-upserted` | **DEFERRED** | Checked, not assumed: nothing in the ledger, the journal or machinery records an output as a deliverable. Artifacts and source provenance are Phase 5. |

### The fence — on every payload, and what to do with it

Every event carries `entityId`, `threadId`, `turnId` and `bindingRevision`. §13: *"The
renderer rejects events that do not match the immutable binding."* Concretely:

- **Equality is `entityId` + `threadId`.** Those are immutable for the life of a thread.
- **`bindingRevision` is a STALENESS fence, never an equality key.** It is the revision of
  the *activation* that produced the event, so it advances on every thread activation and
  is legitimately **higher** than the revision a re-projection of the same thread reports.
  Comparing it for equality would make you reject every live event after any thread
  switch. Reject anything **older** than your current activation; accept at or above.
- A payload can never be built from a loose thread id: the fence's only constructor takes
  a binding the ledger issued, and it is private to richos-core.

### `visibility` — and why you cannot leak from this family

Every payload carries `visibility`, and on this family **it is always `"ceo"`** — because
the spine refuses to emit anything else here. This is the *calm* family:

- **Internal** items (re-prime, rotation, model reasoning, a Tier-3 silent proactive
  message) reach no family at all.
- **Technical** detail is not hidden here, it is **absent**. Exact commands, output
  previews and file paths travel on `rich://machinery`, which the calm view does not
  subscribe to. An `activity-upserted` payload has no `detail` object — the bytes were
  removed before the event was constructed, so a renderer of this family cannot show a raw
  command it was never handed.

Keep carrying the field. Do not default it.

### `phase` — **it may be `"unknown"`, and today it always is for streamed replies**

```jsonc
{ "messageId": "turn_37…:text:0", "phase": "unknown", … }
```

`phase` is one of `"commentary" | "final" | "proactive" | "recovery" | "unknown"`. **Today
every streamed message is `"unknown"`, and a renderer must not treat that as "final".**

This is measured, not assumed. `docs/verification/acp-emission-probe-2026-08-28.md` §2 is
the complete union of inbound ACP traffic across five runs: 52 `agent_message_chunk`s and
**zero** message-open, message-close or role updates. Nothing on the wire separates Rich's
thinking-out-loud from his answer. And `rich://message-started` fires the instant the first
delta is persisted — before the turn is over — so even a perfect after-the-fact rule would
be unavailable at emission time.

The tempting fallback is also simply false. *"The last run of a completed turn is the final
answer"* breaks the moment Rich verifies something after writing his conclusion, which
makes the last run a two-word `"Confirmed."` and the deliverable the run before it. **The
CEO reads the final response as the deliverable, so labelling commentary as final is a
product defect, not a cosmetic one.**

**What a renderer should do:** render an `"unknown"` message as Rich's prose in sequence
order — no "final answer" treatment, no distinct final-response styling, no
collapse-the-commentary behaviour — until a real phase signal exists. `phase` is always
present in the JSON precisely so nobody writes `phase ?? "final"`.

**One phase is real**: a proactive message (Rich speaking unprompted) is emitted as
`"proactive"`, because the ledger records it as one. `"commentary"`, `"final"` and
`"recovery"` are currently unreachable values.

### Messages: ids, runs, and what closes one

A turn's prose is **one message per contiguous run of the shared `seq` counter** — a run
ends wherever a tool call took the positions in between. A turn where Rich talks, works,
then talks again produces two messages, not one.

- `messageId` is `{turnId}:text:{runIndex}` — **the same id a reload projects from the
  ledger.** A cold reopen re-states what you already rendered; it does not duplicate it
  (§13: *"repeated event IDs are idempotent"*).
- `seq` on `message-started` is the run's first position in the shared counter, or `null`
  when the position was never recorded. **Never zero by default.**
- A message is closed by `message-completed` when the tool call starts, not at turn end —
  so *"commentary, then activity"* is live-accurate.
- `message-completed` carries the run's **full text**. A consumer that missed every delta
  is still correct.
- A turn that fails mid-stream still closes its open message: the partial text is already
  durable.

### `turn-status`: the states that exist, and the four that do not

`status` is one of `queued | working | recovering | completed | failed | stopped`.

§11 names ten states. Four are **never emitted** because nothing can produce them:
`draft` (UI state before a durable turn), `streaming_final` (needs the phase signal that
does not exist), `waiting_for_user` (§9.4 has no signal — see below), and `stopping`. Do
not write branches for them yet.

**`stopped` joined this list on 2026-08-29 (slice 6).** It is emitted only after
`Ledger::stop_turn`, which is itself reachable only from a stop request that was fsync'd to
the intake log *before* the lease was cancelled (`steering.rs`). There is no path from a
crash to this status, which is what makes §6.1's `You stopped after {duration}` — an
attribution to the CEO — safe to render. A crash or a rotation still produces
`work_duration state: "interrupted"` on a reload, and **which one it was is still not
recorded**; the only thing that state can now say for certain is that it was not the CEO.

**`stopping` is a UI-LOCAL state and is deliberately not on the wire.** The `stop_turn`
command does not answer until the request is durable, so the renderer setting `stopping`
from that return is a statement of recorded fact rather than an optimistic guess. Emitting
it as an event would need the spine, and the spine's mutex is held by the very turn being
stopped — which is the whole reason `steering.rs` exists.

**`waiting_for_user` (§9.4) STILL HAS NO SIGNAL, and slice 6 did not invent one.** §22 lists
worker waiting state under "must not be faked", `worker_status.rs` refuses to infer it, and
`TeammateIdle` cannot distinguish "paused for input" from "finished for good". It is not
merely unimplemented: implementing it would also break §6.3's timer, which pauses in that
state — `Turn::active_ms` is `ended_at - started_at` and is exact today precisely *because*
there is no pause to exclude. Whoever lands the signal must replace that measure with
accumulated active time, not extend it.

- `activeDurationMs` is the **measured** span (`ended_at - started_at`) and is explicitly
  `null` until the turn ends. It is never `now() - startedAt`, because that turns a
  five-minute task into a twelve-hour one after an overnight restart. Use `startedAt` to
  tick a live timer; use `activeDurationMs` for the frozen number.
- A proactive turn is written atomically, so it emits only `completed`, with
  `startedAt: null` and `activeDurationMs: null` — there was no delivery to time.

**Mid-turn crash — the one place this contract goes beyond §13.** When the compute lease
dies mid-turn and an automatic replay is possible, the crashed turn emits `recovering`
(not `failed`: it is about to be superseded, and a reload will not render it at all), and
the replacement turn's `queued` carries **`supersedesTurnId`**. That field is a **merge
instruction, not an announcement** — merge the two turn ids into one exchange. Without it
you would draw the CEO's single prompt twice. Do not surface it as "we reconnected"; §21's
calm recovery wording is a product decision that has not been made. When no replay is
possible, the turn emits `failed` and stays failed.

**A clean, watermark-triggered session rotation emits nothing on any family.** It happens
at a turn boundary and is invisible by construction.

### `activity-upserted`: upsert semantics

The payload **is** the timeline activity record (`kind: "activity"`, fence flattened into
it) plus `at`. Merge by `id`, last write wins — one tool call is ONE row that arrives
several times as it moves `queued → completed`. Order by `(turnId, sequence)`, never `at`.

- `state` is `queued | running | completed | stopped | failed | unknown`. **`unknown` is
  common and is not an error**: 34 of the 58 tool events measured on 2026-08-28 carried no
  `status` field at all. It is not "completed". `stopped` has no source and never appears.
- `summary` is a semantic line built from the activity type alone — *"Ran a command"*,
  *"Read 8 files"*. Never the command, never the output. Rolling up *"Read 8 files"* across
  several rows is the renderer's job.
- `sequence` is the OPENING record's position in the shared per-turn counter, so an
  activity row interleaves correctly with `message-delta`s ordered by the same counter.
  **Gaps are normal** — see the `seq` rule above.
- `completedAt` is set only when the row genuinely reached a terminal state.

**Accounting updates are not activity.** `usage_update`, `available_commands_update` and
`session_info_update` are untyped vendor kinds; as of 2026-08-29 they are **technical**, so
they do not appear on this family at all. They previously projected as CEO rows reading
*"Worked"* — one live turn produced six of them against one real command. They are still
routed, retained, and rendered in technical mode with their vendor kind.

### `worker-upserted`: the delegation you see while it is happening

Added 2026-08-29. It was deferred while there was no worker lifecycle signal anywhere;
the engine's four emitters now write `worker-events.jsonl`
(`engine/docs/worker-lifecycle-events.md`), and a `Task` tool call is joined to it **by
identity**. Before this the join ran only inside `get_timeline`, so a delegation reached
the screen after a snapshot read and showed as a nameless *"Worked"* row for the rest of
the turn. The §26 fixture measured the gap: **0 chips live, 3 after the snapshot.**

The payload **is** the `worker_activity` timeline item a reload projects (fence flattened
into it, `detail` already removed) plus `at`, so:

- **Merge by `id`, last write wins** — the same upsert as `activity-upserted`. The id is
  the machinery id, stable across re-projection, so a repeated id is idempotent and a cold
  reopen re-states the row instead of drawing a second one.
- **One delegated run is ONE row**, however many lifecycle events it produced. `created →
  started → updated → run_ended` all arrive under the same id.
- `worker.agentId` is the join key and **is not globally unique across sessions**. The
  emitter admits a lifecycle row only when its `session_id` matches the tool call's; a
  renderer never has to think about it, but never key anything on `agentId` alone either.
- **A row may arrive as `activity` first and become `worker_activity` later, under the
  same id.** The `agentId` is extractable only from the tool result, and the engine's
  `created` hook writes at about that same instant in another process — so a delegation
  whose lifecycle row lands late is drawn as an ordinary activity row and upgraded at the
  next observation. **Replace the item on a kind change; do not merge over it**, or the
  activity row's `summary` / `state` / `activityType` cling to a worker row where they mean
  something else.

`worker.state` is `pending_init | running | unknown` and **nothing else in practice**:

- `run_ended` crosses the wire as **`unknown`**, never `completed`. The reason a run ended
  is not observable anywhere in the hook set, and `unknown` is the honest superset of
  completed, interrupted and failed. Render it as *Ended · outcome not recorded*.
- `waiting`, `interrupted`, `failed` and `completed` are in the type because they are §12's
  vocabulary. **Nothing constructs them.** If one ever arrives, it is a new signal, not a
  default.
- There is no `completedAt`, no `resultRef`, no `errorRef` and **no duration**: §22 forbids
  faking elapsed active time, and the wall-clock spread between the first and last
  lifecycle rows is not active time.

**THE ONE STALENESS LIMIT, STATED.** This event is emitted when machinery arrives and once
more at the turn's end — there is no poll and no timer. A worker's state changes through
hook writes that produce no ACP traffic at all, so between two tool calls a chip can be up
to one tool call behind. It is never wrong about a worker that was never witnessed, and the
turn-end emission means the last live row is the row an immediate reload projects.

### `thread-summary-updated`

`status` is one of `idle | queued | working | failed`, computed exactly as
`thread::summaries` computes the sidebar, so a live row and a re-listed row cannot
disagree. §3.2's `waiting for CEO`, `completed while away` and `archived` are **not
emitted**: the first has no state to be in, the second needs a per-thread seen marker that
does not exist, and the third needs an archive that does not exist. Emitted at turn
transitions only, so it always carries a real `turnId`.

### Ordering and durability

- **Every event is emitted after the durable write that makes it true**, and several read
  their content back out of the ledger rather than from the value in hand. What is on the
  wire is what survived, not what was intended.
- Sequences are monotonic within one item stream; repeated ids are idempotent.
- **Missed events never block the spine.** The ledger is the source of truth; a webview
  that is not listening never stalls or fails a turn. On reconnect, take a snapshot
  (`get_messages`, and the typed timeline) and resume — do not replay from memory.

### Seeing it for real

```
cargo run -p richos-core --example live_events_roundtrip -- <engine_dir> "your message"
```

Prints both families side by side against a real ACP turn — `old>` for the calm-view events
at the top of this document, `NEW>` for the seven here, payloads verbatim.

---

## Voice mode: `rich://voice-*`

The fourth family, and the only one emitted by a different crate:
`app/crates/richos-voice/src/event.rs` declares the names and payloads;
`TauriVoiceEmitter` in `app/src-tauri/src/main.rs` relays them to the webview verbatim.

| Event name | When | Payload |
|---|---|---|
| `rich://voice-state` | The mic state changed, a new input level is available, or the input went silent / came back. | `{ state, level, bargeInArmed, noAudio, at }` |
| `rich://voice-transcript` | An utterance was recognized and **already submitted to the spine as a turn**. | `{ text, durationMs, latencyMs, at }` |
| `rich://voice-error` | Voice mode could not start, or had to stop. | `{ message, at }` |

Four things a renderer of this family has to know, all of them structural rather than
stylistic:

1. **`state` is the mic's real state, never an optimistic one.** It is one of
   `off | listening | hearing | thinking | speaking`, and the panel is driven only by this
   event — pressing the toggle does not turn the dot on, the device reporting open does.
2. **`noAudio` is a FIELD of the state event, not an error.** It is the post-open silent
   input verdict: the stream is open and healthy but has delivered nothing above -80.00 dBFS
   for 3.008 s. It is not fatal and it clears by itself the moment audio returns.
3. **A transcript is not a request to send anything.** By the time it arrives the words are
   already a turn on the same thread, through the same `Spine::submit_prompt` typed text
   uses — so voice and text are one durable conversation, and the reply arrives on the calm
   family above like any other. `durationMs` and `latencyMs` are measured, never estimated.
4. **`message` on `voice-error` is always a calm, Rich-voiced line.** Device names, exit
   codes and file paths go to stderr and never to the CEO.

There is **no live partial transcript**: `whisper-cli` has no partial-hypothesis stream, so
nothing arrives between the start of an utterance and its finished text. That is a stated
deviation from the UX direction §4.1 sketch, not an omission here.

---

## The staging desk: `rich://correction-staged`

The fifth family, added 2026-08-30 with the spoken-correction trigger. Source of truth:
`app/crates/richos-core/src/staging.rs` (the constant, the `CorrectionObserver` sink and
the payload); the relay is in `app/src-tauri/src/main.rs`.

| Event name | When | Payload |
|---|---|---|
| `rich://correction-staged` | The CEO said something that looked like a correction, and it has been written down as a QUESTION. | one `Staged`: `{ candidates: [...], withheld: [...] }` |

It is deliberately **not** a §13 event. §13 lists eleven, this is none of them, and a
subscription list is the proof of what a surface carries — inventing a twelfth would
misrepresent the brief.

Four rules for whoever renders it, all of them the ruling rather than taste:

1. **Nothing has been learned.** `ceo-decisions.md` §7: *"Nothing is ever learned
   silently."* This event announces a question, and `confirm` is the only path to a
   vocabulary write. Render it as an ask — never as a notification that something changed.
2. **Ask it in the words you were given.** Each candidate carries a built `prompt`
   (*"Add "X" to your vocabulary?"*, or *"… (you corrected this before)"* once
   `declinedBefore > 0`), so every surface asks identically and a second ask does not read
   as amnesia.
3. **A candidate carries its own `threadId` and `turnId`, captured at STAGE time.** Do not
   re-derive them when he answers: the active thread can move while a question waits, and a
   candidate re-scoped to wherever he happens to be looking has laundered itself across an
   entity boundary.
4. **`withheld` is not an error and is not a candidate.** It is the pairs the gate refused,
   with `from`, `to` and a `reason`. It exists so the refusal is inspectable; it must not be
   rendered as a question the CEO can answer.

The payload is camelCase like every other family. A candidate is
`{ key, at, threadId, turnId, utterance, ask, declinedBefore, prompt }`, where `ask` carries
the detector's own reading — `from`, `to`, `frame`, the two similarity legs, which `leg` let
it through, and an `anchor` that is **evidence and never a gate** (`null` simply means there
is nothing to quote).

**Missing this event costs a prompt, never a record.** The question is already durable on
disk before the observer is called, so a UI that is not listening loses the ask and not the
candidate.
