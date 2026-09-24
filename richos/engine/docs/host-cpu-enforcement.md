# Host CPU enforcement

The September 23 incident had two independent causes: a software-rendered Android emulator could consume almost nine cores and native builds did not participate in the shared worker budget. Cooperative worker counts alone do not enforce CPU usage.

## Installed mechanism

`python3 scripts/lib/cpu_guard.py install /absolute/path/to/richos/engine` installs `com.richos.cpu-guard` and `com.richos.cpu-guard.devices` as independent user LaunchAgents, copies its runtime to `/Volumes/E1TB/state/richos/cpu-guard/runtime` and adds one standalone Bash guard plus SessionStart/Stop notices to the user's Claude settings. Launchd output goes to `/dev/null` because macOS refused to open the external-volume log during spawn; runtime failures are recorded in the state directory. Existing settings are preserved and backed up with private permissions. This registration also works with older cached engine plugins. Launchd restarts the watchdog after a crash and starts it at login.

The service samples CPU-time deltas every two seconds. It terminates an owned process and its observed descendants after ten seconds above three cores. Host saturation and aggregate owned CPU do not authorize terminating ordinary running jobs. Survivors of a per-process runaway intervention receive SIGKILL after a three-second grace period. These are sampling targets, not real-time OS guarantees.

Proof runs, native builds and simulator admission share `cpu_policy.py`: new work waits when total CPU (user plus system) reaches the default 80% limit. The watchdog reports admission against the same measure and boundary. An admitted job may finish while the host is busy. Explicit proof-run CPU overrides and the existing low-priority admission exception remain available; memory checks still apply.

Ownership comes from registered PID and birth identity, observed ancestry and exact emulator generations in the device registry. Reparented descendants retain their observed identity. Session roots are protected. PID identity is checked again before signalling. Unregistered processes are reported, never killed by name. Simulator services are owned by launchd rather than the CLI: intervention addresses exact registered simulator UDIDs instead of guessing service-process ownership.

`native-work.py -- COMMAND ...` acquires the existing machine budget and, for compilation, a single shared native-build lane. Prebuilt Xcode `test-without-building` runs retain machine admission, device leases and the same process caps but do not hold the compiler lane. They can run beside an unrelated build when host headroom permits it. Combining that action with a build action still requires the compiler lane. The launcher measures CPU/memory headroom before starting. Gradle uses one worker, no parallel mode, no persistent daemon and an in-process Kotlin compiler; JVMs see one processor. Swift builds/tests use one job. Xcode builds use one job and disable parallel tests, automatic test diagnostics and performance diagnostics. Release checks and simulator suites also use the capped launcher. `randroid`, `rios` and the Swift CLI's Xcode invocations use this entry point. A stale CPU heartbeat or failed/stale device-collector heartbeat closes native admission on macOS. Collector stderr is preserved in the incident record. Existing process supervisors also enroll managed workloads when the service is healthy.

Android launches and `rios` simulator boots share the existing two-device live pool and serialized boot pool. Each device holds a machine worker until shutdown via an independent lease holder. Devices have a 15-minute maximum lifetime and a five-minute CLI inactivity limit. Activity renewal cannot extend the maximum lifetime.

A test run is one long call rather than a series of CLI calls, so it renews its own activity: `testdevices.py run-active --kind KIND --id ID --owner-pid PID -- COMMAND ...` starts COMMAND as its child and renews the lease's inactivity clock every 30 seconds while that child runs. Renewal stops, and the five-minute limit applies again, when the child ends, when the lease's registered owner is no longer proven alive, when the renewer itself ends, or when the lease is gone or replaced. It never renews an expired lease and never touches the lifetime. The collector's own rules are unchanged: an ended owner or lease holder is collected at the next pass whether or not anything is renewing. The native iOS UI suite and `Release/simulator-tests.sh` run their boot and Xcode test through it. Before September 24 nothing renewed a running suite, and the collector shut its simulator down five minutes in.

A registry lock held by another caller when the lease collector runs is a skipped cycle, not a collector failure: the next cycle, two seconds later, retries. The first skip of a busy spell and the recovery are recorded in the event history without raising an alert. A spell longer than 180 seconds is reported as a collector failure again, because the longest legitimate hold is a `simctl` call under the lock, bounded at 120 seconds. Before September 24 a lock busy for five seconds made the collector exit 1, which closes native admission.

`acquire-ios --purpose ui-suite` declares a 30-minute lifetime for a new lease. The UI suite runs its whole selection serially on one device, which took 787-884 seconds per device under load against a 15-minute lifetime that also covers the boot. Splitting the selection across leases was rejected: the pool admits one lease at a time, so every split adds a serial warm boot and app reset to every proof, and a growing suite would reach the ceiling again. A caller names a declared purpose, never a number. Acquiring an existing lease again never lengthens it, and registering it again resets it to the default. The collector stops expired devices, devices whose owners ended and devices whose lease holders died. Prepared iOS devices retain their OS on disk after shutdown; legacy devices are deleted. Every removal addresses a registered generation or UDID. Stop/delete commands remain available.

## Inspection

```
python3 scripts/lib/cpu_guard.py status
launchctl print gui/$(id -u)/com.richos.cpu-guard
```

The state directory contains the heartbeat, ownership records, intervention history, latest alert and original Claude settings backups. Status distinguishes current host utilization, `ios_admission_reason`, the incident record and each registered simulator's startup phase/deadline. An incident record is not a claim that CPU is currently high. The Bash guard refuses direct Gradle, Swift build/test, Xcode build, emulator and simulator-boot commands. It allows inspection and shutdown commands. Its parser distinguishes heredoc data from commands; it is not a shell sandbox.

