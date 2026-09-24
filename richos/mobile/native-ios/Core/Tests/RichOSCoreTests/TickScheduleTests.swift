import Foundation
import Testing
@testable import RichOSCore
@testable import RichOSFixtures

/// The app's one timer on virtual time, with the semantics of the SwiftUI `.task(id:)` that runs it in
/// `RichOSNativeApp`: one sleep per distinct `TickSchedule.nextTick`, a `tick` when it ends, and
/// nothing more until the value changes. What it counts is every wakeup the app would take.
struct VirtualTimer {
    var state: AppState
    var now: Int64
    private(set) var ticks: [Int64] = []
    private(set) var effects: [Effect] = []

    init(_ state: AppState, now: Int64) { self.state = state; self.now = now }

    mutating func send(_ action: Action) {
        let (next, effects) = Reducer.reduce(state, action)
        state = next
        self.effects += effects
    }

    /// Lets virtual time run to `end`, taking every tick the app's timer would take on the way.
    mutating func run(until end: Int64) {
        var armed: Int64?
        while let due = TickSchedule.nextTick(state), due != armed {
            let at = max(now, due)
            guard at <= end else { break }
            now = at
            send(.tick(at: at))
            ticks.append(at)
            armed = due
        }
        now = max(now, end)
    }
}

@Suite struct TickScheduleTests {
    static let hour: Int64 = 3_600_000
    static let t0: Int64 = 1_790_000_000_000

    func recordingReady() throws -> AppState {
        var s = try Fixture.named("conv-empty").state
        s.microphone = .granted
        return s
    }

    /// Before 2026-09-24 the app woke ten times a second whenever it was on screen, at rest or not
    /// (`RichOSNativeApp.swift`, a 100 ms loop). At rest nothing is owed a tick, so nothing wakes.
    @Test func anIdleAppIsOwedNoTickInAnHour() throws {
        for name in ["conv-empty", "conv-populated", "conv-scrolled", "conv-beginning", "conv-replying", "conv-streaming", "pair-intro"] {
            var timer = VirtualTimer(try Fixture.named(name).state, now: Self.t0)
            #expect(TickSchedule.nextTick(timer.state) == nil, "\(name) is owed nothing")
            timer.run(until: Self.t0 + Self.hour)
            #expect(timer.ticks.isEmpty, "\(name): \(timer.ticks.count) wakeups in an hour at rest")
        }
    }

    @Test func aRecordingIsTickedEvery100msWhileItRunsAndNotAfterItEnds() throws {
        var timer = VirtualTimer(try recordingReady(), now: Self.t0)
        timer.send(.voicePress(id: "v1", width: 386, at: Self.t0))
        timer.run(until: Self.t0 + 1_000)
        #expect(timer.ticks == (1...10).map { Self.t0 + Int64($0) * 100 }, "ten ticks in the first second")
        #expect(timer.state.voice?.phase == .held, "the press delay passed on a tick")
        #expect(timer.state.voice?.recordingStartedAtMs == Self.t0 + VoiceGeometry.pressDelayMs)
        #expect(timer.effects.contains(.startRecording(id: "v1")))
        #expect(timer.state.voice?.nowMs == Self.t0 + 1_000)

        timer.send(.voiceRelease(at: Self.t0 + 1_050))
        guard case .ending? = timer.state.voice?.phase else {
            Issue.record("the release sends the recording: \(String(describing: timer.state.voice?.phase))")
            return
        }
        #expect(TickSchedule.nextTick(timer.state) == nil, "an ended recording is not running")
        timer.run(until: Self.t0 + Self.hour)
        #expect(timer.ticks.count == 10, "no tick after the recording ended, though the end was never settled")
    }

    /// Android's `AppStoreIdleTest` case: a tap on the microphone (too short) leaves the session
    /// ending, and a screen that never settles it must not keep the timer running.
    @Test func aTapOnTheMicrophoneLeavesNoTimerRunning() throws {
        var timer = VirtualTimer(try recordingReady(), now: Self.t0)
        timer.send(.voicePress(id: "v1", width: 386, at: Self.t0))
        timer.send(.voiceRelease(at: Self.t0 + 80))
        #expect(timer.state.voice?.phase == .ending(.tooShort))
        timer.run(until: Self.t0 + Self.hour)
        #expect(timer.ticks.isEmpty)
    }

    @Test func aLockedRecordingKeepsTickingUntilItsCeiling() throws {
        var timer = VirtualTimer(try recordingReady(), now: Self.t0)
        timer.send(.voiceStartLocked(id: "v1", width: 386, at: Self.t0))
        timer.run(until: Self.t0 + Limits.voiceCeilingMs + 1_000)
        #expect(timer.state.keptRecordings.map(\.id) == ["v1"], "the ceiling stopped and kept it")
        #expect(timer.ticks.last == Self.t0 + Limits.voiceCeilingMs, "the last tick is the one that reached the ceiling")
        #expect(timer.ticks.count == Int(Limits.voiceCeilingMs / TickSchedule.voiceCadenceMs))
    }

