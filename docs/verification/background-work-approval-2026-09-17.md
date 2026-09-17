# The approval queue, the control behind the sentence, and the update gate — what was measured

**Date:** 2026-09-17. **Branch:** `cc/echo-opus-approve1`. **Base:** richos main `316be1c0`,
with main `aadb5b74` merged in mid-slice (`9343e860`).

**What governs this, in order.** The CEO's **Two Riches spec** — his words, verbatim —
the Two Riches page, which lives in the private richos-hq record under that repository's own
plans directory and is named for the date above — **it is not in this repository and a reader
with only this one will not find it** (the page at
`df6ad9c8`, his words at `c0a34315`), with `wiki/ceo-decisions.md` §51 as its decision record
and the **background-work spec, revision 5** as the engineering annex where it does not
contradict the page. Section numbers below (§5.2, §5.7, §6.4, §7.6, §7.8) are the annex's.
**Where the annex and the page disagree, the page wins**, and §4 names every place they did.
Reviewed by Sage (`32b7a476`) and Frank (`b95c45e6`) mid-slice; both are acknowledged in the
durable ack ledger and §4 says what each one changed. Everything asserted here about the CODE
carries its own `file:line` in this repository, so none of it depends on having the spec to
hand.

**The headline first, because it is the one thing that is NOT here.** §7's rule is that every
acceptance case is observed on the installed app: *"Source-only evidence does not close any of
these."* **§7.1–7.3, §7.6 and §7.8 were not walked on screen, and this record does not claim
they were.** §1 says why, with the refusal verbatim, and what was measured instead is named as
what it is.

---

## 1. Why the on-screen walk did not happen, and it is not the reason slice 1 had

Slice 1 could not walk because a nightly candidate was on this Mac. **This time no candidate was
running** — checked at the start and again at the end:

```
$ pgrep -fl richos-tauri        # session start
no richos-tauri running

$ gui-boot.test.sh, at the end:  "Z this run launched 7 app(s) and 0 are still running"
```

**The blocker is the agent shape, and it was probed rather than inherited.** The brief asks for
a dev build under a temp HOME. A worktree-isolated agent is refused any home redirect, at
PreToolUse, verbatim:

```
$ HOME=<scratch> /bin/echo "home redirect probe"
This agent is isolated in the worktree …, but this command sets HOME, injecting git
configuration whose effect on where git writes can't be verified. Refusing to run it …
```

That is the same control that stopped `esc-20260917T122550Z-9d69e5c2` earlier the same day, on
a different walk. **The app has no data-directory override, checked here rather than assumed:**
`app.path().app_data_dir()` (`richos/app/src-tauri/src/main.rs:1193`) derives from the home
directory, and `RICHOS_TEST_DATA_DIR` is read by exactly one place that is not it
(`src-tauri/src/update_startup.rs:59`). So a scratch home is the only isolation that keeps a dev
boot off the CEO's own application state, and booting against the real one would write into the
installed app's Application Support — which the brief forbids.

**A second limit, and it would bite even with a home to point at.** The only provider stand-in
this repository has answers `initialize` and idles (`richos/app/scripts/lib/gui-launch.sh:152-176`).
With it, no assignment can be registered and no permission request can be raised, so §7.6 and
§7.8 need a signed-in provider as well as a window.

Raised as `esc-20260917T174242Z-78acf1d3`, state **work-complete** — the code is done and
committed; the walk is what needs a different seat.

**What that leaves unwalked, precisely:** the measured time from his sentence to the receipt on
screen (§7.1 — the app-side component is measured below, the model's own latency is not and
cannot be here); three messages during a run (§7.2); Stop on the conversation (§7.3); a request
found waiting after an absence (§7.6); and the approve press on the real surface (§7.8). **None
of this is a claim that the walk will pass.** It is a statement that it has not been attempted.

---

## 2. What WAS measured

### 2.1 The turn still ends on a receipt, and the number moved by nothing

```
$ cargo run -p richos-core --example assignment_receipt_timing --release
richos_assignments.record, 20 runs, in-process over the real JSON-RPC frames:
  fastest 7.503875ms
  median  8.54875ms
  slowest 16.08ms
  mean    8.831175ms
```

**The arithmetic, shown rather than asserted:** `3.0 s ÷ 8.549 ms = 350.9` and
`3.8 s ÷ 8.549 ms = 444.5`. So the CEO's turn pays between **1/351 and 1/445** of the
`richos_work.prepare` step §7.1 moved off it — median, this machine, release build. Slice 1
measured 8.582 ms; this slice's desk work is not on that path and the number says so.

