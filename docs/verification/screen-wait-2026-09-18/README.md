# Waiting for the screen — what was measured, and what could NOT be established

**2026-09-18 · `cc/echo-opus-screenwait1` · Echo**

The CEO's ruling §56 (`richos-hq/wiki/ceo-decisions.md`), verbatim:

> *"I like that "Watch for the Mac's screen to unlock" feature that you had running here.
> Should be added to the RichOS app for automatic use when Rich needs it."*

The acceptance is his sentence: **when Rich needs the screen and it is locked, the app waits for
the unlock on its own and carries on.**

---

## THE HONEST HEADLINE, FIRST

**The unlocked reading is proven against a real GUI session on this Mac. The LOCKED reading is
not.** Every locked-screen behavior in this slice — the wait, the durable state, the resume on
unlock, the stop, the quit, the recovery — is driven through a fake screen source in unit tests,
not through a real lock.

That is a deliberate limit and it was set by the lead, not worked around:

- **The CEO was at the desk all day and the screen was not taken for a forced lock.** A forced
  lock costs him his hands typing a password back in, which is not a thing a test may spend.
- **A forced lock would not have proven it anyway.** `sysadminctl -screenLock status` on this Mac
  reports **`screenLock delay is 300 seconds`**, so `pmset displaysleepnow` sleeps the display and
  leaves the session **unlocked** for five minutes. The obvious command does not produce the state
  it looks like it produces.
- So the live half was done by **observation** — watch for a natural lock rather than cause one.
  **No natural lock occurred while the task was live** (see `observation.log`). So the observation
  produced a negative result, and that is stated here rather than dressed up.

**What that means for a reader:** the code path that reads `CGSSessionScreenIsLocked` and returns
`Screen::Locked` has never run against a really locked screen on this machine. The branch is three
lines and its inputs are exercised (the key's presence, its type, and the corroborating on-console
key), but the end-to-end "lock the Mac, watch RichOS park a job, unlock it, watch the job go" walk
is **outstanding** and needs either a human at the desk or a window where the screen is free.

---

## 1. The reader, against a real GUI session (UNLOCKED — established)

Run on this Mac while the screen was unlocked and Ray's candidate was on screen:

```
dictionary: 11 entries
CGSSessionScreenIsLocked: ABSENT (what an unlocked screen looks like)
kCGSSessionOnConsoleKey present: true
CGDisplayIsAsleep(main): false
```

**ABSENT is the unlocked reading, and it needed a second key to be trustworthy.** macOS does not
write `CGSSessionScreenIsLocked = false`; it omits the key. So an absent key and an *unsupported*
key look identical, and a reader that treated absence as "unlocked" on its own would report
unlocked forever on a future macOS that renamed it. `kCGSSessionOnConsoleKey` — measured present —
is the corroboration: no on-console key means `Unknown`, which proceeds rather than waits, so a bad
reading can never strand work.

The shipped reader's own tests do this live read every run
(`src-tauri/src/screen.rs`, `the_reader_answers_without_crashing_and_says_what_it_established`).
They deliberately accept any of the three readings, because pinning one would make the suite depend
on the state of somebody's desk.

## 2. The cost of a reading, and why the poll interval is 2 seconds

A reading is an IPC round trip to the window server, so **its cost tracks that server's load.** The
first sample taken was an outlier and the spread is the finding:

| what | µs per reading |
|---|---|
| six samples, idle machine, optimized, 2000 readings each | 45.9 · 47.0 · 47.8 · 48.9 · 49.3 · 58.1 |
| the shipped reader, DEBUG build, two keys + `CGDisplayIsAsleep` | 75.1 |
| one sample taken **while `cargo` was building this crate** | **298.4** ← worst observed |

The arithmetic deliberately uses the **worst** figure, so the conclusion is an upper bound:

```
  worst observed reading                       298.4 µs   = 0.0002984 s
  at SCREEN_POLL = 2 s   0.0002984 / 2      = 0.00014920  = 0.014920 % of one core
  at the typical 75.1 µs  0.0000751 / 2     = 0.00003755  = 0.003755 % of one core
  at the 10 s of the watcher he liked        = 0.00002984  = 0.002984 % of one core
  worst-case added latency                   = one interval = 2 s
```

