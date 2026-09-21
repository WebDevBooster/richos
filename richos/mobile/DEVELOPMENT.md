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

## Android PWA through the same CLI

The Android PWA remains supported. `pwa` serves the actual `richos/web/web-app` source in Chromium at a 360 × 800 touch viewport, using the existing test Mac over loopback HTTPS. It performs the real pairing flow and verifies the certificate words. Its TLS exception accepts only that test certificate's public key; nothing is added to a keychain. The server binds only to `127.0.0.1`. Commands travel through local files, not a network control endpoint.

```sh
node richos/mobile/cli/mobile.mjs pwa prepare
node richos/mobile/cli/mobile.mjs pwa fixture offline
node richos/mobile/cli/mobile.mjs pwa action '{"type":"select-thread","threadId":"planning"}'
node richos/mobile/cli/mobile.mjs pwa action '{"type":"compose","text":"Hello Rich"}'
node richos/mobile/cli/mobile.mjs pwa action '{"type":"send"}'
node richos/mobile/cli/mobile.mjs pwa state
node richos/mobile/cli/mobile.mjs pwa screenshot
node richos/mobile/cli/mobile.mjs pwa action '{"type":"network","online":true}'
node richos/mobile/cli/mobile.mjs pwa verify
node richos/mobile/cli/mobile.mjs pwa refresh
node richos/mobile/cli/mobile.mjs pwa stop
```

`prepare` starts a reusable browser session with the offline fixture. Set `RICHOS_PWA_HEADED=1` on that first command to open its window. Playwright is resolved through the repository's existing browser harness, including the main checkout's install for linked worktrees; `RICHOS_PLAYWRIGHT` can explicitly name its module. Chromium must be installed in that Playwright's browser cache. No dependency is added to the shipped PWA or mobile app. Missing tooling fails explicitly.

PWA actions use visible controls for compose, send, conversation selection and retry. The `network` action changes browser connectivity. Fixtures are `offline`, `online`, `queued` and `revoked`; the last configures the test Mac to reject subsequent authenticated requests. `transport accept|unreachable|revoked` controls that server. `reset` starts a fresh paired offline context. `restart` closes and reopens the page in the same browser context; it is not a full browser-process restart. `refresh` brings the test network online, clears only shell caches and reloads current source while preserving IndexedDB and pairing. `stop` closes the browser and server. Sessions are disposable and do not touch a user's phone or real Mac identity.

`pwa verify` (also `pwa scenario offline-reconnect`) first runs the shared deterministic headless scenario, then uses the actual PWA's conversation picker, composer and Send button. It proves that a queued message survives an offline page reload through the service worker and IndexedDB, then reaches the synthetic Mac once after reconnect with the same client ID and conversation. It reports semantic snapshots and checks for uncaught browser exceptions. Screenshots are under the external cache's `pwa/output/playwright/` directory.

The shared production module today is `web-app/lib/queue.js`. The PWA retains its existing controller; it does not yet run the minimal native shell's entire `core/app.js`. Both use one CLI and the same queue implementation. Browser checks use real browser time and random signing/message IDs, so their trace is checked for behavior rather than exact equality with the deterministic native/headless trace. `advance` and synthetic lost-ack commands belong to the headless/simulator targets. As further behavior is extracted or added, keep it headless and shared where applicable. Android microphone, push, installation and background behavior still need physical-phone verification.

## Registered repository proofs

The repository runner discovers these suites under `richos/app/scripts`:

- `mobile-headless.test.sh`: `npm test` runs the core and CLI tests in disposable external sessions. It verifies persistence across real CLI processes, structured errors, locking, resource selection and the unpaired Release bootstrap. It needs Node and npm, with no simulator or browser.
- `mobile-pwa.test.sh`: runs the actual Chromium PWA target through pairing, visible Send, offline reload, reconnect, page restart and source refresh. Playwright/Chromium absence is `NOT RUN`, exit 2. The suite forces headless mode and stops its worker.
- `mobile-ios.test.sh`: builds a dedicated simulator app, compares all three native/headless traces, checks process persistence and refresh, runs the visible-control XCUITest and verifies Release exclusion. Missing macOS/Xcode/XcodeGen or an available iOS runtime is `NOT RUN`, exit 2. Build/test failures on a capable host exit 1.