**What it does not contain:** the model's own latency before it calls anything, which §7.1 itself
calls *"usually the largest single term"*. Unmeasured, here as there.

### 2.2 The desk, end to end, against the real desk

Every one of these drives `ScopedPermissions` and `PermissionDesk` themselves — no second
implementation of the path under test — and every negative carries a positive control in the
same test:

| Test | What it refuses |
|---|---|
| `a_background_request_with_no_visible_turn_waits_instead_of_being_denied` | §5.1's refusal surviving |
| `a_second_request_queues_behind_the_first_and_blocks_only_its_own_worker` | *"Another action is already waiting"* over a queue (§5.5, §5.6) |
| `the_deadline_ends_the_call_and_never_the_request` | §5.7's whole sentence, including the standing decision being spent once |
| `a_standing_decision_never_covers_a_different_action` | an approval for one input covering another |
| `a_decline_after_the_deadline_reaches_the_assignment_and_refuses_the_step` | a decline that reaches nothing |
| `forgetting_one_assignment_leaves_every_other_assignments_request_alone` | §5.4's unit of revocation |
| `forgetting_an_assignment_drops_the_standing_decision_too` | an approval outliving its assignment |
| `the_step_that_changes_his_repository_is_the_one_that_has_to_ask` | `integrate` reaching the allow-list, asserted across all five work tools rather than by naming four |
| `a_conversation_request_still_dies_with_its_turn` | §5.7's survival leaking onto the conversation |
| `an_approval_given_after_the_call_ended_puts_the_assignment_back_on_the_lease` | an answer that decides nothing |
| `a_declined_step_stops_the_assignment_and_never_reads_as_finished` | §0 row 7 inverted |
| `stopping_an_assignment_takes_its_question_off_his_screen` | a question he can answer into nothing |
| `a_blocked_receipt_names_the_step_it_is_waiting_on_in_his_words` | a wire tool name on his screen |
| `a_running_assignment_blocks_an_update_with_the_conversation_idle` | §6.4's blind update gate |
| `one_back_end_per_conversation_thread_and_one_only` | the CEO's shape drifting back to one back end per job, or to one for the app |
| `two_conversations_run_at_the_same_time_and_neither_queues_behind_the_other` | his *"multiple things in parallel"* being one thing at a time |
| `one_desk_gives_each_conversation_its_own_queue` | one conversation's answer emptying another's queue (Sage 12) |
| `today_both_audiences_reach_the_four_and_neither_takes_the_fifth_without_him` | the front desk's tool list moving on one side only |
| `a_quiet_back_end_never_hides_a_busy_one_on_another_conversation` | an update installing over the second thread's work |
| `a background result SURVIVES his next sentence` (UI) | Frank's defect (a) |

### 2.3 Contrast, computed under the real renderer, both themes

`ui/tests/background-work.js` measures every word on the assignment surface from WebKit's own
resolved colors, alpha-composited against the real ancestor background:

```
every word on the assignment surface clears WCAG AA in dark mode
  heading 12.06:1; title 12.06:1; state and detail 5.78:1; stop control 5.78:1;
  the question 5.78:1; approve control 5.78:1; decline control 5.78:1   — all at 16px
every word on the assignment surface clears WCAG AA in light mode
  heading 18.07:1; title 18.07:1; state and detail 6.38:1; stop control 6.38:1;
  the question 6.38:1; approve control 6.38:1; decline control 6.38:1   — all at 16px
```

`ui/tests/local-notice.js`, for the status line Ray's finding #8 moved out of the message lane:

```
the notice clears WCAG AA in dark mode:   body 12.06:1 at 16px; left rule 6.54:1 at 2px
the notice clears WCAG AA in light mode:  body 18.07:1 at 16px; left rule 6.58:1 at 2px
```

**Floor: 4.5:1 for normal text, 3:1 for the non-text indicator, both themes. Nothing on either
surface is declared exempt** — the line naming the step an assignment stopped at, and the line
telling him his words are back in the box, are both text he is expected to read. (The ratios
above are a measurement of pixels and settle nothing about whose decision a step is; that is
`permissions.rs`'s allow-list and is §2.2's business, not this section's.) Every size is 16px;
nothing is in the 14px skippable tier.

### 2.4 The wording, read off the rendered DOM

§7.8: *"the wording is the test, not a detail of it."* The blocked row is required to contain
*"ready for you to approve"* and none of `done`, `finished`, `complete`, `landed` — and the same
scan is re-run against the `settled` row, which does speak of finishing, so a clean result is a
fact about the blocked row rather than about a scan that cannot fire.

**And the sentence now names a control that is there.** `ui/tests/affordances.js`'s new
`assignment-waiting` fixture drives the real shell — the chip, the pane it opens, the row — and
asserts the sentence AND the approve control on screen. The registry row says which control, so
the two cannot drift.

---

## 3. The gates

```
$ cargo test -p richos-core
The library suite: 638 passed, 0 failed, 1 ignored. Every integration suite green.
(613 on slice 1's base; 1171 `#[test]` across the crate, which is what `app/README.md`'s
Build & test block now says.)

