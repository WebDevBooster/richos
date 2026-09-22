import XCTest

/// The visible controls, driven the way a finger drives them (build plan §5.1 I2): compose and send,
/// hold and release, slide left to cancel, slide up to lock then send, slide up to lock then cancel —
/// and the conversation following the newest message unless the reader scrolls up, with every send
/// resuming it (PRD §5; ledger §2.8 M2 with RichOS's resume-on-send).
final class InteractionTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    private func rows(_ app: XCUIApplication) -> Int {
        app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'row.'")).count
    }

    private func orb(_ app: XCUIApplication) -> XCUIElement { app.descendants(matching: .any)["composer.mic"] }

    func testComposeAndSendAddsTheMessageAndFollowsIt() {
        let app = Screen.launch("comp-idle")
        let field = app.textFields["composer.field"].exists ? app.textFields["composer.field"] : app.textViews["composer.field"]
        assertOnScreenAndHittable(field, in: app, "the message field")
        field.tap()
        field.typeText("Move the Friday review to 3 PM.")
        let send = app.descendants(matching: .any)["composer.send"]
        assertOnScreenAndHittable(send, in: app, "Send")
        send.tap()
        let sent = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'Move the Friday review to 3 PM.'")).firstMatch
        XCTAssertTrue(sent.waitForExistence(timeout: 3), "the sent message is not in the conversation")
        XCTAssertTrue(sent.isHittable, "the conversation did not follow the message just sent")
        XCTAssertTrue(orb(app).waitForExistence(timeout: 2), "the microphone did not come back after sending")
    }

    func testHoldAndReleaseSendsAVoiceMessage() {
        let app = Screen.launch("comp-idle")
        let before = rows(app)
        let mic = orb(app)
        assertOnScreenAndHittable(mic, in: app, "the microphone")
        mic.press(forDuration: 1.4)
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline, rows(app) == before { Thread.sleep(forTimeInterval: 0.1) }
        XCTAssertEqual(rows(app), before + 1, "releasing did not send a voice message")
        let voices = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'Your voice message'"))
        XCTAssertEqual(voices.count, 2, "the new message is not a voice message")
    }

    func testATapIsTooShortAndSendsNothing() {
        let app = Screen.launch("comp-idle")
        let before = rows(app)
        orb(app).tap()
        XCTAssertTrue(app.staticTexts["composer.toast"].waitForExistence(timeout: 2), "no hint after a tap")
        XCTAssertEqual(rows(app), before, "a tap sent something")
    }

    func testSlideLeftCancelsAndSendsNothing() {
        let app = Screen.launch("comp-idle")
        let before = rows(app)
        let mic = orb(app)
        let start = mic.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.6, thenDragTo: start.withOffset(CGVector(dx: -200, dy: 0)))
        Thread.sleep(forTimeInterval: 1.2)  // the bin ritual
        XCTAssertEqual(rows(app), before, "sliding left sent a message")
        XCTAssertTrue(orb(app).exists, "the microphone did not come back after the cancel")
    }

    func testSlideUpLocksThenSendSends() {
        let app = Screen.launch("comp-idle")
        let before = rows(app)
        let start = orb(app).coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.6, thenDragTo: start.withOffset(CGVector(dx: 0, dy: -110)))
        let cancel = app.buttons["voice.cancel"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 2), "sliding up did not lock")
        // Cancel sits at exactly the center of the capsule (round-12 NOTES "Locked layout").
        let windowMid = app.windows.firstMatch.frame.midX
        XCTAssertEqual(cancel.frame.midX, windowMid, accuracy: 2)
        Thread.sleep(forTimeInterval: 1.0)  // still recording, hands free
        XCTAssertEqual(rows(app), before, "lifting the finger after locking sent the message")
        let send = app.descendants(matching: .any)["voice.send"]
        assertOnScreenAndHittable(send, in: app, "the locked Send circle")
        send.tap()
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline, rows(app) == before { Thread.sleep(forTimeInterval: 0.1) }
        XCTAssertEqual(rows(app), before + 1, "tapping Send did not send")
    }

    func testSlideUpLocksThenCancelSendsNothing() {
        let app = Screen.launch("comp-idle")
        let before = rows(app)
        let start = orb(app).coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.6, thenDragTo: start.withOffset(CGVector(dx: 0, dy: -110)))
        let cancel = app.buttons["voice.cancel"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 2), "sliding up did not lock")
        cancel.tap()
        Thread.sleep(forTimeInterval: 1.3)  // the locked-cancel ritual, 950 ms
        XCTAssertEqual(rows(app), before, "Cancel sent a message")
        XCTAssertFalse(app.buttons["voice.cancel"].exists)
    }

    func testReadingOlderShowsLatestAndSendingResumesFollowing() {
        let app = Screen.launch("conv-scrolled")
        let latest = app.buttons["conversation.latest"]
        XCTAssertTrue(latest.waitForExistence(timeout: 3), "no Latest pill while reading older messages")
        let field = app.textFields["composer.field"].exists ? app.textFields["composer.field"] : app.textViews["composer.field"]
        field.tap()
        field.typeText("Thanks.")
        app.descendants(matching: .any)["composer.send"].tap()
        let sent = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'Thanks.'")).firstMatch
        XCTAssertTrue(sent.waitForExistence(timeout: 3))
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline, !sent.isHittable { Thread.sleep(forTimeInterval: 0.1) }
        XCTAssertTrue(sent.isHittable, "sending did not return to the newest message")
    }

    func testScrollingUpShowsLatestAndLatestReturns() {
        let app = Screen.launch("conv-populated")
        let list = app.collectionViews["conversation.list"]
        XCTAssertTrue(list.waitForExistence(timeout: 3))
        list.swipeDown()
        let latest = app.buttons["conversation.latest"]
        XCTAssertTrue(latest.waitForExistence(timeout: 3), "scrolling up did not offer Latest")
        latest.tap()
        let newest = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'Short it is.'")).firstMatch
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline, !newest.isHittable { Thread.sleep(forTimeInterval: 0.1) }
        XCTAssertTrue(newest.isHittable, "Latest did not return to the newest message")
    }

    func testSettingsOpensAndForgetAsksFirst() {
        let app = Screen.launch("comp-idle")
        app.buttons["header.settings"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["settings.sheet"].waitForExistence(timeout: 3))
        app.buttons["settings.forget"].tap()
        XCTAssertTrue(app.buttons["forget.keep"].waitForExistence(timeout: 3), "Forget did not ask first")
        app.buttons["forget.keep"].tap()
        XCTAssertFalse(app.buttons["forget.confirm"].exists)
    }
}
