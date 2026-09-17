# Background work, the app side — what was measured, and what could not be walked

**Date:** 2026-09-17. **Branch:** `cc/echo-opus-lease1`. **Base:** richos main `b2496b4c`
(norm-opus-seat1's work seat, engine side).

**Spec:** the background-work spec, revision 5 at `9255e71a`. **It is not in this
repository**, and a reader with only this one will not find it: it lives in the private
richos-hq record, under that repository's own plans directory, named for the date above.
Section numbers below (§1, §2.9, §5.8a-ii, §7.1) are that document's. Everything this record
asserts about the CODE carries its own `file:line` in this repository or in `richos/engine`,
so none of it depends on having the spec to hand.

**The headline first, because it is the one thing that is NOT here.** The spec's §7 is
explicit: *"Every case is observed on the installed app. Source-only evidence does not close
any of these."* **§7.1–7.3 were not walked on screen, and this record does not claim they
were.** The reason is named below with the evidence; what was measured instead is named as
what it is.

---

## 1. Why the on-screen walk did not happen

A nightly candidate was under QA on this Mac for the whole of this session, and the brief's
standing constraint is *"never touch it, never launch a second instance while it runs
(`pgrep -fl richos-tauri` first)."* It was checked at the start of the work and again at the
end:

```
$ pgrep -fl richos-tauri      # session start
34765 ./RichOS.app/Contents/MacOS/richos-tauri
89472 … provider-supervisor.py … (its provider group)

$ pgrep -fl "RichOS.app/Contents/MacOS/richos-tauri"      # after the build
15085 ./RichOS.app/Contents/MacOS/richos-tauri

$ pgrep -fl "RichOS.app/Contents/MacOS/richos-tauri"      # at the handoff, checked again
15085 ./RichOS.app/Contents/MacOS/richos-tauri
```

Two different pids, so this was not one stale process — a candidate was replaced and QA
continued. Nothing in this branch was run against a window.

**What that leaves unwalked, precisely:**

- **§7.1** — he gives an assignment and has an answer in seconds, observed on screen with
  the measured time from his sentence to the receipt. The app-side component of that number
  is measured below; **the model's own latency, which §7.1 itself calls *"usually the largest
  single term"*, is not, and cannot be without a live provider.**
- **§7.2** — three messages while it runs, and the background lease still able to REPORT
  after the third. The engine half of that is pinned by `norm-opus-seat1`'s own tests
  against the real engine; the app half needs a running app and a provider.
- **§7.3** — Stop on the conversation, observed not to stop the work, and the per-assignment
  stop observed to stop it. Pinned in `richos-core` below, not on screen.
- **`bash richos/app/scripts/gui-boot.test.sh`** — it boots the app, so it was not run for
  the same reason.

**None of this is a claim that the walk will pass.** It is a statement that it has not been
attempted, and that the next thing this branch needs is that walk on a machine with no
candidate on it.

---

## 2. What WAS measured, and what the number does not contain

### 2.1 What the CEO's turn now pays to write an assignment down

The step §7.1 moved off his turn — `richos_work.prepare` — is **3.0–3.8 s per assignment**
(spec §7.1, three independent passes by parties who did not share a number). What replaced
it on his turn is `richos_assignments.record`, driven over the same newline-delimited
JSON-RPC frames the child speaks:

```
$ cargo run -p richos-core --example assignment_receipt_timing --release
what the turn ends with, verbatim:
  I've taken down your assignment: landing the three branches. It's running now, and
  you'll find it with your saved work. I'll tell you when there's something for you to
  look at.

richos_assignments.record, 20 runs, in-process over the real JSON-RPC frames:
  fastest 7.592375ms
  median  8.582333ms
  slowest 9.668625ms
  mean    8.439858ms
```

**The arithmetic, shown rather than asserted:** `3.0 s ÷ 8.582 ms = 349.6` and
`3.8 s ÷ 8.582 ms = 442.7`. So the turn now pays between **1/350 and 1/443** of what the
step it replaced cost — at the median, on this machine, in a release build.

**What that number does NOT contain**, in the same shape §7.1 uses for its own:

| Component | In this number? |
|---|---|
| The model's latency before it calls anything | **No.** Unmeasured, and the largest single term |
| The MCP stdio round trip to a spawned child | **No.** The server is driven in-process |
| Validating and writing the assignment, fsynced | Yes |
| Reading it back and rendering the receipt sentence | Yes |
| Spawning the work lease, `prepare`, guards, workspace creation | **No — that is the point.** All of it is now after the turn |

**So "seconds" is not established by this.** What is established is that the app-side cost
of ending a turn on a receipt is single-digit milliseconds, and that the multi-second step
is no longer on that path.

### 2.2 The turn boundary, measured against a work turn that is still running

`work_host.rs`'s `registering_returns_before_the_work_starts_and_the_work_still_runs` runs a
scripted work turn of **400 ms** and requires registration to return in **under 100 ms**,
then asserts the work really did keep running for the whole 400 ms afterwards. The positive
control is in the same test: the elapsed time at the end is asserted to be **≥ 400 ms**, so
a build where registration secretly waited would fail the first assertion and a build where
nothing ran at all would fail the second.

### 2.3 Contrast, computed under the real renderer, both themes

`ui/tests/background-work.js` measures every word on the assignment surface from WebKit's
own resolved colors, alpha-composited against the real ancestor background:

```
every word on the assignment surface clears WCAG AA in dark mode
  heading 12.06:1 at 16px; title 12.06:1 at 16px; state and detail 5.78:1 at 16px;
  stop control 5.78:1 at 16px
every word on the assignment surface clears WCAG AA in light mode
  heading 18.07:1 at 16px; title 18.07:1 at 16px; state and detail 6.38:1 at 16px;
  stop control 6.38:1 at 16px
```

Re-derived independently, by hand, from the palette rather than from the browser —
`--ink #dfe4ee` and `--ink-soft rgba(223,228,238,0.64)` over `--card #182440`; `--ink
#0c1322` and `--ink-soft rgba(12,19,34,0.68)` over `--card #fdfcf8` — giving 12.06:1 /
18.07:1 and 5.78:1 / 6.36:1. The browser's light soft reads 6.38:1 against the hand
figure's 6.36:1; the difference is float compositing versus integer rounding, and both are
far above the 4.5:1 floor.

**Floor: 4.5:1, normal text, both themes. Nothing on this surface is declared exempt** — an
assignment's title, its state and the control that stops it are all text he is expected to
read. Every size is 16px; nothing is in the 14px skippable tier.

### 2.4 The wording, read off the rendered DOM

§7.8: *"the wording is the test, not a detail of it."* The suite renders a `blocked`
assignment and a `settled` one side by side, reads the blocked row's text, and requires it
to contain *"ready for you to approve"* and none of `done`, `finished`, `complete`,
`landed`. **The scan carries a positive control in the same check**: the identical scan run
against the settled row, which does speak of finishing — so a clean result on the blocked
row is a fact about that row rather than about a scan that cannot fire.

---

## 2.5 What the UI gates said, and the gap one of them found

The full UI suite (46 suites) turned two red, both on this branch's work.

**`affordances.js`** asserts every user-visible state string is classified and that any state
the CEO can act on names a control present in the same view. Eleven new states were
unclassified. Ten were annotations. **The eleventh was a product finding:**

> *"Ready for you to approve."* is ACTIONABLE — the point of the state is that the last step
> is his. **There is no approve control on that surface**, because the desk that would hold
> his decision while he is away is §5.2/§5.7 and is not built: a request raised with no
> visible turn is still denied outright (`permissions.rs:55`). Naming a control would have
> been a claim about something that is not there.

So the sentence changed rather than the classification: *"Ready for you to approve. Ask Rich
to continue it when you are ready."* — §7.8's mandated phrase, plus the path that exists
today, with the composer as its control. The registry row says why, and says that the
sentence and the row change together when the queue lands.

**A scanner blind spot the fix exposed, worth recording because it is a class rather than an
instance.** `ui/tests/lib/state-strings.js` decides a Rust literal is CEO-facing from its own
line and **the two above it**. One of these sentences was visible to the gate only because an
unrelated `ok_or_else` happened to sit two lines up; adding a comment moved it out of the
window and the gate silently stopped seeing a shipped sentence. Both are now named
`const … : &str`, a form the scanner recognizes directly.

**`docs-claims.js`** found the same shape one level out: `rich://work-notice` was a private
constant, and that gate builds its inventory from `pub const NAME: &str = "rich://…"` — a
shipped event outside the inventory of the check that exists to catch shipped events outside
the inventory. It is `pub` now and documented in `app/STREAMING.md`.

**Two of that suite's failures are NOT this branch's, and that was measured rather than
assumed.** The suite was run at the merge base:

```
$ git checkout b2496b4c && node ui/tests/docs-claims.js
  FAIL  every per-file test count in app/README.md is the count in that file
        ["ledger_forward_compat_tests.rs: README says 20, the file has 25",
         "setup.rs: README says 38, the file has 43"]
  FAIL  every `cargo test -p <crate>` total in app/README.md is the tree's own total
        README must distinguish direct tests from ignored checks
```

Byte-for-byte the two that remain here. `docs-claims.js` is red on main today, in two files
this branch does not touch.

## 3. The tests, and the counts

```
$ cargo test -p richos-core
52 suites, all ok. The library suite: 613 passed, 0 failed, 1 ignored
                   (583 passed on the base commit, so 30 new cases.)

$ cargo check --manifest-path src-tauri/Cargo.toml
exit 0. Three warnings, all pre-existing: activation.rs OVERRIDE_ENV, activation.rs
OVERRIDE_REGULAR, nav.rs::readable. None introduced here.

$ RICHOS_PLAYWRIGHT=… node ui/tests/background-work.js
5 checks, 5 pass.

$ RICHOS_PLAYWRIGHT=… node ui/tests/run.js
46 planned, 46 ran, 0 skipped. affordances.js and docs-claims.js were red on the first
pass; affordances.js is green after §2.5's fixes (94 checks, 0 failed), and
docs-claims.js keeps only the two failures it already had at the merge base.
```

The named invariants added:

| Test | What it refuses |
|---|---|
| `registering_returns_before_the_work_starts_and_the_work_still_runs` | A registration that pays for preparation |
| `registration_is_a_write_and_never_pays_for_preparation` | The same, at the register level |
| `stop_turn_never_cancels_the_work_lease` | The inverted Stop, with a positive control on the same control |
| `the_per_assignment_stop_interrupts_it_and_never_settles_it` | A stop that reads as a finish |
| `a_queued_assignment_that_is_stopped_never_starts` | A stop that reaches the wrong assignment |
| `background_work_is_settled_against_the_work_lease_session_not_the_conversation` | §2.9's blind settle check |
| `workers_all_ending_means_ready_to_approve_and_only_the_obligation_can_settle_it` | Calling a waiting assignment finished |
| `every_assignment_gets_its_own_seat_and_no_assignment_gets_the_ceo_seat` | Two assignments on one seat |
| `a_work_leases_config_omits_the_continuity_server_and_keeps_the_work_server` | Un-prompted checkpoint access on a work lease |
| `neither_lease_can_take_the_others_preparation_path` | The host calling `brief` on a work seat |
| `a_work_seat_is_refused_rather_than_written_onto_the_ceos_row` | A seat bound onto his cursor |
| `quit_stops_the_work_lease_by_name_and_settles_nothing` | A quit that leaves a receipt saying `running` |
| `arguments_cannot_redirect_the_company_the_conversation_or_the_instruction` | A model choosing where its record lands |
| `a_closed_grant_records_nothing_and_says_so_without_implying_a_start` | §1.4's softened failure |

---

## 4. Four things found while building that the spec does not say

Each was found by reading the landed engine or by a test going red, not by reasoning, and
each is built the way the engine forces rather than the way the spec's prose reads.

1. **The seat's `turn_id` is the OBLIGATION, and that fixes the seat's cardinality.** The
   engine's reconciler reads exactly two fields off a seat row
   (`richos/engine/mega-lander/app.py:700-704`): the audience must be `worker`, and
   `turn_id` is the assignment it looks up. A seat keyed on anything else can never be
   reconciled. Because the seat is therefore spelled from the obligation, **two open
   assignments on one obligation would share one seat** — §5.8c's reproduced collision — so
   registration refuses the second, which is the same refusal the engine makes one level
   down (`app.py:314-317`).

2. **An assignment whose workers have all ended is NOT finished.** The claim about WHOSE
   action is awaited is the engine's, not a measurement, and it is quoted rather than
   inferred — `richos/engine/mega-lander/app.py:664-669`: *"An assignment whose workers have
   all stopped is NOT settled: that is exactly the state where it has run, stopped at
   integrate and is waiting for him."* The app's first build in this branch settled on the
   workers alone, which by that sentence would have reported a finish for the state the
   engine calls waiting. Settled is now read from the obligation;
   workers-ended-plus-obligation-open is `blocked`, *"ready for you to approve"*; an
   unreadable obligation is still running.

3. **The spec does not name what the conversation CALLS to register, and `prepare` cannot be
   it.** `prepare` is synchronous to the end (`app.py:362-370`) and refuses without a live
   visible turn (`:255-257`, `:41-42`), so it can be neither the fast half nor the
   after-the-turn half. Registration is therefore an app-owned MCP tool in the shape this
   app already ships one in (`richos_onboarding`), needing no engine change; `prepare` keeps
   its contract and is simply called later, by the work lease.

4. **§7.8's own sentence has no control behind it in this build**, which §2.5 records in
   full. The spec assumes §5.2's queue when it writes *"the approval request is waiting where
   §7.6 puts it"*; that queue is not built, so the surface says what it can honestly offer
   instead. This is the one place where the wording the spec mandates and the mechanism the
   spec assumes came apart, and it is named here rather than resolved by weakening the
   wording.

---

## 5. What is deliberately not built

Spec rows **5** (the window-closed process model, §2.4/§2.4a/§2.5) and **9** (recovery, §6)
are the next slice and were out of scope by the brief. `WorkHost::open_assignments` and
`WorkHost::settlement` are the two seams both will need and are built; nothing calls them
from an exit arm, and nothing reconciles a receipt after a crash.

Also not built, and named so nobody reads their absence as an oversight:

- **§5.2/§5.5/§5.7's permission queue.** A request raised with no turn open is still
  DENIED, not queued (`permissions.rs:55`). The app can reach `blocked` because the work
  lease's own turn ends and the obligation is read; it cannot yet hold his approval for
  days. §7.6 and §7.8 cannot be walked until that lands.
- **§6.4's update gate.** It still reads only the conversation lease's session
  (`updates.rs:659-663`), so background workers are invisible to it. The spec calls that
  *"not optional and not a follow-up"*; it is a follow-up here, and it is a real hole:
  an update could install over live background work.
- **The standing doctrine does not yet tell Rich to use `richos_assignments.record`.** The
  tool's own description carries the instruction, which is how the onboarding tools work,
  but `doctrine.rs` was not touched.
