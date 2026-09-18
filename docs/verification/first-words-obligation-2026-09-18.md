# The register opens the obligation, nothing can write to ECS before his first words, and what was written DISPATCHES

**2026-09-18 · branch `cc/echo-opus-obligation2` · CEO ruling §55
(`richos-hq` `wiki/ceo-decisions.md`), continuing `docs/verification/first-words-2026-09-18.md`
(runs A and B) and closing its finding 2**

*"Rich **immediately** replies with: "On it!" and only after that does all that work."* …
*"Yes, a few seconds is fine. But 35 seconds of waiting for the first response is not. Go."*

Runs **C** and **D** of `crates/richos-core/examples/first_reply_timing_e2e.rs` against the real
provider on the CEO's subscription — **six model turns, which is the whole of what this slice
spent**: each run is a priming turn, a task turn and a question turn. Logs verbatim in
`first-words-2026-09-18-logs/`. Plus one run of the same probe in
`RICHOS_PROBE_DISPATCH_ONLY=1`, which spends nothing at all.

**Run C is a finding rather than a confirmation, exactly as run B was, and the record is
organized around that.** The probe's new grant watch caught the app opening the front desk's
continuity grant **7 ms and 5 ms IN FRONT OF his first words** — an `fsync` on the one path §55
is about, and a window in which the invariant this slice claims did not hold. Fixed at
`cddea51e`; run D is the same probe on the fixed code and passes.

---

## The numbers

Send → his first words, off `LiveEvent::MessageStarted`/`MessageDelta` — the events the webview
renders his text from.

| | before this slice (run A) | run C | **run D** |
|---|---|---|---|
| a task turn, the lease's first VISIBLE turn | 7.998 s | 5.778 s | **5.612 s** |
| a question turn, warm | 6.358 s | 6.241 s | **5.702 s** |
| the priming turn, before he typed | 2.768 s | 2.214 s | **2.686 s** |
| his first words vs the register's answer | the same instant | 5.778 / 5.786 | **5.612 / 5.621** |
| the continuity grant vs his first words | not measured | **7 ms and 5 ms BEFORE — the defect** | **5 ms and 6 ms after** |
| the grant across the priming turn | not measured | never opened | **never opened** |
| runs of prose he can see | 1 | 1 | 1 |
| model turns the run spent | 3 | 3 | 3 |

Run D's accounting, in the same form the three previous records used:

```
front desk made ready before he types : 2.686 s  (Ready { millis: 2686, spawned: false })
the continuity grant across the priming turn : shut at its start = true, opened at = None

he said    : Land the pricing branch and get the staging deploy done.
Rich said  : "On it!"
send -> first words : 5.612 s      send -> turn ended : 6.786 s
      3.047 s  mcp__richos_assignments__record        <- the FIRST tool call
      3.533 s  {"assignment":"Land the pricing branch and get the staging deploy done.","kind":"tas…
      5.612 s  HIS FIRST WORDS
      5.617 s  the continuity grant is first seen OPEN
      5.621 s  tool_call closed: {"recorded":true,"say":"On it!","say_nothing_else":true}
runs of prose he can see : 1
[withheld] the model's own "On it!" after the receipt, 6 chars, the same sentence again

he said    : Why has the nightly build been failing since Tuesday? …
Rich said  : "I'll investigate."
send -> first words : 5.702 s      send -> turn ended : 7.006 s
      3.224 s  mcp__richos_assignments__record        <- the FIRST tool call
      3.820 s  {"assignment":"Why has the nightly build been failing since Tuesday, and what is act…
      5.702 s  HIS FIRST WORDS
      5.708 s  the continuity grant is first seen OPEN
      5.712 s  tool_call closed: {"recorded":true,"say":"I'll investigate.","say_nothing_else":true}
runs of prose he can see : 1
[withheld] the model's own "I'll investigate." after the receipt, 17 chars, the same sentence again
```

**`tool calls before he spoke : 2` on every turn of both runs, and both of them are the
register.** The wire reports a tool call's NAME and its complete ARGUMENTS as two machinery
frames, and the probe lists both. `first_reply::first_reply_faults` scores the register's
POSITION, which is 0 on all four turns — there is no second tool.

