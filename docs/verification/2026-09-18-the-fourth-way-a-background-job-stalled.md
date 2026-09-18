# The fourth way a background job stalled — the back end was never told its obligation, and a turn that had ended read as "still running"

Echo (Rust & Tauri desktop engineer). 2026-09-18. Worktree
`/Users/alex/ab/richos-wt/echo-opus-worklease2`, branch `cc/echo-opus-worklease2`.

Found by `echo-opus-worklease1` running the whole flow for real
(`esc-20260918T115854Z-852c5f9c`; its record is
`docs/verification/2026-09-18-the-third-way-a-background-job-died.md`, §5). Two things came out
of that run: the work lease's brief names no identifier, so the model invented one and
`richos_work.prepare` refused it; and when the turn then ended with nothing prepared, the
assignment was written `running` and **no notice reached the CEO at all**.

**The headline: the flow now runs end to end.** A job registered in his words lands a commit in
the fixture repository, with an independent review, and he is told what landed — and no model
typed an identifier anywhere in it. §4 is the run, with the tool calls quoted.

---

## 0. What in the brief I re-derived before building on it, and what came back different

| The brief's statement | What I found |
|---|---|
| "make sure the scope file `richos_work` reads carries `obligation_id`" | **Already true, under a different spelling — no app change was needed.** See §1. |
| `brief_for` is at `work_host.rs:1601-1610` | It was at `:1699-1737` on my base `d2178d02`; the numbers had moved. The substance holds: it names the repositories and the title and no identifier. |
| the real obligation was `qa-notes-line` (the brief marks the search for this as unshown) | **Reproduced independently, twice.** The probe's `checkpoint` reply on both of my runs carries `"record_id":"qa-notes-line","status":"applied"`. It is the probe's own literal, not a guess. |
| `prepare` refused an invented id "in 8 ms" with *"item is absent or outside the active scope"* | **Reproduced offline** on a work scope naming `obl-add-notes-line`: `REFUSED after 5.2 ms: item is absent or outside the active scope`. Same sentence; my timing is my machine's, not a correction of theirs. |
| "the settle reading … wrote 'still running' … the assignment sits in Running indefinitely" | The code path is real and is fixed (§2). **But the instance that was observed had a second cause nobody had found: the probe was reading two directories that never exist.** §3, and it is the most important finding in this record. |

---

## 1. The obligation was already in the scope — spelled `turn_id`

The brief's first instruction was to make the work scope carry the obligation. It has carried it
since the work seat existed. `ecs.rs`'s `bind_work_seat` says so in its own doc, above the line
that does it:

> **The `turn_id` is the ASSIGNMENT, not a turn.** Spec §5.3: a request cannot outlive its
> `turn_id` today, so the work lease's binding needs a stable identity that is not a turn — the
> assignment. It is carried in the turn field because the binding's six fields are fixed by the
> engine's own `BINDING_FIELDS`.

and again at the call:

> **`turn_id` is the OBLIGATION.** Not a turn, and not the app's own assignment id: the engine's
> seat reconciler maps a seat back to its assignment by reading exactly this field off the row
> (`mega-lander/app.py:704`).

`bind_work_assignment` (`native.rs`) calls it with the assignment's `obligation_id` and writes the
returned binding straight into the scope file through `ecs::write_scope`. Read off the real run's
own receipt, which carries that binding verbatim:

```
"binding": {"audience":"worker","entity_id":"qa-test-co","revision":1,
            "session_id":"e9617cee-782b-4944-a6a6-755d7f51829f",
            "thread_id":"thr_b102031fa2e640b4b079b2aff2b44a5b",
            "turn_id":"qa-notes-line"}
```

**So the app side of the brief's instruction was a no-op, and I wrote no app line for it.** The
work was entirely in the engine: reading a fact that was already there.

`carried_obligation(scope)` in `mega-lander/app.py` answers it, and it is deliberately narrow —
`audience == "worker"` **and** a seat, because on a conversation scope `turn_id` really is a turn
and reading it as an obligation would be worse than requiring the argument. `prepare` and
`complete` both take it from the scope and **ignore** an argument naming a different one. Silently:
a work lease carries exactly one assignment, so an argument is at best a correct copy and at worst
the guess that broke the run. Both schemas drop it from `required`, both descriptions say the
connection already knows, and `DESKTOP.md` — the back end's own doctrine — says it in one sentence
and stops asking for it in steps 3 and 7.

**`complete` was not in the brief and is not scope creep.** It is the call that closes the
assignment. A guessed obligation there leaves the obligation open after every piece of work has
landed, and the host's settle reading then reports a failure over work that succeeded. Fixing only
`prepare` would have moved the defect one step later and made it harder to see. The real run of §4
calls `complete` with `{"worker_ids": [...]}` and no obligation, so this half is exercised rather
than argued.

