# app-voice-ci and ui-suite-ci red on main — causes, fixes, proofs

**Author:** echo-opus-ci1. **Base:** richos main `2cf3d7af630a8c585d9fe55f0d79a05186f9150c`.
**Branch:** `cc/echo-opus-ci1`. Nothing under `engine/` was touched.

Four separate faults, and none of them was broken product code. Two were documents and a
registry that fell out of step with code merged the same morning. Two were tests that timed
the CI runner instead of the thing they meant to time. Every fix keeps each assertion and
each ceiling exactly as it was.

## Two premises in the brief were off, and here is what the record shows instead

1. **ui-suite-ci did not first break at `013cbff8`.** It has been red on every main push
   since the `echo-opus-st1` merge `8cb30972` (run 34458859801, 09:07Z). The last green
   main run was `a8fe95f3` (34455966264). `013cbff8` changed nothing under `app/`.
   Source: `gh run list --repo WebDevBooster/richos --workflow ui-suite-ci.yml --limit 40`.
2. **app-voice-ci did first go red at `013cbff8`, but that commit did not cause it.**
   `git diff c1df6f24 013cbff8 -- app/crates/richos-voice | wc -l` prints `0`. The green
   run at `c1df6f24` (34462743510) and the red one (34499150632) used the same image,
   `macos-26-arm64/20260831.0337`, and the same `rustc 1.98.0 (88d9e12ae 2026-08-18)`.

Main has not moved since dispatch: `git -C /Users/alex/ab/richos rev-parse HEAD` still reads
`2cf3d7af…`, and nothing between `013cbff8` and it touches `app/` or `.github/workflows/`.

---

## 1. app-voice-ci: a wall-clock ceiling timed the runner's queue

**The log line** (run 34499150632, job `voice`):

```
30.000 s of audio ->  3453.3 ms  (1874 windows)
thread 'the_gate_costs_a_small_fraction_of_the_recognition_it_guards' panicked at crates/richos-voice/tests/voiced_acceptance.rs:296:9:
measuring 30 s of audio took 3453.3 ms against a 3000 ms ceiling — that cost is paid on every turn the CEO speaks
```

**Classification: a flake, from a difference between CI and a developer machine.** The
source was identical and the image and toolchain matched, so the only thing that changed
was load. The runner has 3 vCPUs, and this binary runs four tests in parallel. The other
three run the same autocorrelation over their own audio, and two of them also start `say`.
The workflow's own header had already named this exact test as "THE LIKELIEST FLAKE".

**The fix** (`b259d6c5`): the test now measures `VoiceEvidence::measure` with the calling
thread's CPU clock (`CLOCK_THREAD_CPUTIME_ID` via `libc`, which is already a direct
dependency, so the lockfile does not change). `measure` runs on one thread, only allocates,
and does no I/O (`voiced.rs:188-232`), so the CPU its thread uses **is** its cost. The
ceilings did not move: 3000 ms debug, 250 ms release. The wall time is still printed next
to the CPU figure. Three new controls keep the clock honest:

- it advances over a busy loop, so it is not stuck at zero;
- it advances less than 20 ms across a 100 ms sleep, so it is not the wall clock under
  another name;
- it never reads more than the wall time, so it is not the process-wide clock, which would
  charge this test for its neighbors' work in a parallel run.

**Measured on an M4 with the CI's exact compiler** (`rustup toolchain install 1.98.0`), for
the 30.000 s buffer:

| condition | CPU | wall |
|---|---|---|
| idle, whole file, debug | 1042.2 ms | 1104.7 ms |
| 9 busy loops, `--test-threads=3`, debug (3 runs) | 1355.3 / 1364.0 / 1382.7 ms | 1881.7 / 2139.8 / 1891.1 ms |
| release, alone (3 runs) | 90.1 / 79.8 / 79.0 ms | same |
| **negative control:** `taskpolicy -b` (efficiency cores only), debug | **4840.0 ms, RED, exit 101** | 4866.7 ms |

So the CPU clock stops charging time spent waiting for a core, and it still fails code that
really is slow.

**Workflow** (`4a2f1e69`): the header now records that the predicted flake happened. It
also corrects the claim "the log will carry the runner's figure", which was only true on a
red run, because libtest hides a passing test's output. A new step runs that one test
again with `--nocapture` after the gate passes, so every green run records the runner's
margin. The step reuses the binary the gate step built, so there is no extra compile.

**Local proof:**

```
cd app && cargo +1.98.0 test --locked -p richos-voice            # exit 0
  lib 206 passed, 4 ignored | barge_in_composition 15 | voiced_acceptance 4 | doc 0
cd app && cargo +1.98.0 test --locked -p richos-voice --test voiced_acceptance -- \
  --exact --nocapture the_gate_costs_a_small_fraction_of_the_recognition_it_guards   # exit 0 (the new step)
```

