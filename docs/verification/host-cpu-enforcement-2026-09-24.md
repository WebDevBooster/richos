> Follow-up: this initial verification was followed by a real iOS CPU recurrence. See [the recurrence report](host-cpu-ios-recurrence-2026-09-24.md) for the missing paths, corrections and current simulator stop.

# Host CPU enforcement: installed verification

The local implementation is installed and active. Code commits are `623fac5f`, `566f7097`, `7075689a` and `5b046e62`, in that order. The last three incorporate findings from actual deployment and smoke checks, including a launchd log-open failure, asynchronous service teardown and macOS returning unchanged CPU counters for subsecond samples.

## Live results

- The installed `com.richos.cpu-guard` LaunchAgent produced a healthy heartbeat. Its independent runtime is `/Volumes/E1TB/state/richos/cpu-guard/runtime/cpu_guard.py`.
- The existing Claude process, PID 84585, invoked the newly installed user hook. Its registration changed from the manually enrolled label to `Claude session 7dc081b0-2043-4bec-ba05-aa1754d5ad0b`, demonstrating that this session picked up the hook without restarting.
- After an intentional SIGKILL of the watchdog, launchd started a new watchdog and its healthy heartbeat appeared in **5.58 seconds**.
- Two commands submitted together through native admission ran sequentially: first 00:22:26.612 to 00:22:28.617 UTC, second 00:22:29.181 to 00:22:31.186 UTC. Both received `JAVA_TOOL_OPTIONS=-XX:ActiveProcessorCount=1`.
- A real headless Android emulator, PID 27543, was launched with two virtual cores using a task-specific AVD. Only this test device's activity timestamp was aged past the normal five-minute boundary. It exited and its AVD and lease record were removed automatically in **9.55 seconds**. This proves device expiry, not a replay of the app's original rendering defect.
- The installed watchdog intervened against actual Claude-owned Java workloads during sustained host overload: PIDs **24282**, **57987** and **64020**. The last consumed **6.33 cores** in the measured sample. Recorded descendants were signalled too. These were actual production interventions, not injected CPU samples.
- The installed hook returned refusal code 2 for direct emulator and Gradle launches. It allowed read-only text and emulator shutdown commands. The commands were supplied as hook payloads and were not executed.
- Android and iOS `headless state` commands succeeded. The iOS command rebuilt its CLI successfully through capped Swift admission. Android Gradle task-graph construction through `randroid test core --dry-run` succeeded with the one-processor JVM setting and a single-use daemon; no test execution is claimed for that dry run.

## Automated validation

- **17 CPU guard/native-admission tests passed**, including a real CPU-burning process beside an unrelated bystander, generation reuse, detached descendants, aggregate overload, broken-hook refusal, unavailable-counter retry and notice deduplication.
- **49 device-collector tests passed**, including new lifetime, inactivity, holder-death and simulator-pressure tests.
- Final `ci-shard.sh --only-units scripts/lib/cpu_guard.test.sh` passed against code commit `5b046e62`.
- A focused `proof-run.py` run completed both selected checks in 20 seconds with one worker: the CPU guard unit and the device collector's 49 cases. A subsequent targeted CPU unit run verified the final counter-retry and notice changes.
- Swift parser validation and shell syntax checks passed.
- Replay of 2,768 recent Claude Bash calls flagged two actual direct heavy launches and one malformed command. `bash -n` independently rejected the malformed command. No false refusals remained in this corpus. This is an observed corpus result, not proof of a complete shell parser.

An earlier CI-wrapper attempt reported failures because source files were edited while it ran and the live Claude session registered additional agents in the shared operator ledger. These were not passing receipts and were not presented as such. The final focused run passed after implementation stabilized.

## Evidence on the external SSD

- `/Volumes/E1TB/ab/host-cpu-enforcement-restart-proof.json`
- `/Volumes/E1TB/ab/host-cpu-enforcement-live-proof.json`
- `/Volumes/E1TB/ab/host-cpu-hook-proof.json`
- `/Volumes/E1TB/ab/host-cpu-enforcement-final-unit.jsonl`
- `/Volumes/E1TB/ab/host-cpu-enforcement-proof/`
- `/Volumes/E1TB/ab/host-cpu-native-smoke/`
- `/Volumes/E1TB/state/richos/cpu-guard/events.jsonl`

## Limits

There is no 100% guarantee and no kernel CPU quota. The service reacts to sustained measurements, so short spikes remain possible. Older worktrees retain older build scripts until updated, though their observed Claude descendants and exact registered emulators are watched. Arbitrary unobserved detachments, privileged processes and unowned applications are outside full containment. The CPU service reports unowned consumers rather than killing them. See `richos/engine/docs/host-cpu-enforcement.md` for thresholds and operating details.
