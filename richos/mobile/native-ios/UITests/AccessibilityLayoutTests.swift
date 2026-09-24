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

    /// I02 (native acceptance r1, the physical iPhone SE): opened with the Mac out of reach, the line
    /// that says so was the first row of the conversation, drawn under the floating header and its
    /// fade at 1.38:1. It is one line, below the header and clear of it, fully inside the window and
    /// not covered, in both appearances, at the default and the largest text size, and the composer
    /// keeps its place under it.
    func testTheOutOfReachLineIsClearOfTheHeader() {
        let words = "Showing what was on this phone · your Mac is out of reach"
        for (id, appearance, size) in [("launch-cached", "light", nil), ("launch-cached", "dark", nil),
                                       ("conn-cached", "light", nil), ("conn-cached", "dark", Self.largest),
                                       ("launch-cached", "light", Self.largest)] as [(String, String, String?)] {
            let what = "\(id) \(appearance) \(size == nil ? "default" : "ax5")"
            let app = Screen.launch(id, appearance: appearance, textSize: size)
            let line = app.descendants(matching: .any)["conversation.cachedNotice"]
            XCTAssertTrue(line.waitForExistence(timeout: 5), "\(what): the out-of-reach line is missing")
            Thread.sleep(forTimeInterval: 0.6)
            XCTAssertEqual(line.label, words, "\(what): the line's words")
            let copies = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", words)).count
            XCTAssertEqual(copies, 1, "\(what): the line is drawn \(copies) times")
            let window = app.windows.firstMatch.frame
            XCTAssertTrue(window.contains(line.frame), "\(what): the line at \(line.frame) is outside the window \(window)")
            var headerBottom: CGFloat = 0
            for part in ["header.nameplate", "header.settings", "connection.line"] {
                let element = app.descendants(matching: .any)[part]
                guard element.exists else { continue }
                XCTAssertFalse(element.frame.intersects(line.frame), "\(what): \(part) \(element.frame) covers the line \(line.frame)")
                headerBottom = max(headerBottom, element.frame.maxY)
            }
            XCTAssertGreaterThan(headerBottom, 0, "\(what): the header is missing")
            XCTAssertGreaterThanOrEqual(line.frame.minY, headerBottom, "\(what): the line starts above the header's bottom")
            XCTAssertTrue(line.isHittable, "\(what): the line is covered")
            assertOnScreenAndHittable(app.descendants(matching: .any)["composer.mic"], in: app, "\(what): the record control")
            keepScreenshot(app, name: "i02-\(appearance)-\(size == nil ? "default" : "ax5")-\(id)")
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
