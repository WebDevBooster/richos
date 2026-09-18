# The front desk's first reply, and when "running" becomes true — 2026-09-18

Echo (`echo-opus-receipt1`), branch `cc/echo-opus-receipt1`, from `ee59193a`.

Fixes Ray's candidate-.7 audit rows 2, 6 and 8, and implements the CEO's ruling **§55**, which
landed mid-task and replaced the wording half of the brief.

---

## 1. What was actually wrong, re-derived rather than taken from the brief

The brief asserted the defect's location without a source, so it was re-derived first.

| Claim | Verified at | Verdict |
|---|---|---|
| `assignment.rs:279-283` builds the sentence | `fn sentence` at **279**, the literal `It's running now` at **281** | confirmed |
| `assignment_tools.rs:170` hands it to the model verbatim as `say` | `Ok(json!({"recorded": true, "say": receipt.sentence()}))` at **170** | confirmed |
| neither a model paraphrase nor a code slip | a hard-coded `format!` string returned in a field named `say`; its own doc comment cited the annex requirement *"says it is running"* | confirmed — **deliberate** |

**The app's own doctrine already forbade the sentence the app composed.** This is the finding
that makes it a defect rather than a preference:

- `doctrine/front-desk.md:46-49` — *"Writing an assignment down is not starting it, and starting
  is not finishing. The receipt you are handed says what it establishes: the work is written
  down. Say that, and nothing more than that. Never report work as done, landed, prepared or
  underway on the strength of having recorded it."*
- `doctrine/front-desk.md:14` — *"you write it down with `richos_assignments.record` and end your
  turn with the sentence it hands back."*

The model was instructed to end its turn with a sentence the same file forbids it to say. The
contradiction was between two things the app wrote, not in the model's behavior.

## 2. CEO §55 — read in full, and it supersedes the brief's wording

`richos-hq/wiki/ceo-decisions.md:2822-2846`. His words:

> 1) User gives a task 2) Rich immediately checks whether or not that requires some clarification
> questions and if not: 3) Rich **immediately** replies with: "On it!" and only after that does
> all that work that took 35 seconds in this example. And if clarification questions need to be
> asked, then Rich asks those questions first. And once all answers are in, Rich replies with a
> simple "Got it. On it!" That's it. Instant responses and ultra-short replies.

and, told a few seconds is the floor:

> Yes, a few seconds is fine. But 35 seconds of waiting for the first response is not. Go.

**Two defects died here and they were different defects.** Row 2 is that *"running"* was FALSE.
§55 is that the whole paragraph was the wrong SHAPE at the wrong TIME. Fixing only row 2 would
have left him waiting 35 s for a more accurate paragraph.

### Annex change (job 5) — for Rich to carry to `richos-hq`

`background-work-spec-2026-09-17.md` §1.2, line 270, currently requires *"says it is running"*.

Under §55 the replacement is **not** the brief's *"says it is written down and will start on its
own"* — that wording was written before the ruling and is also superseded. The annex line should
read:

> says **"On it!"** and nothing else — no restating the task, no claim about state, no location.
> The form after a clarifying question is **"Got it. On it!"**. (CEO §55, 2026-09-18, which
> supersedes this line.)

## 3. What the receipt says now

```
On it!
```

and, when he answered a clarifying question first:

```
Got it. On it!
```

Both are fixed strings owned by the app (`assignment.rs`, `Receipt::sentence` /
`sentence_after_questions`). Which one is used is selected by `after_questions`, a fact the model
**reports**; it composes nothing. A model free to compose this would eventually compose the
35-second paragraph again.

## 4. "Running" now means the back end took the turn

`work_host.rs`'s `run_one` wrote `AssignmentState::Running` **before** it called `lease.prompt` —
before the back end had been asked for anything. The detail string on that very line read
*"Preparing the workspace and starting the work"*, which is the state word the record should have
carried.

