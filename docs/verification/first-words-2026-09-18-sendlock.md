# The five seconds before his turn started were never the lock — they were the prime behind it

**2026-09-18 · branch `cc/echo-opus-sendlock1` · CEO ruling §55
(`richos-hq` `wiki/ceo-decisions.md`) · run **F** of
`crates/richos-core/examples/first_reply_timing_e2e.rs`, continuing
`docs/verification/first-words-2026-09-18-toolsearch.md` (run E)**

*"Rich **immediately** replies with: "On it!" and only after that does all that work."* …
*"Yes, a few seconds is fine. But 35 seconds of waiting for the first response is not."*

---

## 1. The brief's premise, and the arithmetic that refutes it

The brief was built on §4 of the previous record, which decomposed Ray's measurement 1 on
candidate .10 — "On it!" on the window at **+12 s** — as **≈5 s before the turn started plus
≈7 s of turn**, and named the cause: `ready_the_front_desk` holds the spine's mutex for the
whole of `Spine::prime_front_desk`, and `send_message` opens by taking that same mutex.

**Every sentence of that is true. The conclusion drawn from it is not.** The brief asked for
the Send to come off the lock *and* for the contended run's first words to land "within run
E's numbers (+1 s)" — 6.995 s. Those two cannot both happen, and the reason is three lines of
existing code rather than an opinion:

| the fact | where |
|---|---|
| the priming is a **model turn**, not a process start | `prime_front_desk` → `prepare_request` → `prime_lease_if_needed` → `Cognition::reprime` |
| the lease is **serial** — one turn at a time, queue-not-interrupt | continuity design §3.1, enforced throughout `spine.rs` |
| an already-primed thread **never primes twice** | `spine.rs`, `prime_lease_if_needed`'s early return on `lease_primed && lease_primed_thread == thread` |

So his prompt reaches the provider when the priming turn ENDS, whether it waited on the mutex
or on the intake log. The contended cost is `prime_remainder + turn` under both shapes, and
the five seconds are not recoverable by removing the block. **The pre-prime is a bet that the
CEO is slower than the prime, and Ray lost it.**

Raised before any of the work below was built on it, as
**`esc-20260918T195518Z-79f7b0d9`**, and accepted.

---

## 2. Run F — the contended case, measured

`RICHOS_PROBE_CONTENDED=1`: a brand-new thread's pre-prime is started on its own thread, the
spine's mutex is held for the whole of it exactly as the shell holds it, and the Send goes in
**500 ms** later.

```
CONTENDED: he opened a brand-new thread and typed 500 ms into its pre-prime.
the pre-prime, its own turn only        : 2.868 s   (Ready { millis: 2868, spawned: false })
the priming thread returned after       : 11.266 s  (prime + the turn it drained)
the spine was shut when he pressed Send : true
his Send was ACCEPTED in                : 4 ms      (durable, intake 1)
the remainder of the prime he queued behind : 2.368 s
send -> first words                     : 9.647 s
    of which the prime's remainder      : 2.368 s
    of which the turn itself            : 7.279 s
priming turns in the ledger             : 1
visible turns in the ledger             : 1
    "Land the pricing branch and get the staging deploy done." -> "On it!"
intake still pending after the prime    : 0
runs of prose he can see                : 1
the turn, in arrival order:
      5.646 s  mcp__richos_assignments__record        <- the FIRST tool call
      6.089 s  {"assignment":"Land the pricing branch…","kind":"tas…
      9.647 s  HIS FIRST WORDS
      9.656 s  tool_call closed: {"recorded":true,"say":"On it!","say_nothing_else":true}

PASS: his Send was taken in 4 ms while the spine was shut, made durable there, and handed
over exactly once after the prime — one priming turn, one visible turn, nothing left in the
intake.
```

### 2.1 What moved: 2368 ms → 4 ms, a factor of **592**

Under the shape this replaces, those 2368 ms were spent inside `state.spine.lock()`, with the
window reading *"Sending your message / Waiting for Rich to accept it"* and his sentence
living **nowhere but the webview**. It is now `fsync`'d to the intake log before the call
returns; quitting RichOS in that window used to lose it with no trace anywhere.

The arithmetic is the measurement, not a threshold: the prime's remainder is
`2.868 − 0.500 = 2.368 s`, and 4 ms is what one local `fsync` costs. The shell's own
`send_wait_notice` cannot fire on this path at all — it sits after `state.spine.lock()`,
which the deferred branch returns before reaching.

### 2.2 What did not move, exactly as predicted: `send -> first words`

**9.647 s, of which 2.368 s is the prime's own remainder.** That is §1's arithmetic coming
out on a real provider. This slice does not move that number and the code says so in three
places rather than leaving it to be rediscovered.

### 2.3 Reported, not concluded from

