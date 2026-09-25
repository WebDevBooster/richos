import XCTest

/// Opt-in checks against an isolated Mac through the normal app controls. No fixture,
/// development bridge or substituted microphone is used. Supply configuration only to
/// the test runner, never to the app. The host runner must reject skipped selected tests.
final class PhysicalDeviceTests: XCTestCase {
    private let app = XCUIApplication(bundleIdentifier: "dev.richos.connect")
    private var config: [String: String] = [:]

    override func setUpWithError() throws {
        continueAfterFailure = false
        #if targetEnvironment(simulator)
        throw XCTSkip("Physical iPhone checks require a real device")
        #else
        guard let raw = ProcessInfo.processInfo.environment["RICHOS_PHYSICAL_CONFIG"],
              let data = raw.data(using: .utf8) else {
            throw XCTSkip("Physical checks require an explicitly prepared isolated lab")
        }
        config = try JSONDecoder().decode([String: String].self, from: data)
        XCTAssertEqual(config["isolatedLab"], "true")
        #endif
    }

    override func tearDown() {
        if app.state == .runningForeground { keepScreenshot(app, name: name) }
        // Preserve the tested session for independent launch and resource measurements.
        // A failure never starts another test or tries to repair user work.
    }

    private func element(_ id: String) -> XCUIElement { app.descendants(matching: .any)[id] }
    private var field: XCUIElement {
        app.textFields["composer.field"].exists ? app.textFields["composer.field"] : app.textViews["composer.field"]
    }
    private func launchPaired() {
        app.launch()
        XCTAssertTrue(field.waitForExistence(timeout: 10), "Expected the lab's existing pairing")
    }
    private func send(_ text: String) {
        let value = field.value as? String ?? ""
        // XCTest exposes an empty native TextField's placeholder as its value.
        // Also require microphone mode so actual text equal to the placeholder
        // cannot be mistaken for an empty composer.
        XCTAssertTrue(value.isEmpty || (value == field.placeholderValue && element("composer.mic").exists && !element("composer.send").exists),
                      "Refuse to replace an occupied composer")
        field.tap()
        field.typeText(text)
        XCTAssertEqual(field.value as? String, text, "Input differs before Send")
        element("composer.send").tap()
        let reply = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "ack: " + text)).firstMatch
        XCTAssertTrue(reply.waitForExistence(timeout: 30), "No reply through the actual route")
    }

    func testPairAndDeliverAcrossHomeAndRelaunch() throws {
        let link = try XCTUnwrap(config["pairLink"])
        let words = try XCTUnwrap(config["words"]).split(separator: " ").map(String.init)
        XCTAssertTrue(link.hasPrefix("https://"))
        XCTAssertFalse(words.isEmpty)
        app.launch()
        XCTAssertTrue(element("pair.link").waitForExistence(timeout: 10), "Pairing test requires an unpaired test installation")
        element("pair.link").tap()
        let input = element("pairlink.field")
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        input.tap()
        input.typeText(link)
        element("pairlink.submit").tap()
        XCTAssertTrue(element("pair.match").waitForExistence(timeout: 15))
        for (index, word) in words.enumerated() {
            XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Word \(index + 1): \(word)")).firstMatch.exists,
                          "Mac fingerprint differs; do not confirm")
        }
        element("pair.match").tap()
        // Pairing v2: the phone now waits for "They match" ON THE MAC, pressed by the lab's operator.
        // Bounded well inside the runner's 240 s per-test allowance.
        let consent = element("consent.continue")
        if !consent.waitForExistence(timeout: 3) {
            XCTAssertTrue(element("takeover.pair-awaiting-mac").exists, "They match did not lead to the wait for the Mac")
            print("PHYSICAL_PRESS_THEY_MATCH_ON_MAC")
            let deadline = Date().addingTimeInterval(120)
            while Date() < deadline, !consent.exists, !field.exists, !element("pair.error").exists { Thread.sleep(forTimeInterval: 1) }
            XCTAssertFalse(element("pair.error").exists, "The Mac did not accept this phone")
        }
        if consent.exists { consent.tap() }
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        verifyDeliveryAndRestoration()
    }

    func testDeliverAcrossHomeAndRelaunch() {
        launchPaired()
        verifyDeliveryAndRestoration()
    }

    private func verifyDeliveryAndRestoration() {
        let probe = "iPhone physical " + UUID().uuidString
        send(probe + " first")
        let draft = "Keep 9012345678901234567 " + UUID().uuidString
        field.tap(); field.typeText(draft)
        XCTAssertEqual(field.value as? String, draft)
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 5))
        app.activate()
        XCTAssertEqual(field.value as? String, draft)
        app.terminate(); app.launch()
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        XCTAssertEqual(field.value as? String, draft, "Relaunch lost the draft")
        element("composer.send").tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "ack: " + draft)).firstMatch.waitForExistence(timeout: 30))
        send(probe + " after relaunch")
    }

    func testSpokenMessageReachesMacAndReturnsReply() throws {
        let phrase = try XCTUnwrap(config["spokenPhrase"])
        XCTAssertFalse(phrase.isEmpty)
        launchPaired()
        allowMicrophoneIfNeeded()
        lockRecording()
        print("PHYSICAL_SPEAK_NOW")
        Thread.sleep(forTimeInterval: 12)
        XCTAssertTrue(element("voice.cancel").exists, "Foreground recording ended before Send")
        element("voice.send").tap()
        let reply = app.descendants(matching: .any).matching(NSPredicate(
            format: "label CONTAINS[c] %@ AND label CONTAINS[c] %@", "ack:", phrase)).firstMatch
        XCTAssertTrue(reply.waitForExistence(timeout: 100), "Spoken message did not return through the actual microphone and Mac")
        XCTAssertFalse(element("voice.cancel").exists)
        let controls = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "voice.play."))
        let identifier = try XCTUnwrap(controls.allElementsBoundByIndex.last?.identifier)
        let play = app.buttons.matching(NSPredicate(format: "identifier == %@ AND label == %@", identifier, "Play voice message")).firstMatch
        XCTAssertTrue(play.waitForExistence(timeout: 5), "Transcript reconciliation lost the recording control")
        play.tap()
        let stop = app.buttons.matching(NSPredicate(format: "identifier == %@ AND label == %@", identifier, "Stop voice message")).firstMatch
        XCTAssertTrue(stop.waitForExistence(timeout: 3), "Original recording did not start playing")
        stop.tap()
        XCTAssertTrue(play.waitForExistence(timeout: 3), "Stop did not return the playback control")
        app.terminate(); app.launch()
        XCTAssertTrue(reply.waitForExistence(timeout: 10), "Relaunch lost the spoken reply")
        XCTAssertTrue(play.waitForExistence(timeout: 5), "Relaunch lost the recording")
        play.tap()
        XCTAssertTrue(stop.waitForExistence(timeout: 3), "Relaunch lost original WAV playback")
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 5))
        app.activate()
        XCTAssertTrue(play.waitForExistence(timeout: 5), "Playback did not stop on Home")
    }

    func testScrollAndQuietBackgroundReturn() {
        launchPaired()
        let list = app.collectionViews["conversation.list"]
        XCTAssertTrue(list.waitForExistence(timeout: 5))
        for _ in 0..<4 { list.swipeDown(); list.swipeUp() }
        list.swipeDown()
        XCTAssertTrue(element("conversation.latest").waitForExistence(timeout: 5))
        keepScreenshot(app, name: "physical-reading-before-home")
        // Host Instruments attaches during this settled foreground window. Sleep runs
        // in the test runner, never the app; there is no recurring app probe or fixture.
        print("PHYSICAL_RESOURCE_FOREGROUND_WINDOW")
        Thread.sleep(forTimeInterval: 30)
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 5))
        print("PHYSICAL_RESOURCE_BACKGROUND_WINDOW")
        Thread.sleep(forTimeInterval: 90)
        XCTAssertTrue(app.state == .runningBackground || app.state == .runningBackgroundSuspended,
                      "App should remain hidden; suspension is expected and welcome")
        app.activate()
        XCTAssertTrue(element("conversation.latest").waitForExistence(timeout: 5))
        keepScreenshot(app, name: "physical-reading-after-home")
        element("conversation.latest").tap()
        XCTAssertTrue(field.exists)
        XCTAssertFalse(element("voice.cancel").exists)
    }

    func testReplyNotificationAfterHomeAndTermination() {
        XCTAssertEqual(config["delayedReplies"], "true")
        launchPaired()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        if element("card.notificationsOn").exists {
            element("card.notificationsOn").tap()
            let prompt = springboard.alerts.firstMatch
            XCTAssertTrue(prompt.waitForExistence(timeout: 5))
            XCTAssertTrue(prompt.staticTexts.allElementsBoundByIndex.contains { $0.label.localizedCaseInsensitiveContains("notifications") })
            prompt.buttons["Allow"].tap()
        }
        element("header.settings").tap()
        let enabled = element("settings.notifications")
        XCTAssertTrue(enabled.waitForExistence(timeout: 20), "Native notification registration did not complete")
        XCTAssertEqual(enabled.value as? String, "1")
        // The SE's sheet grabber overlaps the top-edge system gesture region. Start
        // on the visible title below it so this dismisses the sheet, not opens Notification Center.
        let title = app.staticTexts["Settings"]
        XCTAssertTrue(title.exists)
        title.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.1,
            thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.95)))
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"),
            object: element("settings.sheet"))], timeout: 5), .completed, "Settings did not dismiss")
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        for terminate in [false, true] {
            let probe = "Physical notification " + UUID().uuidString
            XCTAssertTrue(element("composer.mic").exists, "Refuse to replace an occupied composer")
            field.tap(); field.typeText(probe)
            XCTAssertEqual(field.value as? String, probe)
            element("composer.send").tap()
            XCUIDevice.shared.press(.home)
            if terminate { app.terminate() }
            let notification = springboard.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", probe)).firstMatch
            XCTAssertTrue(notification.waitForExistence(timeout: 45), "No actual APNs preview after \(terminate ? "termination" : "Home")")
            keepScreenshot(springboard, name: terminate ? "notification-after-termination" : "notification-after-home")
            notification.tap()
            XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
            let reply = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "ack: " + probe)).firstMatch
            XCTAssertTrue(reply.waitForExistence(timeout: 15), "Notification tap did not restore the referenced reply")
        }
    }

    private func lockRecording() {
        let mic = element("composer.mic")
        XCTAssertTrue(mic.waitForExistence(timeout: 5))
        let start = mic.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.7, thenDragTo: start.withOffset(CGVector(dx: 0, dy: -110)))
        XCTAssertTrue(element("voice.cancel").waitForExistence(timeout: 5), "Recording did not lock")
        XCTAssertTrue(element("voice.timer").exists)
    }

    private func allowMicrophoneIfNeeded() {
        // Permission is requested through the actual feature. Accept only this app's
        // microphone prompt, without touching other alerts or system preferences.
        element("composer.mic").press(forDuration: 0.05)
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let prompt = springboard.alerts.firstMatch
        if prompt.waitForExistence(timeout: 3) {
            XCTAssertTrue(prompt.label.localizedCaseInsensitiveContains("microphone") || prompt.staticTexts.allElementsBoundByIndex.contains { $0.label.localizedCaseInsensitiveContains("microphone") })
            XCTAssertTrue(prompt.buttons["Allow"].exists)
            prompt.buttons["Allow"].tap()
        }
    }

    func testActualMicrophonePreservesUnsentAudioAfterHomeAndTermination() {
        launchPaired()
        allowMicrophoneIfNeeded()
        lockRecording()
        Thread.sleep(forTimeInterval: 3)
        XCTAssertTrue(element("voice.cancel").exists, "Foreground recording stopped unexpectedly")
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 5))
        Thread.sleep(forTimeInterval: 3)
        app.activate()
        XCTAssertTrue(element("kept.send").waitForExistence(timeout: 5), "Home lost unsent audio")
        XCTAssertFalse(element("voice.cancel").exists, "Recording restarted on return")
        app.terminate(); app.launch()
        XCTAssertTrue(element("kept.send").waitForExistence(timeout: 10), "Relaunch lost recovered audio")
        element("kept.discard").tap()
        lockRecording()
        Thread.sleep(forTimeInterval: 3)
        app.terminate(); app.launch()
        XCTAssertTrue(element("kept.send").waitForExistence(timeout: 10), "Process termination lost journaled audio")
        XCTAssertFalse(element("voice.cancel").exists)
        // Keep the recovered file for independent WAV inspection after this check.
        lockRecording()
        element("voice.cancel").tap()
        XCTAssertTrue(element("composer.mic").waitForExistence(timeout: 5))
        XCTAssertTrue(element("kept.send").exists, "Canceling a new recording discarded previously kept audio")
    }

    /// A walker's list of real-control steps (`richos/app/scripts/qa/phone-ios.py`). The host
    /// validates the vocabulary before anything is built; this runs it through XCUITest, the only
    /// way to touch an iOS 26 phone's controls. Every step prints one `PHONE_STEP` JSON line with
    /// its phone-clock start and end, so the host can join what the phone did with what it measured.
    /// A failed step stops the script with its reason: nothing is retried and nothing is repaired.
    func testScript() throws {
        let raw = try XCTUnwrap(config["steps"], "A script check needs steps")
        let steps = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [[String: Any]],
                                  "steps must be a JSON list of objects")
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for (index, step) in steps.enumerated() {
            let action = step["do"] as? String ?? ""
            let started = Date().timeIntervalSince1970
            var detail: [String: Any] = [:]
            let reason = perform(action, step, springboard: springboard, detail: &detail)
            let line: [String: Any] = ["i": index, "do": action, "start": started, "end": Date().timeIntervalSince1970,
                                       "ok": reason == nil, "error": reason ?? NSNull(), "detail": detail,
                                       "appState": stateName(app.state)]
            let data = try JSONSerialization.data(withJSONObject: line, options: [.sortedKeys])
            print("PHONE_STEP " + String(decoding: data, as: UTF8.self))
            if let reason, step["optional"] as? Bool != true {
                keepScreenshot(app, name: "script-failed-step-\(index)")
                XCTFail("step \(index) \(action): \(reason)")
                return
            }
        }
    }

    private func stateName(_ state: XCUIApplication.State) -> String {
        switch state {
        case .notRunning: return "notRunning"
        case .runningBackgroundSuspended: return "suspended"
        case .runningBackground: return "background"
        case .runningForeground: return "foreground"
        default: return "unknown"
        }
    }

    /// The element a step names: `id` (accessibility identifier) or `label` (substring of the
    /// accessibility label), in the app or, with `"in": "springboard"`, in the system UI.
    private func root(_ step: [String: Any], _ springboard: XCUIApplication) -> XCUIApplication {
        switch step["in"] as? String {
        case "springboard": return springboard
        // The route under test (PRD §5): only its connect switch is ever read or pressed. The
        // host refuses a shot or tree there, because its screen shows the person's own account.
        case "tailscale": return XCUIApplication(bundleIdentifier: "io.tailscale.ipn.ios")
        default: return app
        }
    }

    private func target(_ step: [String: Any], _ springboard: XCUIApplication) -> XCUIElement? {
        let root = root(step, springboard)
        if step["id"] == nil, step["label"] == nil, let kind = step["kind"] as? String {
            return kind == "switch" ? root.switches.firstMatch : root.buttons.firstMatch
        }
        if let id = step["id"] as? String {
            return id == "composer.field" && root == app ? field : root.descendants(matching: .any)[id]
        }
        if let label = step["label"] as? String {
            return root.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", label)).firstMatch
        }
        return nil
    }

    // swiftlint:disable:next cyclomatic_complexity function_body_length
    private func perform(_ action: String, _ step: [String: Any], springboard: XCUIApplication,
                         detail: inout [String: Any]) -> String? {
        let timeout = step["timeout"] as? Double ?? 5
        switch action {
        case "launch":
            // Only Apple's own text-size override, never an app fixture: the app stays the Release app.
            if let size = step["textSize"] as? String {
                app.launchArguments = ["-UIPreferredContentSizeCategoryName", size]
            } else {
                app.launchArguments = []
            }
            app.launch()
        case "activate": root(step, springboard).activate()
        case "terminate": app.terminate()
        case "home":
            XCUIDevice.shared.press(.home)
        case "lock":
            let selector = NSSelectorFromString("pressLockButton")
            guard XCUIDevice.shared.responds(to: selector) else { return "this XCTest has no lock button" }
            XCUIDevice.shared.perform(selector)
        case "unlock":
            // Only for a phone with no passcode: Home wakes the lock screen, a second Home opens it.
            XCUIDevice.shared.press(.home); Thread.sleep(forTimeInterval: 1); XCUIDevice.shared.press(.home)
        case "sleep":
            Thread.sleep(forTimeInterval: step["seconds"] as? Double ?? 1)
        case "mark":
            detail["label"] = step["label"] as? String ?? ""
        case "state":
            detail["springboardForeground"] = springboard.state == .runningForeground
        case "waitState":
            let want: XCUIApplication.State = ["background": .runningBackground, "suspended": .runningBackgroundSuspended,
                                               "foreground": .runningForeground, "notRunning": .notRunning][step["state"] as? String ?? ""] ?? .unknown
            if !app.wait(for: want, timeout: timeout) { return "app did not reach \(step["state"] ?? "")" }
        case "wait", "tap", "type", "value", "gone", "press", "swipe", "exists":
            guard let element = target(step, springboard) else { return "step names no id or label" }
            let begin = Date()
            if action == "gone" {
                let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element)
                if XCTWaiter.wait(for: [gone], timeout: timeout) != .completed { return "still on screen after \(timeout) s" }
                detail["waitedMs"] = Int(Date().timeIntervalSince(begin) * 1000); return nil
            }
            if action == "exists" { detail["exists"] = element.exists; return nil }
            guard element.waitForExistence(timeout: timeout) else { return "not on screen within \(timeout) s" }
            detail["waitedMs"] = Int(Date().timeIntervalSince(begin) * 1000)
            detail["label"] = element.label
            switch action {
            case "tap": element.tap()
            case "type":
                if step["focus"] as? Bool != false { element.tap() }
                let deletes = step["delete"] as? Int ?? 0
                if deletes > 0 { element.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: deletes)) }
                element.typeText(step["text"] as? String ?? "")
            case "value":
                let value = element.value as? String ?? ""
                detail["value"] = value
                if let want = step["equals"] as? String, value != want { return "value differs from what the step expected" }
            case "press":
                let start = element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                let seconds = step["seconds"] as? Double ?? 0.7
                if let drag = step["drag"] as? [Double], drag.count == 2 {
                    start.press(forDuration: seconds, thenDragTo: start.withOffset(CGVector(dx: drag[0], dy: drag[1])))
                } else {
                    start.press(forDuration: seconds)
                }
            case "swipe":
                switch step["direction"] as? String {
                case "up": element.swipeUp()
                case "down": element.swipeDown()
                case "left": element.swipeLeft()
                case "right": element.swipeRight()
                default: return "swipe needs direction up, down, left or right"
                }
            default: break
            }
        case "count":
            guard let label = step["label"] as? String else { return "count needs a label" }
            let root = root(step, springboard)
            detail["count"] = root.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", label)).count
            if let want = step["equals"] as? Int, detail["count"] as? Int != want { return "count differs from what the step expected" }
        case "alert":
            let alert = springboard.alerts.firstMatch
            guard alert.waitForExistence(timeout: timeout) else { return "no system alert within \(timeout) s" }
            detail["text"] = alert.staticTexts.allElementsBoundByIndex.map(\.label)
            if let button = step["button"] as? String {
                guard alert.buttons[button].exists else { return "the alert has no \(button) button" }
                alert.buttons[button].tap()
            }
        case "shot":
            // `screen: true` keeps the whole screen (lock screen, a system alert); the default keeps
            // only this app, so nothing else on a person's phone lands in a record by accident.
            let image = (step["screen"] as? Bool == true) ? XCUIScreen.main.screenshot() : app.screenshot()
            let shot = XCTAttachment(screenshot: image)
            shot.name = step["name"] as? String ?? "shot"
            shot.lifetime = .keepAlways
            add(shot)
        case "audit":
            // XCTest's accessibility audit of what is on screen now. Findings are recorded, never
            // fixed or skipped here; the walker judges them.
            var issues: [String] = []
            do {
                try app.performAccessibilityAudit { issue in
                    issues.append("\(issue.auditType.rawValue)|\(issue.compactDescription)|\(issue.element?.identifier ?? "")|\(issue.element?.label ?? "")")
                    return true
                }
            } catch {
                return "the audit could not run: \(error.localizedDescription)"
            }
            detail["issues"] = issues
        case "tree":
            let tree = XCTAttachment(string: app.debugDescription)
            tree.name = step["name"] as? String ?? "tree"
            tree.lifetime = .keepAlways
            add(tree)
        default:
            return "unknown step \(action)"
        }
        return nil
    }
}
