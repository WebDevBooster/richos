# Mobile development loop

The mobile UI and CLI run the same `core/app.js` action handlers. That core imports the existing PWA's `lib/queue.js` directly. Packaging copies that exact file into the iOS app; there is no second queue implementation or source fork.

The minimal Swift/WKWebView host proves the development workflow. It is not yet a complete phone client. Pairing, native microphone integration, real Mac transport, notifications and update-policy behavior are subsequent slices. The final client framework remains a feasibility decision.

## Headless first

Requires Node.js with the built-in test runner. No npm dependencies or simulator are needed. Run from the repository root:

```sh
node --test richos/mobile/test/*.test.js
node richos/mobile/cli/mobile.mjs headless scenario offline-reconnect
node richos/mobile/cli/mobile.mjs headless scenario interrupted
node richos/mobile/cli/mobile.mjs headless scenario revoked
```

`offline-reconnect` queues a message in the selected conversation while offline, reconstructs the application from durable state, reconnects to a simulated Mac that accepts the message but loses its acknowledgement, reconstructs again and advances a controlled clock through the retry deadline. It verifies one logical delivery and the same message ID on retry. No sleeps or real network are involved.

CLI output is JSON with an `ok` flag, elapsed milliseconds and semantic state. Errors exit nonzero with a structured explanation. Each scenario resets its own state. Stateful commands share a persisted headless session in the external cache:

```sh
node richos/mobile/cli/mobile.mjs headless fixture offline
node richos/mobile/cli/mobile.mjs headless action '{"type":"select-thread","threadId":"planning"}'
node richos/mobile/cli/mobile.mjs headless action '{"type":"compose","text":"Hello Rich"}'
node richos/mobile/cli/mobile.mjs headless action '{"type":"send"}'
node richos/mobile/cli/mobile.mjs headless state
node richos/mobile/cli/mobile.mjs headless action '{"type":"network","online":true}'
```

Other commands: `reset`, `restart`, `transport accept|unreachable|lose-ack|revoked` and `advance <milliseconds>`. Fixtures: `offline`, `online`, `queued`, `interrupted` and `revoked`. `action` accepts `compose`, `send`, `select-thread`, `network`, `sync`, `retry` and `discard`. Unknown actions and fixture names fail explicitly.

## Simulator through the same CLI

Requires macOS, Xcode with an installed iOS simulator runtime and XcodeGen. `doctor` reports the actual tool versions and cache paths. The checked-in Swift source targets iOS 16.7; simulator success is not proof of physical-device compatibility.

```sh
node richos/mobile/cli/mobile.mjs doctor
node richos/mobile/cli/mobile.mjs sim prepare
node richos/mobile/cli/mobile.mjs sim scenario offline-reconnect
node richos/mobile/cli/mobile.mjs sim fixture queued
node richos/mobile/cli/mobile.mjs sim state
node richos/mobile/cli/mobile.mjs sim refresh
node richos/mobile/cli/mobile.mjs sim verify
node richos/mobile/cli/mobile.mjs sim ui-test
node richos/mobile/cli/mobile.mjs check-release
```

`prepare` generates the Xcode project outside the repository, builds the minimal Debug app and installs it in a dedicated simulator. It does not launch the Simulator desktop window. `refresh` copies the current JavaScript/CSS/HTML into the running development app and reloads it without compiling Swift. All headless state, action, fixture and scenario commands also work with `sim`.

`sim verify` compares the complete semantic trace from three scenarios between Node and the real WKWebView runtime. It separately terminates and relaunches the native app and checks that its queued message survives. `sim restart` is an actual native-process restart; the scenario's `restart` step reconstructs only the application core.

`sim ui-test` resets to the offline fixture, uses XCUITest to type into the visible composer and tap Send, then checks the resulting queue through the CLI bridge. This is intentionally separate from direct action execution. It stores an `.xcresult` including a screenshot in the external cache. `sim screenshot` captures the current screen without opening a desktop window.

## Boundaries

- `core/`: real application actions and state, backed by the PWA queue. Add new behavior here before wiring controls.
- `ui/`: rendering and input events. Its release entry has no fake Mac connection and keeps sending disabled until real pairing adapters exist.
- `dev/`: deterministic environment adapters, persistent synthetic receipts and scenarios. The simulated Mac's receipt table models deduplication; it does not test a real Mac server.
- `cli/`: headless persistence, resource packaging and simulator orchestration. The same request envelope reaches the development runtime in both modes.
- `ios/`: minimal host and one focused visible-control test.

Development fixture access and commands are compiled only for Debug simulator builds. The native bridge accepts a UUID referencing a local sandbox command file. It exposes neither a network listener nor arbitrary JavaScript evaluation. The webview loads local resources only. Debug assets are separate from Release assets; `check-release` builds Release and inspects its executable, Info.plist and resources for development markers and URL registration. This simulator Release check is not signed App Store artifact verification.

Each CLI invocation locks its checkout's cache to prevent overlapping resets or installs. On a crash, inspect `cli.lock/owner.json` and confirm the PID is gone before removing the lock. A timed-out simulator request is a failure, not a successful action; inspect state before retrying a send.

## Storage and measurements

Projects, DerivedData, generated resources, command results and screenshots are kept under `/Volumes/E1TB/caches/richos-mobile/<checkout-hash>/`. `RICHOS_MOBILE_CACHE` can select another directory on that volume. The CLI refuses an absent volume and never redirects build output into the repository. By default the CLI uses a separate simulator device set on the external SSD. Some macOS installations deny CoreSimulator access to external volumes. It never silently falls back: where the workspace owner permits Apple's default system-managed device storage, choose a fresh cache and set `RICHOS_MOBILE_SIMULATOR_STORAGE=system` for the first simulator command. The choice is then saved in that cache. Existing devices and global Simulator preferences are untouched. Build output remains external under either policy. Xcode UI-test destination discovery for an external device set is not assumed; verify it on the development machine.

Keep measured timings and private verification reports in `richos-hq`. Measure these separately: a fresh Node process running a focused scenario, direct core execution, JavaScript screen refresh, Swift incremental build, cold build/install/boot and native UI automation. Cold simulator boot and UI automation are not part of a routine application-logic edit. Establish budgets from measured results; a green fixture is not evidence about real microphone permissions, radio transitions, APNs or App Store installation.

For new platform behavior, add a narrow adapter and controllable outcomes without importing platform APIs into the core. Update-policy evaluation belongs in the same core and must be runnable headlessly when implemented. Validate actual store availability and installation separately on real devices.
