import XCTest
@testable import RichOSCompanionCore

/// The companion parses the SHARED authority's coordination answers (architecture §5.4). The decision logic
/// lives once in the Node service; these tests prove the companion reads its verdicts faithfully +
/// builds the correct promotion-ownership block — the seam that makes the system generic over
/// companion type.
final class CoordinationTests: XCTestCase {

    func testParsesStandDownClaim() throws {
        let json = """
        { "request": {"surface":"desktop-companion-macos"},
          "decision": "stand-down",
          "reason": "chrome-extension already owns this call",
          "conflictSessionId": "ext-1",
          "excludeProcessHint": "Google Chrome" }
        """.data(using: .utf8)!
        let d = try Coordination.parseClaimResult(json)
        XCTAssertEqual(d.decision, .standDown)
        XCTAssertEqual(d.conflictSessionId, "ext-1")
        XCTAssertEqual(d.excludeProcessHint, "Google Chrome")
    }

    func testParsesOwnClaimWithSupersede() throws {
        let json = """
        { "decision": "own", "reason": "richer surface supersedes", "supersede": ["mac-4"] }
        """.data(using: .utf8)!
        let d = try Coordination.parseClaimResult(json)
        XCTAssertEqual(d.decision, .own)
        XCTAssertEqual(d.supersede, ["mac-4"])
        XCTAssertNil(d.conflictSessionId)
    }

    func testMalformedClaimThrows() {
        let json = "{ \"nope\": true }".data(using: .utf8)!
        XCTAssertThrowsError(try Coordination.parseClaimResult(json))
    }

    func testParsesFailoverCandidates() throws {
        let json = """
        { "zone": "/tmp/z",
          "candidates": [
            { "sessionId": "ext-dead", "surface": "chrome-extension", "captureKind": "browser-tab",
              "processHint": "Google Chrome", "reason": "owner interrupted" }
          ] }
        """.data(using: .utf8)!
        let c = try Coordination.parseFailoverCandidates(json)
        XCTAssertEqual(c.count, 1)
        XCTAssertEqual(c[0].sessionId, "ext-dead")
        XCTAssertEqual(c[0].surface, "chrome-extension")
        XCTAssertEqual(c[0].processHint, "Google Chrome")
    }

    func testPromotionOwnershipBlockMatchesTheContract() {
        let json = Coordination.promotionOwnership(deadSessionId: "ext-dead", processHint: "Google Chrome")
        // Serialize via the companion's JSON encoder and read it back to assert the exact field shape
        // the pipeline (coordination.js) expects: {ownerSurface, supersedes, processHint}.
        let obj = (try? JSONSerialization.jsonObject(with: json.data())) as? [String: Any]
        XCTAssertEqual(obj?["ownerSurface"] as? String, "desktop-companion-macos")
        XCTAssertEqual(obj?["supersedes"] as? String, "ext-dead")
        XCTAssertEqual(obj?["processHint"] as? String, "Google Chrome")
    }
}
