# Mobile development loop

The mobile UI and CLI run the same `core/app.js` action handlers. That core imports the existing PWA's `lib/queue.js` directly. Packaging copies that exact file into the iOS app; there is no second queue implementation or source fork.

The Swift/WKWebView client now includes native recording/playback, protected signing, pairing, conversation history, drafts, offline text delivery and update controls. It reuses the PWA stylesheet and its API, thread, fingerprint, stream and queue modules. Voice submission and notifications belong to Part 4; managed RichOS Connect belongs to Part 3. This is an installable technical pilot, not the public consumer release.

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

The shared production modules include the PWA queue, API, thread model, inbound validation, fingerprint and stream owner. The PWA retains its existing controller; it does not yet run the minimal native shell's entire `core/app.js`. Both use one CLI and the same queue implementation. Browser checks use real browser time and random signing/message IDs, so their trace is checked for behavior rather than exact equality with the deterministic native/headless trace. `advance` and synthetic lost-ack commands belong to the headless/simulator targets. As further behavior is extracted or added, keep it headless and shared where applicable. Android microphone, push, installation and background behavior still need physical-phone verification.

## Native client

The Swift/WKWebView client uses the PWA's API, signing-input contract, fingerprint phrase,
single event-stream owner and durable queue. `core/client.js` owns pairing confirmation,
messages, reconnect cursors and recording actions. `platform/native.js` adapts those ports
to protected files, Keychain signing, URLSession and AVAudioRecorder. The private key and
recording bytes stay behind the native boundary. The current voice control saves bounded
recordings locally; it does not claim the Mac accepts uploaded voice.

```sh
node richos/mobile/cli/mobile.mjs client scenario connection-restart
node richos/mobile/cli/mobile.mjs client scenario recording-interruption
node richos/mobile/cli/mobile.mjs sim client-prepare
node richos/mobile/cli/mobile.mjs sim action '{"type":"compose","text":"Client action check"}'
node richos/mobile/cli/mobile.mjs sim state
node richos/mobile/cli/mobile.mjs sim refresh
```

The client scenarios use replaceable transport/recording ports and execute the actual
client actions. They cannot prove microphone permission or hardware behavior. The simulator
client commands use real native adapters. `sim prepare` returns to the original deterministic
fixture host. Both screens support source refresh through the same CLI.

Physical builds and focused checks use the connected device identifier and signing team:

```sh
RICHOS_IOS_DEVICE=<device-id> RICHOS_APPLE_TEAM=<team-id> node richos/mobile/cli/mobile.mjs device build
RICHOS_IOS_DEVICE=<device-id> RICHOS_APPLE_TEAM=<team-id> node richos/mobile/cli/mobile.mjs device verify recording
RICHOS_IOS_DEVICE=<device-id> RICHOS_APPLE_TEAM=<team-id> RICHOS_MOBILE_TEST_CONFIG=<external-json-path> node richos/mobile/cli/mobile.mjs device verify text
```

The external JSON has `pairLink` and `words` for an isolated test server. It is copied only
into the test bundle. `lab serve` starts an expiring loopback protocol server with its own
identity, pairing and synthetic replies; it never opens the user's real Mac identity or
conversation store. `RICHOS_LAB_PORT` optionally fixes its loopback port. For a phone,
expose that loopback port through a private HTTPS test route such as Tailscale Serve.
The lab uses a verified TLS upstream; it does not bypass certificate validation. Its
mode-0600 `lab.json` contains a single-use pairing code and test status. Stop the owned lab
process with SIGTERM and stop its separately started Serve process after testing.

Physical test logs stream to the external cache as the test runs. The runner monitors
the pre-existing host USB devices, stops its own process group if one disappears or resets,
enforces a time limit and never resets USB or retries a failed physical test automatically.
That detects a disruption; it does not prove the initiating cause or prevent every USB fault.
XCUITest stops on its first assertion failure and terminates its app during teardown.
Recording-start failure also releases the audio session and removes its partial file.

Simulator proofs explicitly skip live microphone recording, which would use the host Mac's
microphone. Run the named physical recording check for that evidence. A missing remote
configuration is an explicit skipped remote test, never evidence of connectivity. The
headless suite tests supervision and orchestration with substituted process/device ports;
it does not claim those tests exercise Xcode or a physical USB device.