So 2 s costs **at most 0.0149 % of one core**, about 0.0038 % in practice, **and nothing at all
when no wait is outstanding** — at a fifth of the latency of the 10-second watcher he described as
the thing he liked. `screen.rs`'s `the_poll_interval_is_the_measurement_it_claims_to_be` recomputes
both shares so a change to the constant has to face the numbers that justified it.

**Why the first number was corrected rather than amended away.** The first commit of this slice
quotes 298.4 µs as *the* measured cost. It was one sample, taken under build load, and it is six
times the idle figure. The conclusion did not move — the arithmetic was already built on the
pessimistic number — but a reader deserves to know the figure is a ceiling and not a typical case.

## 3. No distributed-notification observer, and why that is a decision

`com.apple.screenIsLocked` / `com.apple.screenIsUnlocked` on `NSDistributedNotificationCenter` is
**deliberately not built**:

1. It can buy **at most 2 s** of latency, against 0.0149 % of one core, and only while something
   is already waiting.
2. **It cannot be the mechanism, only an optimization.** Those notifications are posted by
   `loginwindow` and are not delivered for every path into a locked session — which is why a poll
   backstop was asked for in the same sentence that asked for them. A mechanism that needs a
   backstop to be correct *is* the backstop.
3. It would cost a block-based observer retained across threads, with an `NSOperationQueue` and a
   run loop, inside a `Send + Sync` source.

If the 2 s is ever shown to matter, the interval is one constant.

## 4. No new dependency, verified rather than asserted

`CGDisplayIsAsleep` is reachable through `core-graphics 0.25`, already in the shell's `Cargo.lock`
beneath `tao`/`wry`. **`CGSessionCopyCurrentDictionary` is in no crate in the tree**, so it is
declared as an `extern` against CoreGraphics — a framework this process already links — with four
CoreFoundation entry points beside it.

**Evidence: `Cargo.lock` is byte-unchanged in both workspaces across this whole branch.**

## 5. What the tests actually prove (fake screen source)

`cargo test -p richos-core` — **exit 0, 54 suites, 701 passed / 0 failed** in the lib (was 680 at
`ec620488`). `cargo check` in `src-tauri` clean; its 3 screen tests green.

Each property below is pinned by a named test:

| property | where |
|---|---|
| a locked screen that unlocks ends the wait by itself, in 3 samples | `screen.rs` |
| an unlocked screen costs ONE reading and announces nothing | `screen.rs` |
| an unestablished reading NEVER blocks (the polarity rule) | `screen.rs` |
| a sleeping display on an unlocked session does not block | `screen.rs` |
| a stop reaches a waiting thread and is never reported as availability | `screen.rs` |
| **nothing polls the screen until something waits** (+ a source-reading negative control) | `screen.rs` |
| a screen-bound assignment parks, spends no lease, binds no seat, raises no notice, then runs on unlock | `work_host.rs` |
| work that does not need the screen never reads it | `work_host.rs` |
| a screen that cannot be read runs the work rather than waiting forever | `work_host.rs` |
| a quit leaves a parked assignment stopped **for good** | `work_host.rs` |
| his stop reaches a parked assignment | `work_host.rs` |
| a relaunch reports it unknown and says it had not started | `recovery.rs` |
| the status read gives it its own heading, not `waiting_for_you` | `status_tools.rs` |
| the live screen reading keeps `unknown` apart from `unlocked` | `status_tools.rs` |
| a screen need survives the record; an older record still reads | `assignment.rs` |

### Two tests were proven able to fail, because a green assertion nobody has seen go red is worth little

- **`the_module_spawns_nothing_outside_its_own_tests`** failed on its first run — on this module's
  own documentation, which contains the sentence *"There is no `std::thread::spawn` in this file"*.
  It now strips comment lines and asserts the phrase really is in the prose, so a stripper that
  stripped nothing would itself be caught.

- **`a_quit_leaves_an_assignment_parked_on_a_locked_screen_stopped_for_good` was WRONG on its first
  draft and the correction is the most useful thing in this record.** It asserted that `shutdown()`
  returns quickly and that the receipt says `interrupted` — and it **passed with the fix deleted**,
  so it guarded nothing. `shutdown` never blocks on a screen wait: its drain loop waits on
  `inner.live`, and a screen wait happens strictly before the lease, so `live` is `None` and the
  drain returns at once either way.

  The real defect is the opposite of a hang and far worse: without the stop, the runner thread stays
  parked after the app has quit, and when the screen is unlocked minutes later **it wakes up and
  carries on with work the app already told him was stopped** — advancing the receipt and opening a
  lease after the process was supposed to be done. The test now quits, *then* unlocks, then asserts
  nothing stirred. **Proven to fail with the `watch.stop()` removed from `shutdown`: the receipt was
  rewritten 51 ms and 59 ms after quit on two runs.**

  A second finding from that defeat run: the final **state** settled back to `interrupted`, so a
  state assertion alone stayed green. `updated_at_ms` is the witness that actually catches a
  resurrection, and it is asserted first for that reason.

