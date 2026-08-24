import XCTest
@testable import RichOSCompanionCore

/// End-to-end (pure-Swift) proof that the SessionWriter produces a valid contract directory: the WAV
/// is a decodable 2-channel 16-bit file, session.json flips open->closed with populated audio, and
/// health.ndjson carries one row per tick. (The REAL P1 transcription handoff is proven separately
/// by the on-Mac `ingest` + `node bin/richos-service.js run` E2E — see README.)
final class SessionWriterTests: XCTestCase {

    func testWritesValidContractDirectory() throws {
        let tmp = NSTemporaryDirectory() + "richos-companion-test-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: tmp) }

        let startedAt: Int64 = 1_700_000_000_000
        var clock = startedAt
        let params = SessionContract.Params(
            sessionId: SessionContract.sessionDirName(startedAt: startedAt, platformId: "system", slug: "call"),
            startedAt: startedAt, sampleRate: 16_000, chunkMs: 3000, micEnabled: true,
            captureTarget: "system", platformId: "system", platformLabel: "Desktop call",
            platformSlug: "call", companionVersion: "test", processHint: nil)

        let writer = SessionWriter(rootZone: tmp, params: params, clock: { clock })
        try writer.start()

        let dir = (tmp as NSString).appendingPathComponent(params.sessionId)
        // session.json exists at START with status open.
        let openData = try Data(contentsOf: URL(fileURLWithPath: (dir as NSString).appendingPathComponent("session.json")))
        let openObj = try JSONSerialization.jsonObject(with: openData) as! [String: Any]
        XCTAssertEqual(openObj["status"] as? String, "open")

        // Feed 3 seconds of aligned tone; mic=LEFT, system=RIGHT.
        for _ in 0..<3 {
            let mic = (0..<16_000).map { sinf(Float($0) * 0.05) * 0.5 }
            let sys = (0..<16_000).map { sinf(Float($0) * 0.10) * 0.5 }
            writer.pushMic(mic); writer.pushSystem(sys)
            try writer.pump()
            try writer.writeHealthTick(micPeak: 0.5, micRms: 0.35, sysPeak: 0.5, sysRms: 0.35,
                                       tapRunning: true, micRunning: true)
            clock += 1000
        }
        try writer.close()

        // Closed session.json: audio populated.
        let closedData = try Data(contentsOf: URL(fileURLWithPath: (dir as NSString).appendingPathComponent("session.json")))
        let closedObj = try JSONSerialization.jsonObject(with: closedData) as! [String: Any]
        XCTAssertEqual(closedObj["status"] as? String, "closed")
        let audio = closedObj["audio"] as? [String: Any]
        XCTAssertGreaterThan(audio?["bytesTotal"] as? Int ?? 0, 3 * 16_000 * 4 - 100) // ~3s stereo 16-bit

        // The WAV part decodes as 2-channel 16-bit at 16 kHz with ~3s of data.
        let wavPath = (dir as NSString).appendingPathComponent("audio-part-00.wav")
        let pcm = try WavReader.read(path: wavPath)
        XCTAssertEqual(pcm.channels, 2)
        XCTAssertEqual(pcm.sampleRate, 16_000)
        XCTAssertEqual(pcm.channelsData.count, 2)
        XCTAssertGreaterThan(pcm.channelsData[0].count, 16_000 * 2) // > 2s of frames

        // health.ndjson has one row per tick.
        let health = try String(contentsOf: URL(fileURLWithPath: (dir as NSString).appendingPathComponent("health.ndjson")), encoding: .utf8)
        let rows = health.split(separator: "\n").filter { !$0.isEmpty }
        XCTAssertEqual(rows.count, 3)
    }

    func testWavWriterHeaderIsValidAfterFlush() throws {
        let path = NSTemporaryDirectory() + "richos-wav-\(UUID().uuidString).wav"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let w = try WavWriter(path: path, sampleRate: 48_000, channels: 2, bitsPerSample: 16)
        try w.append(ChannelMixer.int16LEBytes([1, 2, 3, 4])) // 2 frames
        try w.close()
        let pcm = try WavReader.read(path: path)
        XCTAssertEqual(pcm.sampleRate, 48_000)
        XCTAssertEqual(pcm.channels, 2)
        XCTAssertEqual(pcm.channelsData[0].count, 2)
    }
}