**The budgets are deliberately NOT re-derived downward.** `FIRST_TURN_BUDGET` stays 11 s and
`FIRST_WORDS_BUDGET` stays 9 s. Three clean runs now span **5.612 s to 7.998 s** on the lease's
first visible turn and **5.702 s to 6.358 s** warm, measured hours apart on identical code —
which is the provider variance the wide headroom was taken for. A budget cut to today's fastest
run would flap, and a probe that flaps is a probe that gets waived.

---

## FINDING — the grant opened in front of his first words, and the probe is what caught it

`esc-20260918T…` (raised, see below). Run C, both turns:

```
[task]     grant first seen open 5.771 s   HIS FIRST WORDS 5.778 s    -> 7 ms EARLY
[question] grant first seen open 6.236 s   HIS FIRST WORDS 6.241 s    -> 5 ms EARLY
```

All three of the reader's call sites did the same thing: `he_has_now_been_spoken_to()` and THEN
`Self::route(...)`. That function opens `richos_continuity`'s own scope file, and opening it is a
`write_verified` with an `fsync` in it. So the app's own disk write sat between deciding to speak
and speaking.

**Two things were wrong with that, and the smaller one is the latency.**

1. **7 ms of his wait**, spent on an `fsync` in front of his sentence, on the one path §55 is about.
2. **The grant was open, briefly, before he had heard anything** — which is the exact property
   this slice claims. The window is far too short for a model round trip, so nothing was ever
   measured getting through it. A window nothing got through is still not the invariant.

**The measurement is conservative in the safe direction, which is why it can be trusted.** The
probe polls that file every 2 ms on a thread of its own, so an observed open is never EARLIER
than the true one — the real inversion is at least the 7 ms and 5 ms it saw. Polling rather than
reading at the event is deliberate: the grant is opened inside the reader, under its lock, in the
same call that routes his words, so a read from the live observer would land after the flip
whatever the true order was, and a filesystem read on the thread whose latency IS the measurement
is the last thing this probe should do.

**The fix is the order** (`cddea51e`): route the text, then open the grant, at all three sites.
That inverts the only remaining risk and inverts it safely — a model whose next frame lands
before the write completes gets its checkpoint refused by the engine's adapter and writes it a
moment later, rather than getting one through early.

`receipt_said` is still set BEFORE the text is routed and that is not an inconsistency: it is a
field behind the lock the routing path also takes, guarding a real race (a delta racing the flag
it is tested against). This one was I/O in front of his sentence.

**Proven able to fail, twice.**
`native::…::the_bookkeeping_grant_is_shut_until_his_first_words_on_a_real_turn` now drives TWO
deltas through a real child and reads the flag at each, asserting `[false, true]` — shut at his
first words, open by the second run of them. Two deltas rather than one is what makes both halves
observable: with one, *"shut when he heard it"* and *"never opens at all"* are the same reading.
With the delta site alone put back the way it was, the same test goes red with `left: [true,
true]`. And the probe's own arm is red in run C's log by measurement rather than by argument.

---

## The join, closed: what the register wrote DOES dispatch

The previous record could only state this, off source, with no dispatch attempted:

> **And the other half is worse than the three seconds. Run A called the register first with no
> ECS write anywhere on the turn … so both of run A's assignments carry an obligation that was
> never opened, and `prepare` would refuse them.**

`does_it_dispatch` replaces that sentence with a measurement. It writes the work lease's scope
exactly as `native.rs`'s `prepare_work_turn` does — `actions_allowed: true` (the standing grant,
spec §5.4), the binding from `bind_work_seat` whose `turn_id` IS the obligation, the frozen
instruction reference — and calls `mega-lander/app.py`'s `call(scope, "prepare", …)`, which is the
whole tool handler (`__main__` only wires it to the MCP transport with `handler=call`).

Measured on runs C and D and on the model-free run, every time:

| | the store, inspected on the WORK seat | `prepare` |
|---|---|---|
| the register's own `work-<uuid>`, a task (`commitment`) | **Open** | reaches the DISPATCH step |
| the register's own `work-<uuid>`, an investigate (`open_loop`) | **Open** | reaches the DISPATCH step |
| the OLD SHAPE, `land-pricing-branch-staging-deploy` | **Absent** | `ScopeError: item is absent or outside the active scope` |

