import XCTest

/// Opens the app on a round-12 screen by name — the core's fixture of the same name
/// (`-rios-fixture <id>`) — in a chosen appearance (`-rios-appearance`) and text size, with the clock
/// pinned to the fixtures' morning so every run draws the same picture. No test navigates by hand to
/// reach a screen.
enum Screen {
    /// 2026-09-22, 9:41 AM UTC: the instant the fixtures are posed at (`Fixtures.now`).
    static let fixtureNow = "1790070060000"

    @discardableResult
    static func launch(_ id: String, appearance: String = "dark", textSize: String? = nil,
                       interactive: Bool = false, mac: String? = nil) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-rios-fixture", id, "-rios-appearance", appearance]
        if interactive {
            app.launchArguments += ["-rios-interactive-fixture", "YES"]
            // A stand-in Mac for the wait for the press on the Mac (`DevBridgeFixtureMac`).
            if let mac { app.launchArguments += ["-rios-fixture-mac", mac] }
        } else {
            app.launchArguments += ["-rios-now", fixtureNow]
        }
        if let textSize {
            app.launchArguments += ["-UIPreferredContentSizeCategoryName", textSize]
        }
        // Fixture times are UTC instants; UTC shows round 12's 8:02 AM.
        app.launchEnvironment["TZ"] = "UTC"
        app.launch()
        return app
    }

    /// Round 12's catalog, grouped as in `shared/screens.js`: the 63 in-app ids (the four that are not
    /// app screens on iPhone — two web-app-only, two on Apple's lock screen — have no fixture), plus
    /// pairing v2's six, which round 12 predates (the wait for the press on the Mac and the ways a
    /// pairing ends).
    static let groups: [String: [String]] = [
        "pairing": ["pair-intro", "pair-scanner", "pair-scanner-found", "pair-camera-denied", "pair-progress",
                    "pair-words", "pair-refused", "pair-blocked", "pair-stale", "pair-consent",
                    "pair-awaiting-mac", "pair-mac-update", "pair-mac-refused", "pair-mac-expired",
                    "pair-words-rejected", "pair-unreachable"],
        "conversation": ["conv-empty", "conv-populated", "conv-pending", "conv-replying", "conv-streaming",
                         "conv-playing-reply", "conv-preparing-reply", "conv-older-loading", "conv-beginning",
                         "conv-scrolled", "conv-focused", "conv-retry"],
        "composer": ["comp-idle", "comp-typing", "comp-keyboard", "comp-disabled", "comp-too-long"],
        "voice-hold": ["voice-press", "voice-permission", "voice-holding", "voice-slide-left", "voice-bin",
                       "voice-sent", "voice-too-short"],
        "voice-lock": ["voice-slide-up", "voice-lock-transition", "voice-locked", "voice-locked-scrolled",
                       "voice-locked-cancel", "voice-locked-send", "voice-ceiling-warning", "voice-ceiling-reached",
                       "voice-interrupted"],
        "recovery": ["rec-card", "rec-unsupported", "rec-mic-denied"],
        "connection": ["conn-reconnecting", "conn-offline", "conn-service", "conn-mac", "conn-revoked",
                       "conn-incompatible", "conn-cached"],
        "notifications": ["notif-offer", "notif-settings"],
        "settings": ["settings", "settings-forget", "settings-forget-blocked"],
        "updates": ["upd-banner", "upd-dialog", "upd-blocking", "upd-feature-off"],
        "launch": ["launch-cached"],
    ]
}

extension XCTestCase {
    /// Keeps a screenshot in the result bundle, named `<device>-<appearance>-<id>` so the suite can
    /// export it beside the mockup of the same name.
    func keepScreenshot(_ app: XCUIApplication, name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "\(Self.deviceTag)-\(name)"
        shot.lifetime = .keepAlways
        add(shot)
    }

    static var deviceTag: String {
        let w = Int(XCUIScreen.main.screenshot().image.size.width)
        return w <= 375 ? "se" : "pm"
    }

    /// Everything the app drew is inside the window and can be touched (accessibility audit F1, F2).
    func assertOnScreenAndHittable(_ element: XCUIElement, in app: XCUIApplication, _ what: String,
                                   file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(element.waitForExistence(timeout: 5), "\(what) is missing", file: file, line: line)
        let window = app.windows.firstMatch.frame
        let frame = element.frame
        XCTAssertTrue(window.contains(frame), "\(what) at \(frame) is outside the window \(window)", file: file, line: line)
        XCTAssertTrue(element.isHittable, "\(what) cannot be touched", file: file, line: line)
    }

    /// No button VoiceOver would announce only as "button" (accessibility audit F12).
    func assertEveryButtonNamed(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let unnamed = app.buttons.allElementsBoundByIndex.filter { $0.exists && $0.label.trimmingCharacters(in: .whitespaces).isEmpty }
        XCTAssertTrue(unnamed.isEmpty, "unnamed buttons: \(unnamed.map { $0.frame })", file: file, line: line)
    }

    /// The message field, which is a text view once it can grow to several lines.
    func messageField(_ app: XCUIApplication) -> XCUIElement {
        let field = app.textFields["composer.field"]
        return field.exists ? field : app.textViews["composer.field"]
    }
}