### Probed both ways

Against the pre-fix engine the two new tests fail with the defect's own signature:

```
ValueError: obligation_id must be a nonempty bounded string
AssertionError: "unresolved execution" does not match
                "completion requires an obligation and its complete final worker set"
Ran 2 tests ... FAILED (failures=1, errors=1)
```

and the production refusal itself reproduces, then stops reproducing:

```
pre-fix   REFUSED after 5.2 ms: item is absent or outside the active scope
restored  PREPARED (no refusal)
```

Four arms, because a one-armed test would pass for a derivation that trusted anything:

- **A** the lease names nothing → prepared against `fixture-task`.
- **B** the lease names `obl-add-notes-line`, which is what actually happened → the scope wins and
  the invented id appears nowhere in the receipt. It reuses **arm A's `request_id`**, so if the
  invented id had reached `normalized` at all the call would have refused with *"already used for
  different work"* instead of returning arm A's record. That is the assertion that the wrong id is
  **ignored** rather than merely refused.
- **C** a conversation scope still **requires** the argument, and a wrong one there is still refused.
- **D** a work scope bound to an obligation that does not exist is still refused, and prepares
  nothing. Deriving is not trusting.

---

## 2. A turn that has ENDED is never "still running"

`run_one`'s `Outcome::StillRunning` arm wrote `advance(Running, detail)`. Nothing in the app
re-reads a `Running` row — `run_one` returns there — so that state had no watcher and no exit. On
worklease1's run the row reached it at t+350.207 s and sat for the remaining 1,150 s with
`notices: []`.

**`StillRunning` is not a state; it is a missing witness.** §0's rule — *anything we cannot witness
counts as still running* — is a rule about what may be **claimed**, and it holds while a turn is
open. At that line the turn has provably ended: `prompt` returned `Ok`, the grant has been revoked
(step 4), the lease is idle. So *"could not witness it ending"* and *"it is still going"* have come
apart, and reporting the second is a claim about a job that is not running.

The arm now fails the assignment and raises a notice. What he hears goes through
`what_happened` — **the same funnel the `NotSettled` arm beside it already uses** — so this arm
cannot make a claim that one would not. With no receipts it says *"No work was started, so nothing
was landed."*; with receipts that show a land it names the land, because a worker journal the app
could not read is no evidence at all about what the engine wrote under its land lock.

`settlement()` and `outcome()` are **unchanged**. That reading was never the defect; only its
consumer was. One diagnostic line was added: `settlement` now logs **which** `Unattributed` reason
it was, because the run that produced all of this ended on that branch and nothing wrote the reason
down. It earned its keep within the hour — §3 below is that log line.

A question that ends with no answer passes an empty reason, so `says::could_not_answer` uses its
own sentence. `what_happened` reads the **work** receipts; a question has none, and *"No work was
started, so nothing was landed"* about a question he asked is literally true and a non-sequitur
(§58). `says::failure`'s dispatch and the placement of the answered arm are
`echo-opus-question1`'s and are untouched.

### Probed, and two tests were asserting the defect

With the arm put back:

```
assertion `left != right` failed: a job whose turn has ended still reads as running
  left: Running   right: Running
```

Three arms: the hung run itself; **a witnessed run with a receipt that still settles and still
names its land** (without it, a build that failed everything would pass); and the identical
assignment with **readable** evidence and the same open obligation producing the same sentence
through the already-correct `NotSettled` arm — which is what shows the new arm reports a missing
witness with the reading the module already uses rather than inventing one.

Both tests that asserted `Running` were corrected carrying their reason:

- `background_work_is_settled_against_the_work_lease_session_not_the_conversation` — the settle
  reading it checks is unchanged and still asserted; the assignment's state is a different question
  and is now asserted separately.
- the four-endings test's arm 3, *"an unreadable record was called a failed land"*. The concern is
  intact: the sentence is still read off the receipts and still claims no land. Only the state word
  moved.

---

## 3. The finding I did not go looking for: a probe that was wrong about WHERE

**Run 2 landed the work and reported a failure.** The fixture moved
`5c1fb70d5743f2d0…` → `d2000e4e4f71a5fa…`, `notes.txt` gained its line, a reviewer passed it,
`integration.verified` is `true`, and a completion receipt was written with `verified: true`. What
he was told:

```
NOTICE [Failed] Add a line to the notes file and land it stopped before it finished.
                No work was started, so nothing was landed.
```

