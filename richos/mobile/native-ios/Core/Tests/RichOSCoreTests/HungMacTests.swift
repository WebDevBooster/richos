import Foundation
import Testing
@testable import RichOSCore
@testable import RichOSFixtures

/// A clock the test moves: a request that hangs moves it by its timeout, a back-off wait by its length.
final class VirtualClock: Clock, @unchecked Sendable {
    private let lock = NSLock()
    private var now: Int64
    init(_ start: Int64) { now = start }
    func nowMs() -> Int64 { lock.lock(); defer { lock.unlock() }; return now }
    func advance(_ ms: Int64) { lock.lock(); now += max(0, ms); lock.unlock() }
    func set(atLeast ms: Int64) { lock.lock(); now = max(now, ms); lock.unlock() }
}

/// I06's Mac: the connection is accepted (the tunnel is up) and nothing ever comes back. Every
/// request takes the phone's whole request timeout (`URLSessionTransport.defaultRequestTimeout`,
/// 30 s; the phone logged 30,962–31,018 ms) and then fails. Each start is recorded, and so is the
/// most requests ever in flight at once.
actor HungMac: HTTPTransport, EventStreamTransport {
    let clock: VirtualClock
    let requestMs: Int64
    let streamMs: Int64
    private(set) var starts: [(at: Int64, target: String)] = []
    private var inFlight = 0
    private(set) var mostInFlight = 0

    init(clock: VirtualClock, requestMs: Int64 = 31_000, streamMs: Int64 = 60_000) {
        self.clock = clock; self.requestMs = requestMs; self.streamMs = streamMs
    }

    private func hang(_ request: HTTPRequest, for ms: Int64) {
        starts.append((clock.nowMs(), request.method + " " + (request.target.components(separatedBy: "?").first ?? request.target)))
        inFlight += 1
        mostInFlight = max(mostInFlight, inFlight)
        clock.advance(ms)
        inFlight -= 1
    }

    func send(_ request: HTTPRequest, origin: String) async throws -> HTTPResponse {
        hang(request, for: requestMs)
        throw URLError(.timedOut)
    }

    func open(_ request: HTTPRequest, origin: String) async throws -> (response: HTTPResponse, bytes: AsyncThrowingStream<Data, Error>) {
        hang(request, for: streamMs)
        throw URLError(.timedOut)
    }
}

@Suite struct HungMacTests {
    static let t0: Int64 = 1_790_000_000_000

    /// A paired phone on screen with the conversation, the Mac's stream not yet answered.
    static func onScreen() throws -> AppState {
        var s = try Fixture.named("conv-empty").state
        s.connectionNotice = nil
        s.troubleSinceMs = nil
        return s
    }

