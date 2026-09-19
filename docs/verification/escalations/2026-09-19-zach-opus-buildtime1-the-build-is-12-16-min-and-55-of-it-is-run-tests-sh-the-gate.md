# Escalation: The build is 12-16 min and 55% of it is run-tests.sh; the gate the brief lets me skip is 5.5%

- id: `esc-20260919T182332Z-76772d61`
- raised: 2026-09-19T18:23:32Z
- from: zach-opus-buildtime1
- worktree: `/Users/alex/ab/richos-wt/zach-opus-buildtime1` (branch `cc/zach-opus-buildtime1`)
- head: `a92f0527691c046ddb32ccd7c3540dac37d9ae94`
- state: **work-complete**
- for: lead

## The question

May I take the next slice on run-tests.sh itself — running its 14 independent suites in parallel, and/or skipping the two heaviest when their inputs are unchanged — which is where 522 of 950 seconds actually are? The land-proof flag the brief specified is built, tested and correct, and it saves 52 seconds.

## What was already tried

Instrumented nightly-local.py with per-line wall clock and per-phase timing; ran a full traced build of current main f247c535 (run 20260919T180454Z-ac11d13e, 950.2s, rc 0, candidate .6) and derived the split from log byte offsets against the clock; cross-checked the shape against run a7232406's staging mtimes.

## Proceeding meanwhile

Everything the brief asked for is committed on cc/zach-opus-buildtime1. The one deliverable I could not produce is the flagged end-to-end build: its gates phase runs gui-boot.test.sh on screen and the screen grant was withdrawn.

## The measurement

Run `20260919T180454Z-ac11d13e`, log `~/.richos-nightly/logs/20260919T180454Z-ac11d13e.log`,
`build` of `f247c535e110945e975d83b07f20f05b21572fa4`, rc 0, candidate
`v1.2.0-nightly.20260919.6`. Wall clock per phase was derived by sampling the run log's
size against the clock four times a second while it ran, which maps every byte offset --
and therefore every line -- to an instant without the build's own scripts cooperating.
Line numbers below are that log's.

```
phase                                                    starts     seconds   share
fetch + plan + preflight + runtime-verify                18:04:54       8.9    0.9%
gates/core-tests      cargo test -p richos-core          18:05:03      52.2    5.5%   <- the only skippable one
gates/updater-tests   cargo test richos-user-update      18:05:55      13.0    1.4%
gates/script-suites   run-tests.sh, 14 suites            18:06:08     522.4   55.0%
  front-door.test.sh        (host gap, launches nothing) 18:06:08       0.0
  frontend-payload.test.sh                               18:06:08       0.3
  gui-boot.test.sh          ON SCREEN                    18:06:09     161.6
  make-engine-asset.test.sh                              18:08:50     128.7
  make-release.test.sh                                   18:10:59     157.5
  nightly-local.test.sh                                  18:13:36       1.3
  nightly.test.sh                                        18:13:38      24.1
  no-compile-time-paths.test.sh                          18:14:02       2.5
  package-app.test.sh                                    18:14:04       8.9
  rebuild-survival.test.sh                               18:14:13       1.0
  run-tests.test.sh                                      18:14:14       0.5
  signing-setup.test.sh                                  18:14:15       3.0
  updater-setup.test.sh                                  18:14:18      19.8
  voice-component.test.sh                                18:14:38      13.2
gates/privacy-sweep   named-persons.sh --tree            18:14:51      21.6    2.3%
plan-recheck + tag push + prepare                        18:15:12      30.0    3.2%
build/engine-asset    tar 119 MB                         18:15:42      33.0    3.5%
build/engine-asset    SECOND build, reproducibility      18:16:15      24.9    2.6%
build/engine-member-audit                                18:16:40       6.1    0.6%
build/engine-release-create + upload 119 MB              18:16:46       0.8    0.1%
build/engine-verify   download 119 MB back               18:16:47      75.2    7.9%
build/app-preflight                                      18:18:02       2.3    0.2%
build/app-compile     cargo + frontend                   18:18:05     102.0   10.7%
build/app-bundle-and-sign                                18:19:47       2.1    0.2%
build/app-notarize + staple + Gatekeeper verify          18:19:49      45.3    4.8%
build/app-archive + zip + manifest                       18:20:34      10.4    1.1%
TOTAL                                                    18:04:54     950.2  100.0%

all four gates                    609.3s  64.1%
nightly.py build                  332.1s  34.9%
```

The shape is confirmed independently by the staging mtimes of the three earlier runs of
the same day, which bracket the same boundaries without any instrument:

```
run        started(Z)  pre-build gates  engine  publish+verify  app    total
18f947e8   12:58:16          660 s       96 s        48 s       176 s   980 s
fa028f73   14:51:48          503 s       67 s        48 s       103 s   721 s
a7232406   16:28:00          512 s       70 s        49 s       113 s   744 s
```

Two things follow, and neither depends on the absolute seconds:

1. **The pre-build gates are two thirds of every run.** 64% measured here, 68-70% in the
   three mtime-bracketed runs. The compile everyone points at is 10.7%.
2. **`run-tests.sh` alone is 55%**, and two of its fourteen suites -- `make-release.test.sh`
   and `make-engine-asset.test.sh` -- are 286 s, 30% of the whole build between them. Those
   are precisely the suites the brief rules out skipping, correctly, because no land runs
   them. They are not redundant. They are SERIAL, and independent of each other.

The absolute total of this run is an upper bound: the Mac was contended (another agent had
an app on screen during the gui-boot window, and this agent was running unit suites during
the early gates). The shares are robust; the seconds are not to be quoted as a floor.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260919T182332Z-76772d61`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260919T182332Z-76772d61 --disposition "<what you decided or did>"
