# The job lands. The connection now names the turn it sent, and the host asks for the land.

**2026-09-18, echo-opus-turnfix1.** The two slices before this one made the worker able to act
(`echo-opus-worktree1`) and the settlement card stop killing the run (`echo-opus-settle1`). With
both in, the worker edited, committed and handed back, and a reviewer passed the commit byte for
byte — **and the job still did not land**, because the host's continuation turn was answered by a
turn the platform had injected.

It lands now. On one real-provider run of `examples/work_lease_roundtrip`, on a fresh temp state
root and a synthetic fixture repository:

```
t+   0.015s  Registered :: Written down. Preparation has not started.
t+   0.218s  Preparing  :: Opening the work connection.
t+   2.052s  Running    :: The back end has started on it.
t+  49.749s  Running    :: A helper is doing the work.
t+ 192.148s  Settled    :: It landed on main in qa-fixture. An independent review passed it first.

FIXTURE BEFORE  head=896df5f9588d58b0eeee71eb673e829f7d7ae621  notes.txt = "hello\n"
FIXTURE AFTER   head=200376ac07c064877dcb746d9e48122a038091a5  notes.txt = "hello\nAdded a line as requested.\n"
200376a Append a note line to notes.txt
896df5f the fixture's starting state
2832ffa Initialize repository
```

And what the CEO would have read, the only notice raised on the whole run:

> Add a line to the notes file and land it is finished. It landed on main in qa-fixture. An
> independent review passed it first. Everything it produced is with your saved work.

Every file quoted here is in `turn-correlation-2026-09-18-logs/`.

Environment: macOS 24.6.0 arm64, `claude` 2.1.277 (`/Users/alex/.local/bin/claude` →
`~/.local/share/claude/versions/2.1.277`), engine tree `richos/engine` at this branch, delivered
runtime `/Users/alex/ab/richos-rechecks/deep-20260916/runtime-archive/engine/runtime`.

---

## 1. What was wrong, and it was not the back end

`NativeClient::prompt` parked a sender and returned on the **next** `result` frame to arrive. The
premise was written down in the code — *"there is at most one turn in flight, and the next
`result` ends it"* — and it is false on this wire. The measurement that disproved it is the
previous slice's: the host's second continuation returned **1.847 s** after the reviewer's
`SubagentStop` with **zero** tool calls, and three of that session's six `UserPromptSubmit` rows
were turns the **platform** injected (`worker-turn-grant-2026-09-18.md` §5).

## 2. The correlation the protocol offers — read off the binary, not assumed

Both fields below are quoted from the schema embedded in the binary this product spawns
(`strings ~/.local/share/claude/versions/2.1.277`). Neither was being read.

**`command_lifecycle`** — `{type, command_uuid, state, uuid, session_id}`:

> The queued command's uuid — the client-supplied uuid on the inbound message. Commands enqueued
> without a uuid (e.g. the one-shot `-p "prompt"` string path) emit no lifecycle events.

> 'queued' when the inbound message enters the command queue; 'started' when it drains into a
> turn; then exactly one terminal state … Ordering relative to the result frame is per-path: a
> command that starts a fresh turn emits 'completed' AFTER that turn's result frame …; a command
> folded into an already-in-flight turn emits 'completed' BEFORE that turn's result frame.

Three things make it usable here and each was checked rather than hoped for:

1. **The client supplies the id.** The inbound SDK user message schema carries
   `uuid: ee().optional()`, so `prompt` now mints one per turn and writes it with the message.
   Without it the child emits no lifecycle events at all.
2. **The forwarder is installed for a stdio session.** In the binary, `cb(e, r)` installs the
   `command_lifecycle` forwarder for every transport that is not the remote one; our lease is
   plain stdio.
3. **The session announces it.** `capabilities: ["interrupt_receipt_v1",
   "interrupt_cancel_queued_v1", "msg_lifecycle_v1"]` on the `system/init` frame — present in the
   2026-08-31 captures, `native-claude-stream-json-2026-08-31/raw/run2-multiturn-one-process.jsonl`
   line 1, and that capture is from 2.1.251, so this is not new.

**`queued_turn_count`** on the `result` frame:

> User-initiated sends still waiting in the command queue when this result was produced. Greater
> than 0 means at least one more user turn (and result) follows without further input, barring
> cancellation; 0 means none is pending … System-generated queue entries are not counted.

