import XCTest

final class QuestionTests: XCTestCase {
    func testTapAndOfflineEditLeaveTheComposerAvailable() {
        // Keep the supplied offline state: OS network reports stay suspended,
        // while these visible controls still use the real reducer and storage.
        let app = Screen.launch("ask-open", appearance: "dark")
        keepScreenshot(app, name: "ask-open")
        app.buttons["question-option-today"].tap()
        XCTAssertTrue(app.staticTexts["You answered: Ship today"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["By tap, on your phone"].exists)
        XCTAssertFalse(app.buttons["questions.open"].exists)
        app.buttons["Change answer"].tap()
        app.buttons["question-option-tomorrow"].tap()
        XCTAssertTrue(app.staticTexts["You answered: Ship tomorrow"].waitForExistence(timeout: 5))
        keepScreenshot(app, name: "ask-offline-edited")
    }
    func testOtherAnswerInLightTheme() {
        let app = Screen.launch("ask-open", appearance: "light")
        app.buttons["Other answer"].tap()
        let field = app.descendants(matching: .any)["question-other-answer"]
        field.tap(); field.typeText("Next Tuesday")
        app.buttons["Send"].tap()
        XCTAssertTrue(app.staticTexts["You answered: Next Tuesday"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["By typing, on your phone"].exists)
        keepScreenshot(app, name: "ask-other-saved")
    }
}
