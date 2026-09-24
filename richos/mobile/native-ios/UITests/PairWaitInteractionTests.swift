import XCTest

/// The wait for the press on the Mac against a Mac that HOLDS the ask (`pair-wait`; Sage's pair-v2
/// hypotheses review §1): real taps into the production core, with a stand-in Mac at the effect seam
/// (`-rios-fixture-mac`, `DevBridgeFixtureMac`). An ask can now be out for up to 14 s, so the screen
/// must stay truthful and usable for all of it, and hear the press the moment it happens.
final class PairWaitInteractionTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement { app.descendants(matching: .any)[id] }

    /// While the Mac holds the phone's They match, the screen says which press is missing, keeps the
    /// words up, and "They do not match" still works at once: it does not wait for the hold to end.
    func testWhileTheMacHoldsTheAskTheyDoNotMatchStillLeavesAtOnce() {
        let app = Screen.launch("pair-words", interactive: true, mac: "holds")
        let match = app.buttons["pair.match"]
        assertOnScreenAndHittable(match, in: app, "They match")
        match.tap()
        XCTAssertTrue(element(app, "takeover.pair-awaiting-mac").waitForExistence(timeout: 3), "They match did not lead to the wait for the Mac")
        // The ask is held by the Mac now (for up to 14 s).
        Thread.sleep(forTimeInterval: 2)
        XCTAssertTrue(element(app, "takeover.pair-awaiting-mac").exists, "the held ask ended the wait")
        XCTAssertTrue(app.staticTexts["Now press They match on your Mac"].exists, "the screen does not name the missing press")
        XCTAssertTrue(element(app, "pair.words").exists, "the words left the screen while the Mac held the ask")
        let noMatch = app.buttons["pair.noMatch"]
        assertOnScreenAndHittable(noMatch, in: app, "They do not match while the Mac holds the ask")
        let pressed = Date()
        noMatch.tap()
        let card = element(app, "pair.error")
        XCTAssertTrue(card.waitForExistence(timeout: 3) && card.label.contains("Stopped, and nothing was paired"),
                      "They do not match waited for the hold: \(card.exists ? card.label : "no card")")
        XCTAssertLessThan(Date().timeIntervalSince(pressed), 5, "the way out took as long as the hold")
        XCTAssertFalse(element(app, "pair.words").exists, "the words outlived the pairing")
    }

    /// The press on the Mac lands during a hold: the phone hears it then, not at a later scheduled
    /// ask, and goes on to consent.
    func testThePressOnTheMacDuringAHoldPairsAtOnce() {
        let app = Screen.launch("pair-words", interactive: true, mac: "press-after-2000")
        app.buttons["pair.match"].tap()
        XCTAssertTrue(element(app, "takeover.pair-awaiting-mac").waitForExistence(timeout: 3), "They match did not lead to the wait for the Mac")
        let started = Date()
        XCTAssertTrue(element(app, "takeover.pair-consent").waitForExistence(timeout: 6), "the press on the Mac was not heard during the hold")
        // Pressed 2 s after the ask arrived: heard within one round trip of that, never 7 s or more later.
        XCTAssertLessThan(Date().timeIntervalSince(started), 5, "the press was heard late")
        XCTAssertFalse(element(app, "takeover.pair-awaiting-mac").exists, "still claims to be waiting")
    }

    /// Going to the Home Screen during a hold cancels the ask (nothing runs off screen); coming back
    /// resumes the wait truthfully, and "They do not match" is still the way out.
    func testLeavingDuringAHoldAndReturningKeepsTheWaitTruthful() {
        let app = Screen.launch("pair-words", interactive: true, mac: "holds")
        app.buttons["pair.match"].tap()
        XCTAssertTrue(element(app, "takeover.pair-awaiting-mac").waitForExistence(timeout: 3))
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 5))
        app.activate()
        XCTAssertTrue(element(app, "takeover.pair-awaiting-mac").waitForExistence(timeout: 3), "the wait did not resume on return")
        XCTAssertTrue(app.staticTexts["Now press They match on your Mac"].exists)
        XCTAssertTrue(app.buttons["pair.noMatch"].isHittable)
    }
}