**What only CI can prove, stated plainly:** whether the **runner's** CPU figure clears
3000 ms, and by how much. The one runner number on record, 3453.3 ms, is wall time under
contention, so the CPU figure must be lower. How much lower cannot be measured from this
machine. `unverified:` per core, that runner looks about 2x slower than this M4 in debug
builds. That estimate divides 3453.3 ms by the 1.4-1.6x wall/CPU ratio measured under load
here, then compares the result with 1042.2 ms, and only the runner can confirm it. If its
uncontended CPU cost is near 2000 ms, the margin is about 1.5x, not the 3x the ceiling
comment assumes. The new step prints the figure on every green run from the first run
after landing. If it comes in close to 3000 ms, that is the evidence for re-deriving the
debug ceiling from the runner, which is a separate decision from this fix.

---

## 2. ui-suite-ci shard 1, docs-claims.js: two stale documents

**The log lines** (run 34499150611, shard 1; the same text since run 34462743647 at `c1df6f24`):

```
FAIL  every `cargo test -p <crate>` total in app/README.md is the tree's own total
      actual ["richos-voice: README says 210 tests, the tree has 229"]
FAIL  app/STREAMING.md documents every `rich://` event the app declares
      actual ["rich://voice-notice (declared in crates/richos-voice/src/event.rs)"]
```

**Classification: the documents were wrong and the test was right.** `echo-opus-hw1`
(`978a34ab`, merged in `c1df6f24`) added `EVENT_VOICE_NOTICE` (`event.rs:31`) and 19 unit
tests, but did not update either document. The checker counts `#[test]` on disk, and cargo
agrees: 206 + 4 ignored + 15 + 4 = 229, of which 225 run.

**Fixes:** `9f37959a` adds the `rich://voice-notice` row to `app/STREAMING.md`, adds a
fifth renderer rule explaining why the notice must not share the `voice-error` handler, and
corrects the intro's "subscribed only while the mic is open". `da75dbcf` changes the voice
figures in `app/README.md` from 210 to 229 tests, and from 206 to 225 run.

**Local proof:** `node app/ui/tests/docs-claims.js` → **exit 0**, 6 of 6 PASS
(`richos-core=985+5 richos-voice=229+0`; `20 declared event names, all documented`).

---

## 3. ui-suite-ci shard 3, affordances.js: five CEO-facing strings nobody classified

**The log line** (run 34499150611, shard 3), shortened:

```
FAIL  every derived state is classified, and every classification is a real state
      actual ["I couldn't work out how fast this machine hears, …  <- app/crates/richos-voice/src/hardware.rs:375",
              "I'm using my faster hearing on this machine. …      <- …/hardware.rs:362",
              "I'm using my lighter hearing on this machine — …    <- …/hardware.rs:369",
              "RichOS could not open   <- app/src-tauri/src/startup_alert.rs:150",
              "RichOS ran into an unexpected problem while starting up … <- …/startup_alert.rs:155"]
FAIL  POSITIVE CONTROL: an unclassified new state IS flagged      (the same strings, as a knock-on)
```

**Classification: the registry was missing rows and the test was right.** The scrape
treats every `ceo_message()` literal, and every `const …: &str` in the Tauri command layer,
as CEO-facing by rule. `echo-opus-st1` (`b052f0b0`) added the two startup constants, and
`978a34ab` added the three `Resolution::ceo_message()` sentences. Neither added rows.
`978a34ab`'s own message says "app/ui/tests is untouched".

**Fixes:**

- `27ce4e26`: the three hardware sentences are **INFORMATIONAL**, following the
  `SoundButNoWords` precedent. The product made a choice and says so, the sentences ask
  nothing, and no setting overrides the choice. The only lever is turning voice off and on
  with ◉, which re-runs resolution, and that control is already on screen. None of the
  three matches the suite's `IMPERATIVE` check.
- `52851406`: the two startup constants are **NOT-RENDERED**, which is the bucket's literal
  definition ("never reaches the DOM"). They appear in a `CFUserNotificationDisplayAlert`
  only while no window exists. The section note says plainly that the person **does** read
  them. It also records, for a reviewer to check, how the rule's question is answered on
  that native surface: the alert has "OK" and "Show Details", and "Show Details" reveals
  `~/Library/Logs/RichOS/startup.log` (`startup_alert.rs:492-499`). The note also dates the
  nine `update_startup` rows above it. Their "stderr and return" wording was written before
  st1 routed that call site through `cannot_start` with exit 1.

**Local proof:** `node app/ui/tests/affordances.js` under Playwright 1.61.1 WebKit
(`npm ci` from the committed lockfile) → **exit 0**, 86 PASS, 0 FAIL, "the affordance rule
holds". INFORMATIONAL went from 112 to 115 and NOT-RENDERED from 27 to 29. With only
`27ce4e26` applied, the suite was still red on exactly the two startup strings. That was
checked, not assumed.