**The exclusion is what makes it a signal rather than noise, and it was checked in the binary's
own code.** The counting predicate is
`jqn(e) = P4(e) && e.mode === "prompt" && e.shouldQuery !== false && !e.isMeta && QTn(e.origin)`.
The subagent hand-back enqueues with `isMeta: true` (`enqueueReportingAdmission({mode:"prompt",
… priority:"next", … isMeta:!0, …})`) and so does the worker/task notification
(`{mode:"prompt", … passive:!0, isMeta:!0, …}`). So the platform's own injections are **not**
counted, and this client's send is the only user-initiated one there can be — there is at most
one parked prompt.

## 3. The invariant, and where it degrades

**A parked prompt is answered by the `result` of the turn that consumed the message it sent,
never by the next `result` to arrive.** A result reaches it only when the child has said our
message drained into a turn, or has said nothing of ours is waiting behind it
(`queued_turn_count == 0`). A result reported with a user send still queued belongs to a turn that
was already in flight: it is retained on the between-turn lane (§1.4 G5 — traffic is never
dropped) and the prompt keeps waiting. Frames arriving while our message is known-queued are
retained the same way rather than streamed into this turn (§1.4 G4 — no false attribution). A
terminal state saying the child threw our command away ends the wait positively, so the
correlation can never become a new way to hang.

| what the child says | what happens |
|---|---|
| `command_lifecycle` for our uuid: `started` / `completed` | the turn in flight is ours; the next `result` is its answer |
| `command_lifecycle` for our uuid: `queued`, and a `result` with no count | that result is another turn's — retained, keep waiting |
| a `result` with `queued_turn_count >= 1` | another turn's — retained, keep waiting |
| a `result` with `queued_turn_count == 0` | ours |
| a terminal lifecycle state the child uses for a command it threw away | the prompt returns with that reason rather than waiting for a turn that will never run |
| **neither field, ever** | **the next `result` is delivered — exactly as before 2026-09-18** |

The last row is the floor and it has its own test. A child that names no turns leaves
`queued_turn_count` alone deciding, which is weaker (a count, not an identity) and still strictly
better than "the next result wins".

**`ReaderState::turns_named_by_the_child`** says which of those is actually carrying the load: one
stderr line per lease, at the first lifecycle frame naming our own command. It was added after the
run below and so is **not yet observed on a real wire** — a fallback quietly doing all the work
looks exactly like the mechanism working, which is the reason it exists.

## 4. The host's half: the continuation names the step it is actually at

The one sentence that served every wait round told the back end, at the end of a REVIEW, to
prepare a reviewer — for work a reviewer had just passed. `REVIEW_PASSED_CONTINUATION` names the
land (`integrate`) and then closing the assignment, and the choice between the two is a **reading
of the receipts**, never a count of how many times the loop has been round: a reviewer's own
receipt says `passed`, no land is recorded, and a worker's run ended with nothing landed. All
three, because any two of them are also true of a state that needs a different next step.
`work_status::trail` gains `reviews_passed` for it, counted from the reviewer's receipt exactly as
`changes_requested` already is.

And a continuation that delivered **no item at all** is asked once more
(`CONTINUATION_REASK_LIMIT = 1`). Not inferred from elapsed time and not from silence on a timer:
the child sent a terminal `result` with no turn traffic in front of it, which no turn that
prepares, reviews or lands anything can do. One re-ask covers a single stolen result; a second
would be the host guessing, and every ask is a real model turn on a real subscription.

**What that second check does NOT reach, stated rather than left to be discovered:** it catches a
result with no traffic in front of it, which is the measured shape. A theft whose injected turn
also streamed its own frames after our send is caught by §3 and not by this.

## 5. The run, turn by turn — every model turn spent

`journal-index.txt` is the work lease's own callback journal, one line per row. The seven
`UserPromptSubmit` rows are every turn this lease ran:

| row | whose turn | what it did |
|---|---|---|
| 2 | **the host** (the brief) | `ToolSearch`, `repositories`, `inspect`, two `Bash`, `Read`, `prepare`, `Agent` → the worker; `Stop` at row 20 |
| 21–45 | the worker `a8a9d3bce1d1292b8` | its own `Bash`/`Read`/`Edit`/`Bash` calls **after** that turn ended, then `SubagentHandback` |
| 46 | the platform | the worker's hand-back, injected |
| 51 | the platform | a `task-notification`, injected |
| 52 | **the host** (continuation 1) | `inspect`, `prepare`, `Agent` → the reviewer; `Stop` at row 60 |
| 61–74 | the reviewer `aa9e87685c47a1b6f` | six `Bash` calls, then `SubagentHandback` |
| 75 | the platform | the reviewer's hand-back, injected |
| 77–78 | — | **`mcp__richos_work__integrate` — THE LAND** |
| 79 | **the host** (continuation 2) | the `REVIEW_PASSED` sentence, on the real wire |
| 80 | the platform | a second `task-notification`, injected |
| 81–82 | — | `mcp__richos_work__complete` — the assignment closed |

**The host sent three turns and the lease ran seven**; the other four were the platform's. That
ratio is the whole finding of this slice: a client that assumes the next `result` is its own is
wrong more often than it is right on a lease that dispatches helpers.

The receipts (`work-receipts.json`) say the same thing from the other side: the worker's receipt is
`integrated` with `verified: true`, `branch: main`, `commit: 200376ac…` and
`reviewer_id: d7829fb7…`; the reviewer's own receipt carries the checks it ran
(`git show --stat 200376ac…`, `git diff 200376ac…~1 200376ac…`, a trailing-newline check with
`xxd`, `git status --short`) — and `reviewer_id` on the land names that receipt, so the review is
read from the reviewer rather than assumed from the land.

**What this run does not isolate.** It proves the land end to end. It does not, on its own, say
which of the two signals in §3 did the work, because the probe does not capture the child's raw
frames and the lease persists no transcript. The mechanism is proven separately, against the
recorded frame sequence, in §6.

## 6. Both ways, on the replayed frames

Four tests in `native.rs` drive a scripted child. The first replays the defect's own sequence: the
host's continuation is sent while an injected turn is in flight, the injected turn's `result`
arrives first carrying `queued_turn_count: 1`, then our own turn starts and ends.

Probed by mutation, `result_is_another_turns` forced to `false` — the pre-change behavior:

```
a_turn_the_platform_injected_never_answers_the_prompt_this_client_sent  FAILED
  assertion `left == right` failed: the prompt was answered by a turn it did not send
    left: ""            <- the defect's signature: the prompt returns having streamed nothing
   right: "landing it"

a_result_with_a_user_send_still_queued_is_not_this_prompts_answer       FAILED
    left: ""   right: "mine"
```

`a_child_that_names_no_turn_at_all_still_answers_the_next_result` passes **both** ways, on
purpose: it is the floor, and a change that broke it would be a new way to hang.

The host's half, `after_a_passing_review_the_continuation_asks_for_the_land_and_a_silent_turn_is_asked_once_more`,
drives three cases through the whole host on the engine's own receipt shape and the app's own
callback journal. Probed both ways:

- forcing the receipt read to miss → fails on the two sentences in full (the worker one where the
  land one belongs);
- `CONTINUATION_REASK_LIMIT = 0` → fails at 2 turns against 3.

## 7. Suites

- `cargo test -q -p richos-core` — **1358 passed, 0 failed, 4 ignored**, summed across all test
  binaries (the summed `ignored` is 4; the lib binary's own line reads 1). Five of them are this slice's: four in `native.rs`, one in `work_host.rs`.
- `cargo test -q --bin richos-tauri` — 301 passed, 0 failed, 1 ignored.
- `richos/engine/mega-lander/tests/app.test.sh` — 32 run, 0 failed; 16/16 mutants still
  load-bearing.
- `richos/engine/scripts/test-app-engine-hook.py` — 6 run, 0 failed.

## 8. Hygiene

No RichOS app instance was launched: this is a headless crate probe, not a walk — `pgrep -fl
richos-tauri` returns nothing, before and after. No `say`, no `afplay`, no audio of any kind. CI is
paused and nothing here is CI.

`$TMPDIR`'s `richos-*` entries: **0 before**, the probe fixture retained on purpose
(`RICHOS_PROBE_KEEP_FIXTURE=1`) so this record could be written from it, then deleted by hand —
**0 after**, verified with `ls -d "$TMPDIR"richos-*`, and `pgrep -fl work_lease_roundtrip` returns
nothing.

**Provider spend: ONE run, which was the budget.** Three host-sent turns inside it (rows 2, 52,
79), plus the four the platform injected and the two helper runs the back end dispatched. No other
real-provider turn was spent on this slice; every claim in §2 comes from reading the shipped
binary, which costs nothing.