`Running` is now written from exactly one place: inside the prompt callback, on the child's first
stream item. That item is parsed off the child's own stream in reply to our prompt, so it is a
**positive** signal — the standard the continuity design's §5.2 holds the crash watchdog to.
Nothing is inferred from elapsed time, from the lease being open, or from silence.

### The brief's prescribed gate would have inverted the defect

The brief named `Cognition::work_readiness_after_turn == Yes` as the moment. Re-derived:

- its only call site is `work_host.rs:656`, reached **after `lease.prompt` returns** — i.e. after
  the entire work turn, "the long one". Gating the word there would leave every assignment
  reading `preparing` for the whole run and `running` only once the run had **ended**.
- its signature is `Result<(), CognitionError>`, **not** an enum with a `Yes` variant. `Ok(())`
  means all three `InitFact`s are `Yes` (`native.rs:2564`, predicate at `native.rs:315-317`).
- `honest()` exists **only** at `work_host.rs:1574`. There is none in `native.rs`, as the brief
  stated.

The readiness reading is untouched and stays where it is. The two ask different questions: whether
the lease was ever **equipped**, versus whether the turn was **taken**.

### A bug I introduced and caught, worth recording

Testing the stream item **alone** reported three of the module's own scenarios — a job that ran
and did not land, a land the reviewer refused, a land with the assignment still open — as jobs
that *"did not start"*. That is row 2 inverted and just as false.

There are **two** positive signals and the honest test needs both: `outcome.is_ok()` is also
proof, because `prompt` answers `Ok` only on the child's terminal `result` frame. Absence of a
signal is still never read as a signal.

### A pre-turn failure says it did not start

`says::did_not_start` — *"{title} did not start. {why} Nothing was changed, and nothing is
running."* Every failure on Ray's walk was pre-turn and every one was reported as *"stopped before
it finished"*, which claims there was something to stop and invites the wrong question ("how far
did it get?") about a job that got nowhere.

`a_work_lease_that_refuses_to_open_is_reported_as_a_failure_not_as_started` had **already named
this invariant in its own name** while asserting the opposite string.

### The status read

`registered`, `preparing` and `running` all shared the `running` key in
`richos_status.background_work`, so a job the back end had never touched reached the front desk
under the heading "running" — and the front desk said so. `starting` is now its own section. The
rows always carried the honest state word; a bucket label outranks a field the model has to read
twice. Nothing is omitted or reordered: the two sections together are still exactly `is_open`.

## 5. Row 8 — the failure card and the double period

**The seam label.** The card read *"cognition protocol: The desktop engine plugin did not load"*.
The sentence after the label was always the right sentence; the prefix is `thiserror`'s `Display`
on `CognitionError` (`cognition.rs:19-24`), which exists so logs name their seam. So the prefix is
not wrong, it is just not **his**. `honest()` strips it and nothing else does — that function is
the one funnel between a `CognitionError` and a sentence he reads, so `Display` keeps the label for
every log and every test that asserts on a seam. The detail is **moved**, not discarded: one
stderr line, emitted only when there was a label to strip.

Matching is exact-prefix on the two labeled variants, never a cut at the first colon — a real
reason can legitimately contain one (*"the land lock timed out after 300 s: nothing was merged"*).

**Exposed by the strip:** with the label gone the card can now open on a lowercase word, because
`CognitionError::Io(e.to_string())` wraps whatever the operating system said. `honest` now raises a
leading lowercase ASCII letter, and only that, so a reason opening on a quote, a number or a path
is untouched.

**The double period** (`esc-20260918T085540Z-a89cf867`, from `echo-opus-ui1`): *"… and land it..
It's running now"* was built in `richos-core`, not the UI. Fixed at the **source** rather than the
join: a title is a noun phrase that all eight sentences keep talking after, so fixing one join
would have left the rest reading *"and land it. is finished."*