    /// I06 (native acceptance r1, iPhone): the Mac accepts connections and never answers. The app,
    /// driven exactly as the app drives it (the reducer, the real effect handler, and the one timer
    /// ticking only when `TickSchedule` says time is owed), for five minutes after a Send. The stream
    /// never opens; its owner reports the loss at its 60 s timeout.
    ///
    /// On the phone: two requests always in flight, each replaced within a second of its 31 s timeout,
    /// with no growing gap, and "Sending…" with a turning mark on an idle screen. Expected: the same
    /// calm state as a Mac that is plainly gone — "Waiting to send", a still clock, the card with
    /// "Try now" — and nothing hammering a Mac that cannot answer.
    @Test func aHungMacIsNotRetriedBackToBackAndTheMessageWaitsCalmly() async throws {
        let clock = VirtualClock(Self.t0)
        let mac = HungMac(clock: clock)
        let network = NetworkEffects(transport: mac, stream: mac, identities: PairedMemoryIdentityStore(), clock: clock,
                                     sleep: { _ in throw CancellationError() })
        var s = try Self.onScreen()
        var observed: [AppState] = []
        var pending: [Action] = [.foregrounded(at: clock.nowMs())]
        // What happens around the app: the person sends one second after it came up; the stream's
        // owner, whose open hangs until its 60 s timeout, then reports the loss.
        var outside: [(at: Int64, actions: [Action])] = [
            (Self.t0 + 1_000, [.compose(text: "Spin probe quebec"), .sendDraft(clientID: "c1", at: Self.t0 + 1_000)]),
            (Self.t0 + 60_000, [.connectionLost(at: Self.t0 + 60_000)]),
        ]
        let end = Self.t0 + 5 * 60_000
        while clock.nowMs() < end {
            if pending.isEmpty {
                // The app's one timer sleeps to the next moment time is owed, or not at all.
                let due = TickSchedule.nextTick(s)
                if let event = outside.first, due.map({ event.at <= max($0, clock.nowMs()) }) ?? true {
                    outside.removeFirst()
                    clock.set(atLeast: event.at)
                    pending = event.actions
                    continue
                }
                guard let due else { break }
                clock.set(atLeast: due)
                pending = [.tick(at: clock.nowMs())]
                continue
            }
            let (next, effects) = Reducer.reduce(s, pending.removeFirst())
            s = next
            observed.append(s)
            for effect in effects {
                if case .deliver = effect { pending += await network.handle(effect, state: s) }
            }
        }

        let attempts = await mac.starts.filter { $0.target.hasPrefix("POST /api/messages") || $0.target.hasPrefix("GET /api/challenge") }
        let gaps = zip(attempts.dropFirst(), attempts).map { $0.at - ($1.at + mac.requestMs) }
        #expect(gaps.allSatisfy { $0 >= 1_000 } && gaps == gaps.sorted(),
                "each retry waits longer after the last one timed out; waits after each timeout: \(gaps) ms")
        #expect(attempts.isEmpty,
                "nothing is sent to a Mac whose stream has not answered: one connection owner, one retry policy (\(attempts.count) attempts: \(attempts.map { ($0.at - Self.t0) / 1000 }) s)")
        let afterSend = observed.drop { $0.outbox.isEmpty }
        #expect(!afterSend.isEmpty)
        #expect(afterSend.allSatisfy { $0.messages.last?.delivery == .waiting },
                "the message reads Waiting to send with a still clock the whole time, never Sending… with a turning mark")
        let notified = try #require(observed.first { $0.connectionNotice != nil }, "the interruption is explained")
        #expect(notified.connectionNotice == .reconnecting)
        let explainedAt = try #require(notified.troubleSinceMs) + ConnectionReducer.quietMs
        #expect(explainedAt <= Self.t0 + ConnectionReducer.quietMs,
                "explained once the quiet 3 s after coming on screen have passed, not a minute later")
        #expect(s.messages.last?.delivery == .waiting && s.connectionNotice == .reconnecting,
                "the calm state the card is drawn from (ScreenModel: a waiting message and a notice)")
        #expect(TickSchedule.nextTick(s) == nil, "and nothing more is owed: no timer, no retry, no frame")
    }

    /// The same Mac, reached while its stream is open (the stream answered, then the Mac stopped
    /// answering requests): each delivery that times out waits its back-off from the moment it failed
    /// — 1 s, doubling to 16 s (the reference queue; Android `Outbox.kt`, `notBefore = clock.now() +
    /// retryDelayMs(...)`). Measured from the attempt's start, a 31 s timeout left every wait in the
    /// past, so the next attempt began at once.
    @Test func aDeliveryThatTimesOutWaitsItsBackOffFromTheFailure() async throws {
        let clock = VirtualClock(Self.t0)
        let mac = HungMac(clock: clock)
        let network = NetworkEffects(transport: mac, stream: mac, identities: PairedMemoryIdentityStore(), clock: clock,
                                     sleep: { _ in throw CancellationError() })
        var s = try Self.onScreen()
        var pending: [Action] = [.foregrounded(at: clock.nowMs()), .connected(at: clock.nowMs()),
                                 .compose(text: "Spin probe quebec"), .sendDraft(clientID: "c1", at: clock.nowMs())]
        let end = Self.t0 + 6 * 60_000
        while clock.nowMs() < end {
            if pending.isEmpty {
                guard let due = TickSchedule.nextTick(s) else { break }
                clock.set(atLeast: due)
                pending = [.tick(at: clock.nowMs())]
                continue
            }
            let (next, effects) = Reducer.reduce(s, pending.removeFirst())
            s = next
            for effect in effects {
                if case .deliver = effect { pending += await network.handle(effect, state: s) }
            }
        }
        let starts = await mac.starts.map(\.at)
        let waits = zip(starts.dropFirst(), starts).map { $0 - ($1 + mac.requestMs) }
        #expect(waits.prefix(6) == [1_000, 2_000, 4_000, 8_000, 16_000, 16_000],
                "the wait after each timed-out attempt: \(waits) ms")
        #expect(await mac.mostInFlight == 1, "one request at a time")
    }
}
