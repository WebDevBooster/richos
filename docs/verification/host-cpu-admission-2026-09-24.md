# CPU admission and interrupted work repair

Rich's report was correct. The intervention history recorded compression processes using about 0.38–0.89 cores and Gradle processes using about 0.74–2.07 cores being terminated during host contention. The watchdog's host and aggregate thresholds treated small running jobs as expendable. Admission used user CPU while the watchdog used user plus system CPU.

## Repair

Immediate commit `37e70b8f` removed host-pressure and aggregate-owned-CPU termination of ordinary work. It was fast-forwarded into local main and installed before finishing the admission changes. The independent per-process runaway protection remains: an owned process exceeding three cores for ten seconds can still be stopped. Simulator incident containment remains separate.

`cpu_policy.py` now supplies the shared default admission boundary: total CPU, including user and system, must be below 80%. Proof runs, reserve admission, native builds and simulator boot admission use it. The watchdog reports the same boundary in its heartbeat. A busy host queues new work rather than authorizing termination of already admitted small jobs. Existing memory checks, explicit proof CPU overrides and the previously authorized low-priority exception remain.

The hook's recognized entrypoint check now requires the shared policy module as well as the prepared simulator API. Old worktrees need to update before those commands are accepted. The hook is path/command validation, not a shell sandbox.

## Verification

- 22 CPU guard/native admission tests passed, including preserving modest workers at 99.5% host CPU and retaining per-process runaway detection.
- 21 reserve/scenario tests passed, including refusal when system CPU makes total CPU exceed the boundary and admission after a lower follow-up sample.
- All 22 proof-run assertions passed.
- All 24 runner reliability tests passed. A bounded real child waits behind a mocked 95% host sample, finishes despite contention during execution and is followed by queued work after CPU drops. The shared-boundary test exercises proof, native and simulator admission at 79%, 80% and 95% total CPU.
- All 29 lint fixture tests passed.
- The complete `lint.sh --all` gate passed in 78.80 seconds, including ShellCheck, project rules, Rust fast Clippy and Tauri Clippy. SC2004 remained at 17, preserving Rich's `c9988b5c` correction. The full lint ran through native admission with one Cargo build job.
- `git diff --check` passed.

Two test fixtures needed isolation from live machine state. The cancellation fixture now injects quiet host samples so its child actually starts before cancellation. The iOS wrapper fixture uses a temporary guard-state directory; its fake `xcrun` refuses every simulator command. No real simulator was booted and the machine's persistent iOS incident stop was not cleared.

Logs are preserved at `/Volumes/E1TB/ab/host-cpu-admission-repair/`: `guard-tests.log`, `reserve-tests.log`, `proof-tests.log`, `reliability-tests.log`, `lint-tests.log` and `lint-all.log` with `lint-all.json`. The proof log includes the initial fixture failure; the separate reliability log records the corrected suite passing. These are regression and gate results, not a claim that all unrelated workloads can never saturate macOS.
