import XCTest

/// The app's half of the automated App Review walk (CEO 2026-10-04, §107: the CEO is never the first
/// tester). Only `rios review-walk` runs it (`Tools/review-walk.mjs`), against the RELEASE app on a
/// simulator and the live review service, doing what the review notes tell Apple's reviewer to do:
/// paste the pairing link, check the six words, press They match, send a message, see the Demo reply.
/// No fixture, development bridge or launch argument reaches the app.
///
/// The access page's half runs in a real browser on the Mac. The two meet through files in the walk's
/// own directory (`dir`), which a simulator's test runner reads and writes like any Mac process:
///   app-words      written here: the six words the app shows
///   page-verdict   written by the Mac: "match", or why not (then this test stops)
///   app-pressed    written here: They match was pressed in the app
///   app-done       written here: the Demo reply to this walk's message arrived
/// Every step prints one `REVIEW_WALK_STEP` line; a failed step stops the test with its reason.
final class ReviewWalkTests: XCTestCase {
    private struct Walk: Decodable { let link: String; let dir: String; let message: String }

    override func setUp() {
        continueAfterFailure = false
    }

    func testReviewerWalk() throws {
        guard let raw = ProcessInfo.processInfo.environment["RICHOS_REVIEW_WALK"] else {
            throw XCTSkip("Only rios review-walk runs the reviewer walk")
        }
        let walk = try JSONDecoder().decode(Walk.self, from: Data(raw.utf8))
        let app = XCUIApplication()
        app.launchArguments = []
        let any = { (id: String) in app.descendants(matching: .any).matching(identifier: id).firstMatch }

        // 3. Open the pairing link in the app, as the notes say: paste it into the pairing link field.
        app.launch()
        try step("open it in the app") {
            guard any("pair.link").waitForExistence(timeout: 30) else { return "the unpaired app never showed Use a pairing link instead" }
            any("pair.link").tap()
            let field = any("pairlink.field")
            guard field.waitForExistence(timeout: 10) else { return "the pairing link field never opened" }
            field.tap()
            field.typeText(walk.link)
            any("pairlink.submit").tap()
            guard any("pair.match").waitForExistence(timeout: 45) else {
                return any("pair.error").exists ? "the app refused the link: \(any("pair.error").label)" : "the app never showed the six words"
            }
            return nil
        }

        // 4. The six words, both sides, then They match here and (by the Mac) on the page.
        try step("six words match and They match on both sides") {
            var words: [String] = []
            for index in 1...6 {
                let prefix = "Word \(index): "
                let word = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", prefix)).firstMatch
                guard word.exists else { return "the app shows no word \(index)" }
                words.append(String(word.label.dropFirst(prefix.count)))
            }
            try write(walk.dir, "app-words", words.joined(separator: " "))
            guard let verdict = wait(walk.dir, "page-verdict", seconds: 120) else { return "the access page never compared the words" }
            guard verdict == "match" else { return "the words differ: \(verdict)" }
            any("pair.match").tap()
            try write(walk.dir, "app-pressed", "yes")
            // The Mac presses They match on the page now; the app hears it and asks for consent.
            guard any("consent.continue").waitForExistence(timeout: 120) else {
                return any("pair.error").exists ? "the pairing ended: \(any("pair.error").label)" : "the app never heard They match on the access page"
            }
            any("consent.continue").tap()
            return nil
        }

        // 5. Send one message and see its Demo reply arrive.
        try step("send a message and see the Demo reply") {
            // The message field is a text view once it can grow to several lines (Support.swift messageField).
            guard any("composer.field").waitForExistence(timeout: 20) else { return "the conversation never opened after pairing" }
            let input = messageField(app)
            input.tap()
            input.typeText(walk.message)
            guard any("composer.send").waitForExistence(timeout: 5) else { return "no Send button after typing" }
            any("composer.send").tap()
            // The demo reply quotes the message it answers, so only this walk's reply can match.
            let reply = app.descendants(matching: .any).matching(NSPredicate(
                format: "label CONTAINS %@ AND label CONTAINS %@", "Demo reply", walk.message)).firstMatch
            guard reply.waitForExistence(timeout: 60) else { return "no Demo reply to the message within 60 s" }
            try write(walk.dir, "app-done", reply.label)
            return nil
        }
        keepScreenshot(app, name: "review-walk-done")
    }

    /// Runs one step: prints its line, and fails the test with its reason when it has one.
    private func step(_ name: String, _ body: () throws -> String?) throws {
        let reason = try body()
        let line: [String: Any] = ["name": name, "ok": reason == nil, "detail": reason ?? ""]
        let data = try JSONSerialization.data(withJSONObject: line, options: [.sortedKeys])
        print("REVIEW_WALK_STEP " + String(decoding: data, as: UTF8.self))
        if let reason {
            keepScreenshot(XCUIApplication(), name: "review-walk-failed")
            XCTFail("\(name): \(reason)")
            throw NSError(domain: "ReviewWalk", code: 1, userInfo: [NSLocalizedDescriptionKey: "stopped at \(name)"])
        }
    }

    private func write(_ dir: String, _ name: String, _ text: String) throws {
        let path = URL(fileURLWithPath: dir).appendingPathComponent(name)
        let partial = path.appendingPathExtension("partial")
        try Data(text.utf8).write(to: partial)
        _ = try FileManager.default.replaceItemAt(path, withItemAt: partial)
    }

    private func wait(_ dir: String, _ name: String, seconds: TimeInterval) -> String? {
        let path = URL(fileURLWithPath: dir).appendingPathComponent(name).path
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if let data = FileManager.default.contents(atPath: path) { return String(decoding: data, as: UTF8.self) }
            Thread.sleep(forTimeInterval: 0.5)
        }
        return nil
    }
}