**The cross-seat join is the thing this slice bet on, and it holds.** The register opens the item
on the CEO's own per-thread seat (`ceo-thread:<thread>`, the only seat the engine accepts a
`checkpoint` from). `prepare` inspects it from the WORK seat, `work-seat:<obligation_id>`. Those
are different rows in `ecs_active_context`, and the item resolving across them is what makes an
assignment dispatchable. Nothing about that was measured before today.

**The old shape is not a synthetic control.** `land-pricing-branch-staging-deploy` is verbatim the
id run B's model minted for the same sentence, carried by a lease exactly as a real one would
carry it. Nothing ever opened it, and the engine refuses it in its own words.

**"Reaches the dispatch step" is a positive observation, not "it failed somewhere else."** After
the obligation gate `prepare` still checks the host-attested instruction, the connected
repository, the main checkout, the role, request-id reuse and the per-obligation unresolved-work
rule, then writes its receipt and its brief and builds the spawn command
(`mega-lander/app.py:322-430`). Reaching `spawn:` means every one of those passed, and the probe
FAILS a green row that stops anywhere before it. **Proven able to fail:** with `repo_argument`
pointed at an unconnected path — one line, reverted — both green rows go red with *"stopped before
the dispatch step … : connect this exact repository to the active company before dispatch"*
(`dispatch-negative-control-unconnected-repository.log`).

**And it costs nothing to re-check.** `RICHOS_PROBE_DISPATCH_ONLY=1` starts no lease and spends no
model turn: the register's own code writes the assignment and the engine's own `prepare` judges
it. That mode is also how this whole section was developed and proven red before a single model
turn was spent on it.

---

## FINDING — the engine's own operator guards sit in the app's dispatch path, and one of them refuses it today

**Measured, not inferred.** On every run above, both green rows stopped at the last step of
`prepare` with this:

```
spawn: refused by 1 of 9 guard(s) - NOTHING WAS CREATED.
  [1] guard-owned-state.sh REFUSES this spawn  (engine: …/richos/engine/hooks/hooks.json)
      system   : ci — Continuous integration across every governed repository
      PAUSED WebDevBooster/richos   Operator requested a CI pause to resume product work.
  guards evaluated (all of them, every time):
    ok      guard-sealed-worktree.sh …  ok guard-worktree-isolation.sh …  ok guard-definition-drift.sh
    ok      verify-agent-prompt.sh   …  ok guard-ceo-ask-first.sh      …  ok guard-model-ceiling.sh
    ok      guard-stale-staging.sh   …  REFUSED guard-owned-state.sh   …  ok guard-brief-scope.sh
```

`prepare` runs `spawn.py`, which collects every `PreToolUse[Agent]` guard from
`engine/hooks/hooks.json` and from the settings files under its project directory — and its
project directory is the APP's coordination root (`RICHOS_ENTITY_ROOT`). So the app's own
background dispatch is evaluated against the engine's operator guards, and
`guard-owned-state.sh` refuses whenever a standing system is unhealthy in that session. Its two
escape hatches are *"dispatch somebody at it"* and an `owned-state-ack:` line in the spawn
prompt; the front desk has neither, and the brief `prepare` writes is not a place a prompt line
can be added by anything the app controls.

**What this does and does not say.** It says that on this machine today a real RichOS background
dispatch reaches `spawn.py` and is refused there, for a reason about the developer's session
rather than about the CEO's work — and that the refusal text quoted above would be what the app
had to turn into a sentence for him. It does NOT say the app is broken for a user with no engine
repository: `ci-status.sh --offline` is what decided it here, and what that answers on a
different machine was not measured. Whether the engine's operator guards belong in the product's
dispatch path is not this slice's call; it is raised rather than taken.

---

## FINDING — `RICHOS_APP_SCOPE` gates EVERY tool, not the two continuity tools

Re-derived here rather than quoted from the commit that found it:

* `engine_profile.rs:235` — `.env("RICHOS_APP_SCOPE", scope)`, where `scope` is the continuity
  scope path passed to `configure`.
* `engine_profile.rs:117-119` — the engine hook is registered for nine events with
  `{"hooks":[{…}]}` and **no `matcher` key**, so its `PreToolUse` registration covers every tool.
* `scripts/app-engine-hook.py:50-53` —
  `if event == "PreToolUse": active = scope(); if active.get("actions_allowed") is not True: raise
  ValueError("This app turn is stopped or is supplying context. New actions are unavailable.")`

