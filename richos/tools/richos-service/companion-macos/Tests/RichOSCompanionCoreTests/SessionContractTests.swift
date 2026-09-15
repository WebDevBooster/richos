import XCTest
@testable import RichOSCompanionCore

/// Pins the on-disk contract to P1's frozen schemaVersion 2. Every field the pipeline reads
/// (`contract.js`, `pipeline.js`, `reconcile.js`, `merge.js#renderMarkdown`) is asserted here.
final class SessionContractTests: XCTestCase {

    // 1_700_000_000_000 -> 2023-11-14T22:13:20.000Z -> stamp "2023-11-14T22-13-20Z"
    func testStampMatchesExtensionStampFor() {
        XCTAssertEqual(SessionContract.stampFor(1_700_000_000_000), "2023-11-14T22-13-20Z")
    }

    func testSessionDirNameShape() {
        let id = SessionContract.sessionDirName(startedAt: 1_700_000_000_000, platformId: "system", slug: "call")
        XCTAssertEqual(id, "2023-11-14T22-13-20Z--system--call")
    }

    func testAudioPartFilenameIsPipelineMatchable() {
        XCTAssertEqual(SessionContract.audioPartFile(0), "audio-part-00.wav")
        // Must satisfy the pipeline's part regex /^audio-part-\d+\.[a-z0-9]+$/i
        XCTAssertNotNil(SessionContract.audioPartFile(0).range(
            of: #"^audio-part-\d+\.[a-z0-9]+$"#, options: .regularExpression))
    }

    private func params() -> SessionContract.Params {
        SessionContract.Params(
            sessionId: "2023-11-14T22-13-20Z--system--call", startedAt: 1_700_000_000_000,
            sampleRate: 48_000, chunkMs: 3000, micEnabled: true, captureTarget: "system",
            platformId: "system", platformLabel: "Desktop call", platformSlug: "call",
            companionVersion: "0.1.0-p2", processHint: nil)
    }

    private func parse(_ json: JSON) -> [String: Any] {
        let data = Data(json.serialized().utf8)
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    func testOpenSessionJSONHasFrozenV2Shape() {
        let obj = parse(SessionContract.sessionJSON(params(), status: "open", endedAt: nil,
                                                    audioParts: [], health: SessionContract.HealthSummary()))
        XCTAssertEqual(obj["schemaVersion"] as? Int, 2)
        XCTAssertEqual(obj["status"] as? String, "open")
        XCTAssertTrue(obj["endedAt"] is NSNull) // explicit null, not omitted

        let capture = obj["capture"] as? [String: Any]
        XCTAssertEqual(capture?["source"] as? String, "desktop-companion-macos")
        XCTAssertEqual(capture?["method"] as? String, "coreaudio-tap+mic")
        XCTAssertEqual(capture?["captureTarget"] as? String, "system")
        XCTAssertEqual(capture?["sampleRate"] as? Int, 48_000)
        let channels = capture?["channels"] as? [String: Any]
        XCTAssertEqual(channels?["left"] as? String, "microphone (me)")
        XCTAssertEqual(channels?["right"] as? String, "system/tap (everyone else)")

        let audio = obj["audio"] as? [String: Any]
        XCTAssertEqual((audio?["parts"] as? [Any])?.count, 0)
        XCTAssertEqual(audio?["bytesTotal"] as? Int, 0)

        let ownership = obj["ownership"] as? [String: Any]
        XCTAssertEqual(ownership?["ownerSurface"] as? String, "desktop-companion-macos")
        XCTAssertTrue(ownership?["supersedes"] is NSNull)

        let pipeline = obj["pipeline"] as? [String: Any]
        XCTAssertEqual(pipeline?["status"] as? String, "pending")
        XCTAssertTrue(pipeline?["model"] is NSNull)
        XCTAssertEqual((pipeline?["modelRuns"] as? [Any])?.count, 0)
        let loro = pipeline?["loroCorrection"] as? [String: Any]
        XCTAssertEqual(loro?["applied"] as? Bool, false)
        XCTAssertEqual(loro?["corrections"] as? Int, 0)

        // §3.4 — companion has no captions, present-from-birth empty.
        let captions = obj["captions"] as? [String: Any]
        XCTAssertEqual(captions?["available"] as? Bool, false)
        XCTAssertEqual(captions?["count"] as? Int, 0)
    }

    func testClosedSessionPopulatesAudioAndEndedAt() {
        var h = SessionContract.HealthSummary()
        h.heartbeats = 12; h.greenSeconds = 12; h.worstLevel = "green"; h.recordsWritten = 12
        let part = SessionContract.AudioPart(part: 0, bytes: 96_044, firstChunkAt: 1_700_000_000_000,
                                             lastChunkAt: 1_700_000_012_000)
        let obj = parse(SessionContract.sessionJSON(params(), status: "closed",
                                                    endedAt: 1_700_000_012_000, audioParts: [part], health: h))
        XCTAssertEqual(obj["status"] as? String, "closed")
        XCTAssertEqual(obj["endedAt"] as? Int, 1_700_000_012_000)
        let audio = obj["audio"] as? [String: Any]
        XCTAssertEqual(audio?["bytesTotal"] as? Int, 96_044)
        let parts = audio?["parts"] as? [[String: Any]]
        XCTAssertEqual(parts?.first?["file"] as? String, "audio-part-00.wav")
        XCTAssertEqual(parts?.first?["bytes"] as? Int, 96_044)
    }

    func testHealthSampleShape() {
        let s = SessionContract.HealthSample(
            sessionId: "s", t: 1_700_000_001_000, micRms: 0.1234567, sysRms: 0.02, micRmsMean: 0.05,
            sysRmsMean: 0.01, bytesTotal: 1000, bytesDelta: 100, part: 0, tapRunning: true,
            micRunning: true, level: "green", problems: [])
        let data = Data(s.json().compact().utf8)
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        XCTAssertEqual(obj["t"] as? Int, 1_700_000_001_000)
        XCTAssertEqual((obj["micRms"] as? Double) ?? -1, 0.123457, accuracy: 1e-6) // rounded to 6dp
        XCTAssertEqual(obj["level"] as? String, "green")
        XCTAssertEqual(obj["tapRunning"] as? Bool, true)
    }
}
