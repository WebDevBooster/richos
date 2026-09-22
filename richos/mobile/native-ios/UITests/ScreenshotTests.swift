import XCTest

/// Every round-12 screen, opened by name from the core's fixture, photographed in both appearances.
/// One test per screen group and appearance, so a run can be scoped with `-only-testing:` to the group
/// a change touched (`native-ios-ui.test.sh --only ScreenshotTests/testComposerDark`).
///
/// Each screen also has to pass the checks that make a picture worth keeping: the app came up and
/// stayed up, and every button carries a name VoiceOver can say.
final class ScreenshotTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = true
    }

    private func photograph(_ group: String, _ appearance: String) {
        for id in Screen.groups[group] ?? [] {
            let app = Screen.launch(id, appearance: appearance)
            XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10), "\(id): the app did not come up")
            // Let entrance animations finish (the longest is a 380 ms sheet); poses are frozen.
            Thread.sleep(forTimeInterval: 1.0)
            XCTAssertEqual(app.state, .runningForeground, "\(id): the app did not stay up")
            keepScreenshot(app, name: "\(appearance)-\(id)")
            assertEveryButtonNamed(app)
            app.terminate()
        }
    }

    func testPairingDark() { photograph("pairing", "dark") }
    func testPairingLight() { photograph("pairing", "light") }
    func testConversationDark() { photograph("conversation", "dark") }
    func testConversationLight() { photograph("conversation", "light") }
    func testComposerDark() { photograph("composer", "dark") }
    func testComposerLight() { photograph("composer", "light") }
    func testVoiceHoldDark() { photograph("voice-hold", "dark") }
    func testVoiceHoldLight() { photograph("voice-hold", "light") }
    func testVoiceLockDark() { photograph("voice-lock", "dark") }
    func testVoiceLockLight() { photograph("voice-lock", "light") }
    func testRecoveryDark() { photograph("recovery", "dark") }
    func testRecoveryLight() { photograph("recovery", "light") }
    func testConnectionDark() { photograph("connection", "dark") }
    func testConnectionLight() { photograph("connection", "light") }
    func testNotificationsDark() { photograph("notifications", "dark") }
    func testNotificationsLight() { photograph("notifications", "light") }
    func testSettingsDark() { photograph("settings", "dark") }
    func testSettingsLight() { photograph("settings", "light") }
    func testUpdatesDark() { photograph("updates", "dark") }
    func testUpdatesLight() { photograph("updates", "light") }
    func testLaunchDark() { photograph("launch", "dark") }
    func testLaunchLight() { photograph("launch", "light") }
}
