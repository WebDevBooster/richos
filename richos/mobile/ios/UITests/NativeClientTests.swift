import XCTest

final class NativeClientTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private var serverRun: String?
    private var recoveredVoiceTarget: String?
    private var recoveredVoiceOrigin: String?

    private func launchClient() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--native-client"]
        if let serverRun { app.launchArguments.append("--integration-session=" + serverRun) }
        if let recoveredVoiceTarget, let recoveredVoiceOrigin {
            app.launchArguments += ["--integration-copy-voice-to=" + recoveredVoiceTarget, "--integration-copy-voice-origin=" + recoveredVoiceOrigin]
        }
        // Always release the app's microphone/session, including an assertion failure.
        addTeardownBlock { app.terminate() }
        app.launch()
        return app
    }

    func testClientRejectsInsecurePairing() throws {
        #if targetEnvironment(simulator)
        let app = launchClient()
        XCTAssertTrue(app.webViews.buttons["Scan your Mac’s code"].waitForExistence(timeout: 15))
        app.webViews.descendants(matching: .any).matching(identifier: "Use a pairing link instead").firstMatch.tap()
        let field = app.webViews.textFields.firstMatch
        field.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.5)).tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        app.typeText("http://example.invalid/#pair=invalid")
        app.webViews.buttons["Pair with Mac"].tap()
        XCTAssertTrue(app.webViews.staticTexts["Pairing requires an HTTPS origin"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.webViews.buttons["Send"].exists)
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
        if config["useRecoveredRecording"] == "true" {
            recoveredVoiceTarget = config["threadId"]
            recoveredVoiceOrigin = config["origin"]
        }
        let app = launchClient()
        XCTAssertTrue(app.webViews.buttons["Settings"].waitForExistence(timeout: 15))
        if app.webViews.descendants(matching: .any).matching(identifier: "Use a pairing link instead").firstMatch.exists {
            app.webViews.descendants(matching: .any).matching(identifier: "Use a pairing link instead").firstMatch.tap()
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
        let settings = app.webViews.buttons["Settings"]
        settings.tap()
        let enable = app.webViews.buttons["Enable reply notifications"]
        if enable.exists { enable.tap() }
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        if springboard.alerts.firstMatch.waitForExistence(timeout: 3) {
            let allow = springboard.alerts.buttons["Allow"]
            if allow.exists { allow.tap() }
        }
        XCTAssertTrue(app.webViews.staticTexts["Reply notifications are on."].waitForExistence(timeout: 30), "Apple token must be registered through the authenticated Mac and managed provider")
        app.webViews.buttons["Close settings"].tap()
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
        if config["useRecoveredRecording"] == "true" {
            let saved = app.webViews.buttons.matching(identifier: "Send unsent recording")
            XCTAssertTrue(saved.firstMatch.waitForExistence(timeout: 10), "The previous phone recording must still be available; never request another recording silently")
            let send = saved.allElementsBoundByIndex.last!
            expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: send); waitForExpectations(timeout: 10)
            send.tap()
        } else {
            try lockMicrophone(app)
            // Deliberate interval for the operator's agreed spoken sentence, on the iPhone.
            Thread.sleep(forTimeInterval: 10)
            app.webViews.buttons["Send voice message"].tap()
            let finished = NSPredicate { _, _ in !app.webViews.buttons["Send voice message"].exists }
            expectation(for: finished, evaluatedWith: nil); waitForExpectations(timeout: 5)
        }
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
        XCTAssertFalse(app.webViews.buttons["Hold to record"].isEnabled)
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "Independent policy received on iPhone"; shot.lifetime = .keepAlways; add(shot)
        let restored = NSPredicate { _, _ in !paused.exists && app.webViews.buttons["Hold to record"].isEnabled }
        expectation(for: restored, evaluatedWith: nil); waitForExpectations(timeout: 25)
        #endif
    }

    private func lockMicrophone(_ app: XCUIApplication) throws {
        let mic=app.webViews.buttons["Hold to record"]
        XCTAssertTrue(mic.waitForExistence(timeout:15))
        let start=mic.coordinate(withNormalizedOffset:CGVector(dx:0.5,dy:0.5))
        start.press(forDuration:0.5,thenDragTo:start.withOffset(CGVector(dx:0,dy:-110)))
        let springboard=XCUIApplication(bundleIdentifier:"com.apple.springboard")
        if springboard.alerts.buttons["OK"].waitForExistence(timeout:2) {
            springboard.alerts.buttons["OK"].tap()
            start.press(forDuration:0.5,thenDragTo:start.withOffset(CGVector(dx:0,dy:-110)))
        }
        XCTAssertTrue(app.webViews.buttons["Send voice message"].waitForExistence(timeout:10),"Slide up must lock the microphone")
    }

    func testIntegrationClearsUnsentTestRecordings() throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Only the disposable physical integration app has these operator test recordings")
        #else
        guard Bundle(for: Self.self).bundleIdentifier == "dev.richos.mobile.integration.uitests",
              let url = Bundle(for: Self.self).url(forResource:"native-test-config",withExtension:"json"),
              let config = try JSONSerialization.jsonObject(with:Data(contentsOf:url)) as? [String:String],
              config["cleanupTestRecordings"] == "true" else { throw XCTSkip("Cleanup requires an explicit request in the disposable integration app") }
        let app = XCUIApplication()
        app.launchArguments = ["--native-client"]
        app.launch()
        XCTAssertTrue(app.webViews.buttons["Hold to record"].waitForExistence(timeout:15))
        let discard = app.webViews.buttons.matching(identifier:"Discard unsent recording")
        for _ in 0..<100 {
            let before=discard.count
            if before == 0 { break }
            discard.firstMatch.tap()
            expectation(for:NSPredicate { _, _ in discard.count < before },evaluatedWith:nil)
            waitForExpectations(timeout:5)
        }
        XCTAssertEqual(discard.count,0)
        XCTAssertFalse(app.webViews.buttons["Send unsent recording"].exists)
        let shot=XCTAttachment(screenshot:app.screenshot());shot.name="Normal composer after test recording cleanup";shot.lifetime = .keepAlways;add(shot)
        // No microphone is used; leave the cleaned composer visible for the operator.
        #endif
    }

    func testNativeRecordingAndRelaunch() throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Recording is verified on the physical iPhone with device verify recording; a simulator would capture the Mac microphone")
        #else
        let (app, _) = try pairedClient()
        let initialCount = app.webViews.buttons.matching(identifier: "Discard unsent recording").count
        try lockMicrophone(app)
        Thread.sleep(forTimeInterval: 2)
        app.webViews.firstMatch.swipeUp()
        XCTAssertTrue(app.webViews.buttons["Send voice message"].exists,"Scrolling must leave locked recording active")
        XCUIDevice.shared.press(.home)
        app.activate()
        let count = NSPredicate { _, _ in app.webViews.buttons.matching(identifier: "Discard unsent recording").count == initialCount + 1 }
        expectation(for: count, evaluatedWith: nil); waitForExpectations(timeout: 10)
        app.terminate(); app.launch()
        XCTAssertTrue(app.webViews.buttons["Hold to record"].waitForExistence(timeout: 15))
        XCTAssertEqual(app.webViews.buttons.matching(identifier: "Discard unsent recording").count, initialCount + 1)
        try lockMicrophone(app)
        app.webViews.buttons["Cancel recording"].tap()
        XCTAssertTrue(app.webViews.buttons["Hold to record"].waitForExistence(timeout: 5), "Cancel must activate instead of a text selection menu")
        XCTAssertEqual(app.webViews.buttons.matching(identifier: "Discard unsent recording").count, initialCount + 1)
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "Interrupted voice survives relaunch"; shot.lifetime = .keepAlways; add(shot)
        app.webViews.buttons.matching(identifier: "Discard unsent recording").element(boundBy: initialCount).tap()
        // Button activation and touch-release are separate physical checks. No
        // spoken phrase is needed to prove that each creates exactly one bubble.
        let bubbles = app.webViews.buttons.matching(identifier: "Play voice message")
        let before = bubbles.count
        let cancelStart=app.webViews.buttons["Hold to record"].coordinate(withNormalizedOffset:CGVector(dx:0.5,dy:0.5))
        cancelStart.press(forDuration:0.5,thenDragTo:cancelStart.withOffset(CGVector(dx:-120,dy:0)))
        XCTAssertTrue(app.webViews.buttons["Hold to record"].waitForExistence(timeout:5))
        XCTAssertEqual(bubbles.count,before,"Sliding left must cancel without sending")
        XCTAssertEqual(app.webViews.buttons.matching(identifier:"Discard unsent recording").count,initialCount,"Cancellation must not create a recovery step")
        try lockMicrophone(app)
        app.webViews.buttons["Send voice message"].tap()
        let sentLocked = NSPredicate { _, _ in bubbles.count == before + 1 && !app.webViews.buttons["Send voice message"].exists }
        expectation(for: sentLocked, evaluatedWith: nil); waitForExpectations(timeout: 10)
        let mic = app.webViews.buttons["Hold to record"]
        XCTAssertTrue(mic.waitForExistence(timeout: 5))
        mic.press(forDuration: 2)
        let sentHeld = NSPredicate { _, _ in bubbles.count == before + 2 && !app.webViews.buttons["Send voice message"].exists }
        expectation(for: sentHeld, evaluatedWith: nil); waitForExpectations(timeout: 10)
        let sentShot = XCTAttachment(screenshot: app.screenshot()); sentShot.name = "Locked Send and held release each submit once"; sentShot.lifetime = .keepAlways; add(sentShot)
        #endif
    }
}