## Registered repository proofs

The repository runner discovers these suites under `richos/app/scripts`:

- `mobile-headless.test.sh`: `npm test` runs the core and CLI tests in disposable external sessions. It verifies persistence across real CLI processes, structured errors, locking, resource selection and the unpaired Release bootstrap. It needs Node and npm, with no simulator or browser.
- `mobile-pwa.test.sh`: runs the actual Chromium PWA target through pairing, visible Send, offline reload, reconnect, page restart and source refresh. Playwright/Chromium absence is `NOT RUN`, exit 2. The suite forces headless mode and stops its worker.
- `mobile-ios.test.sh`: builds a dedicated simulator app, compares all three native/headless traces, checks process persistence and refresh, runs the visible-control XCUITest and verifies Release exclusion. Missing macOS/Xcode/XcodeGen or an available iOS runtime is `NOT RUN`, exit 2. Build/test failures on a capable host exit 1.

```sh
bash richos/app/scripts/run-tests.sh --no-host-screen --only mobile-headless.test.sh
bash richos/app/scripts/run-tests.sh --no-host-screen --only mobile-pwa.test.sh
bash richos/app/scripts/run-tests.sh --no-host-screen --only mobile-ios.test.sh
```

All three suites choose unique scratch on the mounted external SSD and pass a scoped `TMPDIR` to their descendants. An existing external `TMPDIR` is respected; an unset or non-external value uses `/Volumes/E1TB/tmp/codex/`. The caller's environment and nightly configuration are unchanged. Scratch is removed after child processes finish. An absent SSD reports `NOT RUN`, exit 2, consistently.

The iOS proof suite defaults explicitly to Apple's system device storage, using the owner's approved simulator exception. The external custom device set fails on this development Mac with CoreSimulator `NSCocoaErrorDomain 513`/`EPERM` and simctl exit 22. No environment override is needed for an ordinary suite run. `RICHOS_MOBILE_SIMULATOR_STORAGE=external` remains an explicit opt-in for hosts that support it; a failed creation is still a failure, never a silent fallback or pass. The interactive CLI's existing storage defaults are unchanged.

Native proof builds remain external under `/Volumes/E1TB/caches/richos-mobile-ios-proof/<checkout-hash>-<storage>/`. A matching older `<checkout-hash>/` cache is reused. An incompatible saved policy is preserved and gets a separate policy-specific cache instead of being overwritten. `RICHOS_MOBILE_IOS_TEST_CACHE` can explicitly select another external cache, subject to the CLI's saved-policy checks. The suite locks that cache for its whole run and shuts down only its selected simulator. Reusable build caches remain available; tests do not delete another run's cache.

An unavailable host never earns a passing proof. `run-tests.sh` refuses undeclared exit-2 gaps. To record a known missing runtime without treating it as a product failure, set `RUN_TESTS_DECLARED_GAPS='mobile-ios.test.sh: <actual host reason>'`. A stale declaration on a capable host is rejected too. Both missing-runtime and missing-browser paths have regression tests.

Each suite has dependency `inputs` and exact-file `covers` rows. Coverage describes the assertions above, not all behavior in a directory. A new unproved module remains `UNCOVERED` even if an input directory selects a suite. On an integration merge, `bash richos/app/scripts/proof-for.sh HEAD^1..HEAD` must exit 0; that command selects proofs but does not execute them.

## Boundaries

- `core/`: real application actions and state, backed by the PWA queue. Add new behavior here before wiring controls.
- `ui/`: rendering and input events. The release client starts unpaired and enables sending only after the user confirms pairing.
- `dev/`: deterministic environment adapters, persistent synthetic receipts and scenarios. The simulated Mac's receipt table models deduplication; it does not test a real Mac server.
- `cli/`: headless persistence, resource packaging and simulator orchestration. The same request envelope reaches the development runtime in both modes.
- `ios/`: native services and focused visible-control checks; physical recording and remote text are separate selectable tests.

