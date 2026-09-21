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

    func testAuthenticatedTextAndStreamResume() throws {
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
        let editor = app.webViews.textViews["Message"]
        editor.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.2)).tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        let message = "Native phone check " + String(UUID().uuidString.prefix(8))
        app.typeText(message)
        app.webViews.buttons["Send"].tap()
        let reply = app.webViews.staticTexts.containing(NSPredicate(format: "label CONTAINS %@ AND label CONTAINS %@", message, config["replyMarker"] ?? "That is the whole answer.")).firstMatch
        XCTAssertTrue(reply.waitForExistence(timeout: 20), "Reply must arrive through the authenticated native event stream")
        app.terminate(); app.launch()
        XCTAssertTrue(app.webViews.staticTexts["Connected to your Mac"].waitForExistence(timeout: 20))
        XCTAssertTrue(reply.waitForExistence(timeout: 10), "Cached reply must survive process termination")
        // A cached bubble alone cannot prove the restarted stream works.
        editor.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.2)).tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        let resumedMessage = "Native resume check " + String(UUID().uuidString.prefix(8))
        app.typeText(resumedMessage)
        app.webViews.buttons["Send"].tap()
        let resumedReply = app.webViews.staticTexts.containing(NSPredicate(format: "label CONTAINS %@ AND label CONTAINS %@", resumedMessage, config["replyMarker"] ?? "That is the whole answer.")).firstMatch
        XCTAssertTrue(resumedReply.waitForExistence(timeout: 20), "A fresh reply must cross the restarted stream")
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "Signed text and stream after relaunch"; shot.lifetime = .keepAlways; add(shot)
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