## Boundaries

This is a circuit breaker, not a kernel CPU quota. Short spikes can occur before the sustained-load threshold. macOS scheduling, inaccessible processes and service failures can delay action. Unobserved children that immediately detach can evade ancestry tracking; exact device records cover the normal emulator detach path. Arbitrary code and indirect shell execution cannot be made unbypassable by a text hook. Other users' processes and privileged workloads are outside this per-user service.

Older active worktrees retain their old build scripts until updated. Their observed Claude descendants and registered emulators are still covered by the watchdog, but only updated entry points gain admission and compiler caps. External SSD availability is required. Direct command refusal in an already-running Claude host depends on its settings reload; external watchdog enforcement does not depend on Claude reading a hook or replying to an alert.

Do not claim that this makes host saturation impossible or promises 100% reliability.

## September 24 iOS recurrence

A fresh iOS simulator per proof triggered first-boot system work, followed by Xcode's automatic `simctl diagnose` dump. At peak load, `ps` repeatedly exceeded its five-second timeout. The previous watchdog only launched device cleanup after successful process sampling and called itself healthy even when that cleanup failed. Its discarded stderr means the exact cause of the historical collector exit 1 cannot be reconstructed.

Device cleanup has its own launchd service. It reads Mach host counters independently of process enumeration. During an intervention it attempts exact-UDID shutdown before either owner process lookup or simulator inventory, including records written by older checkouts. The CPU service also stops observed agent-owned simulator test owners and `simctl diagnose` descendants, while preserving session roots and unrelated processes. macOS/CoreSimulator can still delay RPCs; failures close admission and remain visible.

The first recurrence policy stopped iOS after ten seconds of host CPU at or above 85%, then persisted a manual incident stop. A subsequent controlled recovery reached 100% host CPU and was stopped about twenty seconds after boot. That proves the rule triggered again, not that startup was stuck or that the simulator caused all host load. This rule was too coarse for normal development and is superseded below.

### Productive work and bounded recovery

Busy CPU alone no longer stops a simulator. The independent device worker intervenes when host CPU is at least 85% **and** the CPU worker has failed or stale process monitoring for a further ten seconds. A successful process heartbeat becomes stale after twelve seconds. This is evidence that monitoring is impaired, not a claim to measure every kind of UI responsiveness. Missing monitoring still closes admission to new work. The per-process runaway limit remains independent.

Startup has one shared deadline across boot, `bootstatus` and app-state cleanup: 180 seconds for an OS without a recorded successful boot, 120 seconds for a previously successful prepared OS. These are initial containment budgets, not performance targets or claims that every runtime needs that long. Both the startup caller and independent worker enforce the deadline. A duplicate boot cannot reset it. The manifest records `boot_completed_at` only after startup and cleanup succeed. Creation alone does not prove an OS is warm. Successful runs retain the prepared OS for reuse.

Automatic intervention persists a cooldown of 30 seconds, then 120 seconds, then 600 seconds for subsequent incidents within an hour. Repeated samples of one incident count once. After the cooldown, a new launch request may proceed only with healthy workers, current CPU below the shared admission limit and completed exact-device cleanup. Recovery never boots or retries a test itself. An active cooldown survives service restarts, and repeated failures therefore cannot create an immediate restart loop.

An operator `block-ios REASON`, or an old incident file without a mode, remains a manual stop. `recover-ios REASON` requires healthy workers, current CPU headroom and no registered iOS devices. It archives the incident and records the recovery reason without booting anything. Do not delete incident files to bypass those checks. Headless tests, physical devices and shutdown remain available during any iOS stop.

The user hook rejects recognized native/proof entrypoints from checkouts whose collector lacks the prepared-pool API or whose engine lacks the shared CPU policy module. This is command/path validation, not an arbitrary-code sandbox. Update active checkouts and the installed guard together when changing policy.

`testdevices.py acquire-ios --type TYPE --runtime RUNTIME --owner-pid PID` leases a prepared simulator from a machine-wide pool. Its manifest is under `/Volumes/E1TB/caches/richos-ios-prepared`; Apple device storage remains in the previously approved default device set. Only one pool lease is active across checkouts, including across different device types. Each type/runtime is created once. A missing previously prepared device is an error, not an automatic fresh replacement. A new type/runtime uses the bounded first-boot path.

`boot-ios` waits for boot completion, uninstalls user apps and resets keychain and privacy permissions. It does not erase the simulator OS. `release-ios` checks the owner identity, shuts the device down and releases the lease without deleting the prepared OS. This isolates app containers and credentials but is not a factory-reset OS image. Tests requiring pristine system state need a separately scheduled cold-device test.

The native app, platform/share and UI suites use this pool. UI tests run their complete selection serially on each requested device type. `rios sim stop` reports `retained`, not `deleted`. Builds and Xcode tests use the capped launcher with `-collect-test-diagnostics never`; the installed Xcode's help confirms support for this flag.

Tests exercise productive 100% host load, startup deadlines, monitoring failure, cooldown/backoff, manual recovery, reuse, app cleanup, ownership conflicts, old records and failed cleanup. The device suite uses a fake CoreSimulator. These tests establish policy behavior, not on-machine warm-boot performance. Record physical host measurements separately.
