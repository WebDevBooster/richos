import Foundation
import Testing
@testable import RichOSCore
@testable import RichOSFixtures

/// The first wait andy-opus-resume1 found on Android, checked on the iPhone (2026-10-01): a message
/// whose sends failed waits out a doubling back-off (`ConversationReducer.retryDelayMs`, 1 s doubling
/// to 16 s, stamped as `notBefore` at the failure), and coming back on screen did not clear it. The
/// stream opens on the return and `connected` pumps the outbox, but `pump` moves the head only once
/// `notBefore <= at`, so a message that failed five times just before the person left waited up to
/// 16 s after the return before it was even tried. The bar: back on screen, a waiting message is
/// sent and its reply shown within about 1 to 2 s.
@Suite struct ReturnBackOffTests {
    static let t0: Int64 = 1_790_000_000_000

    /// A paired phone on screen whose one message has failed `failures` times, the last at `lastAt`.
    static func failed(_ failures: Int, lastAt: Int64, reason: String = "unreachable") throws -> AppState {
        var s = try Fixture.named("conv-empty").state
        s = Reducer.reduce(s, .compose(text: "Book the 7:10 to Denver, aisle.")).state
        s = Reducer.reduce(s, .sendDraft(clientID: "c1", at: t0)).state
        for n in 1...failures {
            let at = n == failures ? lastAt : t0 + Int64(n) * 10
            s = Reducer.reduce(s, .deliveryFailed(clientID: "c1", failure: .retryable(reason: reason, afterMs: nil), at: at)).state
            if n < failures { s.outbox[0].state = .sending }
        }
        return s
    }

    static func delivers(_ effects: [Effect]) -> Bool { effects.contains(.deliver(clientID: "c1")) }

    @Test func aReturnSendsAWaitingMessageAtOnceThoughItsBackOffHadTimeLeft() throws {
        let failedAt = Self.t0 + 1_000
        var s = try Self.failed(5, lastAt: failedAt)
        #expect(s.outbox[0].notBefore == failedAt + 16_000, "five failures: the next try waits 16 s")

        // He leaves 1 s later and is back 3 s after that: 12 s of the wait are still left.
        s = Reducer.reduce(s, .backgrounded(at: failedAt + 1_000)).state
        s = Reducer.reduce(s, .foregrounded(at: failedAt + 4_000)).state
        let (opened, effects) = Reducer.reduce(s, .connected(at: failedAt + 4_100))
        #expect(Self.delivers(effects), "the stream opened on the return: the waiting message goes now, not 12 s later")
        #expect(opened.outbox[0].state == .sending)
        #expect(opened.outbox[0].attempts == 5, "the return clears the wait, never the count of failures")
    }

    /// Back-off still applies while the app stays on screen and failing: the return cleared one wait,
    /// and the next failure waits the next step of the same sequence.
    @Test func onScreenTheBackOffStillGrowsAfterTheReturn() throws {
        let failedAt = Self.t0 + 1_000
        var s = try Self.failed(5, lastAt: failedAt)
        s = Reducer.reduce(s, .backgrounded(at: failedAt + 1_000)).state
        s = Reducer.reduce(s, .foregrounded(at: failedAt + 4_000)).state
        s = Reducer.reduce(s, .connected(at: failedAt + 4_100)).state
        let again = failedAt + 4_300
        s = Reducer.reduce(s, .deliveryFailed(clientID: "c1", failure: .retryable(reason: "unreachable", afterMs: nil), at: again)).state
        #expect(s.outbox[0].attempts == 6)
        #expect(s.outbox[0].notBefore == again + 16_000, "the sixth failure waits 16 s, as before the return")
        #expect(TickSchedule.nextTick(s) == again + 16_000, "and the one timer is owed then, not sooner")
        #expect(!Self.delivers(Reducer.reduce(s, .tick(at: again + 15_999)).effects), "nothing goes before the wait ends")
        #expect(Self.delivers(Reducer.reduce(s, .tick(at: again + 16_000)).effects))
    }

    /// The Mac's own word on waiting (a 429 with `Retry-After`) is kept across a return: clearing it
    /// would only draw another refusal.
    @Test func aWaitTheMacAskedForIsKeptAcrossTheReturn() throws {
        let failedAt = Self.t0 + 1_000
        var s = try Fixture.named("conv-empty").state
        s = Reducer.reduce(s, .compose(text: "Book the 7:10 to Denver, aisle.")).state
        s = Reducer.reduce(s, .sendDraft(clientID: "c1", at: Self.t0)).state
        s = Reducer.reduce(s, .deliveryFailed(clientID: "c1",
                                              failure: .retryable(reason: ConversationReducer.rateLimitedReason, afterMs: 60_000),
                                              at: failedAt)).state
        s = Reducer.reduce(s, .backgrounded(at: failedAt + 1_000)).state
        s = Reducer.reduce(s, .foregrounded(at: failedAt + 4_000)).state
        let (_, effects) = Reducer.reduce(s, .connected(at: failedAt + 4_100))
        #expect(!Self.delivers(effects), "the Mac asked for 60 s; the return does not override it")
    }

    /// The courier names a 429 so the reducer can tell the Mac's wait from the phone's own back-off.
    @Test func aRateLimitIsNamedByTheCourier() {
        let response = HTTPResponse(status: 429, headers: ["Retry-After": "60"])
        #expect(Courier.reason(for: response) == ConversationReducer.rateLimitedReason)
        #expect(Courier.reason(for: HTTPResponse(status: 503)) == "fault")
    }
}
