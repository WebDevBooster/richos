import XCTest

/// The visible controls, driven the way a finger drives them (build plan §5.1 I2): compose and send,
/// hold and release, slide left to cancel, slide up to lock then send, slide up to lock then cancel —
/// and the conversation following the newest message unless the reader scrolls up, with every send
/// resuming it (PRD §5; ledger §2.8 M2 with RichOS's resume-on-send).
final class InteractionTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    private func rows(_ app: XCUIApplication) -> Set<String> {
        Set(app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'row.'"))
            .allElementsBoundByIndex.map(\.identifier))
    }

    private func assertNewVoice(_ app: XCUIApplication, after before: Set<String>,
                                file: StaticString = #filePath, line: UInt = #line) {
        // UICollectionView recycles off-screen rows. Its visible count need not grow on Send.
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline, rows(app).subtracting(before).isEmpty { Thread.sleep(forTimeInterval: 0.1) }
        let added = rows(app).subtracting(before)
        XCTAssertEqual(added.count, 1, "expected one new message identity", file: file, line: line)
        guard let id = added.first else { return }
        let message = app.descendants(matching: .any)[id]
        XCTAssertTrue(message.label.hasPrefix("Your voice message"), "new row is not a voice message", file: file, line: line)
        XCTAssertTrue(message.isHittable, "the conversation did not follow the sent voice message", file: file, line: line)
    }

    private func orb(_ app: XCUIApplication) -> XCUIElement { app.descendants(matching: .any)["composer.mic"] }

    /// Interactive fixtures supply a controlled microphone answer and recording effects.
    /// These checks prove real gestures into the production core, not physical audio capture.
    /// A broken fixture fails the test instead of silently skipping the required gesture.
    private func requireMicrophoneKnownToCore(_ app: XCUIApplication) throws {
        let granted = app.descendants(matching: .any)["debug.microphone.granted"]
        guard granted.waitForExistence(timeout: 3) else {
            let seen = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'debug.microphone.'")).firstMatch.identifier
            XCTFail("interactive fixture microphone is '\(seen)', expected granted")
            return
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
        let app = Screen.launch("comp-idle", interactive: true)
        try requireMicrophoneKnownToCore(app)
        let before = rows(app)
        let mic = orb(app)
        assertOnScreenAndHittable(mic, in: app, "the microphone")
        mic.press(forDuration: 1.4)
        assertNewVoice(app, after: before)
    }

    func testATapIsTooShortAndSendsNothing() throws {
        let app = Screen.launch("comp-idle", interactive: true)
        try requireMicrophoneKnownToCore(app)
        let before = rows(app)
        orb(app).tap()
        let line = app.staticTexts["composer.toast"]
        XCTAssertTrue(line.waitForExistence(timeout: 2), "no hint after a tap")
        XCTAssertEqual(rows(app), before, "a tap sent something")
        // XCTest's accessibility lookup can consume most of the display interval.
        // TooShortLineTests covers the latch; this check proves appearance and disappearance.
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: line)
        XCTAssertEqual(XCTWaiter.wait(for: [gone], timeout: 3), .completed, "the too-short line never left")
    }

    func testSlideLeftCancelsAndSendsNothing() throws {
        let app = Screen.launch("comp-idle", interactive: true)
        try requireMicrophoneKnownToCore(app)
        let before = rows(app)
        let mic = orb(app)
        let start = mic.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        // The positive probe: a hold alone records (the timer appears), so "nothing was sent" below
        // cannot pass merely because no recording ever began.
        mic.press(forDuration: 0.9)
        Thread.sleep(forTimeInterval: 1.0)
        assertNewVoice(app, after: before)
        let afterHold = rows(app)
        start.press(forDuration: 0.6, thenDragTo: start.withOffset(CGVector(dx: -200, dy: 0)))
        Thread.sleep(forTimeInterval: 1.2)  // the bin ritual
        XCTAssertEqual(rows(app), afterHold, "sliding left sent a message")
        XCTAssertTrue(orb(app).exists, "the microphone did not come back after the cancel")
    }

    func testSlideUpLocksThenSendSends() throws {
        let app = Screen.launch("comp-idle", interactive: true)
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
        assertNewVoice(app, after: before)
    }

    func testSlideUpLocksThenCancelSendsNothing() throws {
        let app = Screen.launch("comp-idle", interactive: true)
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

    func testBackgroundKeepsLockedVoiceAndReturnAllowsANewRecording() throws {
        let app = Screen.launch("comp-idle", interactive: true)
        try requireMicrophoneKnownToCore(app)
        let before = rows(app)
        let start = orb(app).coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.6, thenDragTo: start.withOffset(CGVector(dx: 0, dy: -110)))
        XCTAssertTrue(app.buttons["voice.cancel"].waitForExistence(timeout: 2))
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 5))
        app.activate()
        XCTAssertTrue(app.buttons["kept.send"].waitForExistence(timeout: 3), "backgrounding lost the unsent recording")
        XCTAssertFalse(app.buttons["voice.cancel"].exists, "capture restarted on return")
        XCTAssertTrue(rows(app).subtracting(before).isEmpty, "backgrounding or returning sent the recording")
        app.buttons["kept.discard"].tap()
        XCTAssertFalse(app.buttons["kept.send"].exists)
        let returned = rows(app)
        orb(app).press(forDuration: 1.4)
        assertNewVoice(app, after: returned)
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
        let showsLatest = latest.waitForExistence(timeout: 3)
        if !showsLatest {
            keepScreenshot(app, name: "scrolling-up-missing-latest")
            print(app.debugDescription)
        }
        XCTAssertTrue(showsLatest, "scrolling up did not offer Latest")
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
