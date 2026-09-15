import XCTest
@testable import RichOSCompanionCore

/// The mic-vs-tap failover (§6.4): one source stalling must not freeze the recording — write the
/// live side, silence-fill the dead side, alarm. Never lose the live half; never go silent.
final class MixDecisionTests: XCTestCase {
    let threshold: Int64 = 15_000

    func testBothLiveTakesCommonMinimum() {
        let d = MixDecision.decide(micAvail: 100, systemAvail: 60, micSilentMs: 0, systemSilentMs: 0,
                                   starveThresholdMs: threshold)
        XCTAssertEqual(d, MixDecision(frames: 60, useMic: true, useSystem: true,
                                      micStarved: false, systemStarved: false))
    }

    func testSystemStalledFailsOverToMicOnly() {
        // system silent past threshold, mic still delivering
        let d = MixDecision.decide(micAvail: 80, systemAvail: 0, micSilentMs: 0, systemSilentMs: 20_000,
                                   starveThresholdMs: threshold)
        XCTAssertEqual(d.frames, 80)
        XCTAssertTrue(d.useMic)
        XCTAssertFalse(d.useSystem)      // RIGHT silence-filled
        XCTAssertTrue(d.systemStarved)   // -> red alarm
        XCTAssertFalse(d.micStarved)
    }

    func testMicStalledFailsOverToSystemOnly() {
        let d = MixDecision.decide(micAvail: 0, systemAvail: 50, micSilentMs: 20_000, systemSilentMs: 0,
                                   starveThresholdMs: threshold)
        XCTAssertEqual(d.frames, 50)
        XCTAssertFalse(d.useMic)         // LEFT silence-filled
        XCTAssertTrue(d.useSystem)
        XCTAssertTrue(d.micStarved)
    }

    func testBothStalledWritesNothingButAlarmsBoth() {
        let d = MixDecision.decide(micAvail: 0, systemAvail: 0, micSilentMs: 20_000, systemSilentMs: 20_000,
                                   starveThresholdMs: threshold)
        XCTAssertEqual(d.frames, 0)
        XCTAssertTrue(d.micStarved)
        XCTAssertTrue(d.systemStarved)
    }

    func testBriefLagUnderThresholdDoesNotFailover() {
        // system briefly behind but within threshold -> stay aligned, wait (min = 0 this pump).
        let d = MixDecision.decide(micAvail: 40, systemAvail: 0, micSilentMs: 0, systemSilentMs: 5_000,
                                   starveThresholdMs: threshold)
        XCTAssertEqual(d.frames, 0)
        XCTAssertFalse(d.systemStarved)
    }
}
