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
}
