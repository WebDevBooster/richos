import Foundation
import RichOSCore
import Testing
@testable import RichOSNative

/// "Hold the button while you speak." outlives the core's toast (Android `withTooShortLine`).
@Suite("Too-short line")
struct TooShortLineTests {
    private static func live(_ phase: VoiceSession.Phase, id: String = "v1") -> VoiceSession {
        let now = VoiceClock.nowMs()
        return VoiceSession(id: id, phase: phase, startedAtMs: now - 100, nowMs: now, recordingStartedAtMs: nil, width: 386)
    }

    private static func paired(_ change: (inout AppState) -> Void = { _ in }) -> AppState {
        var s = AppState()
        s.pairing = .paired
        change(&s)
        return s
    }

    @Test func theCoreClearsTheLineWhenTheEndingSettlesSoTheScreenMustHoldIt() {
        // The reason for the latch: the core's toast is gone 150 ms in, at the settle.
        let ending = Self.paired { $0.voice = Self.live(.ending(.tooShort)); $0.toast = .tooShort }
        let settled = Reducer.reduce(ending, .voiceSettled).state
        #expect(settled.voice == nil && settled.toast == nil)
        // Latched, the line is still drawn on the settled screen.
        #expect(TooShortLine.apply("v1", to: ScreenModel(state: settled)).toast == .tooShort)
        // Unlatched (the timer ran out), it goes.
        #expect(TooShortLine.apply(nil, to: ScreenModel(state: settled)).toast == nil)
    }

    @Test func onlyALiveTooShortEndingLatches() {
        #expect(TooShortLine.ending(Self.live(.ending(.tooShort), id: "v7")) == "v7")
        #expect(TooShortLine.ending(Self.live(.ending(.sent))) == nil)
        #expect(TooShortLine.ending(Self.live(.held)) == nil)
        #expect(TooShortLine.ending(nil) == nil)
        // A posed fixture (its clock far from now) draws its own frame and starts no timer.
        var posed = Self.live(.ending(.tooShort))
        posed.nowMs -= 60_000
        #expect(TooShortLine.ending(posed) == nil)
    }

    @Test func aNewRecordingTakesThePlaceOfTheLine() {
        let recording = Self.paired { $0.voice = Self.live(.held, id: "v2") }
        #expect(TooShortLine.apply("v1", to: ScreenModel(state: recording)).toast == nil)
    }

    @Test func anotherNoticeIsNeverCoveredByTheLine() {
        let warned = Self.paired { $0.toast = .ceilingWarning }
        #expect(TooShortLine.apply("v1", to: ScreenModel(state: warned)).toast == .ceilingWarning)
    }
}
