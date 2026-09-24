# Host CPU enforcement

The September 23 incident had two independent causes: a software-rendered Android emulator could consume almost nine cores and native builds did not participate in the shared worker budget. Cooperative worker counts alone do not enforce CPU usage.

## Installed mechanism

`python3 scripts/lib/cpu_guard.py install /absolute/path/to/richos/engine` installs `com.richos.cpu-guard` and `com.richos.cpu-guard.devices` as independent user LaunchAgents, copies its runtime to `/Volumes/E1TB/state/richos/cpu-guard/runtime` and adds one standalone Bash guard plus SessionStart/Stop notices to the user's Claude settings. Launchd output goes to `/dev/null` because macOS refused to open the external-volume log during spawn; runtime failures are recorded in the state directory. Existing settings are preserved and backed up with private permissions. This registration also works with older cached engine plugins. Launchd restarts the watchdog after a crash and starts it at login.

The service samples CPU-time deltas every two seconds. It terminates an owned process and its observed descendants after ten seconds above three cores, or sheds the largest owned consumer when aggregate owned work exceeds 60% of the machine. Sustained host load above 85% also sheds owned work consuming at least half a core. Survivors receive SIGKILL after a three-second grace period. These are sampling targets, not real-time OS guarantees.

Ownership comes from registered PID and birth identity, observed ancestry and exact emulator generations in the device registry. Reparented descendants retain their observed identity. Session roots are protected. PID identity is checked again before signalling. Unregistered processes are reported, never killed by name. Simulator services are owned by launchd rather than the CLI: sustained host pressure sheds only exact registered simulator UDIDs instead of guessing service-process ownership.

`native-work.py -- COMMAND ...` acquires the existing machine budget and a single shared native-build lane. It measures CPU/memory headroom before starting. Gradle uses one worker, no parallel mode, no persistent daemon and an in-process Kotlin compiler; JVMs see one processor. Swift builds/tests use one job. Xcode builds use one job and disable parallel tests, automatic test diagnostics and performance diagnostics. Release checks and simulator suites also use the capped launcher. `randroid`, `rios` and the Swift CLI's Xcode invocations use this entry point. A stale CPU heartbeat or failed/stale device-collector heartbeat closes native admission on macOS. Collector stderr is preserved in the incident record. Existing process supervisors also enroll managed workloads when the service is healthy.

Android launches and `rios` simulator boots share the existing two-device live pool and serialized boot pool. Each device holds a machine worker until shutdown via an independent lease holder. Devices have a 15-minute maximum lifetime and a five-minute CLI inactivity limit. Activity renewal cannot extend the maximum lifetime. The collector stops expired devices, devices whose owners ended and devices whose lease holders died. Prepared iOS devices retain their OS on disk after shutdown; legacy devices are deleted. Every removal addresses a registered generation or UDID. Stop/delete commands remain available.

## Inspection

```
python3 scripts/lib/cpu_guard.py status
launchctl print gui/$(id -u)/com.richos.cpu-guard
```

The state directory contains the heartbeat, ownership records, intervention history, latest alert and original Claude settings backups. The Bash guard refuses direct Gradle, Swift build/test, Xcode build, emulator and simulator-boot commands. It allows inspection and shutdown commands. Its parser distinguishes heredoc data from commands; it is not a shell sandbox.

## Boundaries

This is a circuit breaker, not a kernel CPU quota. Short spikes can occur before the sustained-load threshold. macOS scheduling, inaccessible processes and service failures can delay action. Unobserved children that immediately detach can evade ancestry tracking; exact device records cover the normal emulator detach path. Arbitrary code and indirect shell execution cannot be made unbypassable by a text hook. Other users' processes and privileged workloads are outside this per-user service.

Older active worktrees retain their old build scripts until updated. Their observed Claude descendants and registered emulators are still covered by the watchdog, but only updated entry points gain admission and compiler caps. External SSD availability is required. Direct command refusal in an already-running Claude host depends on its settings reload; external watchdog enforcement does not depend on Claude reading a hook or replying to an alert.

Do not claim that this makes host saturation impossible or promises 100% reliability.

## September 24 iOS recurrence

A fresh iOS simulator per proof triggered first-boot system work, followed by Xcode's automatic `simctl diagnose` dump. At peak load, `ps` repeatedly exceeded its five-second timeout. The previous watchdog only launched device cleanup after successful process sampling and called itself healthy even when that cleanup failed. Its discarded stderr means the exact cause of the historical collector exit 1 cannot be reconstructed.

Device cleanup now has its own launchd service. It reads Mach host counters independently of process enumeration. With a registered iOS simulator and sustained host pressure, it persists `ios-block.json` and shuts down exact registered UDIDs. Under pressure it attempts shutdown before either owner process lookup or simulator inventory, including records written by older checkouts. The CPU service also stops observed agent-owned simulator test owners and `simctl diagnose` descendants, while preserving session roots and unrelated processes. macOS/CoreSimulator can still delay RPCs; failures close admission and remain visible.

The incident stop stays across service restarts. `cpu_guard.py check-ios` refuses local simulator launches while it exists. `rios headless` and headless tests remain available. Only explicitly scheduled recovery should remove the incident stop, after inspecting `status` and updating active worktrees. Never remove it just to retry a failed proof. The user hook rejects recognized native/proof entrypoints from checkouts whose collector lacks the prepared-pool API. This is command/path validation, not an arbitrary-code sandbox.

`testdevices.py acquire-ios --type TYPE --runtime RUNTIME --owner-pid PID` leases a prepared simulator from a machine-wide pool. Its manifest is under `/Volumes/E1TB/caches/richos-ios-prepared`; Apple device storage remains in the previously approved default device set. Only one pool lease is active across checkouts, including across different device types. Each type/runtime is created once. A missing previously prepared device is an error, not an automatic fresh replacement. A new type/runtime still requires an initial boot, which must be scheduled. The incident stop prevents that boot now.

`boot-ios` waits for boot completion, uninstalls user apps and resets keychain and privacy permissions. It does not erase the simulator OS. `release-ios` checks the owner identity, shuts the device down and releases the lease without deleting the prepared OS. This isolates app containers and credentials but is not a factory-reset OS image. Tests requiring pristine system state need a separately scheduled cold-device test.

The native app, platform/share and UI suites use this pool. UI tests run their complete selection serially on each requested device type. `rios sim stop` reports `retained`, not `deleted`. Builds and Xcode tests use the capped launcher with `-collect-test-diagnostics never`; the installed Xcode's help confirms support for this flag.

No real simulator was booted to verify this recurrence fix, in accordance with the current scheduling restriction. Tests exercise reuse, app cleanup, ownership conflicts, old records, stalled process lookup and failure reporting through a fake CoreSimulator. Warm-boot CPU improvement still needs a scheduled on-machine measurement; do not represent these tests as that measurement.