That split `sanitize_title` into two functions, and the tests are why: a **detail** is a whole
sentence and keeps its period. Stripping it for the title's sake took the period off three of
`work_host`'s outcome sentences before three tests caught it. `sanitize_line` is now the shared
flatten/bound primitive.

§55 removed the title from the receipt, so the exact string Ray saw is gone — but the seven
sentences in `says` that report a **result** still name the assignment in his own words, and they
are what he reads for the rest of a job's life.

## 6. Row 6 — the 32-second wait. MEASURED: it is 0.03% the app's

Ray's timestamps, re-derived: 08:12:32.020Z → 08:13:04.452Z = **32.432 s**
(64.452 − 32.020 = 32.432).

```
$ cargo run -p richos-core --example assignment_receipt_timing
richos_assignments.record, 20 runs, in-process over the real JSON-RPC frames:
  fastest 7.258709ms
  median  9.50175ms
  slowest 18.073667ms
  mean    10.402306ms
```

- 9.50 ms ÷ 32,432 ms = **0.0293%**
- 32,432 − 9.5 = **32,422.5 ms**, i.e. **99.97%** of what he waited was not the registration path

**So there is nothing in the app's write path to make faster**, and a micro-optimization is not
being reported as a fix for a 32-second wait. Every second of it was model turns: two lookups plus
the model's own latency before each call. What removes it is removing the calls.

**Source answer to "does the doctrine or the tool description invite the lookups":** partly, yes.
`doctrine/front-desk.md:34` said *"never answer from memory when you can look"*, and the status
tool's description said *"Read this before answering any question of his about how work is
going"*. Neither scoped itself to a question about **existing** work, so a new request read as an
occasion to look. Both are now fenced, and the doctrine opens with his numbered sequence rather
than with an inventory of tools.

## 7. Outstanding — named, not papered over

1. **The send → "On it!" measurement against a live model turn is NOT done.** It needs a dev build
   under a temp `HOME` and one real turn on his subscription. Two honest reasons it is not in this
   record rather than one:
   - **There is no instrumentation for it.** Grepped `richos-core`, `ui/` and `ledger.rs`: nothing
     records time from send to first visible text. `submit_prompt` returns at turn **completion**,
     which is the wrong end of the turn for §55's criterion.
   - **n=1 would be weak evidence for a stochastic property.** One lucky turn is not proof the
     model registers first.
   **And the vehicle for it is itself blocked.** While this slice was being written, main took
   `7729032e` — Ray's candidate-.8 walk could not start because the Mac's screen is locked. That
   walk is where a repeated send → "On it!" measurement would come from, so §55's acceptance is
   outstanding for two independent reasons, not one.
2. **The doctrine steers; it does not enforce.** `tests/doctrine_sentinel.rs`'s own doc says so in
   as many words: *"What it does NOT prove: that the model will FOLLOW the shipping doctrine's
   judgment clauses … a preference, not an enforcement."* §55's acceptance is therefore a
   **behavioral** measurement that belongs in Ray's walk, repeated, not a unit test. Nothing in
   the app can structurally force the register to be the first tool call without taking the status
   tool away from the front desk, which it needs for status questions.
3. **`ui/main.js:2918-2920` carries the same defect on his screen and is NOT mine to fix.**

   ```js
   const openWork = rows.filter((row) => ["registered", "preparing", "running"].includes(row.state)).length;
   if (openWork) parts.push(`${openWork} ${openWork === 1 ? "assignment" : "assignments"} running`);
   ```

   A job only just written down makes the summary say *"1 assignment running"*. This is
   `echo-opus-ui1`'s footprint — for Rich to sequence after that branch lands.

   **`ui/work-summary.js:76-78` needs no change and is evidence the UI was right all along:**
   `registered` → *"Written down. Nothing has been prepared yet."*, `preparing` → *"Getting a
   workspace ready."*, `running` → *"Running."* The per-row sentences were already honest; the
   backend was writing the wrong state under them. `ui/timeline.js`'s `running` is worker and
   activity state, a different state machine, and is unaffected.

