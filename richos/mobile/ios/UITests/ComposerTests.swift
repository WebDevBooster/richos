import XCTest

final class ComposerTests: XCTestCase {
    func testVisibleSendQueuesTypedText() throws {
        let app = XCUIApplication()
        app.launch()
        let editor = app.webViews.textViews["Message"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        editor.tap()
        editor.typeText("Typed through the visible composer")
        app.webViews.buttons["Send"].tap()
        XCTAssertTrue(app.webViews.staticTexts["Typed through the visible composer"].waitForExistence(timeout: 5))
        let remaining = editor.value as? String ?? ""
        XCTAssertTrue(remaining.isEmpty || remaining == "Talk to Rich", "Composer must clear only after durable enqueue")
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Visible composer queued message"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