Development fixture access and commands are compiled only for Debug simulator builds. The native bridge polls for UUID-named local sandbox command files while the Debug simulator app is running. Development commands use no URL scheme. The production `richos://conversation/` scheme accepts only validated conversation destinations; it cannot execute commands or initiate pairing. It exposes neither a network listener nor arbitrary JavaScript evaluation. The webview loads local resources only. Debug assets are separate from Release assets; `check-release` builds Release and inspects its executable, Info.plist and resources for development markers and unexpected URL registrations. This simulator Release check is not signed App Store artifact verification.

Each CLI invocation locks its checkout's target session to prevent overlapping resets or installs. The browser target has its own `pwa.cli.lock`, so it can run alongside native checks. On a crash, inspect `cli.lock/owner.json` and confirm the PID is gone before removing the lock. A timed-out simulator request is a failure, not a successful action; inspect state before retrying a send.

## Storage and measurements

Projects, DerivedData, generated resources, command results and screenshots are kept under `/Volumes/E1TB/caches/richos-mobile/<checkout-hash>/`. `RICHOS_MOBILE_CACHE` can select another directory on that volume. The CLI refuses an absent volume and never redirects build output into the repository. By default the CLI uses a separate simulator device set on the external SSD. Some macOS installations deny CoreSimulator access to external volumes. It never silently falls back: where the workspace owner permits Apple's default system-managed device storage, choose a fresh cache and set `RICHOS_MOBILE_SIMULATOR_STORAGE=system` for the first simulator command. The choice is then saved in that cache. Existing devices and global Simulator preferences are untouched. Build output remains external under either policy. Xcode UI-test destination discovery for an external device set is not assumed; verify it on the development machine.

Keep measured timings and private verification reports in `richos-hq`. Measure these separately: a fresh Node process running a focused scenario, direct core execution, JavaScript screen refresh, Swift incremental build, cold build/install/boot and native UI automation. Cold simulator boot and UI automation are not part of a routine application-logic edit. Establish budgets from measured results; a green fixture is not evidence about real microphone permissions, radio transitions, APNs or App Store installation.

For new platform behavior, add a narrow adapter and controllable outcomes without importing platform APIs into the core. Update-policy evaluation runs in `core/updates.js` and is exercised through the same client actions in Node and the simulator. Validate actual store availability and installation separately on real devices.

## Real Mac protocol integration

`bash richos/app/scripts/mobile-mac.test.sh` runs the actual client actions and native-shaped transport adapter against the production Rust phone listener, authentication, intake, Spine and gated timeline. It verifies fingerprint confirmation, signed messages, invalid-signature refusal, deduplication and a fresh reply after client restart. The provider produces deterministic replies and a test adapter replaces the desktop AppHandle bridge. This proves the transport/core integration without using an AI account or a person's conversations.

For a physical test, start `node richos/mobile/cli/mobile.mjs lab mac` with `RICHOS_MOBILE_MAC_ORIGIN` set to your separate HTTPS test origin. Wait for its ready result before reading `mac.json` for the loopback proxy port. Expose that port using a separately owned Tailscale Serve endpoint. The proxy verifies the Rust server's private test CA; the phone verifies the public endpoint with system TLS. No trust bypass is required.

The server writes `mac-test-config.json` in its cache. Pass that path through `RICHOS_MOBILE_TEST_CONFIG`, set `RICHOS_MOBILE_TEST_APP=integration`, `RICHOS_IOS_DEVICE` and `RICHOS_APPLE_TEAM`, then run `node richos/mobile/cli/mobile.mjs device verify text`. Pairing codes expire after five minutes. Stop and restart the lab for a fresh code if needed.

The integration profile installs `dev.richos.mobile.integration` and uses an `integration` subdirectory beneath the selected cache. A Debug-only launch argument clears this app's saved session once per new server run. It preserves recordings and does not affect the ordinary app or the Android pairing. Relaunches with the same run marker keep their session, which the physical test verifies by receiving another fresh reply after restart. Release verification checks that this reset mechanism is absent.

Stop the foreground lab and its separately owned Tailscale Serve endpoint after testing. The lab closes its sockets, retains synthetic timeline/intake/ledger evidence in the cache and deletes its scratch data. `lab serve` remains the faster JavaScript protocol fixture; it is not the production Rust server.


