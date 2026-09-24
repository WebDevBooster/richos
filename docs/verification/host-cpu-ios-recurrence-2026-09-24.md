# iOS CPU recurrence: prepared devices and independent cleanup

The first CPU fix was incomplete. The Claude transcript records fresh simulator first boots around 01:37 BST, another simulator plus `simctl diagnose` around 01:40 and load average 433 with essentially no idle CPU around 01:42. The original watchdog repeatedly timed out in `ps`, delaying its device cleanup. It also reported healthy process sampling while cleanup exited 1. Historical collector stderr was discarded, so the precise original exit-1 cause is not established.

## Changes

- `testdevices.py` now maintains a shared prepared-device pool, keyed by device type and runtime, with one active lease across checkouts. It creates each device once and retains the shut-down OS between runs. Missing previously prepared devices fail explicitly instead of silently triggering another cold creation.
- Booting a new lease removes installed user apps and resets keychain and privacy permissions. It preserves system preparation rather than running `simctl erase`. It is not a factory-reset OS image. Tests requiring that must be scheduled separately.
- The native app, platform/share and UI tests now acquire/release this pool. UI device types run serially. The CLI reports the retained device rather than claiming it was deleted. Ownership checks prevent stale cache records from using or releasing another run's lease.
- Release checks and simulator Xcode commands use the capped native launcher. It forces `-collect-test-diagnostics never` and disables performance diagnostics. The installed Xcode help confirms these options. The native wrapper refuses device boots and diagnostic dumps passed to it directly.
- `com.richos.cpu-guard.devices` is an independent launchd service. Its Mach CPU counters do not enumerate processes. Incident cleanup shuts down exact registered simulator UDIDs before asking for owner process status or full device inventory. This includes the old registration format, without CPU leases.
- Overall guard health requires both workers. Cleanup failures preserve stderr and close native admission. Under sustained pressure with a registered simulator, the incident stop is persistent across restarts.
- The installed user hook rejects recognized old-checkout native/proof entrypoints, local simulator suites during the incident stop and direct `simctl diagnose`. It permits headless commands and shutdown. Indirect arbitrary code remains outside what a text hook can prove.

Implementation first committed as `6216311a` on `codex/host-cpu-enforcement`, fast-forwarded into local main and installed. The follow-up commit containing this report tightens refusal messages and prevents direct diagnostic/device commands being routed through the native wrapper.

## Verification

- 22 CPU guard/native admission tests passed.
- 55 device collector/pool tests passed. These use fake CoreSimulator state and real bounded test processes. Two complete pool leases used the same UDID, created once, reset app/keychain state twice and never erased or deleted the prepared OS. Tests also cover exclusive ownership, stale caches, legacy records, failed cleanup and missing process lookup.
- Swift syntax parsing and shell syntax checks passed. `rios headless state` rebuilt the changed CLI and returned successfully, without a simulator.
- Installed-hook payload probes refused Isaac's older proof entrypoint, a local simulator suite and `simctl diagnose`; headless state and shutdown were allowed. These payload commands were not executed. The real simulator suite entrypoint was also invoked and refused before creating output or starting a simulator.
- Live CPU worker PID 95579 was SIGSTOPped for six seconds, then resumed in a finally block. Its heartbeat stayed unchanged while device worker PID 95576 advanced its successful heartbeat by 6.93 seconds.
- Killing only the independent device worker caused launchd to restart it as PID 45926 in 0.26 seconds in this observation.
- Both services subsequently reported healthy. Simulator inventory showed no booted devices.

Evidence: `/Volumes/E1TB/ab/host-cpu-ios-recovery/` contains `cpu-tests.log`, `device-tests.log`, `independent-services.json`, `device-service-restart.json`, `admission.json`, `rios-headless.json` and `rios-headless.log`.

## Current operational state and limits

The persistent `ios-block.json` is active, preserving the instruction that no simulator runs occur until explicitly scheduled. It is not automatically cleared after a cooldown. No real simulator was booted for this verification. The pool's actual first preparation and warm-boot CPU improvement remain unmeasured on this Mac and must be measured during that scheduled run. A new device type/runtime still needs one initial boot.

This removes repeated fresh-device creation from the updated paths and automatic Xcode diagnostics from the capped launcher. It does not guarantee zero CPU spikes, bound CoreSimulator RPC latency or sandbox every older/custom script. Active worktrees must take the changes before their next native/proof run. Changes are committed locally, not pushed by this task.