So deferring the grant on THAT file would not have delayed the front desk's bookkeeping; it would
have made §55's own first tool call — the register — impossible. That is why the
`richos_continuity` server reads a SECOND copy of the scope, and why the hook's file keeps exactly
the lifecycle it always had. The escalation this slice was dispatched from held that
`actions_allowed` gated the two continuity tools; it gates all of them. Raised to the ledger.

---

## Garbage (CEO §54)

**Zero `richos-*` directories in `$TMPDIR` were left by this session's runs.** Counted against a
listing taken before the first run: 761 entries appeared, 761 are gone, and the single `richos-*`
entry standing that was not in the baseline belongs to another agent's live run
(`richos-front-door-ivT8Uq`) and was left alone.

**The probe itself never leaked** — its `Scratch` drop guard removed every `richos first reply *`
fixture, including on the run that failed.

**The unit test suite did, and that is fixed** (`61aa950a`). `$TMPDIR` on this Mac holds **7,915**
`richos-*` entries and the two largest families were this crate's own test helpers: **858
`richos-skills-fixture-*`** and **818 `richos-doctrine-fixture-*`**. Measured with the same
command minutes apart:

```
one `cargo test -q -p richos-core --lib` run, BEFORE : 221 richos-* entries left behind
one `cargo test -q -p richos-core --lib` run, AFTER  :  91, none of them from native.rs
```

The 130 that disappeared are `native_driver_tests`'s own families. The mechanism, read from the
code rather than from the count: all seventeen temp-directory call sites in that module now go
through one `richos-core-test-fixtures-<pid>` directory, and a `libc::atexit` handler registered
by `fixture_root()` removes it. The counts above are consistent with that and do not by
themselves prove which line did it. **Its honest limit:** `atexit` does not run if the test binary
is killed, so a killed run leaves ONE directory instead of ~130. The remaining 91 per run belong
to other modules (`richos-worker-status-test-*`, `richos-staging-*`, `richos-provision-*`) and are
named here rather than fixed here — they are a sweep of their own.

**The standing 7,915 was left alone, and the scope of the removal is what says so:** the cleanup
loop iterated over exactly the set difference between the baseline listing and the listing after
the runs, and over nothing else. Other agents were running against the same directory at the time,
and removing 7,915 entries under them is the kind of cleanup that becomes an incident.

---

## What this record does NOT claim

* **The app was never put on screen.** No window, no `richos-tauri` process, no GUI walk — the
  probe is headless, nothing was launched, and there is no pid to report gone (CEO §54 addendum
  4). So this says nothing about what the timer beside his reply reads.
* **Nothing here was tested with audio.** No `say`, no playback, no microphone (CEO §53).
* **No worker was ever dispatched.** `prepare` reaches the spawn step and is refused there, so no
  workspace was created, nothing was registered in any worktree ledger, and the end-to-end
  background flow — worker, review, integrate — is still unmeasured by this probe.
* **The 5 ms / 6 ms gap after his words is a POLL, not a stopwatch.** It is an upper bound on
  nothing and a lower bound on the ordering: the grant was not open at his first words, and was
  within 6 ms afterwards. The unit test is what pins the order itself.
* **Two runs, not three, and the brief asked for two visible turns.** Each run also spends the
  priming turn, so the real cost is **six model turns**, not four. There is no version of this
  measurement that spends fewer: the priming turn IS the shape being measured, and skipping it
  (`RICHOS_PROBE_UNPRIMED=1`) reproduces the old defect by design.
* **Run C's failure was not predicted by anything.** It was found by a check added in the same
  slice, which is the argument for adding checks that cost no model turn to run.

## Reproducing it

```
cd richos/app
# the whole thing — three model turns
cargo run -q -p richos-core --example first_reply_timing_e2e -- \
  <path-to>/richos/engine /Users/alex/.richos-nightly/runtime

# the dispatch join alone — no lease, no provider, no model turn
RICHOS_PROBE_DISPATCH_ONLY=1 cargo run -q -p richos-core --example first_reply_timing_e2e -- \
  <path-to>/richos/engine /Users/alex/.richos-nightly/runtime
```

`RICHOS_PROBE_UNPRIMED=1` reproduces the shape where his first message pays for the priming turn,
and fails. A temp directory it removes, no audio device, no window.