The turn itself was **7.279 s** against run E's **5.995 s** for the same sentence — with the
register EARLIER (3.278 s into the turn against 3.915 s) and the leg from the register's
arguments to his first words LONGER (3.56 s against 2.075 s). One run against one run, both
against a live service. It is stated so the next run has something to compare against, not so
anything is concluded from it. It is inside `FIRST_TURN_BUDGET` (11 s) and the run scores it.

---

## 3. The defect run F found in its own instrument

**The first contended run printed a turn of `-1.431 s`.** `prime_front_desk` now drains his
deferred message before returning, and the elapsed clock was being stamped AFTER that drain —
so `FrontDeskReady::Ready.millis` carried the prime PLUS his whole turn:

```
the pre-prime, end to end : 11.356 s  (Ready { millis: 11355, spawned: false })
    of which the turn itself : -1.431 s
```

`Ready.millis` is documented as *"what he would otherwise have waited through on his first
message"*, and the shell prints it verbatim into `app.log` as *"the front desk is ready before
he types: {millis} ms"*. Nothing about an 11355 that should read 2868 is visible without a
second clock to contradict it — and the previous record's own §4 is built on exactly that
`app.log` line (the `4412 ms` it quotes). **A wrong number in `app.log` becomes a wrong number
in a record two days later**, which is this project's `3.19` failure mode.

Fixed at `1056969c`: the clock stops at `let primed_in = started.elapsed()`, before
`end_front_desk_prime` and `poll_intake`. Pinned by
`the_ready_verdict_counts_the_prime_and_never_the_turn_it_drained_on_its_way_out`, which gives
the test lease a 400 ms turn against a prime released immediately — an order of magnitude
apart, so it tells them apart without being a timing threshold. RED-FIRST: with the clock
stamped after the drain again, that test and only that test fails.

**This is why run F cost four model turns and not two.** The first run bought the defect; the
second is the measurement. Stated rather than rounded down.

---

## 4. The shape, and the invariant the lock protects

The intake log is already the one road into the spine that does not need the spine's mutex —
it is how Stop, steering and the phone reach it while a turn runs. A deferred desktop send
takes that road.

- **`IntakeRecord::Desk`**, a fourth utterance record. **Not** a `Channel` with a new mouth:
  `drain_intake`'s `Steer` and `Channel` arms file the turn and stage nothing, so filing a
  typed message as a `Channel` would have **silently dropped every correction he typed during
  a prime**. Today that gap only costs the phone; it would have started costing the desk.
- **`Spine::accept_prompt`**, extracted from `submit_prompt_inner` — whose own comment calls
  it *"the ONE function every CEO utterance passes through"*. That claim is now a function
  rather than a sentence, and the `Desk` arm calls it.
- **`TurnControl::{begin,end}_front_desk_prime` + `defer_send`.** The check and the `fsync`
  happen under ONE guard, and clearing the marker needs that same guard, so there are only two
  orderings and both are safe: a send accepted under the marker is drained by the call that
  clears it; a send that arrives after the clear blocks on a spine microseconds from free. A
  plain read followed by a separate write would have a third ordering — write after the drain
  — and that message would sit in the log until some later boundary happened to find it.
- **Lock order**, stated because there are now three: the priming thread takes SPINE then
  PRIMING; `defer_send` takes PRIMING then INTAKE; nothing takes the spine while holding
  PRIMING. No cycle exists.
- **The invariant the mutex protects is untouched.** Nothing is delivered into a running turn;
  the priming turn still runs under exclusive `&mut Spine`; queue-not-interrupt (§3.1) is
  unchanged. What changed is only which road a message WAITS on.

### 4.1 Proven red first, each half broken on its own

| what was broken | what failed |
|---|---|
| the priming marker never set | 5 of 10 (`accepted-while-shut`, `durable-before-return`, `in-order`, `exactly-once`, `shut-before-drain`) |
| the road shut but never drained | 3 of 10 |
| the `Desk` arm filed the phone's way | the correction test, alone |
| the clock stamped after the drain | the `Ready.millis` test, alone |
| `defer_send` removed from `send_message` | the shell's ordering test (265 passed, 1 failed) |
| `defer_send` present but placed AFTER the mutex | the same test — the version that compiles and does nothing |

---

## 5. What this record does NOT claim

- **It does not claim his first words arrive sooner.** §2.2. They do not, and §1 says why.
- **It does not claim the ≈2 s warm residual of measurement 2 is touched.** That is thread
  depth and the webview path, named with the test each needs in the previous record's §4.
- **It does not claim run F's 7.279 s against run E's 5.995 s means anything.** §2.3.
- **It says nothing about what the timer beside his reply reads.** The probe is headless.
- **The SPOKEN path is not covered.** `submit_prompt_spoken` still blocks on the same mutex
  during a prime: the intake log's utterance records are all typed, and
  `Event::PromptReceived`'s `rich_audible` has no representation on that road
  (`Spine::accept_prompt` logs and degrades if it is ever handed one). Named here rather than
  discovered later.

