# The front desk that only talks and relays, and the conversations that each keep their own — what was measured

**Date:** 2026-09-17. **Branch:** `cc/echo-opus-frontdesk1`. **Base:** richos main `f5157115`,
with main `5cee0cf4` merged mid-slice (the CEO's per-thread ECS seat, engine side).

**What governs this, in order.** The CEO's **Two Riches spec** — his words, verbatim. It lives
in the private richos-hq record under that repository's own plans directory and is named for
the date above; **it is not in this repository and a reader with only this one will not find
it.** Its two reviews (`…-sage-check.md`, `…-frank-check.md`) are beside it there. The
**background-work spec** remains the engineering annex where it does not contradict the page.
Everything asserted below about the CODE carries its own `file:line` in this repository, so
none of it depends on having the spec to hand.

**The headline first, because it is the one thing that is NOT here.** **Nothing in this slice
was walked on screen, and this record does not claim it was.** §7 of the annex is that every
acceptance case is observed on the installed app; §1 below says why that did not happen, with
the two independent reasons named and the evidence for each.

---

## 1. Why there is no on-screen walk, and both reasons are facts about this machine

**A RichOS was already running on this Mac, and `gui-boot.test.sh` launches apps.** Checked
rather than assumed, as the brief requires before running anything:

```
$ pgrep -fl richos-tauri
26884 ./RichOS.app/Contents/MacOS/richos-tauri

$ ps -o lstart=,command= -p 26884
Thu 17 Sep 21:12:58 2026     ./RichOS.app/Contents/MacOS/richos-tauri
```

That is somebody else's session — a candidate walk or the CEO's own — and the boot suite's
last run in this sequence *"launched 7 app(s)"*. Launching seven more against a live one is
not a test, it is an interruption of whatever is on his screen.

**And this worktree has no verified runtime, so the suite refuses on its own precondition
before it reaches a display at all:**

```
$ ls richos/engine/runtime/delivery.json
ls: ...: No such file or directory
```

`gui-boot.test.sh` exits 2 — a declared host gap in its own vocabulary, never a failure — until
a verified runtime is supplied. **The screen was not woken and nothing was unlocked.** A
windowless boot is a fact about the screen, not a defect, and neither is a suite that refuses.

**What that leaves unobserved, precisely:** the front desk answering a status question from
the new read on the real surface; two conversations being typed into on the real surface; and
a conversation returning to a front desk that stayed alive across a switch. Each has an
in-process measurement below, and none of those measurements is a claim that the walk will
pass.

---

## 2. The front desk's tool inventory, before and after

**Before** — read from the merge base rather than recalled
(`git show f5157115:richos/app/crates/richos-core/src/native.rs`, `fn mcp_config`, the
`richos_work` registration with no role filter):

| Lease | Servers |
|---|---|
| conversation (the front desk) | `richos_onboarding`, `richos_assignments`, `richos_continuity`, **`richos_work`** |
| work (the back end) | `richos_onboarding`, `richos_work` |

**After** (`native.rs`'s `mcp_config`, asserted as two exact sets by
`the_front_desk_holds_the_register_and_the_read_and_nothing_that_does_the_work`):

| Lease | Servers |
|---|---|
| conversation (the front desk) | `richos_onboarding`, `richos_assignments`, `richos_continuity`, **`richos_status`** |
| work (the back end) | `richos_onboarding`, `richos_work` |

**The inventories are asserted as SETS, not as absences.** A test that asserted only
`richos_work`'s absence would go on passing if a sixth server appeared beside the fifth, and
*"no orchestration tools"* is a claim about everything on the lease.

**Three enforcements, not one, and each one catches what the others cannot:**

1. **The omission** (`native.rs`'s `mcp_config`) — the tool is not there to call. The same
   argument seam 1 makes for `richos_continuity`.
2. **The desk** (`permissions.rs`) — a work tool on a non-background binding is denied, and
   the refusal names the register so the model's next move is the right one. This catches a
   lease that should not hold the server at all.
3. **The doctrine** (`engine_profile::standing_doctrine`, `doctrine/front-desk.md`) — the
   half neither review named. Both leases came up with the engine's `mega-lander/DESKTOP.md`,
   which is the BACK END's job description: seven numbered steps, every one a `richos_work`
   call. A front desk instructed to do that with the tools removed is a broken turn every
   time. The back end keeps `DESKTOP.md` (read, never written — the engine owns it); the
   front desk gets its own.

---

## 3. What was measured

### 3.1 One conversation waiting behind another conversation's reply

**The lead's ruling of 2026-09-17 is that the spine-per-thread refactor is not built unless a
measurement forces it, which makes the measurement the thing that matters.**

```
$ cargo run -p richos-core --example conversation_wait_behind_another --release
one conversation waiting behind another conversation's reply
  thread A's reply, scripted:            3s
  his message to thread B arrived:       1.004144s into it
  so what was LEFT of A's reply:         1.995856s
  MEASURED wait, send to answer on B:    2.027682958s
  the app's own share of it:             31.826958ms  (measured minus what was left of A)
  thread B answered:                     true
```

Four runs: the app's own share was **31.83 ms, 28.56 ms, 25.31 ms, 25.25 ms**. So the sentence
this supports is: **B waits for whatever is left of A's reply, plus about 25–32 ms.** It does
not wait for work, which runs on its own lease and takes no part in this lock.

**What the number does not contain, named because "seconds" is his word:** the model's own
latency on either conversation. Both replies are scripted. It measures the real mechanism
rather than a model of it — a real `Spine` behind the shell's own `Arc<Mutex<…>>`, with the
second send arriving from another thread exactly as a second Tauri command would.

**The first version of this measurement was WRONG and its own printed arithmetic caught it.**
It chose the slow desk by spawn ORDER, and the warm-up handed that desk to thread B, so the
run reported a 3.017 s "wait" — longer than thread A's entire reply, which is impossible for a
wait that begins partway into it — and an "app's own share" of 1.019 s that was really just
the moment of the send. The example now keys the slow desk to the conversation it belongs to,
and the file says so where the next reader will see it.

### 3.2 Two conversations with turns open at once, against the real engine

`tests/two_conversations_at_once_tests.rs` drives the delivered `ecs` component with no double
in the path. **Every positive has the old behavior as its negative control in the same test**,
because two threads checkpointing successfully would also pass on an engine that had stopped
fencing:

```
running 5 tests
test an_unreachable_engine_answers_no_rather_than_assuming_support ... ok
test the_delivered_engine_answers_the_per_thread_seat_capability_and_its_prefix ... ok
test a_ceo_shaped_seat_that_names_another_thread_is_refused ... ok
test a_new_session_on_the_same_thread_takes_that_threads_seat_back ... ok
test two_conversations_hold_turns_open_at_once_and_both_check_point ... ok

test result: ok. 5 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in 2.18s
```

The headline one runs the exact sequence that used to dead-letter a turn — thread B binds
INSIDE thread A's open turn, and thread A then check points — and requires the identical
sequence on the legacy single cursor to **fail**.

### 3.3 Residency

`tests/resident_front_desk_tests.rs`, 7 tests. Its double reports
`requires_thread_isolation()` **true** (`MockCognition` reports false and would never come
down the park-and-resume path at all), and its `Drop` is the only honest witness that a parked
desk was not quietly killed.

```
running 7 tests
test a_message_to_another_conversation_is_answered_rather_than_refused ... ok
test a_message_sent_while_another_conversation_is_working_is_answered_on_its_own_thread ... ok
test a_returning_front_desk_brings_its_own_context_measurement_and_not_the_other_threads ... ok
test moving_the_central_folder_un_primes_the_parked_front_desks_too ... ok
test a_threads_front_desk_is_still_there_when_he_comes_back_to_it ... ok
test no_front_desk_ever_takes_another_conversations_binding ... ok
test past_the_cap_the_least_recently_spoken_front_desk_is_the_one_retired ... ok

test result: ok. 7 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in 0.60s
```

### 3.4 The desk and the read

| Test | What it refuses |
|---|---|
| `the_front_desk_reaches_no_work_tool_and_the_back_end_still_reaches_the_four` | the refusal landing on one side only — the back end reaching the four is the control in the same test, and the register and the status read are asserted PRESENT so a front desk that could do nothing at all would not satisfy it |
| `the_front_desk_holds_the_register_and_the_read_and_nothing_that_does_the_work` | a sixth server arriving beside the fifth |
| `the_front_desk_is_told_its_own_job_and_never_the_back_ends_execution_contract` | the two Riches being told the same job |
| `another_conversations_work_is_not_in_this_conversations_answer` | one conversation's status answer depending on another's work |
| `it_takes_no_arguments_and_offers_no_verb_that_changes_anything` | a "status" tool that acts |
| `nothing_in_the_answer_is_an_identifier_he_could_be_read_aloud` | a receipt id reaching the model on the READ, having been refused on the write |
| `a_missing_or_damaged_scope_refuses_rather_than_reporting_an_empty_record` | "there is nothing running" said when it means "I could not look" |
| `his_seat_is_derived_from_the_thread_and_never_from_a_stored_mapping` | the app and the engine spelling his seat differently |

---

## 4. The gates

```
$ cargo test -p richos-core
The library suite: 649 passed, 0 failed (638 on the previous slice's base).
Every integration suite green: 1195 passed, 0 failed, 4 ignored, summed across all 54
"test result:" lines — which is 1190 direct tests plus the 5 doc-tests, counted
separately on purpose because the README's own checker counts them separately.

$ cargo check --manifest-path src-tauri/Cargo.toml
exit 0. Three warnings, all pre-existing: activation.rs OVERRIDE_ENV, activation.rs
OVERRIDE_REGULAR, nav.rs::readable. None introduced here.

$ node ui/tests/run.js     (RICHOS_PLAYWRIGHT pointed at an existing install; this
                            worktree has no node_modules and nothing was installed into it)
48 planned, 48 ran, 0 skipped, 688 checks observed against 562 declared
all 48 suites passed — 688 checks over 48 suites
```

**Two suites failed first and both were real**, which is the reason the runner exists:

- `affordances.js` found two unclassified states (`Missing status scope`, `status tool
  server: {error}`) AND, on the next run, two rows classifying strings the product no longer
  renders — the refusal `send_message` used to give when the conversation was not the active
  one. Both directions, and both are now fixed: two rows added, two removed.
- `docs-claims.js` found `app/README.md` naming neither new test file and carrying a stale
  crate total. Corrected to the tree's own numbers (1194 tests, 1190 direct, 4 ignored),
  derived with the checker's own counting rule rather than typed.

**`gui-boot.test.sh` was NOT run**, for the two reasons in §1.

---

## 5. Contrast — WCAG AA, both themes

**No new UI surface, no new palette value, and no new CEO-facing text on any rendered
surface**, so there is nothing here whose ratio this slice moved. Everything this slice adds
is read by the model (`richos_status`'s tool result, the front desk's standing instruction,
the permission desk's refusal) or by an operator (`~/Library/Logs/RichOS/startup.log`). The
one new CEO-facing sentence — *"RichOS could not start the helper it uses to look at work that
is already running."* — renders in the existing startup alert, in the same surface and styling
as the two sentences already beside it, which this slice does not touch. Nothing is declared
exempt.

The assignment surface's own ratios were measured in the previous slice and are unchanged
here (its record carries them: heading 12.06:1 / 18.07:1, every other word 5.78:1 / 6.38:1,
all at 16px, dark and light).

---

## 6. What is deliberately not built

- **Two conversation TURNS at the same instant.** The ECS cursor is no longer what serializes
  them — that landed. What does is the app's own single lock: `AppState` holds one
  `Mutex<Spine>` held for the length of a turn (`src-tauri/src/main.rs`), and `Spine` owns a
  `Ledger` by value which holds the whole in-memory projection over one file
  (`ledger.rs:727-777`), so a second `Spine` would be a second DIVERGENT projection rather
  than a second conversation. Raised as `esc-20260917T195400Z-3e9b24be` with that
  measurement; **ruled the same day not to be built unless a measurement forces it**, Sage's
  finding 8 accepted over Frank's finding 1, and §3.1 is the measurement that ruling asked
  for.
- **Rows 5 and 9** — the window-closed process model and background-work recovery — and
  back-end lease rotation, compaction and boot-time reconciliation. Out of scope by the
  brief; nothing here promises any of them.
- **A bound on RESIDENT desks is not a bound on his threads.** `MAX_RESIDENT_FRONT_DESKS` is
  8 live children; a thread is a ledger partition and there can be thousands. Past the cap the
  least recently spoken desk is retired and that one conversation is back on the path every
  conversation was on before residency. It is a number to revisit with a measurement, not a
  constant with an argument behind it.
- **The permission queue still lives in the running process.** The status read reports the
  durable half — the assignment recorded as stopped at a step of his — and says so in its own
  answer rather than implying it can see the desk.

## 7. Escalations raised

| Id | State | What it was |
|---|---|---|
| `esc-20260917T192024Z-191918ec` | proceeding | Two front desks could not take a turn at once without four ECS engine sites this brief forbade editing. Answered the same evening: the engine side was built separately and landed at `5cee0cf4`; this slice took it. |
| `esc-20260917T195400Z-3e9b24be` | proceeding | With that landed, the remaining serialization is the app's own lock and ledger. Ruled not to be built; §3.1 is the measurement it asked for and §6 states the limit. |

Both raises succeeded and wrote their own record under `docs/verification/escalations/`.
Main moving to `5cee0cf4` was acknowledged durably with `inflight-ack.sh`
(`impact: grew-scope`), and the ruling above with a second ack (`impact: none`).
