# RichOS native iPhone app

SwiftUI, iOS 17 and later. This is the new native app. The preserved app in `../ios/`, `../ui/` and
the PWA in `../../web/web-app/` are separate and are not modified from here.

**The command line comes first.** Application behavior lives in `Core/`, a Swift package that builds
and tests on this Mac with no simulator. The SwiftUI app renders the core's `AppState` and dispatches
its `Action`s; the command line dispatches the same actions and prints the same state. A logic change
is proven in seconds with `bin/rios test` or `bin/rios headless`, and only screen, gesture and
platform work needs the simulator.

## Commands

Run from the repository root or anywhere; `bin/rios` finds its own checkout.

| Loop | Command | What it proves |
|---|---|---|
| L1 logic | `richos/mobile/native-ios/bin/rios test` (add `--filter <name>` for one suite) | The core's unit tests, on this Mac, no simulator. |
| L1′ headless | `richos/mobile/native-ios/bin/rios headless scenario compose-draft` | The real core runs a scenario and prints its trace. |
| L2 simulator | `richos/mobile/native-ios/bin/rios sim prepare`, then `sim state`, `sim fixture conv-empty`, `sim action '<json>'`, `sim screenshot` | The same commands inside the Debug app on a simulator the CLI created. |

`bin/rios --help` lists every command. Output is JSON: `{ok, mode, command, elapsedMs, result}` on
stdout, or `{ok:false, error, elapsedMs}` on stderr with exit 1 — the preserved mobile CLI's grammar
and shape (`../cli/mobile.mjs`), so existing QA habits carry over.

Headless commands share one session in the cache. Fixtures are named after the round-12 screen they
produce (`pair-intro`, `pair-words`, `conv-empty`, `conv-populated`, `conn-revoked`).

## Layout and ownership

| Path | What | Owner stream (build plan §5.0) |
|---|---|---|
| `Core/` | Swift package: `RichOSCore` (state, actions, reducer, effects, ports), `RichOSFixtures` (fixtures, scenarios, command envelope; `#if DEBUG` only), `RichOSCLI` (`rios-cli`) | I1 |
| `bin/rios` | The one command-line entry | I1 |
| `project.yml` | XcodeGen spec; the Xcode project is generated into the cache, never into the repository | I1 |
| `DevBridge/` | Debug-only command mailbox inside the app; excluded from Release | I1 |
| `App/App/` | App entry and the `AppStore` wiring | I1 |
| `App/Features/`, `App/Design/`, `UITests/` | Screens, design system, UI tests | I2 |

## Where things are written

Everything generated goes under one per-checkout cache on the external SSD:
`/Volumes/E1TB/caches/richos-native-ios/<checkout-hash>/` (override with `RICHOS_NATIVE_IOS_CACHE`,
which must stay on `/Volumes/E1TB`). That holds SwiftPM's scratch directory, the Clang module cache,
the generated Xcode project, DerivedData and the headless session. Nothing is written into the source
tree.

## Rules this app keeps

- Core types are `Sendable` values and actors, never `@MainActor`; the one `@Observable` store lives on
  the main actor in the app. Swift 5 language mode with complete strict-concurrency checking.
- Fixtures and the development command envelope are compiled only in Debug.
- The CLI addresses only the simulator it created (its UDID is recorded in the cache); it never uses
  `booted`, and `sim stop` shuts it down and deletes it.
- Development bundle identifier `dev.richos.native.ios`. The production identifier is the CEO's.
