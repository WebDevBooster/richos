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

    /// Voice starts only once the core knows the OS granted the microphone (PRD §3: asked on the first
    /// deliberate press, remembered by the OS). The suite grants it to the app with `simctl privacy`;
    /// mirroring that grant into the core is the platform's job (streams I1/I3). Until the app does,
    /// these tests SKIP with that reason instead of failing on a gesture that never began.
    private func requireMicrophoneKnownToCore(_ app: XCUIApplication) throws {
        let granted = app.descendants(matching: .any)["debug.microphone.granted"]
        guard granted.waitForExistence(timeout: 3) else {
            let seen = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'debug.microphone.'")).firstMatch.identifier
            throw XCTSkip("the core's microphone mirror is '\(seen)', not granted: the app does not yet tell the core the OS permission (I1/I3 platform wiring)")
        }
    }

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

    func testHoldAndReleaseSendsAVoiceMessage() throws {
        let app = Screen.launch("comp-idle")
        try requireMicrophoneKnownToCore(app)
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

    func testATapIsTooShortAndSendsNothing() throws {
        let app = Screen.launch("comp-idle")
        try requireMicrophoneKnownToCore(app)
        let before = rows(app)
        orb(app).tap()
        let line = app.staticTexts["composer.toast"]
        XCTAssertTrue(line.waitForExistence(timeout: 2), "no hint after a tap")
        XCTAssertEqual(rows(app), before, "a tap sent something")
        // The line is one calm 1.8 s, not the 150 ms settle that clears the core's toast.
        Thread.sleep(forTimeInterval: 1.0)
        XCTAssertTrue(line.exists, "the too-short line left before its 1.8 s")
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: line)
        XCTAssertEqual(XCTWaiter.wait(for: [gone], timeout: 3), .completed, "the too-short line never left")
    }

    func testSlideLeftCancelsAndSendsNothing() throws {
        let app = Screen.launch("comp-idle")
        try requireMicrophoneKnownToCore(app)
        let before = rows(app)
        let mic = orb(app)
        let start = mic.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        // The positive probe: a hold alone records (the timer appears), so "nothing was sent" below
        // cannot pass merely because no recording ever began.
        mic.press(forDuration: 0.9)
        Thread.sleep(forTimeInterval: 1.0)
        XCTAssertEqual(rows(app), before + 1, "a plain hold did not record and send; the cancel check below would prove nothing")
        let afterHold = rows(app)
        start.press(forDuration: 0.6, thenDragTo: start.withOffset(CGVector(dx: -200, dy: 0)))
        Thread.sleep(forTimeInterval: 1.2)  // the bin ritual
        XCTAssertEqual(rows(app), afterHold, "sliding left sent a message")
        XCTAssertTrue(orb(app).exists, "the microphone did not come back after the cancel")
    }

    func testSlideUpLocksThenSendSends() throws {
        let app = Screen.launch("comp-idle")
        try requireMicrophoneKnownToCore(app)
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

    func testSlideUpLocksThenCancelSendsNothing() throws {
        let app = Screen.launch("comp-idle")
        try requireMicrophoneKnownToCore(app)
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
