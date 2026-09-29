# Load-sensitive checks in the nightly gates: audit, 2026-09-29

Author: Tom (QA automation), worktree `cc/tom-opus-loadaudit1`, base `74393583`.
Method: a static read of everything the eight gates in `richos/app/scripts/nightly-local.py`
(`GATE_NAMES`, line 371) execute, plus the run logs still on disk. No nightly, UI suite,
mutation pool or broad suite was run. The only things executed were two `ui-ledger.test.py`
methods (about 11 s each, for the one fix below) and read-only file counts.

The CEO's words this is measured against (2026-09-29): *"WHAT IS THE CAUSE OF ALL THIS
RETARDED FUCKSHIT???? FIX AND STOP THE RETARDED FUCKSHIT!"* So every entry names the cause and
a fix that keeps what the check proves. None of them is "retry" or "raise the number".

---

## 1. The cause, in one paragraph

Every failure below has the same shape: **a check turns the speed of the Mac into a fact about
the product.** It does that in one of five ways: (a) an assertion on measured wall time
(`took < 2000`); (b) a fixed deadline on real work, or on a wait that also contains QUEUEING
for a machine worker token; (c) a sleep used as synchronization, followed by an assertion
that the thing has happened; (d) a race against a clock the page or the product runs on its
own; (e) state shared across gates that run side by side (one checkout, one worker budget).
An idle Mac hides all five; the nightly with `--gates-at-once all` is exactly the load that
exposes them. Section 5 is the rule that stops new ones.

## 2. What the logs still show (re-derived, not copied from the brief)

`~/.richos-nightly/logs/` keeps five runs. Two of the seven the brief lists are gone:
`20260928T224842Z-c3cce554` (item 1, proof-for-engine) and `20260928T230511Z-20aa349a` (item 2's
first occurrence). Neither is on disk (`ls ~/.richos-nightly/logs`, and no file under
`~/.richos-nightly/runs/` names either id). Item 1's "45 s subprocess timeout" is therefore the
brief's account, **unverified** here; the code matches it (entry R4).

| Run | Gate | What the log says |
|---|---|---|
| `20260928T233221Z-56bcde43` | ui-suite | `FAILED gates/ui-suite after 699.0s ... home.js (exit 1, 1 failed check(s))` (log line 5489). **Which check is not in the log:** no home.js PASS or FAIL line is present at all. |
| `20260928T235444Z-5610331e` | ui-suite | The log ends at line 5481 (`=== phase gates/ui-suite ends: 595.5s ===`) with no verdict line; the last shard line is cut mid-line by a `richos-nightly-log-sync-...` sentinel. The home.js check is not recoverable from this log either. `843bc1f5` ("failed UI checks name themselves; blocking stdio keeps the sharded log whole") addresses this for future runs. |
| `20260929T003824Z-01545196` | (passed, published .30) | Line 7334: `could not check whether the UI suite left its checkout dirty: gates/ui-suite timed out after 30s`. A 30 s `git status` timed out. Entry R3. |
| `20260929T043716Z-706417af` | updater-tests | `WouldBlock: "another RichOS session is running"`, 2 tests (lines 154-161). Echo's item; excluded. |
| `20260929T044015Z-588457c3` | ui-suite | navigation-evidence check 2: `topUnavailable: "spawnSync /usr/bin/top ETIMEDOUT"`, with `loadavg [13.041, 8.539, 4.648]`, 10 cores, **`freeMemBytes` 432,799,744 of 25,769,803,776** (line 4152). Zach's item; excluded. The same sample shows the Mac was under memory pressure as well as CPU load. |

Measured head-room of checks that PASSED in these logs (grep of the run logs):

