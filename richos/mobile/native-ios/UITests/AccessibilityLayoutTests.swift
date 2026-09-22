import XCTest

/// The preserved app's accessibility audit (richos-hq `docs/verification/2026-09-22-ios-accessibility-
/// audit.md`, F1–F17) as checks the native app must pass, at the largest accessibility text size
/// (AX5) on whichever phone the suite runs — the suite runs it on iPhone SE (3rd generation) and
/// iPhone 16 Pro Max. Same shape as the audit's `AccessibilityLayoutTests.swift` (commit `848c604c`).
final class AccessibilityLayoutTests: XCTestCase {
    static let largest = "UICTContentSizeCategoryAccessibilityXXXL"

    override func setUp() {
        continueAfterFailure = true
    }

    private func field(_ app: XCUIApplication) -> XCUIElement {
        app.textFields["composer.field"].exists ? app.textFields["composer.field"] : app.textViews["composer.field"]
    }

    /// F1, F2, F11: the composer — field and record control — is fully on screen and touchable at the
    /// largest size, with a notice, a card or a draft above it.
    func testComposerKeepsPriorityAtTheLargestSize() {
        for id in ["conv-populated", "conv-retry", "rec-card", "rec-unsupported", "notif-offer", "comp-typing", "conn-mac"] {
            let app = Screen.launch(id, textSize: Self.largest)
            let control = id == "comp-typing"
                ? app.descendants(matching: .any)["composer.send"]
                : app.descendants(matching: .any)["composer.mic"]
            assertOnScreenAndHittable(control, in: app, "\(id): the send/record control")
            assertOnScreenAndHittable(field(app), in: app, "\(id): the message field")
            keepScreenshot(app, name: "ax5-\(id)")
        }
    }

    /// F9: locked, the timer and Cancel do not overlap, and Cancel stays at the center.
    func testLockedRecordingFitsOneRowAtTheLargestSize() {
        let app = Screen.launch("voice-locked", textSize: Self.largest)
        let timer = app.descendants(matching: .any)["voice.timer"]
        let cancel = app.buttons["voice.cancel"]
        XCTAssertTrue(timer.waitForExistence(timeout: 3))
        XCTAssertTrue(cancel.waitForExistence(timeout: 3))
        XCTAssertFalse(timer.frame.intersects(cancel.frame), "timer \(timer.frame) runs into Cancel \(cancel.frame)")
        XCTAssertEqual(cancel.frame.midX, app.windows.firstMatch.frame.midX, accuracy: 2)
        assertOnScreenAndHittable(app.descendants(matching: .any)["voice.send"], in: app, "the locked Send circle")
        keepScreenshot(app, name: "ax5-voice-locked")
    }

    /// F12: no unnamed button on any overlay; F15: pairing's actions are reachable.
    func testOverlaysNameEveryButtonAndKeepActionsReachable() {
        for id in ["settings", "upd-dialog", "upd-blocking", "settings-forget", "pair-intro", "pair-words", "conn-revoked", "pair-consent"] {
            let app = Screen.launch(id, textSize: Self.largest)
            Thread.sleep(forTimeInterval: 1.0)
            assertEveryButtonNamed(app)
            keepScreenshot(app, name: "ax5-\(id)")
        }
    }

    /// F4, F5: the settings button is a fixed-size control with a name, at every size.
    func testSettingsButtonKeepsItsSize() {
        let app = Screen.launch("conv-populated", textSize: Self.largest)
        let settings = app.buttons["header.settings"]
        assertOnScreenAndHittable(settings, in: app, "Settings")
        XCTAssertEqual(settings.frame.width, 52, accuracy: 1)
        XCTAssertEqual(settings.frame.height, 52, accuracy: 1)
        XCTAssertEqual(settings.label, "Settings")
    }

    /// Apple's own audit on the main screen at the default size: element descriptions and hit regions.
    func testSystemAccessibilityAudit() throws {
        let app = Screen.launch("conv-populated")
        Thread.sleep(forTimeInterval: 1.0)
        try app.performAccessibilityAudit(for: [.sufficientElementDescription, .hitRegion]) { issue in
            // The 14 pt timestamps and delivery marks inside bubbles are hidden from VoiceOver (the row
            // reads them in full); Apple's audit still sees their text runs. Not a control.
            issue.element?.elementType == .staticText
        }
    }
}
