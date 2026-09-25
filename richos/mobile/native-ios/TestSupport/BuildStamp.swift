import XCTest

/// Every test this bundle runs carries the stamp the bundle was BUILT with, so a result can
/// prove which build produced it.
///
/// WHY (escalation esc-20260925T014934Z-0a4bf206). On 2026-09-25 a UI run's simulator lease
/// ended mid-suite, another checkout's run leased the same prepared simulator and installed its
/// own build, and the first run's xcodebuild restarted and executed THAT checkout's test bundle.
/// Its result bundle then reported a test that exists only on the other branch. Nothing in the
/// result said whose bundle had run.
///
/// HOW. native-ios-ui.test.sh builds with a fresh `RICHOS_BUILD_STAMP` (its checkout key, commit
/// and run folder), which `TestSupport/TestBundle-Info.plist` puts in this bundle's Info.plist.
/// XCTest instantiates the bundle's principal class (this one) when it loads the bundle; it
/// attaches the stamp to every test case as it starts. `ios_ui_shards.py verify` exports the
/// attachments and refuses a result in which any test that ran lacks this run's stamp.
///
/// Test harness only: nothing here is compiled into the app.
final class BuildStampObserver: NSObject, XCTestObservation {
    static let attachmentName = "richos-build-stamp"

    let stamp: String

    override init() {
        stamp = Bundle(for: BuildStampObserver.self).object(forInfoDictionaryKey: "RichOSBuildStamp") as? String
            ?? "missing"
        super.init()
        XCTestObservationCenter.shared.addTestObserver(self)
    }

    func testCaseWillStart(_ testCase: XCTestCase) {
        let attachment = XCTAttachment(string: stamp)
        attachment.name = Self.attachmentName
        attachment.lifetime = .keepAlways
        testCase.add(attachment)
    }
}