## Part 2 actions and persistence

`client scenario update-controls` drives banner, dialog, blocking and withdrawn policies through the actual client. `sim client-prepare` opens the actual native renderer. In a Debug simulator, `sim policy '<JSON>'` installs a policy through substituted update-service ports; it does not rewrite the policy evaluator. The fixture client identifier is deliberately synthetic and is never bundled in a physical-device or Release build.

The client caches server-ordered history per conversation and keeps each conversation's draft. The outbox remains the PWA queue, including its idempotency IDs and retry schedule. An active send does not hold up typing, navigation or suspension. Retries have a foreground timer. Version-unsupported responses and disabled actions are retained for attention rather than retried indefinitely. The Mac's existing protocol is version 1 when a legacy hello omits `protocol_version`; incompatible explicit versions disable text. Native requests advertise protocol, marketing version and build.

Session schema 2 migrates the Part 1 cache without deleting drafts or the outbox. Unknown schemas and corrupt stored data fail with a recovery message and leave the file intact. Only the replaceable conversation cache is evicted to bound disk use. Unsent work is never evicted. The app refuses to change pairing while unresolved text remains. Local forgetting is separate from revoking the device on the Mac.

Pairing accepts a pasted HTTPS link or a native QR scan, followed by the existing fingerprint comparison. A scan only fills the link field; it does not automatically trust the Mac. Conversation links accept `richos://conversation/#thread=<id>&at=<id>` and explicitly configured universal-link hosts. The PWA's inbound validator checks the payload. Universal links require the matching associated-domain website file before deployment. External HTTPS links open outside the privileged webview. Remote HTML and scripts cannot enter that view.

Recording files are protected native files. Record, stop, cancel, play and delete are native actions. Microphone denial has a Settings recovery button. Playable files left by process termination are recovered into the recording list. Recording is limited to 60 seconds, ten files and two megabytes per file. A critical policy stops and retains captured audio; uploaded voice is not implemented by this slice.

## Release configuration and update service

`release-config.json` contains marketing version, build, numeric `appId`, `policyURL`, `supportURL`, optional `universalHosts` and the `metrics` switch. `RICHOS_MOBILE_RELEASE_CONFIG` can supply an external build configuration. The selected configuration is validated and bundled with the app; it cannot be changed by remote policy data. Development defaults have no App Store ID or hosted policy endpoint and metrics are off. Do not invent an ID to fill them.

`node richos/mobile/cli/mobile.mjs release-config-check` fails until the listing and HTTPS policy/support destinations are configured. This checks configuration only. It does not certify licensing, App Review eligibility, signing, artwork completeness or successful distribution. The pilot reuses the PWA's 180-pixel home-screen artwork for the iPhone X; complete the store artwork set before submission. `check-release` separately verifies that fixture scripts, synthetic update data and native development commands are absent from Release.

See [the update-service runbook](service/README.md) for schema, publication, expiry recovery, availability receipts, metrics and deployment boundaries. The service has a separate native network session from the paired Mac. It uses HTTPS policy fetches plus foreground SSE change hints. Hints trigger a coalesced refetch; a 60-second fallback remains active if streaming fails. Cold start, foreground return and network recovery also trigger checks. Invalid data and service outages do not introduce a lockout. Previously validated policy remains authoritative only until its expiry, at most 24 hours after issue.

For the physical service proof, start `lab updates` in a separate cache, expose its printed loopback port through an isolated private HTTPS route and supply that `/v1/policy` URL in an external release configuration. Pass a test-bundle JSON with `{"updateServiceTest":"true"}` and run `device verify updates`. The fixture publishes a recording pause after the first policy fetch, then withdraws it with a higher revision. The XCUITest checks both visible action states with the real native adapter. The lab retains publication/request timestamps. It never supplies a fabricated App Store destination. Stop its owned process and route after the check.

Actual App Store listing navigation, storefront download availability and an old-to-new Store installation remain distribution checks that require the real listing and released builds. Managed-route verification requires Part 3. A simulated notice or successful development install cannot stand in for those checks.