---

## 6. The slice that WOULD move his first words, and what it has to decide

Recovering the 2.368 s needs a front desk that is **already primed when the thread opens**,
not one that starts priming then. Four things that slice has to settle, with what is already
known about each — so its brief starts from measurements rather than from a preference.

1. **A spare desk cannot be thread-agnostic under the current design, and that is the first
   decision.** `EngineProfile::scope_to` binds the lease's state directory to
   `(entity_id, thread_id)` **before the child is spawned** — `src-tauri/src/main.rs:425`,
   inside `spawn_chat` (line 369), which is what `spawn_scoped` (line 303) calls; the work
   lease has its own copy at line 359. And `NativeCognition::requires_thread_isolation()` is
   true whenever continuity is wired (`native.rs:2955`), so `prepare_request` parks the
   outgoing desk and resumes or spawns the destination's rather than reusing one. A spare is
   therefore either spawned already bound to a
   thread that does not exist yet, or the scoping moves. Neither is free and neither is
   obviously right.
2. **How many spares.** `MAX_RESIDENT_FRONT_DESKS = 8` is the existing ceiling for desks that
   have been USED, and its own comment calls it *"a number to revisit with a measurement, not
   a constant with an argument behind it"*. A spare is a different thing: it is a child he has
   never spoken to. One is probably the answer; the slice should say why.
3. **What a spare costs while it sits idle. NOT MEASURED HERE, and it must be measured rather
   than estimated.** The honest form is RSS and CPU of an idle `claude-agent-acp` child after
   its priming turn, sampled over a few minutes, plus whether the provider bills anything for
   an open session that is not prompted — the priming turn itself is already known to be one
   model turn per spare (`prime_front_desk`'s own doc names the launch-where-he-never-speaks
   case as the one cost this design already accepts).
4. **What happens to the spare on an entity switch.** A spare primed for entity A is useless
   for entity B and must never be adopted by it — the same entity-boundary rule
   `IntakeRecord::Steer::thread_id`'s comment states. Discard and re-prime, or keep one per
   entity, is a cost decision that follows from (3).

A fifth, cheaper option the slice should price before the others: **start the prime at thread
CREATION rather than at the first timeline read.** Measured against the current path it buys
almost nothing — `ui/main.js`'s new-thread flow is `create_thread_in` → `openThread` →
`switch_thread` + `active_context` + `get_timeline`, back to back — but it is one line and it
is the null hypothesis the spare has to beat.

---

## 7. Garbage (CEO §54), and no app on screen (§54 addendum 4)

- **No app instance was launched by this work.** Everything is headless — two Rust suites, a
  UI suite pair under WebKit, and two runs of one example. `pgrep -fl richos-tauri` returns
  nothing, exit 1.
- **The probe's own fixture is gone.** `first_reply_timing_e2e` removes the directory it
  makes; verified absent by path afterwards.
- **The test suite's scratch is self-removing.** `deferred_send_tests` names every file it
  creates and removes them, and `Contended`'s `Drop` also releases the priming latch so a
  failing assertion can never leave a parked thread behind.
- **`ui/tests` had no `node_modules` in this worktree.** Playwright 1.61.1 was copied from the
  main checkout to run `home.js` and `escape.js`; it is gitignored and was removed before
  handoff. The three `shots-home/*.png` the home suite rewrites were reverted — byproducts,
  not changes.
- **Still a §54 gap, unchanged and not mine to sweep:** the Rust suites leave `richos-*`
  scratch directories under `$TMPDIR` from modules that have not moved to a self-removing
  root. The previous record reports it; it belongs to the scratch reaper, not to a per-agent
  judgment call, and another agent's suite is live in that directory.

## 8. Reproducing it

```
cd richos/app

# run F — TWO model turns
RICHOS_PROBE_CONTENDED=1 cargo run -q -p richos-core --example first_reply_timing_e2e -- \
  <path-to>/richos/engine /Users/alex/.richos-nightly/runtime

# the suites — no model turn, no network
cargo test -q -p richos-core                          # 57 suites, 0 failed (748 lib + 10 new)
cargo test -q --bin richos-tauri                      # from src-tauri: 266 passed, 0 failed
cd ui/tests && node home.js && node escape.js         # exit 0; 38 PASS and 10 PASS, 0 FAIL
```

**`scripts/lint-banned.sh --staged` and `scripts/preflight.sh` could not be run: neither
exists anywhere in this repository after the 2026-09-17 relay to
`richos/richos/{app,engine,tools}`** (`find` over both this worktree and
`/Users/alex/ab/richos` returns nothing for either name). Every staged diff was checked by
hand for all four banned patterns instead — `npx convex`, concatenated `adb shell input text`,
`jj` write commands, hard-coded `CONVEX_DEPLOYMENT=` — and none carries any.