$ cargo check --manifest-path src-tauri/Cargo.toml
exit 0. Three warnings, all pre-existing: activation.rs OVERRIDE_ENV, activation.rs
OVERRIDE_REGULAR, nav.rs::readable. None introduced here.

$ node ui/tests/run.js
48 planned, 48 ran, 0 skipped — all 48 suites passed, 687 checks.

$ bash scripts/gui-boot.test.sh          (RICHOS_RUNTIME_DIR pointed at a verified extracted
                                          runtime; `verify-runtime.py` returned verified:true)
=== gui-boot.test.sh: all 33 passed ===
including "Z this run launched 7 app(s) and 0 are still running"
```

**Two things about that last line, and both are limits rather than results.**

**It was run at `ee9ee288`, not at the tip.** The commits after it change the work host, the
permission desk, the update gate's reading and the timeline renderer; none of them is on the
boot path, and *"none of them is on the boot path"* is an argument rather than a measurement.

**The re-run at the tip was REFUSED by the suite's own precondition, exit 2, and I left it
refused.** D4: `available_monitors()` is `CGGetActiveDisplayList`, and a Mac whose screens have
gone to sleep reports every display online and none active, so the suite refuses rather than
asserting something about the machine's power state. Its own advice is to run it under
`caffeinate -u`, which **turns the CEO's screen on** — a visible side effect on his desk — so it
was not run. Exit 2 is a declared host gap in this suite's vocabulary and never a failure; what
it means here is that the boot has not been re-witnessed since `ee9ee288`.

**One precondition had to be supplied and it is named rather than hidden:** this worktree has no
built `engine/runtime/delivery.json`, so `gui-boot.test.sh` exits 2 for a second, different
reason until a verified runtime is supplied. It was pointed at an extracted one outside this
repository, which the harness's own `verify-runtime.py` checked before use.

---

## 4. Where the annex lost to the CEO's page, and what the two reviews changed

**Three places, and the first is the whole shape.**

**(i) One back-end Rich PER CONVERSATION THREAD.** His words: *"each conversation thread always
holds one front desk Rich and one back-end Rich. Regardless of the number of assignments within
a given conversation thread."* The annex's §2.1 gives the APP a second lease and its §5.3/§5.4
language is per-assignment; §51 made it one standing back end; the page makes it one per
thread. The host now holds a `Backend` per thread — lease, queue, runner, live assignment,
cancel handle and settle session — opened on that thread's first assignment. Two tests:
the factory is asked for a back end once per thread across two registrations and a resume, and
two conversations are observed LIVE AT THE SAME MOMENT during a 400 ms scripted turn, which a
shared back end cannot produce at all.

**(ii) What stays per assignment is what the page keeps per assignment** — *"a bookkeeping unit
inside the back end (its own record, seat, stop, approval line)"*: one seat, one standing
grant, one hold at the desk, created and released together.

**(iii) The front desk's tool list — written, then taken back out before landing.** The page's
sense-check note 3 is *"The front desk gets no orchestration tools."* The refusal is four lines
and it is NOT landed, for two reasons:

- **Sage's findings 5 and 6:** `richos_work` is registered on both leases
  (`native.rs:951-952`), and taking it off the front desk leaves it **no read tool at all** —
  the status surfaces are Tauri commands the model cannot call. The refusal needs a read-only,
  app-owned status tool beside it; that tool is not built.
- **The one neither review names:** the standing doctrine still routes work through those tools
  from the conversation (`doctrine.rs`, untouched by slice 1 and by this one). Refusing them
  today would make the app unable to do work at all, silently.

The lines sit in `permissions.rs` as a comment naming both preconditions, and
`today_both_audiences_reach_the_four_and_neither_takes_the_fifth_without_him` pins what each
audience can reach now, so the day it lands it lands against a measurement.

**What the reviews changed beyond that.** Sage's finding 1 (one host per app, reusing a lease
across bindings) is fixed by (i) — and its second half was checked rather than taken: the shell
builds a FRESH engine profile per `spawn_work` and scopes it to the binding it was handed
(`src-tauri/src/main.rs:283-313`, `engine_profile.rs:168-171`), so a per-thread back end carries
its own partition and the engine's check has nothing to refuse. Sage's finding 12 is the
thread-scoped queue reader. Frank's defect (a) — a delivered background result destroyed by his
next sentence — is §5 item 6 below. Frank's defect (b) is §6.4's update gate, already built.
Sage's finding 3 (the land lock is per (entity, thread), not machine-wide) is engine-side: **no
part of it is built here and no part of it is assumed here.**

---

## 5. Six things found while building that the spec does not say

Each was found by reading the landed code or by a gate going red, not by reasoning.

1. **The brief's premise — and slice 1's own record — say a background request is "still
   DENIED (`permissions.rs:55`)". That was not true of the work lease.** Line 55 denies only
   when the grant file is absent or closed, and `bind_work_assignment` writes
   `actions_allowed: true` with the assignment's binding (`native.rs`), so a background request
   reached the desk and **opened the conversation's permission modal**. What was actually broken
   is two different things: the desk refused a SECOND request outright, and the entry was
   deleted when the provider call returned, so the request could not outlive its own 300 s call.
   The fix is the queue and §5.7's survival — not the removal of a refusal that was not firing.

2. **The approve control was unreachable even once it existed.** The work chip is the only way
   to open the pane the assignments live in, and every part of it was fed by
   `get_worker_status`, which returns an empty view whenever no turn is open on the thread — the
   entire window background work lives in. An assignment waiting for his approval had no chip,
   therefore no pane, therefore no control, however plainly the notice said it was ready for
   him. The chip now counts what is waiting and what is running.

3. **§6.4's sentence — "the update gate must read both leases' workers" — is not sufficient on
   its own.** An assignment stopped at a decision of his has NO workers, and one between its
   registration and its first worker has none either. Both are work an update must not install
   over. So the gate reads the assignment register as well, and that is the half that catches
   §7.8's own state.

4. **The queue lives in the running process.** §7.6's *"however long that is"* holds for as long
   as the app runs. Across a crash and relaunch the receipt still says `blocked` and the question
   itself is gone — recovery is §6 and is the next slice. The surface says so rather than
   offering a control that would answer nothing: a blocked assignment with no question on the
   desk keeps slice 1's sentence and the composer.

5. **A decline has no notice kind of its own.** `NoticeKind` has no `declined`, so the decline
   rides on `Interrupted` with its own sentence (`assignment::says::declined`), which is
   deliberately not the stop sentence: *"it was stopped"* describes a stop he pressed, and this
   is an answer he gave.

---

6. **A delivered background result was destroyed by his next sentence** (Frank's defect (a),
   reproduced in the shipped path rather than reasoned). `take_work_notices` hands a result
   over ONCE and marks it delivered; the shell rendered it into the in-memory model; his next
   sentence reloaded the thread, and `applySnapshot` cleared `model.items`. Off the screen and
   already marked delivered is gone for good. Local notices now survive a snapshot, re-inserted
   in time order rather than appended — appending would put a ten-turn-old microphone failure
   under the newest answer and say it just happened. **They are still not evidence:** no ledger
   record, no duration row, and gone with the process. The durable work-journal record Frank
   prefers is a ledger record type and `spine.rs` is outside this brief's footprint.

## 6. What is deliberately not built

- **§6.5's three-option update offer** — *"install after this assignment, stop the assignment,
  or approve it now and then install"*. The gate distinguishes the two states and says in words
  which one is holding the update; the OFFER is a surface change in `ui/updates.js`, outside
  this brief's footprint.
- **Rows 5 and 9** — the window-closed process model and recovery (§2.4/§2.4a/§2.5, §6). Out of
  scope by the brief, and item 4 above is the honest consequence for §7.6.
- **The engine side of §5.8** — the seat and the two threaded appends. Landed separately
  (`b2496b4c`), untouched here.
- **The front desk's orchestration-tool refusal** (the page's note 3) and the read-only,
  app-owned status tool it needs — §4 (iii), with both preconditions named.
- **One flock per repository for lands** (Sage's finding 3). Engine-side; nothing here builds
  or assumes it.
- **The durable work-journal record** for a delivered result (Frank's preferred fix for defect
  (a)); what is built keeps it on screen for the life of the process.
- **The N-threads spine change.** Both reviewers confirm the app runs one conversation at a
  time today (`main.rs:664-673`, one `Mutex<Spine>`, one front-desk ECS seat). The queue is
  thread-scoped and the back end is keyed per thread so that change has somewhere to land;
  nothing here attempts it.