**One gap found and not fixed here:** the scrape cannot see the person sentences passed
inline to `startup_alert::cannot_start` at `main.rs:934` ("RichOS stopped before it could
open a window…") and `main.rs:969`, or the text `person_message` appends. They are
arguments, not a `const`, an `Err(`, or a `ceo_message()`. The scrape lives in
`lib/state-strings.js` and widening it is a separate change, so it is reported here.

## 4. coverage job: follows from the other failures

`coverage` failed at "Every suite accounted for, by name, at one commit" only because two
suites came in red: `2 suite(s) FAILED: affordances.js, docs-claims.js`, with 31 of 31
receipts present. Nothing else was wrong with it.

---

## 5. An intermittent that would have turned this red again: splash.js check 8

It was not red at `013cbff8`, but it failed on run 34471797325 (main, `dc6b7965`) and
34451068719 (`tom-opus-ui1`):

```
FAIL  8  the ceremony is cut, the mark never is — and the bar is pinned FULL
      page.evaluate: TypeError: null is not an object (evaluating 'n.querySelector')
```

**Classification: a race in the test, not a product fault.** `yieldNow` pins the surface
synchronously, then removes `#splash` `FADE_MS + 40` = 180 + 40 = **220 ms** later. The
check pressed a key, then made a **second** Playwright round trip to read the surface. On a
busy runner that round trip can arrive after 220 ms.

**The fix** (`ee49dc29`): before the key press, the test adds a capture-phase `keydown`
listener to `window`. It is registered after `splash.js`'s own listener on the same target,
so it fires in the same dispatch, right after the pin. Every assertion is unchanged.

**Proven by mutation, running the whole of `splash.js` each time:**

| variant | result |
|---|---|
| original check + a 400 ms harness delay after the press | exit 1, **the CI error, word for word** |
| fixed check + the same 400 ms delay | exit 0, check 8 PASS |
| fixed check + the product's `settleBar()` removed | exit 1, "the bar was left standing at a fraction on the way out" |
| fixed check, unmutated | exit 0, 28 PASS |

The product file was restored byte-identical (checked with `cmp`), and the screenshots the
runs re-rendered were thrown away.

## 6. A known intermittent left unchanged on purpose: scale.js's 90 ms budget

Run 34458859801 failed "ONE new activity row does not rebuild the thread" at **101 ms
against a 90 ms budget**. The JavaScript half passed its own 20 ms budget in that run, so
turn reuse was working, and the time went to WebKit layout. Across ten recent runs the
runner measured 40, 67, 38, 101, 70, 52, 45, 60, 53 and 60 ms, and this machine measures
22 ms. So it fails about 1 run in 10. The regression the check exists to catch measured
257 ms. I **did not** change the budget. Raising it would weaken a number someone set from
evidence, and the node-identity check next to it already proves the property. Whether to
calculate this budget from the runner's numbers is a call for its owner. This record gives
them the data.

## Full UI suite in CI's shape, at `ee49dc29`

```
cd app/ui/tests && npm ci
node run.js --shard=N/5 --receipts=<dir>      # N = 1..5, each exit 0
node run.js --coverage=<dir>                   # exit 0
✓ ui-suite: 31/31 discovered suite(s) ran, all green, all at ee49dc299b44d496d6c319ddb50857c8a5c0856f.
  554 checks observed. serial cost 734 s across 5 shard(s).
```

That is local WebKit on macOS 15.6 (arm64). The runner is `macos-26-arm64`. A green
**ui-suite-ci** and **app-voice-ci** on the landed SHA is evidence only CI can produce.

## Tool settings this touched, per the rule on third-party defaults

- **libtest output capture:** left at its default in the gate step, and overridden with
  `--nocapture` in the one new step, because the default hides the only number that step
  exists to print.
- **libtest `--test-threads`:** left at its default on purpose, for the reason the
  workflow already gives: running the suite on one thread would remove the only check that
  the `say` output-path race fix still holds. The CPU clock is what makes that
  parallelism safe for the timing test.
- **`CLOCK_THREAD_CPUTIME_ID`:** a deliberate choice of clock, not a default. Clock id 16
  in both the macOS SDK and `libc` 0.2.189.
- No Playwright, WebKit, cargo profile or Rust toolchain setting was changed.
  `rustup toolchain install 1.98.0` was used only locally, to match the runner's compiler.

## Commits, oldest first

```
9f37959a STREAMING.md documents rich://voice-notice
b259d6c5 The gate's cost is the recognizer thread's CPU time — ceilings unchanged
4a2f1e69 app-voice-ci records the flake it predicted, prints the margin on a green run
da75dbcf app/README.md: richos-voice is 229 tests (225 run, 4 ignored), not 210
27ce4e26 Classify hardware.rs's three voice notices: INFORMATIONAL
52851406 Classify the startup alert's two constants NOT-RENDERED
ee49dc29 splash check 8 reads the pinned surface inside the keystroke
```
