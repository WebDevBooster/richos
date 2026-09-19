# The build's gates phase: 609 s → 215 s → 94 s, with nothing on the host's screen

Measured 2026-09-19 on the release Mac (Apple M4, 10 logical cores, 24 GiB, macOS 15.6),
against `cc/zach-opus-buildtime2` at `4c0433987be2`.

The CEO, the same day:

> WHEN THE FUCK WILL THE BE A PROPER FUCKING SETUP THAT WILL ENABLE SUPER FAST DEVELOPMENT
> AND NOT PATHETICALLY SLOW SNAIL PACE DEVELOPMENT???

> So, every engineer will keep opening the app making me unable to do anything here or WHAT???

## The number

| | gates phase | `run-tests.sh` inside it |
|---|---|---|
| **Before** — run `20260919T180454Z-ac11d13e`, serial, measured by zach-opus-buildtime1 | 609.3 s | 522.4 s |
| **A — cold**: concurrent, `--no-host-screen`, `--checks-done-at-land`, no skip proofs yet | **214.9 s** | 183.2 s |
| **B — warm**: the same, with the two heavy suites' inputs unchanged since A | **93.7 s** | 57.0 s |

The gates phase was 64.1% of a 950 s build. Taking A as the steady state for a commit that
touches the engine or the packaging scripts, and B for one that does not, the whole build's
pre-build gates fall from about ten minutes to between one and a half and three and a half.

`gates/core-tests` is dropped in both by `--checks-done-at-land`, which is what a land
already ran — that flag is zach-opus-buildtime1's, unchanged here.

## `run-tests.sh` alone, same tree, same twelve suites

| pool | wall |
|---|---|
| 1 (serial) | 341 s |
| 2 | 223 s |
| 3 | **167 s** |
| 4 | 183 s |
| 6 | 228 s |
| 10 | 236 s |

**More concurrency is slower past three.** Two suites dominate this harness and contend
with each other for disk and cores, so their own durations inflate as the pool grows:
`make-release.test.sh` goes 131 → 167 → 228 → 236 s across that curve, and the wall clock
is simply whichever of the two finishes last. The pool's job is to get the other ten suites
out of the heavies' way, not to start everything at once.

The first version of the default computed `min(cores, GiB/4)` = 6 — a reasonable derivation,
and 61 s slower than the truth. The default is now `cores/3`, floored at 2, still capped by
4 GiB of headroom per slot; on this Mac that is 3.

## Nothing reached the host's screen, and the naive check would have said otherwise

`pgrep -x richos-tauri`, sampled twice a second throughout both runs
(`pgrep-richos-tauri.log`): **655 samples, 575 empty, 80 matches, 0 of them a real binary.**

Every one of the 80 is of this shape:

```
/private/var/folders/.../T/.tmpXXXXXX/Applications/.richos-updater/<sha>/incoming.app/Contents/MacOS/richos-tauri --richos-internal-update-identity
```

— stub binaries the **updater crate's own tests** (`cargo test -p richos-user-update`, a
pre-existing gate) execute out of their `mktemp` fixture homes as headless identity probes.
They live milliseconds, under `$TMPDIR`, and draw nothing.

**This matters for how the check is written.** A bare `pgrep -x richos-tauri` is not the
question the CEO asked; it reports a window that never opened. The poller classifies every
match by its executable path, and the line that counts is `REAL: 0`. The two suites that do
put a window on a screen — `gui-boot.test.sh` and `front-door.test.sh` — are recorded
`NOT RUN (no screen)` in both reports.

## A defect this measurement found

Run A's first pass (before `4c043398`) came back with `run-tests.test.sh: "state": "notrun"`.
The classifier matched the string `lib/gui-launch.sh` **anywhere** in a file, and that file's
own S1 case writes a fixture containing `. "$DIR/lib/gui-launch.sh"`. The harness's own
self-test had been silently held back from every screenless build, under a reason that reads
entirely legitimate — the exact defect `run-tests.sh`'s header counts five instances of.

The classifier now matches at command position, and case S7 asserts the real inventory's
host-screen set as a set, in both directions.

## What is NOT here, and why

There is no `nightly-local.py build --no-host-screen` end to end. `Runner.checkout()` does
`git fetch origin main` and checks out `FETCH_HEAD`, so a real build necessarily builds
`origin/main` and **cannot** exercise an unlanded branch. The runs above drive the same
`Runner`, the same `gates()`, the same flags, the same phase timing and the same `summary()`
against the worktree the change lives in — 64% of the build and 100% of what changed. The
flagged full build is Rich's, after landing.

## Files

| | |
|---|---|
| `gates-A-cold.log` / `gates-B-warm.log` | the two runs, with `nightly-local.py`'s own phase table |
| `script-suites-A-cold.json` / `script-suites-B-warm.json` | `--results-out`, the report that travels into `build-info.json` |
| `pgrep-richos-tauri.log` | the classified screen poll |