| Check | Bound | Used | Share of bound |
|---|---|---|---|
| memory-strategy.js `Working for 18s` window | 1,000 ms of real time | 301 ms, 324 ms | 30-32% |
| home.js "admitted it in N ms" | 2,000 ms | 247 ms, 318 ms | 12-16% |
| navigation-evidence.js check 4 `collectionMs` | 15,000 ms | 4,004 / 8,582 / **10,031 ms** | up to **67%** |
| navigation-evidence.js check 2 rejection | 1,500-2,500 ms window | 1,504.8 ms | inside |
| gates/privacy-sweep (gate budget) | 120 s | **82.3 s** (only sample) | **69%** |
| gates/workspace-mutants (gate budget) | 3,600 s | 1,816.8 s | 50% |

Gate durations across the five logs (`phase gates/... ends:`): ui-suite 595-690 s of 3,300;
script-suites 357-640 s of 6,900; core-tests 64-79 s of 300; updater-tests 14-29 s of 360;
lint-tauri 5-11 s of 300; release-smoke 1-2.3 s of 60.

---

## 3. The ranked list

Rank is my estimate of how likely the check is to fail on a busy Mac while the product is
fine, from the head-room measured above, how often the check runs, and how much load sits
between its two timestamps. "Proves" is what the check must keep proving after the fix.

### R1. home.js — three wall-clock windows in one suite (the two unexplained home.js failures)

Not being fixed by anyone. The failing check in runs `56bcde43` and `5610331e` is not in
either log (section 2), so these are the candidates, most likely first:

**R1a. "the temporary line" check, `richos/app/ui/tests/home.js:1728-1771`.**
- Assumption, stated in its own comment (lines 1716-1727): the check's driven cycle is 4,750 ms
  deterministic "plus whatever a dozen or so `page.evaluate`/`waitForFunction` round trips cost
  on top of that — not separately measured here", and **1,250 ms of margin** covers those
  round trips before the field's OWN auto-ingest clock fires a second line. Its validation was
  "five consecutive green" runs.
- Under load: round trips that take tens of ms idle take hundreds; the page's own timers keep
  running. The 1,250 ms margin is spent, a second auto-fired line lands inside the drive, and
  the check reads "after" during it: `the line is still up, so 'after' is not after anything`
  or a hush mismatch. The comment records that exact failure on the version before.
- Also in the same check, `home.js:1749`: `waitForFact(..., NO_LABELS_UNDER_IT, 1500)`. The
  derivation (lines 1742-1747) is **frame-based**: 18 frames "= 300ms at 60fps". Under load,
  requestAnimationFrame drops far below 60 fps, and 18 frames exceed 1,500 ms of wall time.
- And `home.js:1755`: `waitForTimeout(900)` then read "after", betting on a gap in a
  "4s-ish cadence".
- Fix that keeps the proof: take the page's clock out of the race. Playwright 1.61.1 (the
  pinned version, `ui/tests/package.json:12`) ships `page.clock`: install it before the page's
  scripts run, drive the field with `page.clock.runFor(ms)`, and the auto-ingest clock, the
  spark, the 2,600 ms line life and the label fade all advance only when the check says so.
  Then "before / during / after" are read at exact virtual instants and nothing depends on
  round-trip cost. If the fade must stay frame-driven, wait on the fact (labels gone) with a
  hang guard, and assert the fade's length in FRAMES (`window.__loro.frames` delta), not ms.

**R1b. `home.js:2800-2824`, `assert(took < 2000, ...)`.**
- Proves: a shader failure the engine KNOWS about is reported through `__loroFailed`, not by
  waiting out the 8,000 ms backstop.
- Assumption: page load plus degrade under 2 s. Idle measured 247-318 ms.
- Under load: a WebKit page load can take several seconds; the check fails although the
  engine reported its own failure.
- Fix: prove the path, not the speed. `r.failed` (line 2823) already shows the engine
  reported. Add the discriminator the 2 s bound stands in for: record which path settled the
  surface (a flag set by the report path vs the timeout path), or install `page.clock` and
  assert the degrade happened with virtual time never advanced to 8,000 ms. Drop `took < 2000`.

