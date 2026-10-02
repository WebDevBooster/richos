import UIKit
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
                       interactive: Bool = false, microphone: String? = nil, mac: String? = nil,
                       notifications: String? = nil, cards: String? = nil) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-rios-fixture", id, "-rios-appearance", appearance]
        // Cards raised on top of the fixture's (`camera-denied`): several share the bottom.
        if let cards { app.launchArguments += ["-rios-cards", cards] }
        // The notification state the conversation starts in (`not-asked` shows the offer card).
        if let notifications { app.launchArguments += ["-rios-notifications", notifications] }
        if interactive {
            app.launchArguments += ["-rios-interactive-fixture", "YES"]
            // The interactive fixture's stand-in for the OS's microphone answer (granted by default).
            if let microphone { app.launchArguments += ["-rios-microphone", microphone] }
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
                       "conn-incompatible", "conn-cached", "conn-tailscale-off"],
        "notifications": ["notif-offer", "notif-settings"],
        "settings": ["settings", "settings-forget", "settings-forget-blocked"],
        "updates": ["upd-banner", "upd-dialog", "upd-blocking", "upd-feature-off"],
        "launch": ["launch-cached"],
    ]
}

/// A screenshot's pixels, read in points, to tell what is drawn from what is not where the accessibility
/// tree cannot: a masked line keeps its frame in the tree.
struct ScreenPixels {
    private let bytes: [UInt8]
    private let width: Int
    private let height: Int
    private let scale: CGFloat

    init(_ shot: XCUIScreenshot) {
        let image = shot.image
        guard let cg = image.cgImage else { bytes = []; width = 0; height = 0; scale = 1; return }
        let w = cg.width, h = cg.height
        var buffer = [UInt8](repeating: 0, count: w * h * 4)
        buffer.withUnsafeMutableBytes { raw in
            let context = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            context?.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        bytes = buffer; width = w; height = h
        scale = CGFloat(w) / max(image.size.width, 1)
    }

    private func rgb(_ x: Int, _ y: Int) -> (Int, Int, Int) {
        let i = (y * width + x) * 4
        return (Int(bytes[i]), Int(bytes[i + 1]), Int(bytes[i + 2]))
    }

    /// The first pixel row (in points) inside `rows` where something is drawn between `x0` and `x1`,
    /// outside `skipping`: a row is plain when every pixel is within `tolerance` of the row's first one
    /// in each channel (the ground's lamp light changes far more slowly than that across a row).
    func firstDrawnRow(in rows: ClosedRange<CGFloat>, from x0: CGFloat, to x1: CGFloat,
                       skipping: ClosedRange<CGFloat>, tolerance: Int = 24) -> CGFloat? {
        guard width > 0 else { return rows.lowerBound }
        var y = Int((rows.lowerBound * scale).rounded(.up))
        while CGFloat(y) <= rows.upperBound * scale, y < height {
            let xs = stride(from: Int(x0 * scale), to: min(Int(x1 * scale), width), by: 1)
                .filter { !skipping.contains(CGFloat($0) / scale) }
            if let first = xs.first {
                let base = rgb(first, y)
                for x in xs {
                    let c = rgb(x, y)
                    if abs(c.0 - base.0) > tolerance || abs(c.1 - base.1) > tolerance || abs(c.2 - base.2) > tolerance {
                        return CGFloat(y) / scale
                    }
                }
            }
            y += 1
        }
        return nil
    }
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
