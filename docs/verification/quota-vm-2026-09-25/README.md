# Quota: remaining VM launch verification

App source: `742c7f090f0ae8d6ee7284fe549fc0f52a0ee8be` (requested main).
Harness fix: `0cab0ed3`, branch `codex/quota-vm-verification`, based on that main.
No application source changed. The retry reused the same VM-compiled binary.

| Suite | Result | Evidence |
| --- | --- | --- |
| gui-boot.test.sh | Exit 0, all 33 passed, first run | [Log](gui-boot.log) |
| front-door.test.sh | Exit 0, 6 passed, 0 failed, targeted retry | [Log](front-door.log) |

The original front-door run exited 1 with three failures; [that failure remains recorded](front-door-first.log). Its scratch home had no company, leaving the composer disabled. The company dialog remained visible even with Settings in the accessibility tree. The harness also expected the obsolete “Techy Mode” label. The fix registers a synthetic company through native UI interactions, distinguishes the company dialog from the ready desk, calibrates closed-sheet dimensions when observable, focuses the composer and asserts against “Technical view”. Typing, Cmd-K, Escape and menu dismissal all passed on the retry. Assertions and native input mechanisms were retained. GUI boot was not rerun.

## Scope and limits

Both actual shell suites ran inside the headless macOS test VM, using committed `testvm/run.sh`, `guest.sh` and `stop.sh`. No app was launched on the host screen. VM defaults were preserved: four CPUs, 7168 MB RAM and 1680x1050 display. [Environment and binary digest](environment.txt).

The GUI suite compiled its debug artifact from the clean requested source inside the VM. The front-door suite used that exact binary in a test bundle made with committed `gui_bundle`; this was not a packaged release, a host installation or a changed product version. Existing runtimes were verified against the checked-in manifest before reuse.

Front-door's conditional opening-screen Return check (C5b) was not exercised because first-run setup covered that screen. Initial C5 calibration was unavailable; the retry calibrates the same closed sheets once the desk becomes observable. These are not counted as passes. GUI boot retains its existing declared vocabulary/evidence-service gaps. This report closes the two requested suite executions, not every possible application scenario.

No real quota reset was approved or redeemed. No broad proof selection was rerun. Prior quota, reset and message-only pause evidence remains in the adjacent verification reports. The separate proposed SIGSTOP/SIGCONT implementation is not part of this run.

## Commands and cleanup

`testvm/run.sh --no-app --no-tailnet --home <empty-fixture> --vm richos-quota-742c7f09`, with TART_HOME in a unique external-SSD scratch directory. The guest held an exact shallow checkout of the source above. Rust and cliclick were installed only inside the disposable clone.

GUI command, executed through `testvm/guest.sh`:

```sh
cd /Users/admin/quota-proof/source
env TMPDIR=/Users/admin/quota-proof/tmp \
  CARGO_TARGET_DIR=/Users/admin/quota-proof/cache \
  RICHOS_RUNTIME_DIR=/Users/admin/quota-proof/runtime \
  bash richos/app/scripts/gui-boot.test.sh
```

The expected `src-tauri/target` path linked to the guest cache. The suite's own `mktemp -t` uses the guest's system temporary directory; both locations are physically inside the external-SSD clone disk. Front-door used [this command](front-door-command.sh), first with the original harness and then with the isolated harness fix.

[Cleanup log](cleanup.log): the VM was stopped, the clone deleted and run state removed. The owned host scratch directory was then deleted. Full logs and AX evidence were preserved at `/Volumes/E1TB/reports/richos-quota-vm-742c7f09/` before deletion.