## 7a. A pre-existing flaky test, established as NOT mine

`work_host::tests::registering_returns_before_the_work_starts_and_the_work_still_runs` failed once
during a full run and passed on the next. It was investigated rather than re-run.

`work_host.rs:2032` is a wall-clock bound: `assert!(took < Duration::from_millis(100))`. Its own
doc says *"the number is the assertion"* — it exists to catch a build that started preparing on the
caller's thread, which would miss by an order of magnitude.

Evidence it is load, not this branch:

| Check | Result |
|---|---|
| the same test alone, 10 consecutive runs | **10/10 ok** |
| registration cost at `ee59193a` (20 runs) | median **9.502 ms**, mean **10.402 ms** |
| registration cost after every change here | median **8.816 ms**, mean **9.579 ms** — **faster** |

It could only get faster: `Receipt::sentence` went from a `format!` over a title to a 6-byte
literal, and the one addition to the path is a `trim_end_matches`. A 100 ms bound against a ~9 ms
median is ~11x of headroom, so a failure means the machine stalled for >90 ms — and the machine was
at that moment spawning app binaries in a loop for another agent's reaper test (see §8).

**The bound was deliberately NOT widened.** Loosening a real guard to hide a load artifact would
trade a flake for a blind spot, and this guard protects §0 row 2 — the thing his whole ask rests
on. Recorded for Tom and Ray instead: under heavy parallel load this assertion can trip, and the
way to tell a real regression from the artifact is the order of magnitude (a regression misses by
10x, not by 10%).

## 8. Verification

```
$ cargo test -p richos-core
TOTAL passed=1229 failed=0      (baseline at ee59193a: passed=1225 failed=0)

$ cd richos/app/src-tauri && cargo check
Finished `dev` profile [unoptimized + debuginfo] target(s) in 45.64s
warning: `richos-tauri` (bin "richos-tauri") generated 4 warnings
```

The 4 warnings are pre-existing dead-code warnings (`src/nav.rs` and neighbors); none is in a file
this branch touched. No `ui/` file changed, so the UI runner was not applicable.

**No app instance was launched by this task.** Every check above is offline and none of it puts a
window on screen. No audio was played (§53 is read and binding, and nothing in this slice touches
the voice path).

`pgrep -fl richos-tauri` was clean at session start. It is **not** clean now, and none of it is
mine — recorded here rather than tidied away, because §54 addendum 4 scopes the quit duty to *"a
test instance you launched, or were handed by Rich with a pid"* and neither applies:

- **pid 39430**, `./RichOS.app/Contents/MacOS/richos-tauri`, started **10:27:32**, now `PPID 1`
  (its launcher has exited, so it is reparented and orphaned). This is a real app instance someone
  else put up during my session. **For Rich to route** — it is either a walk instance still wanted
  by pid, or garbage under §54, and only its owner knows which.
- **a churning set of `scratch-reaper-test.*/allocapp/appbin/richos-tauri` fixtures** (pids seen:
  80144, then 94677, 94845, 95019, 95119, 95164, 95283, 95286, 95290 across two checks seconds
  apart). These are short-lived reaper-test fixtures belonging to an agent whose run is **in
  flight right now**.

**Nothing was killed, deliberately.** Killing another agent's live fixtures mid-run, or an
orphaned instance I cannot attribute, destroys work on an inference about ownership. The rule I
applied is the one this project already holds for worktrees: a positive signal of ownership is
required, and absence of one is not permission.

Every new test carries a positive control in the same body — the `starting`/`running` split
asserts that a job which really **is** running sits under `running`, so it cannot pass on a reader
that stopped reporting anything as running; the doctrine test asserts the file actually loaded;
the `honest` test asserts the seam label still **exists** on `Display`.
