import XCTest

final class NativeClientTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private var serverRun: String?

    private func launchClient() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--native-client"]
        if let serverRun { app.launchArguments.append("--integration-session=" + serverRun) }
        // Always release the app's microphone/session, including an assertion failure.
        addTeardownBlock { app.terminate() }
        app.launch()
        return app
    }

    func testClientRejectsInsecurePairing() throws {
        #if targetEnvironment(simulator)
        let app = launchClient()
        XCTAssertTrue(app.webViews.buttons["Record"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.webViews.buttons["Send"].isEnabled)
        let field = app.webViews.textFields.firstMatch
        field.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.5)).tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        app.typeText("http://example.invalid/#pair=invalid")
        app.webViews.buttons["Pair with Mac"].tap()
        XCTAssertTrue(app.webViews.staticTexts["Pairing requires an HTTPS origin"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.webViews.buttons["Send"].isEnabled)
        #else
        throw XCTSkip("Unpaired UI validation runs in the isolated simulator; preserve this phone's pairing")
        #endif
    }

    func testUpdateNoticeControls() throws {
        #if targetEnvironment(simulator)
        let app = XCUIApplication(); addTeardownBlock { app.terminate() }
        app.launchArguments = ["--native-client", "--update-fixture=banner"]; app.launch()
        XCTAssertTrue(app.webViews.buttons["Update in App Store"].waitForExistence(timeout: 15))
        app.webViews.buttons["Later"].tap()
        XCTAssertFalse(app.webViews.buttons["Update in App Store"].exists)
        app.terminate(); app.launchArguments = ["--native-client", "--update-fixture=blocking"]; app.launch()
        XCTAssertTrue(app.webViews.staticTexts["Update required"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.webViews.buttons["Update in App Store"].exists)
        XCTAssertFalse(app.webViews.buttons["Later"].exists)
        XCTAssertTrue(app.webViews.buttons["Check again"].exists)
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "Mandatory update controls"; shot.lifetime = .keepAlways; add(shot)
        #else
        throw XCTSkip("Synthetic App Store policies are confined to the development simulator")
        #endif
    }

    private func pairedClient() throws -> (XCUIApplication, [String: String]) {
        guard let configURL = Bundle(for: Self.self).url(forResource: "native-test-config", withExtension: "json") else {
            throw XCTSkip("Physical HTTPS pairing config is unavailable; this test does not claim remote connectivity")
        }
        let config = try JSONSerialization.jsonObject(with: Data(contentsOf: configURL)) as! [String: String]
        serverRun = config["serverRun"]
        let app = launchClient()
        XCTAssertTrue(app.webViews.buttons["Record"].waitForExistence(timeout: 15))
        if app.webViews.buttons["Pair with Mac"].exists {
            let field = app.webViews.textFields.firstMatch
            field.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.5)).tap()
            XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
            app.typeText(config["pairLink"]!)
            XCTAssertTrue((field.value as? String) == config["pairLink"], "The entered pairing link must match this run's configuration")
            app.webViews.buttons["Pair with Mac"].tap()
            XCTAssertTrue(app.webViews.buttons["They match"].waitForExistence(timeout: 20))
            XCTAssertTrue(app.webViews.staticTexts[config["words"]!].exists, "The phone must derive the test server's exact fingerprint phrase")
            app.webViews.buttons["They match"].tap()
        }
        XCTAssertTrue(app.webViews.staticTexts["Connected to your Mac"].waitForExistence(timeout: 20))
        return (app, config)
    }

    func testNativeReplyNotification() throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Live Apple alerts require the physical iPhone and the managed provider")
        #else
        guard let url = Bundle(for: Self.self).url(forResource: "native-test-config", withExtension: "json"),
              let config = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: String],
              config["notificationTest"] == "true" else { throw XCTSkip("Live notification lab is not configured") }
        let (app, _) = try pairedClient()
        let settings = app.webViews.staticTexts["Connection and settings"]
        settings.tap()
        let enable = app.webViews.buttons["Enable reply notifications"]
        if enable.exists { enable.tap() }
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        if springboard.alerts.firstMatch.waitForExistence(timeout: 3) {
            let allow = springboard.alerts.buttons["Allow"]
            if allow.exists { allow.tap() }
        }
        XCTAssertTrue(app.webViews.staticTexts["Reply notifications are on."].waitForExistence(timeout: 30), "Apple token must be registered through the authenticated Mac and managed provider")
        settings.tap()
        let editor = app.webViews.textViews["Message"]
        editor.tap()
        let message = "Native notification check " + String(UUID().uuidString.prefix(8))
        app.typeText(message)
        app.webViews.buttons["Send"].tap()
        XCUIDevice.shared.press(.home)
        app.terminate()
        let alert = springboard.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "Rich has replied.")).firstMatch
        if !alert.waitForExistence(timeout: 15) {
            // Focus or banner preferences may defer presentation. Inspect Notification
            // Center without changing the owner's system notification preferences.
            springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.01))
                .press(forDuration: 0.1, thenDragTo: springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8)))
        }
        XCTAssertTrue(alert.waitForExistence(timeout: 45), "A real Apple alert must appear while RichOS is closed")
        let shot = XCTAttachment(screenshot: springboard.screenshot()); shot.name = "Generic native reply alert"; shot.lifetime = .keepAlways; add(shot)
        alert.tap()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15))
        let reply = app.webViews.staticTexts.containing(NSPredicate(format: "label CONTAINS %@ AND label CONTAINS %@", message, config["replyMarker"] ?? "That is the whole answer.")).firstMatch
        XCTAssertTrue(reply.waitForExistence(timeout: 25), "Opening the opaque alert must fetch its conversation from the paired Mac")
        settings.tap()
        app.webViews.buttons["Disable reply notifications"].tap()
        XCTAssertTrue(app.webViews.staticTexts["Reply notifications are off."].waitForExistence(timeout: 25))
        #endif
    }

    func testSpokenVoiceSubmissionAndReply() throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Spoken voice proof uses the phone microphone, never the Mac microphone")
        #else
        guard let url = Bundle(for: Self.self).url(forResource: "native-test-config", withExtension: "json"),
              let config = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: String],
              let phrase = config["spokenPhrase"], !phrase.isEmpty else { throw XCTSkip("An agreed spoken phrase is required for this live microphone check") }
        let (app, _) = try pairedClient()
        app.webViews.buttons["Record"].tap()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        if springboard.alerts.firstMatch.waitForExistence(timeout: 2), springboard.alerts.buttons["OK"].exists { springboard.alerts.buttons["OK"].tap() }
        XCTAssertTrue(app.webViews.staticTexts["Recording…"].waitForExistence(timeout: 10))
        // Deliberate capture interval for the operator's agreed spoken sentence.
        Thread.sleep(forTimeInterval: 10)
        app.webViews.buttons["Stop"].tap()
        let send = app.webViews.buttons.matching(identifier: "Send recording").allElementsBoundByIndex.last!
        XCTAssertTrue(send.waitForExistence(timeout: 10)); XCTAssertTrue(send.isEnabled)
        send.tap()
        let reply = app.webViews.staticTexts.containing(NSPredicate(format: "label CONTAINS[cd] %@ AND label CONTAINS %@", phrase, config["replyMarker"] ?? "That is the whole answer.")).firstMatch
        XCTAssertTrue(reply.waitForExistence(timeout: 55), "The actual phone recording must be transcribed by the Mac and enter the Rich turn")
        app.webViews.buttons.matching(identifier: "Play reply").allElementsBoundByIndex.last!.tap()
        XCTAssertTrue(app.webViews.staticTexts["Playing reply…"].waitForExistence(timeout: 25))
        app.webViews.buttons.matching(identifier: "Stop playback").allElementsBoundByIndex.last!.tap()
        let stopped = NSPredicate { _, _ in !app.webViews.staticTexts["Playing reply…"].exists }
        expectation(for: stopped, evaluatedWith: nil); waitForExpectations(timeout: 5)
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "Phone recording transcribed and answered"; shot.lifetime = .keepAlways; add(shot)
        #endif
    }

    func testAuthenticatedTextAndStreamResume() throws {
        let (app, config) = try pairedClient()
        let editor = app.webViews.textViews["Message"]
        editor.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.2)).tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        let message = "Native phone check " + String(UUID().uuidString.prefix(8))
        app.typeText(message)
        XCTAssertEqual(editor.value as? String, message, "Typing must preserve every character before send")
        app.webViews.buttons["Send"].tap()
        let reply = app.webViews.staticTexts.containing(NSPredicate(format: "label CONTAINS %@ AND label CONTAINS %@", message, config["replyMarker"] ?? "That is the whole answer.")).firstMatch
        XCTAssertTrue(reply.waitForExistence(timeout: 20), "Reply must arrive through the authenticated native event stream")
        XCTAssertEqual(app.webViews.staticTexts.matching(NSPredicate(format: "label == %@", message)).count, 1, "The sent message must appear once")
        app.terminate(); app.launch()
        XCTAssertTrue(app.webViews.staticTexts["Connected to your Mac"].waitForExistence(timeout: 20))
        XCTAssertTrue(reply.waitForExistence(timeout: 10), "Cached reply must survive process termination")
        // A cached bubble alone cannot prove the restarted stream works.
        editor.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.2)).tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        let resumedMessage = "Native resume check " + String(UUID().uuidString.prefix(8))
        app.typeText(resumedMessage)
        XCTAssertEqual(editor.value as? String, resumedMessage, "Relaunch must preserve normal typing")
        app.webViews.buttons["Send"].tap()
        let resumedReply = app.webViews.staticTexts.containing(NSPredicate(format: "label CONTAINS %@ AND label CONTAINS %@", resumedMessage, config["replyMarker"] ?? "That is the whole answer.")).firstMatch
        XCTAssertTrue(resumedReply.waitForExistence(timeout: 20), "A fresh reply must cross the restarted stream")
        XCTAssertEqual(app.webViews.staticTexts.matching(NSPredicate(format: "label == %@", resumedMessage)).count, 1, "Acknowledgement and projection must produce one bubble")
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "Signed text and stream after relaunch"; shot.lifetime = .keepAlways; add(shot)
    }
    func testIndependentUpdateService() throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("The independent HTTPS service is verified through the physical device lab")
        #else
        guard let url = Bundle(for: Self.self).url(forResource: "native-test-config", withExtension: "json"),
              let config = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: String],
              config["updateServiceTest"] == "true" else { throw XCTSkip("Independent policy lab is not configured") }
        let app = launchClient()
        let paused = app.webViews.staticTexts["Update service test: recording temporarily paused."]
        XCTAssertTrue(paused.waitForExistence(timeout: 25), "A foreground policy signal must arrive independently of the paired Mac")
        XCTAssertFalse(app.webViews.buttons["Record"].isEnabled)
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "Independent policy received on iPhone"; shot.lifetime = .keepAlways; add(shot)
        let restored = NSPredicate { _, _ in !paused.exists && app.webViews.buttons["Record"].isEnabled }
        expectation(for: restored, evaluatedWith: nil); waitForExpectations(timeout: 25)
        #endif
    }

    func testNativeRecordingAndRelaunch() throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Recording is verified on the physical iPhone with device verify recording; a simulator would capture the Mac microphone")
        #else
        let app = launchClient()
        XCTAssertTrue(app.webViews.buttons["Record"].waitForExistence(timeout: 15))
        let monitor = addUIInterruptionMonitor(withDescription: "Microphone permission") { alert in
            let allow = alert.buttons["OK"]
            if allow.exists { allow.tap(); return true }
            return false
        }
        defer { removeUIInterruptionMonitor(monitor) }
        let initialCount = app.webViews.buttons.matching(identifier: "Delete recording").count
        XCTContext.runActivity(named: "Request microphone through the visible Record button") { _ in
            app.webViews.buttons["Record"].tap()
        }
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        if springboard.alerts.firstMatch.waitForExistence(timeout: 2) {
            let allow = springboard.alerts.buttons["OK"]
            if allow.exists { allow.tap() }
        }
        XCTAssertTrue(app.webViews.staticTexts["Recording…"].waitForExistence(timeout: 10), "Native recorder must start after permission")
        app.webViews.buttons["Stop"].tap()
        let idle = NSPredicate { _, _ in app.webViews.buttons["Record"].isEnabled }
        expectation(for: idle, evaluatedWith: nil); waitForExpectations(timeout: 5)
        let count = NSPredicate { _, _ in app.webViews.buttons.matching(identifier: "Delete recording").count == initialCount + 1 }
        expectation(for: count, evaluatedWith: nil); waitForExpectations(timeout: 10)
        app.terminate(); app.launch()
        XCTAssertTrue(app.webViews.buttons["Record"].waitForExistence(timeout: 15))
        XCTAssertEqual(app.webViews.buttons.matching(identifier: "Delete recording").count, initialCount + 1)
        app.webViews.buttons["Record"].tap()
        XCTAssertTrue(app.webViews.staticTexts["Recording…"].waitForExistence(timeout: 10))
        XCTAssertFalse(springboard.alerts.firstMatch.exists, "A second launch must not prompt for microphone permission again")
        app.webViews.buttons["Cancel"].tap()
        let stopped = NSPredicate { _, _ in app.webViews.buttons["Record"].isEnabled }
        expectation(for: stopped, evaluatedWith: nil); waitForExpectations(timeout: 5)
        XCTAssertEqual(app.webViews.buttons.matching(identifier: "Delete recording").count, initialCount + 1)
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "Native recording persisted across relaunch"; shot.lifetime = .keepAlways; add(shot)
        // Remove only this test's appended recording; preserve any pre-existing files.
        app.webViews.buttons.matching(identifier: "Delete recording").element(boundBy: initialCount).tap()
        let cleaned = NSPredicate { _, _ in app.webViews.buttons.matching(identifier: "Delete recording").count == initialCount }
        expectation(for: cleaned, evaluatedWith: nil); waitForExpectations(timeout: 5)
        #endif
    }
}