**R1c. `home.js:2241-2268`**: `waitForTimeout(1200)` then `r.frames - framesAt < 30`, then
`waitForTimeout(1500)` then frames unchanged. The frame counts are load-dependent in both
directions; the first bound mixes wall time and frame rate. Fix: assert `running === false`
(already read) and then that frames do not change across two observations separated by a
fact (N more rAF ticks of a probe loop), not by 1.5 s of wall time.

### R2. memory-strategy.js — a 1-second real-time window across a send and two checks

- `richos/app/ui/tests/memory-strategy.js:57` `ANCHOR_18S = 18600`; `:131-137` anchors the
  scenario at `Date.now() - 18600` when the brief is sent (`:318`); `:379-386` then requires the
  live row to read exactly `Working for 18s` and `Date.now() - startedAt` in [18000, 19000).
- Assumption: the send, the two checks between (`:320`, `:364`) and the read all finish within
  1,000 ms of real time. Measured 301 and 324 ms in passing runs.
- Under load: past 1,000 ms the live clock reads `Working for 19s`; both assertions fail.
- Fix: the harness already has `pinClock`/`unpinClock` (`lib/harness.js:536-557`) and this file
  imports them (`:45`). Pin `Date.now` at `anchor + 18600` for the send-to-read span, or use
  `page.clock`. The check keeps its title's promise ("injected, not waited for") on any Mac.

### R3. Every gate budget, and the 30 s cleanup, include machine-token queueing

- `nightly-local.py:986-1013` `Runner.command` runs everything through `owned_run`
  (`:172-197`), which wraps the command in `worker_tokens.py machine` and applies the timeout
  to `process.communicate` (`:196`). `worker_tokens.py:484-551` `machine_command` waits in
  `Budget.acquire` (`:182-215`, up to 1,800 s) for one of the machine's
  `int(0.8 x cores)` = 8 tokens (`:384`; `~/.richos-nightly/worker-budget-v1/capacity.json`
  reads 8) BEFORE the command runs. So every `GATE_BUDGETS` entry (`:40-72`) and
  `CLEANUP_TIMEOUT = 30` (`:73`) is spent on queueing plus execution. The budgets' own
  comments derive them from execution samples only.
- Observed: run `01545196`, line 7334, the UI gate's `git status --porcelain` cleanup
  (`:1286-1290`) "timed out after 30s" while workspace-mutants' eight-worker pool was running.
  That `git status` itself took 30 s on a clean tree is **unverified**; queueing behind the
  pool is the mechanism the code allows. The build-breaking consequence is written in
  `:1263-1266`: a tree left dirty makes the NEXT nightly refuse to start.
- At risk the same way: `gates/privacy-sweep` (120 s, `:71`; measured 82.3 s, 69%, and it starts
  while workspace-mutants is still running), `gates/lint-tauri` (300 s, starts after
  script-suites while the mutation pool and UI shards hold tokens), `gates/release-smoke` (60 s).
- Fix: the one ci-shard already has. `ci-shard.sh:586-587`: "Admission waits do not spend the
  unit's execution deadline". Pass `--timing` from `owned_run`, start the budget clock when
  `worker_tokens` reports the token acquired, and log admission and execution separately on
  the gate line. For cleanup commands (`cleanup=True`): do not take a worker token at all, a
  `git status` is not a CPU worker; or give cleanup its own reserved token.

### R4. proof-for-engine.test.py — a 45 s wall clock around a real engine run (brief item 1)

Not being fixed by anyone.
- `richos/app/scripts/proof-for-engine.test.py:36-44` runs a generated `ci-shard.sh` command
  under `subprocess.run(..., timeout=45)`; `:46-53` points it at the real
  `scripts/locate-engine.test.sh`. Also `timeout=30` (`:29`, `:58`, `proof-for.sh` over the
  whole tree) and `timeout=15` (`:70`).
- Assumption: ci-shard's setup (inventory, `git status` leak-canary baselines of the whole
  checkout and the engine, `leak-canary.sh:113-116`, twice per unit) plus the unit (weight
  8.4 s on a Linux runner, `lib/ci-unit-weights.tsv:233`) fit in 45 s.