    /// Sage's review T2 (richos-hq `e642db4f` §0): in a locked, hands-free recording only this clock
    /// refreshes the session's `nowMs`, and the composer reads a session whose `nowMs` is more than
    /// 2 s old as a posed still (`VoiceClock.isPose`, `ComposerView.swift`): its timer would freeze
    /// 2 s after locking had the schedule waited for the ceiling. It keeps the 100 ms cadence.
    @Test func aLockedRecordingStillReadsLiveFiveSecondsAfterLocking() throws {
        var timer = VirtualTimer(try recordingReady(), now: Self.t0)
        timer.send(.voicePress(id: "v1", width: 386, at: Self.t0))
        timer.run(until: Self.t0 + 400)
        timer.send(.voiceMove(dx: 0, dy: -(VoiceGeometry.lockDistance + 1), at: Self.t0 + 450))
        #expect(timer.state.voice?.phase == .locked)
        let locked = timer.ticks.count
        timer.run(until: Self.t0 + 450 + 5_000)
        #expect(timer.state.voice?.phase == .locked)
        let stale = timer.now - (timer.state.voice?.nowMs ?? 0)
        #expect(stale < TickSchedule.voiceCadenceMs, "the session's time is \(stale) ms old; the composer calls over 2 000 a pose")
        let gaps = zip(timer.ticks.dropFirst(locked), timer.ticks.dropFirst(locked + 1)).map { $1 - $0 }
        #expect(gaps.count == 49 && gaps.allSatisfy { $0 == TickSchedule.voiceCadenceMs }, "a tick every 100 ms while locked")
    }

    @Test func aFingersMovesDoNotPushTheNextTickAway() throws {
        var timer = VirtualTimer(try recordingReady(), now: Self.t0)
        timer.send(.voicePress(id: "v1", width: 386, at: Self.t0))
        timer.run(until: Self.t0 + 200)
        #expect(timer.state.voice?.phase == .held)
        for ms in stride(from: Int64(216), through: 296, by: 16) {
            timer.send(.voiceMove(dx: -Double(ms - 200) / 10, dy: 0, at: Self.t0 + ms))
            #expect(TickSchedule.nextTick(timer.state) == Self.t0 + 300, "a move at +\(ms) ms keeps the tick at +300")
        }
    }

    @Test func nothingIsTickedWhileTheSystemAsksForTheMicrophone() throws {
        var timer = VirtualTimer(try Fixture.named("conv-empty").state, now: Self.t0)
        timer.send(.voicePress(id: "v1", width: 386, at: Self.t0))
        #expect(timer.state.sheet == .microphonePrompt)
        timer.run(until: Self.t0 + Self.hour)
        #expect(timer.ticks.isEmpty)
    }

    @Test func theReconnectingNoticeIsOwedOneTickAtTheEndOfTheQuietPeriod() throws {
        var timer = VirtualTimer(try Fixture.named("conv-populated").state, now: Self.t0)
        timer.send(.connectionLost(at: Self.t0))
        timer.run(until: Self.t0 + Self.hour)
        #expect(timer.ticks == [Self.t0 + ConnectionReducer.quietMs])
        #expect(timer.state.connectionNotice == .reconnecting)
    }

    @Test func aRetryIsOwedWhenItsBackOffRunsOutAndNotWhileOffline() throws {
        var timer = VirtualTimer(try Fixture.named("conv-empty").state, now: Self.t0)
        timer.send(.compose(text: "Book the 7:10"))
        timer.send(.sendDraft(clientID: "c1", at: Self.t0))
        #expect(TickSchedule.nextTick(timer.state) == nil, "in flight: nothing is owed")
        timer.send(.deliveryFailed(clientID: "c1", failure: .retryable(reason: "unreachable"), at: Self.t0 + 40))
        let due = Self.t0 + 40 + ConversationReducer.retryDelayMs(attempt: 1)
        #expect(TickSchedule.nextTick(timer.state) == due)
        let before = timer.effects.filter { $0 == .deliver(clientID: "c1") }.count
        timer.run(until: Self.t0 + Self.hour)
        #expect(timer.ticks == [due], "one tick, and it started the retry")
        #expect(timer.effects.filter { $0 == .deliver(clientID: "c1") }.count == before + 1)

        timer.send(.deliveryFailed(clientID: "c1", failure: .retryable(reason: "unreachable"), at: timer.now))
        timer.send(.networkChanged(online: false, at: timer.now))
        #expect(TickSchedule.nextTick(timer.state) == nil, "offline, no attempt is owed a timer")
    }

    /// What lets the app restart its timer only when this value changes: a tick at (or after) the
    /// time owed always leaves the next one later, or none. Over every screen the app has.
    @Test func aTickAtItsTimeAlwaysMovesTheNextOneLater() throws {
        for fixture in Fixture.all {
            guard let due = TickSchedule.nextTick(fixture.state) else { continue }
            for late: Int64 in [0, 5, 5_000] {
                let at = due + late
                let after = Reducer.reduce(fixture.state, .tick(at: at)).state
                if let next = TickSchedule.nextTick(after) {
                    #expect(next > at, "\(fixture.name): a tick at \(at) left the next one at \(next)")
                }
            }
        }
    }

    /// The app runs its clock from this schedule, not from a fixed loop.
    @Test func theAppsClockIsThisSchedule() throws {
        let source = try String(contentsOf: repositoryRoot.appendingPathComponent("richos/mobile/native-ios/App/App/RichOSNativeApp.swift"),
                                encoding: .utf8)
        #expect(source.contains("TickSchedule.nextTick"))
        #expect(!source.contains("Task.sleep(nanoseconds: 100_000_000)"), "no fixed 100 ms loop")
    }
}