Two wrong answers, one cause, and it is **the probe's, not the product's**. `WorkHost::new` was
given `data` where the app gives `data_dir.join("engine-state")`
(`src-tauri/src/main.rs:2030-2031`). Both of the host's readings hang off that root —
`app_workers::status` reads `<state>/evidence/<session>/callbacks.jsonl`, `work_status::trail` reads
`<state>/work-receipts/<partition>/` — and `RICHOS_APP_STATE`, where the engine's hook and
mega-lander actually write, is `data/engine-state` (`engine_profile.rs:96`, `:235`).

Observed on the retained run rather than inferred:

```
app-data/evidence        -> does not exist   (the host looked here)
app-data/work-receipts   -> does not exist   (the host looked here)

app-data/engine-state/evidence/57e56564-.../callbacks.jsonl
    86 rows, all schema 1, all carrying that session; SubagentStart/Stop matched for
    both the worker (a38453e06c80a8376) and the reviewer (ad475a437f35e7511)
app-data/engine-state/work-receipts/49d1f1ef79b1.../
    worker receipt status=integrated, reviewer receipt verdict=passed, completion
    receipt verified=true; and 49d1f1ef79b1… is exactly the partition hash `trail`
    computes for ["qa-test-co","thr_76f79f642def4e3cbb3903bf39314ce5"]
```

So the settle reading answered `AppEvidenceUnavailable` and `what_happened` answered *"No work was
started"*. **Both were honest about what they could see, and both were looking one directory too
high.** Nothing in the product was wrong in that run.

**Two things follow, and the second is the uncomfortable one.**

1. A probe that is wrong about **where** is the most expensive kind, because every answer it gives
   is well-formed. The reason is written into the file at the line, not only here.
2. **This same defect was present on worklease1's run**, which is the run §2's finding was raised
   from. Its *"the settle reading wrote 'still running'"* observation therefore had a cause outside
   the product. The §2 code path is real, reachable and worth fixing on its own terms — a genuinely
   unreadable journal, a stuck writer, a crash mid-write all reach it — but **the observed instance
   is not evidence that production hangs**, and this record says so rather than letting the fix
   borrow authority from a measurement that turned out to be about the probe.

The diagnostic added in §2 is what found it: `no worker evidence could be attributed to this back
end: Some(AppEvidenceUnavailable)`. Without it the reading was a sentence with no reason behind it,
which is exactly how it survived a whole run before.

---

## 4. The whole flow, once, for real — and it lands

**Environment.** macOS 15.6, arm64. `claude` 2.1.275 (`/Users/alex/.local/bin/claude`). Engine tree
`richos/engine` at this branch. Delivered runtime
`/Users/alex/ab/richos-rechecks/deep-20260916/runtime-archive/engine/runtime`, read-only to this
probe. Fresh temp state root; nothing touches the CEO's app data. One model turn on his
subscription per run, three runs total (one cut short by the probe defect above, two complete).

```
FIXTURE BEFORE  head=3f4b5abd1072f95ce3e3abbbfdbd41f4e35d35c4
3f4b5ab the fixture's starting state
a89a1e7 Initialize repository
notes.txt = "hello\n"
Obligation opened: {... "record_id":"qa-notes-line","status":"applied" ...}
REGISTERED d56d4cbe-a1e8-4c3e-ae69-d69e6f19a13b at t+0
t+   0.019s  Registered :: Written down. Preparation has not started.
t+   0.230s  Preparing  :: Opening the work connection.
t+   1.876s  Preparing  :: Preparing the workspace and starting the work.
t+   2.086s  Running    :: The back end has started on it.
NOTICE [Settled] Add a line to the notes file and land it is finished. It landed on main
                 in qa-fixture. An independent review passed it first. Everything it
                 produced is with your saved work.
t+ 209.657s  Settled    :: It landed on main in qa-fixture. An independent review passed it first.
FIXTURE AFTER   head=95b7ca519ba2e43bb5ee02d74cc1945344013b59
95b7ca5 Append second note to notes.txt
3f4b5ab the fixture's starting state
a89a1e7 Initialize repository
notes.txt = "hello\nSecond note, added 2026-09-18.\n"
```

`work_session: e9617cee-782b-4944-a6a6-755d7f51829f`, `fixture_gained_a_commit: true`,
`reached_running: true` at 2.085937791 s.

**NO MODEL TYPED AN IDENTIFIER — every `richos_work` call, read off that session's own
`callbacks.jsonl`:**

```
#5   repositories  {}
#7   inspect       {}
#17  prepare       {"request_id": "notes-line-worker-1"}
#54  inspect       {}
#56  prepare       {"request_id": "notes-line-reviewer-1", "role": "reviewer"}
#92  integrate     {"worker_id": "f2034c54…", "reviewer_id": "81fcad7f…"}
#96  complete      {"worker_ids": ["f2034c54…"]}
```