- The unit's OWN deadline is `max(900, 3 x 8.4)` = 900 s (`ci-shard.sh:172-174`, `:541`). The
  test's 45 s is 20 times tighter than the harness it exercises, and it is the only clock that
  fires.
- Under load: a Python unittest child, a bash ci-shard, two `git status` passes over a 9,109-file
  checkout and the unit itself exceed 45 s. (Inside the nightly this run inherits the suite's
  token, `worker_tokens.py:491-508`, so the 45 s is execution, not queueing.)
- Fix: the property is "the selector's command runs a real suite and returns PASS". Give the
  subprocess no tighter clock than the unit's own deadline: `timeout=None` and let ci-shard's
  900 s per-unit deadline (which reports TIMED-OUT by name) be the hang guard, or derive the
  test's timeout from `deadline_for` plus a fixed setup allowance. Same for `:29`, `:58`, `:70`,
  and the siblings in R13.

### R5. Leak canaries watch the nightly checkout while the UI gate rewrites files in it

- `nightly-local.py:1417-1422` runs workspace-mutants as
  `ci-shard.sh --only-units ...workspace-spec-fourteen.test.sh` with `cwd` = the nightly checkout.
  `ci-shard.sh:519-520` watches `$PWD` (the whole checkout) and the engine for the unit's
  entire run (1,097-1,817 s measured), and `:626-627` turns any new or changed `git status`
  line into a LEAKED verdict, which fails the gate.
- The UI gate runs at the same time (`GATE_AFTER`, `:383-390`, lists no dependency between
  them), and `nightly-local.py:1259-1273` documents that it REWRITES committed screenshots in
  that same checkout when a picture differs (measured 2026-09-20: two files rewritten on one of
  two identical runs).