```sh
bash richos/app/scripts/run-tests.sh --no-host-screen --only mobile-headless.test.sh
bash richos/app/scripts/run-tests.sh --no-host-screen --only mobile-pwa.test.sh
RICHOS_MOBILE_SIMULATOR_STORAGE=system bash richos/app/scripts/run-tests.sh --no-host-screen --only mobile-ios.test.sh
```

The last command uses Apple's system simulator storage only where the owner has authorized it. Native proof builds and its dedicated device metadata use `/Volumes/E1TB/caches/richos-mobile-ios-proof/<checkout-hash>/`, separate from interactive development state. `RICHOS_MOBILE_IOS_TEST_CACHE` can select another external proof cache. The suite locks that cache for its whole run and shuts down only its selected simulator. Browser and headless test scratch directories are unique and removed after completion.

An unavailable host never earns a passing proof. `run-tests.sh` refuses undeclared exit-2 gaps. To record a known missing runtime without treating it as a product failure, set `RUN_TESTS_DECLARED_GAPS='mobile-ios.test.sh: <actual host reason>'`. A stale declaration on a capable host is rejected too. Both missing-runtime and missing-browser paths have regression tests.

Each suite has dependency `inputs` and exact-file `covers` rows. Coverage describes the assertions above, not all behavior in a directory. A new unproved module remains `UNCOVERED` even if an input directory selects a suite. On an integration merge, `bash richos/app/scripts/proof-for.sh HEAD^1..HEAD` must exit 0; that command selects proofs but does not execute them.

## Boundaries

- `core/`: real application actions and state, backed by the PWA queue. Add new behavior here before wiring controls.
- `ui/`: rendering and input events. Its release entry has no fake Mac connection and keeps sending disabled until real pairing adapters exist.
- `dev/`: deterministic environment adapters, persistent synthetic receipts and scenarios. The simulated Mac's receipt table models deduplication; it does not test a real Mac server.
- `cli/`: headless persistence, resource packaging and simulator orchestration. The same request envelope reaches the development runtime in both modes.
- `ios/`: minimal host and one focused visible-control test.

Development fixture access and commands are compiled only for Debug simulator builds. The native bridge polls for UUID-named local sandbox command files while the Debug simulator app is running. It uses no URL scheme or confirmation dialogs. It exposes neither a network listener nor arbitrary JavaScript evaluation. The webview loads local resources only. Debug assets are separate from Release assets; `check-release` builds Release and inspects its executable, Info.plist and resources for development markers and URL registration. This simulator Release check is not signed App Store artifact verification.

Each CLI invocation locks its checkout's target session to prevent overlapping resets or installs. The browser target has its own `pwa.cli.lock`, so it can run alongside native checks. On a crash, inspect `cli.lock/owner.json` and confirm the PID is gone before removing the lock. A timed-out simulator request is a failure, not a successful action; inspect state before retrying a send.

## Storage and measurements

Projects, DerivedData, generated resources, command results and screenshots are kept under `/Volumes/E1TB/caches/richos-mobile/<checkout-hash>/`. `RICHOS_MOBILE_CACHE` can select another directory on that volume. The CLI refuses an absent volume and never redirects build output into the repository. By default the CLI uses a separate simulator device set on the external SSD. Some macOS installations deny CoreSimulator access to external volumes. It never silently falls back: where the workspace owner permits Apple's default system-managed device storage, choose a fresh cache and set `RICHOS_MOBILE_SIMULATOR_STORAGE=system` for the first simulator command. The choice is then saved in that cache. Existing devices and global Simulator preferences are untouched. Build output remains external under either policy. Xcode UI-test destination discovery for an external device set is not assumed; verify it on the development machine.

Keep measured timings and private verification reports in `richos-hq`. Measure these separately: a fresh Node process running a focused scenario, direct core execution, JavaScript screen refresh, Swift incremental build, cold build/install/boot and native UI automation. Cold simulator boot and UI automation are not part of a routine application-logic edit. Establish budgets from measured results; a green fixture is not evidence about real microphone permissions, radio transitions, APNs or App Store installation.

For new platform behavior, add a narrow adapter and controllable outcomes without importing platform APIs into the core. Update-policy evaluation belongs in the same core and must be runnable headlessly when implemented. Validate actual store availability and installation separately on real devices.
