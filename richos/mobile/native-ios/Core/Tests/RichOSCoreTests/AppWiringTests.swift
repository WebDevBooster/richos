import Foundation
import Testing

/// Pins on how `App/App/RichOSNativeApp.swift` is wired, read as source because the app target
/// needs a simulator to run (its behavior is proven in `UnitTests/`, run on one). Each pins a
/// measured defect so it cannot quietly come back.
@Suite struct AppWiringTests {
    func appSource() throws -> String {
        try String(contentsOf: repositoryRoot.appendingPathComponent("richos/mobile/native-ios/App/App/RichOSNativeApp.swift"),
                   encoding: .utf8)
    }

    /// Sage's review T3 (richos-hq `e642db4f`): the Share extension's context was mirrored on every
    /// state change, reading and decoding a file on the main thread per keystroke and streamed word.
    @Test func theShareMirrorRunsOnlyWhenTheShareContextChanges() throws {
        let source = try appSource()
        #expect(!source.contains(".onChange(of: store?.state)"), "no mirror keyed on the whole state")
        #expect(source.contains(".onChange(of: shareContext)"))
    }
}
