// swift-tools-version: 6.0
//
// RichOS native iPhone app — the core. Builds and tests on this Mac with no simulator.
//
// WHY THIS IS ITS OWN PACKAGE: the CEO's first rule for mobile work is a command-line loop that
// proves a change in seconds (Part 0; build plan §3.1 loop L1). Everything here is plain Swift over
// Foundation, so `swift test` runs it directly on macOS, and `bin/rios headless …` (loop L1′) runs
// the same actions the iPhone app runs. The app (`../project.yml`) links these same targets.
//
// Targets:
//   RichOSCore      AppState, Action, the pure reducer, Effect and the port protocols. Foundation
//                   only — no SwiftUI, no UIKit, nothing main-actor-bound.
//   RichOSFixtures  named starting states, scenarios and the command envelope shared by the CLI and
//                   the Debug app's bridge. Its sources are wrapped in `#if DEBUG`, so a Release build
//                   of the app links an empty module (`rios sim check-release` proves it).
//   RichOSCLI       the `rios-cli` executable behind `bin/rios`: headless mode over the real core,
//                   and the simulator driver (macOS only).
//
// Language mode: Swift 5 with complete strict-concurrency checking as warnings (build plan §3.2).
import PackageDescription

let strict: [SwiftSetting] = [.enableUpcomingFeature("StrictConcurrency")]

let package = Package(
    name: "RichOSCore",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "RichOSCore", targets: ["RichOSCore"]),
        .library(name: "RichOSFixtures", targets: ["RichOSFixtures"]),
        .executable(name: "rios-cli", targets: ["RichOSCLI"]),
    ],
    targets: [
        .target(name: "RichOSCore", swiftSettings: strict),
        .target(name: "RichOSFixtures", dependencies: ["RichOSCore"], swiftSettings: strict),
        .executableTarget(name: "RichOSCLI", dependencies: ["RichOSCore", "RichOSFixtures"], swiftSettings: strict),
        .testTarget(name: "RichOSCoreTests", dependencies: ["RichOSCore", "RichOSFixtures"], swiftSettings: strict),
    ],
    swiftLanguageModes: [.v5]
)
