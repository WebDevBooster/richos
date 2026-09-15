// swift-tools-version: 5.9
//
// RichOS macOS capture companion (P2) — the system architecture §5.2, feeding P1's frozen
// capture->pipeline contract (schemaVersion 2). See ./README.md.
//
// Two targets, deliberately:
//   - RichOSCompanionCore : PURE, hardware-free logic (contract writer, channel mixing, WAV,
//                           health records, ring buffer). This is what `swift test` exercises
//                           deterministically with no Core Audio / no TCC permission.
//   - richos-companion    : the executable — Core Audio process tap + mic capture (needs the
//                           "System Audio Recording" TCC grant) plus the headless `ingest`/`doctor`
//                           paths that DO run without any grant.
import PackageDescription

let package = Package(
    name: "richos-companion",
    platforms: [
        // Core Audio process taps (AudioHardwareCreateProcessTap / CATapDescription) are macOS 14.2+,
        // general system-audio capture usable from 14.4+ (architecture §5.2). Dev/host machine is 15.6.
        .macOS(.v14)
    ],
    targets: [
        .target(
            name: "RichOSCompanionCore"
        ),
        .executableTarget(
            name: "richos-companion",
            dependencies: ["RichOSCompanionCore"]
        ),
        .testTarget(
            name: "RichOSCompanionCoreTests",
            dependencies: ["RichOSCompanionCore"]
        ),
    ]
)
