import Foundation
import Testing
import UIKit
@testable import RichOSNative

/// `LaunchTiming` (the app's own launch and return clock, `perf.py ios --tap-launches`): the kernel's
/// start time of this process is read correctly, and the tool's line names stay what it parses.
@Suite("Launch timing")
@MainActor
struct LaunchTimingTests {
    @Test func theKernelStartTimeIsThisProcesssSpawnOnTheWallClock() throws {
        let start = try #require(LaunchTiming.processStartMicros())
        var tv = timeval()
        gettimeofday(&tv, nil)
        let now = Int64(tv.tv_sec) * 1_000_000 + Int64(tv.tv_usec)
        // The test host was spawned before this test ran, and not long before: the same clock.
        #expect(start < now)
        #expect(now - start < 3_600 * 1_000_000)
        // A second read is the same spawn, not a fresh clock reading.
        #expect(LaunchTiming.processStartMicros() == start)
    }

    @Test func sceneStatesAreNamedAsTheToolReadsThem() {
        #expect(LaunchTiming.stateName(.foregroundActive) == "foregroundActive")
        #expect(LaunchTiming.stateName(.foregroundInactive) == "foregroundInactive")
        #expect(LaunchTiming.stateName(.background) == "background")
        #expect(LaunchTiming.stateName(nil) == "none")
    }

    @Test func itIsOffWithoutTheMarkerFile() {
        // A test host has never been seeded by the measuring tool: no marker, no lines.
        let marker = LocalOnlyStorage.appRoot.appendingPathComponent(LaunchTiming.markerName)
        #expect(!FileManager.default.fileExists(atPath: marker.path))
        #expect(!LaunchTiming.enabled)
    }
}