## 6. The observation walk (negative result, stated as one)

`observation.log` in this directory, produced by `watch.rs` (also committed here) — the same
externs, the same key and the same absence-means-unlocked rule as the shipped reader, built as a
standalone binary so it could be started before the shell had been built:

```
2026-09-18T10:38:46Z START  screen=unlocked on_console_key=true display_asleep=false
...
2026-09-18T11:38:55Z alive  screen=unlocked on_console_key=true display_asleep=false  (1800 samples, no change)
```

**1800 samples over 60 minutes at a 2-second poll. Zero transitions.** The five-minute heartbeat is
deliberate and load-bearing: it is what separates *"no lock happened"* from *"the watcher was dead
and we weren't looking"*. The watcher was killed at the end of the task (pid 24680, confirmed gone
with `pgrep`).

## 7. A pre-existing flake, measured on both sides so nobody re-derives it as mine

`work_host::tests::registering_returns_before_the_work_starts_and_the_work_still_runs` asserts
registration completes in under 100 ms, and fails under full-suite parallelism on a loaded machine.

| tree | command | runs | timing failures |
|---|---|---|---|
| pristine base `ec620488` | full suite | 8 | **1** — `registration took 134.095792ms` |
| this branch | full suite | 8 | 0 |
| pristine base `ec620488` | `--lib` only | 6 | 0 |
| this branch | `--lib` only | 6 | 0 |

**The base is worse than this branch**, and the screen gate is on the runner thread inside
`run_one`, not on `register`'s path at all. Not fixed here: tightening someone else's timing bound
is not this task, and it is a machine-dependent number rather than a defect.

**Three "base failures" seen along the way were artifacts of the comparison harness, not the base.**
`git archive richos/app` leaves behind out-of-tree fixtures the suite reads —
`docs/verification/upstream-failure-2026-09-05/`, `docs/measurements/`, and
`richos/engine/loro/bin/loro-context.mjs`. They are named here so nobody re-derives them as real
defects.

## 8. Still owed

1. **The end-to-end walk on a really locked screen** (§ headline). Needs a human at the desk or a
   free screen. Everything else is proven; this is the one thing that is not.
2. **`ui/main.js:2918`** — the work chip's count is the typed list
   `["registered","preparing","running"]` and does not include `waiting-for-screen`. If a
   screen-waiting assignment is his only open work and nothing else populates the chip, `parts` is
   empty, `drillChipEl.hidden = true`, **the chip disappears and the pane the assignments live in
   cannot be reached at all** — the exact failure the comment four lines above it warns about.
   Adding the word to that list is *not* the fix: the label reads "N assignments running" and would
   then call a parked job running. It needs its own part, in the shape "1 waiting for the screen".
   `ui/main.js` belonged to another teammate this round, so it is reported rather than touched.
3. **A screen wait the BACK END can ask for mid-job.** The status server is the front desk's alone
   by design (`native.rs:1052`, enforced by an assertion in its own suite), so the reading added
   here reaches the front desk and nothing else. A back end that wants to wait mid-job needs a new
   app-owned MCP server attached to `LeaseRole::Work` — its own scope file, its own `--screen-mcp`
   arm, its own permission-desk treatment. The mechanism the CEO's case actually needs is the
   `needs_screen` declaration made when the assignment is written down, and that is built.
4. **Windows.** A documented stub reporting `unknown`, which never blocks. The equivalent is
   `WTSRegisterSessionNotification` with `WTS_SESSION_LOCK`/`WTS_SESSION_UNLOCK`; it needs a window
   handle and a message pump, and there is no Windows build of this app to verify it against.

## Hygiene

No second app instance was launched at any point. Ray's candidate at **pid 76497** was left
untouched throughout and is not mine to quit. The only process this task started was the
observation watcher, **pid 24680, killed and confirmed gone**.