- Under load: shard timing changes which pictures differ, a screenshot is rewritten mid-run,
  and workspace-mutants (or any script suite that runs ci-shard from the checkout root, e.g.
  R4's test with `cwd=ROOT`) is failed as LEAKED for a file it never touched. No LEAKED verdict
  is in the five retained logs; this is **latent**, ranked on the documented drift.
- Fix: the UI gate must not write into the tree other gates are watching. Point
  `publishShot`'s rewrite at a directory outside the checkout when running under the nightly
  (the receipts directory already is), and report drift from there; or have ci-shard watch
  only the engine root when `--only-units` names a unit that runs in its own sandbox. Either
  keeps the canary's proof (this unit wrote nothing it should not have).

### R6. navigation-evidence.js checks 3 and 4 (siblings of Zach's check 2)

- `richos/app/ui/tests/navigation-evidence.js:183` (check 3): `b.elapsedMs >= 1200 && b.elapsedMs < 2200`.
  The upper bound says Playwright's rejection arrived within 1 s of its own deadline; a
  stalled Node event loop or WebKit process delays it.
  Fix: keep the lower bound (it proves the page default decided); prove "the page default
  decided" from the recorded `options: null` and the rejection message `Timeout 1200ms
  exceeded`, which the check already asserts (`:180-182`), and drop the upper bound.
- `:204` (check 4): `b.collectionMs < 15000`, measured at **10,031 ms** under load (67%). The
  collection includes the `top` host sample (`lib/navigation-evidence.js:486`) and a
  `git rev-parse` with `timeout: 2000` (`:467`).
  Fix: the property is "a wedged page cannot hang the collection". The wedged fixture never
  yields, so completion itself proves boundedness. Assert that each sub-step reported its own
  deadline (`dom.unavailable`, `screenshot.unavailable`, already read) and replace 15 s with a
  hang guard derived from the sum of the collector's own internal deadlines.
- Zach's check-2 fix will remove the `top` dependency; check 4's total shrinks with it.

### R7. ui-ledger.test.py — overlap of two node processes inside 1.5 s (FIXED, `6bdca670`)

- Was `richos/app/scripts/ui-ledger.test.py:230-267` at `74393583` (added by `442a1c87`, in
  `843bc1f5`): three shards each slept 1,500 ms, and "two ran at once" was the overlap of their
  wall-clock spans. A second node process slower than 1.5 s to reach its first line made a
  correct budget read "1 shards ran at once".
- Fixed on this branch, test code only: shards mark themselves live and rendezvous on a start
  marker (bounded at 60 s), then stay live 1.5 s so a breach would still be counted
  (`ui-ledger.test.py:230-303` now). New test
  `test_the_budget_proof_does_not_depend_on_how_fast_a_shard_starts` (two shards take 2 s to
  start): **red** with the old fixture (`AssertionError: 1 != 2 : 1 shards ran at once on a
  budget of two worker tokens`), **green** with the new one (`Ran 2 tests in 11.487s, OK`, run
  once). Negative control: the same fixture on a three-token budget counts 3, so the existing
  assertion still fails a breach.

### R8. workspace-spec-fourteen: a signal race and two sleeps as synchronization

In `richos/engine/mega-lander/tests/workspace-spec-fourteen.test.sh`, the suite the
workspace-mutants gate runs:
- `:809-814` C9.6a: starts `python3 -c "signal.signal(SIGTERM, SIG_IGN); time.sleep(3600)"`
  in the background, then (after one hook call, `:810`) sends SIGTERM, `sleep 0.3`, and
  asserts the holder is still alive. Under load, Python has not reached `signal.signal`
  when SIGTERM arrives; the default action kills it and the POSITIVE CONTROL fails.
  Fix: the fixture writes a ready file after installing the handler; wait for that file
  (bounded) before sending TERM.
- `:792-795` C9.3 and `:816-822` C9.6: after the land returns, `sleep 0.3`, then `kill -0` must
  say dead. The holder was re-parented to launchd, which reaps it; under load the zombie can
  outlive 0.3 s and `kill -0` still succeeds.
  Fix: poll until `kill -0` fails or `ps -o stat= -p PID` shows `Z`, with a hang guard of tens
  of seconds; the proof ("the land stopped it") is unchanged.
- `:117` exports `RICHOS_WORKSPACES_STOP_GRACE=1`: the product gets one second between TERM
  and KILL. That is the product's own escalation, so a slow exit is still stopped by KILL;
  noted, not ranked.

### R9. Rust core-tests: wall-clock bounds a few seconds from what they distinguish

`cargo test -p richos-core` runs test threads in parallel in one process; all of these read a
wall clock around real child processes or threads (every line is inside `#[cfg(test)]` or `tests/`):

| File:line | Bound | What it distinguishes | Fix that keeps the proof |
|---|---|---|---|
| `src/native.rs:4198-4200` | `< 1 s` | returned at the question vs. after the fixture's `sleep 3` (`:4189`) | make the fixture block until the test releases it (a FIFO read); returning at all then proves it; keep a hang guard of tens of seconds |
| `src/native.rs:4222-4227` | `< 1 s` | same shape | same |
| `src/native.rs:5642-5646` | `< 2 s` | stop honored vs. handshake completing | fixture handshake never completes unless released |
| `src/operator_runtime.rs:651-655` | `< 1 s` | question recorded without waiting | same shape |
| `src/permissions.rs:684-687` | `< 1 s` | vs. a 3 s wait deadline passed on `:685` | pass an unbounded or very long wait so any completion proves "did not wait" |
| `src/app_workers.rs:219-223` | `< 3 s` | refused while the lock is held | assert the typed result; the lock never frees, so returning proves it |
| `src/quota/probe.rs:257-260` | `< 2 s` | stop kills a `time.sleep(60)` child | the child sleeps 60 s, so a 20 s hang guard still discriminates |
| `src/quota/gate.rs:258` | `recv_timeout(1 s)` | wake after publish | 20-30 s hang guard; the wake itself is the proof |
| `src/quota.rs:730` | `recv_timeout(2 s)` | monitor woken | same |
| `tests/deferred_send_tests.rs:262` | `< 1 s` | its own comment (`:257-261`): the latch cannot release, so "anything that completes at all here completed without waiting" | delete the bound; it proves nothing the completion does not |
| `tests/questions.rs:656-665` | `< 1 s` | bounded ask with a 100 ms budget | 10 s hang guard |
| `tests/native_cancel_tests.rs:131, 161` | env var | `set_var("RICHOS_CANCEL_GRACE_MS", "300")` without a guard, while the compliant-agent test (`:96-126`) runs in parallel in the same binary and reads the grace (`src/native.rs:604`) | a 300 ms grace for a bash fake agent under load turns a clean cancel into "unacknowledged"; serialize with a static `Mutex` as `tests/worker_attribution_tests.rs:35` already does, or pass the grace as a parameter |

`tests/steering_tests.rs:259, 588, 636` (`< 5 s`) and `src/work_host.rs:4776` (`< 10 s`)
have more head-room; same class, lower rank.

### R10. UI suites: sleep, then assert that something HAPPENED

A `waitForTimeout(N)` followed by an assertion that an effect is present fails under load; the
same pattern asserting ABSENCE only passes falsely and is the lower risk. Presence cases:
- `restart-scope.js:290, :303, :386, :408`: `waitForTimeout(700)`, commented
  "> PARK_DEBOUNCE_MS", then reads `localStorage`. `PARK_DEBOUNCE_MS = 400`
  (`richos/app/ui/main.js:294`): 300 ms of slack for a timer to fire and write.
  Fix: `waitForFunction` on the stored value.
- `restart-scope.js:182-203`: `waitForTimeout(1400)` then `seconds2 > seconds`. A delayed
  tick timer reads the same second. Fix: wait for the row text to change, bounded.
- `restart-scope.js:434, :447, :470, :636` (2.5-3 s sleeps, then assert a turn rendered),
  `techy.js:427, :571, :634, :643, :652`, `retention.js:188-264` (150-200 ms, then assert the
  hint text), `operator-notice.js:295`, `escape.js:448, :488, :498, :587`, `setup.js:1078,
  :1242, :1264`. Fix for all: wait on the fact the next line asserts.
- `setup.js:417-435`: counts rAF samples over a window ending in `waitForTimeout(400)` and
  asserts `tops.length > 5`. Fix: wait until the sample count reaches 6 (bounded), then assert.
- `memory.js:278, :322, :358` (400 ms) and `phone.js:1821, :1906, :2181, :2386` follow the
  same pattern where the next line reads state.

Engineers in this directory have already fixed this class one site at a time
(`lib/harness.js:405-409`: "`waitForTimeout` after it would be the same bet on the machine this
directory keeps losing"). The rule in section 5 is what makes the rest converge.

### R11. Harness helpers that time out SILENTLY and hand a wrong state to the caller

- `ui/tests/lib/harness.js:1019-1028` `leaveHome`: if `window.RichHome` is not defined within
  5,000 ms it returns `false`, and a caller that ignores it asserts on the wrong surface.
- `:414-430` `parkPointer` (2,000 ms, `.catch(() => {})`) and `:365-383` `awaitSettled`
  (2,000 ms cap, then resolves): under load the shot is taken hovered or mid-fade and a pixel
  comparison fails far from the cause.
- Fix: keep the bound as a hang guard, but a helper that gives up must say so: throw (or
  return a reason every caller checks), so the failure names the wait that ran out.

### R12. lint-tauri: a 180 s cap that includes waiting for Cargo's lock

- `richos/app/scripts/lint/driver.py:128-139`: Tauri Clippy's deadline is 180 s "including
  Cargo lock waiting". In the nightly it runs after script-suites (`GATE_AFTER`), so today it
  hits a warm target (4-11 s measured). A cold target (a dependency bump) while another
  builder holds the `src-tauri/target` lock would spend the cap waiting. Fix: start the 180 s
  when Cargo reports it holds the lock (Cargo prints "Blocking waiting for file lock"), or
  exclude lock waiting from the cap, as ci-shard excludes admission.
- `lint/test_execution.py:27` (run by `lint.test.sh`, script-suites): a Python child must
  start, take a released `flock` and print within `timeout=2`. Under memory pressure Python
  start alone can exceed that. Fix: 30 s hang guard; the preceding `timeout=.2` line (`:26`) is
  the real assertion and is safe under load (it expects the timeout).

### R13. Other fixed subprocess timeouts around real work in script-suites

Same class as R4, lower head-room risk, same fix (no clock tighter than the work's own
deadline; hang guards at tens of seconds):
`proof-for.test.sh:352-353` (15 s around a generated command), `proof-for-declarations.test.py:72,
:203` (15 s, `proof-for.sh` over the tree), `claude-quota.test.sh:129, :143`
(`communicate(timeout=5)` on a hook), `terminal-quota.test.sh:19-45` (10 s each),
`native-ios-lock.test.py:38, :55` (5 s), `nightly-local.test.py:485-486` (asserts cleanup
finished within 22 s: correct direction as a hang guard, but it is an upper bound on a
loaded Mac), `proof-run.test.py:399-475` (10-60 s waits on real runners).

### R14. Latent: will turn into failures on the day something else changes

- **The worker budget counts processes, not memory.** `worker_tokens.py:384` sizes the machine
  budget at 80% of cores. The failing sample in `588457c3` shows 432 MB free of 24 GB. Four
  WebKit shards, an eight-worker mutation pool and Cargo fit the token count and not the RAM;
  swapping is what makes process start (R4, R7, R8, R12) take seconds. A memory dimension in
  the admission (the CPU guard already reads memory pressure for `reserve.py`) would remove
  load at the source instead of in each check.
- **CPU-guard admission inside tests.** `worker_tokens.py:134-138` consults
  `cpu_guard.verification_admission()` for every non-inherited acquire. Today
  `/Volumes/E1TB/state/richos/cpu-guard/` has no `verification-enabled.json`, so it returns
  nothing. If that policy is installed, every test that runs a real `worker_tokens` acquire
  without inheriting a slot waits on the REAL machine's CPU pressure inside its own fixed
  timeout. The tests already isolate `RICHOS_MACHINE_WORKERS`; they should isolate
  `RICHOS_CPU_GUARD_STATE` too (`runner-reliability.test.py:408` does).
- **Sibling of Echo's WouldBlock (flock inherited across fork).** `richos-core` has the same
  lock shape in `src/operator_claim.rs:276-318` (`ClaimLock` drops without `LOCK_UN`) but no
  `pre_exec` anywhere in the crate, so its children are spawned without a fork window today.
  The day a `pre_exec` is added, it becomes the updater bug. `src/quota/resets.rs:256-258`
  already unlocks explicitly before close; `ClaimLock` should do the same.

### Excluded, as the brief directs, with siblings noted

- navigation-evidence check 2 (Zach, `zach-opus-navflake1`): siblings are R6 (checks 3 and 4).
  The `top` sample itself (`lib/navigation-evidence.js:486`) runs on every failed navigation in
  every UI suite, but only check 2 asserts on it.
- richos-user-update WouldBlock (Echo, `echo-opus-wblock2`): sibling in R14 (`ClaimLock`).
- Not in any gate: `richos/app/scripts/native-responsiveness.test.py` has `loop_ms < 500`,
  `stopMs < 500`, `t < 1000` and `t < 2500` wall bounds (`:192-198`), but no `*.test.sh` runs
  it (grep over `app/scripts/*.test.sh` finds no caller). If it is ever wired in, it is R1-class.

---

## 4. Order of work (by likelihood x cost)

1. R3 (deadlines exclude admission) and R2: small, mechanical, and R3 covers every gate.
2. R1 (home.js on `page.clock`) and R4 (proof-for-engine clock).
3. R5 (UI gate stops writing into the watched checkout).
4. R6, R8, R9, R10, R11 by owning suite; R12-R14 as their areas are next touched.

---

## 5. The rule that stops the class from coming back

**The rule:** *a test may bound TIME only to catch a hang, never to decide a verdict; and a
deadline measures execution, never queueing.* Every wall-clock bound in a check is either a
hang guard, at least 10x the measured execution and outside any assertion, or it is
declared, with the reason it cannot depend on host load (for example: it runs on a virtual
clock).

**Where it lives: the lint that already exists for this, extended.**
`richos/app/scripts/lint/` already carries a blocking, baselined rule of the same kind
(`timeout-success`, `timeout_rules.py`; `test-retry` is its advisory cousin, `lint/README.md`
rules table), runs on every land in `lint.test.sh` and every nightly in `gates/lint-tauri`, and
has the ratchet machinery (`baselines/`, `--lower`, refusal of a raised ceiling against
`refs/heads/main`). A new module `lint/load_rules.py`, registered in `driver.py` `RULES` like
`timeout_rules`, with these blocking IDs:

| ID | Refuses, in test code (`*.test.sh`, `*.test.py`, `ui/tests/**/*.js`, `#[cfg(test)]` and `tests/*.rs`) |
|---|---|
| `wall-clock-verdict` | an assertion comparing a measured duration (`Date.now()`/`performance.now()` difference, `Instant::elapsed`, `time.monotonic()` difference, `$SECONDS`) against an upper literal |
| `short-deadline` | a literal deadline under 30 s on a wait for real work: `subprocess` `timeout=`, `.wait(timeout=)`, `communicate(timeout=)`, Playwright `timeout:`, `waitForFact(..., N)`, `recv_timeout`, `Instant::now() + Duration` |
| `sleep-then-assert` | `waitForTimeout(N)`, `time.sleep(N)`, `sleep N`, `thread::sleep` followed, before any condition wait, by an assertion |
| `host-sample` | `/usr/bin/top`, `os.loadavg`/`getloadavg`, `vm_stat`, `memory_pressure`, `uptime` executed (not mocked) in test code |
| `env-mutation-unguarded` | `std::env::set_var`/`remove_var` in a Rust test without a static guard in the same file |

A site is exempt only by a declaration on the line or the line above:
`load-bound: <why this cannot depend on host load>` (for example
`load-bound: virtual clock, page.clock installed at :NN`), the same "declare it where a reviewer
sees it" discipline as the dialect exemptions. A bare marker exempts nothing.

**Two changes to the existing machinery are needed, and both are the lint owner's call:**
1. The JavaScript scan is advisory today ("`ui-absence` | Advisory, JavaScript report only"). The
   UI suite is where R1, R2, R6 and R10 live, so these IDs must be blocking for
   `ui/tests/**/*.js`.
2. The ceilings are counts, and the README says why that is weak: "fixing one and adding
   another can leave the same count". For these IDs, baseline the SITES (file plus a hash of
   the normalized line) rather than the count, so any NEW site fails even while an old one is
   being removed. The existing sites from section 3 go into the initial baseline and are paid
   down; nothing new gets in undeclared.

**The engine side.** workspace-spec-fourteen (R8) and ci-shard live in `richos/engine/`, which
this lint's inventory does not cover (it scans `app/`). The same `load_rules.py` should be run
over `richos/engine/**/tests/` by whatever lints engine suites; I did not find that entry point
in this pass, so where it plugs in on the engine side is open.

**The runtime half of the rule** is R3's fix and belongs in the runner, not a lint: `owned_run`
starts every gate's clock at admission and prints admission and execution on the gate line, as
`ci-shard.sh:586-605` already does per unit. After that, a gate budget can only be exceeded by
the gate's own work.

---

## 6. Committed on this branch

| SHA | What |
|---|---|
| `6bdca670` | R7 fixed: `richos/app/scripts/ui-ledger.test.py`, test code only, with its new test red on the old fixture and green on the new one, run once, plus a negative-control run. |
| (this file) | The audit. |

Nothing else was changed. The other entries each need either a product-side read I did not do
here (R1's `page.clock` against the field engine, R3's runner change) or a run heavier than
this pass allows (R8 and the Rust suites), so they are left as findings with their fixes, not
as untested edits.