Not one `obligation_id`, on either `prepare` or on `complete`. **Zero `PostToolUseFailure` rows**
— the 8 ms refusal that ended the previous run does not occur. The two receipt ids on `integrate`
and `complete` are the engine's own return values quoted back, which is the one case where a model
handling an identifier is correct by construction.

And every receipt carries the obligation the app put in the scope:

```
receipt 81fcad7feba6  role=reviewer  obligation=qa-notes-line  status=run-ended  verdict="passed"
receipt f2034c542f04  role=worker    obligation=qa-notes-line  status=integrated
   integration verified=True branch=main
     3f4b5abd1072f95ce3e3abbbfdbd41f4e35d35c4 -> 95b7ca519ba2e43bb5ee02d74cc1945344013b59
     reviewer=81fcad7feba6  cleanup_pending=[]
completion  obligation=qa-notes-line  verified=True  workers=['f2034c542f04']
```

### What this establishes, and what it does not

**Established.** A background job registered in the CEO's words reaches its back end at t+2.086 s,
prepares a worker and a reviewer without naming the obligation, lands the reviewed result on `main`
in the fixture, closes the assignment, and puts one sentence on the timeline that names the branch,
the repository and the reviewer's verdict. §52's *"always land on its own"* and the spec's *"the
CEO's conversation is never blocked"* are both satisfied on this path.

**Not established.** This is a headless crate probe. It says nothing about the opening screen, the
timeline render, or anything else on the CEO's screen. It is one repository, one small change, one
worker and one reviewer; a multi-repository assignment, a reviewer that asks for changes, and a
land-lock contention are untested here. And the fixture's `main` is its own default branch, so the
integration branch had nothing to fast-forward past.

---

## 5. Test hygiene

- `cargo test -p richos-core`: **1262 passed / 0 failed** measured the same way on my starting base
  `d2178d02`; **1272 passed / 0 failed** on this branch rebased onto `580f896a`. My branch adds
  **exactly one** richos-core test — verified by counting `#[test]` additions in the diff against
  `580f896a`, which returns 1 — and the rest of the rise is main's §58 land. `README.md`'s line
  moves `1270 → 1271` in that file's own convention (`1267 direct, 4 ignored`, both re-derived
  rather than incremented).
- `mega-lander/tests/app.test.py`: **29 run / 0 failed** before, **31 run / 0 failed** after, and
  re-run green after the rebase.
- `cargo check` in `src-tauri`: `Finished`, 4 pre-existing dead-code warnings (`nav.rs` and
  unrelated), none from this work.
- Every new test was seen to fail against the pre-fix code with the defect's own signature and to
  pass restored. No flake observed in any of the four full richos-core runs.

## 6. Instance and garbage hygiene

No RichOS app instance was launched: this is a headless crate probe, not a walk.
`pgrep -x richos-tauri` returned nothing at the start and nothing at the end. One
`pgrep -f 'RichOS.app/Contents/MacOS/richos-tauri'` at session start matched **another session's
shell command line** containing that pattern, not an app — checked with `pgrep -x` and
`ps -Ao pid,comm` rather than trusted.

Both probe runs were retained on purpose so their evidence could be read
(`RICHOS_PROBE_KEEP_FIXTURE`): `richos-work-lease-58b3d31a…` (712 KB) and
`richos-work-lease-3b09ef82…` (732 KB) under `$TMPDIR`. Both were then removed with one `rm -rf`
naming both paths, which exited 0, and the check afterwards is the absence rather than the removal:

```
ls: …/T/richos-work-lease-*: No such file or directory
```

The removal is evidenced by that command's own exit status; the listing only establishes that
nothing of the shape remains now. Nothing of this work is left in a temp directory (CEO §54). The
scratch scripts and the two run logs this record quotes live under this session's own scratchpad,
which is outside the repository and is not mine to keep.

## 7. Observed and deliberately not changed

- **`what_happened` is a work sentence and the `NotSettled` arm hands it to a question too.** My
  own new arm passes an empty reason for a question kind; the pre-existing arm beside it does not.
  Changing it would restructure `echo-opus-question1`'s code, which landed hours ago and whose
  brief says add rather than restructure. Named here so it is a known seam rather than a surprise.
- **`work_roundtrip.rs` is still stale** — worklease1 recorded it; it drives the conversation
  lease's `richos_work` tools, which no longer exist on that lease.
- **`start_work_lease`'s continuity stub still cannot be read back** — worklease1's §6 entry, still
  latent for the same reason, still unreachable.
