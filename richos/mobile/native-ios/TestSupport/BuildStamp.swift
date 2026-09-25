import ObjectiveC
import XCTest

/// Every XCTest this bundle runs carries the stamp the bundle was BUILT with, so a result can
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
/// XCTest instantiates the bundle's principal class (this one) when it loads the bundle. It
/// exchanges `XCTestCase.invokeTest` once, so every XCTest attaches the stamp at the start of its
/// own invocation, where setUp runs and attachments are recorded. (An attachment added from an
/// observer's `testCaseWillStart` is dropped: measured 2026-09-25, 62 tests, none recorded.)
/// Swift Testing tests do not pass through `XCTestCase`; `BuildStampTests` below is the XCTest
/// that proves such a bundle. `ios_ui_shards.py verify` exports the attachments and refuses a
/// result that does not prove this run's stamp.
///
/// Test harness only: nothing here is compiled into the app.
final class BuildStampObserver: NSObject {
    static let attachmentName = "richos-build-stamp"
    static let stamp: String = Bundle(for: BuildStampObserver.self)
        .object(forInfoDictionaryKey: "RichOSBuildStamp") as? String ?? "missing"

    private static let installed: Bool = {
        guard let original = class_getInstanceMethod(XCTestCase.self, #selector(XCTestCase.invokeTest)),
              let stamped = class_getInstanceMethod(XCTestCase.self, #selector(XCTestCase.richos_stampedInvokeTest))
        else { return false }
        method_exchangeImplementations(original, stamped)
        return true
    }()

    override init() {
        super.init()
        _ = Self.installed
    }
}

extension XCTestCase {
    /// After the exchange this name holds XCTest's own `invokeTest`, so the call below runs it.
    @objc func richos_stampedInvokeTest() {
        let attachment = XCTAttachment(string: BuildStampObserver.stamp)
        attachment.name = BuildStampObserver.attachmentName
        attachment.lifetime = .keepAlways
        add(attachment)
        richos_stampedInvokeTest()
    }
}

/// The XCTest that proves which build a bundle is, including a bundle of Swift Testing tests.
final class BuildStampTests: XCTestCase {
    func testTheBundleCarriesItsBuildStamp() {
        XCTAssertFalse(BuildStampObserver.stamp.isEmpty)
    }
}
