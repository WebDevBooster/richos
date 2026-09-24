import Foundation
import Testing
@testable import RichOSCore
@testable import RichOSFixtures

/// The Mac's stream endpoint for lifecycle tests: every open is recorded; each answers from `plan`
/// (then `fallback`): held open after `chunks` until the phone closes it, answered with a status and
/// no body, or refused at the transport.
actor LifecycleStream: EventStreamTransport {
    enum Answer: Sendable {
        case open(chunks: [String])
        /// Opens, delivers `chunks`, then drops (the Wi-Fi blinked).
        case dropping(chunks: [String])
        case status(Int, challenge: String?)
        case unreachable
    }
    private var plan: [Answer]
    private let fallback: Answer
    private(set) var opened: [HTTPRequest] = []
    private(set) var closed = 0

    init(_ plan: [Answer] = [], fallback: Answer = .open(chunks: [LifecycleStream.hello])) {
        self.plan = plan
        self.fallback = fallback
    }

    static let hello = "id: 2\nevent: hello\ndata: {\"challenge\":\"c-hello\",\"thread_id\":\"thr_5c1e\",\"capabilities\":[\"text\"],\"messages\":[]}\n\n"

    func open(_ request: HTTPRequest, origin: String) async throws -> (response: HTTPResponse, bytes: AsyncThrowingStream<Data, Error>) {
        opened.append(request)
        let answer = plan.isEmpty ? fallback : plan.removeFirst()
        switch answer {
        case .unreachable:
            throw ScriptedMac.TransportFailure()
        case .status(let status, let challenge):
            let headers = challenge.map { ["X-RichOS-Challenge": $0] } ?? [:]
            return (HTTPResponse(status: status, headers: headers), AsyncThrowingStream { $0.finish() })
        case .dropping(let chunks):
            let stream = AsyncThrowingStream<Data, Error> { continuation in
                for chunk in chunks { continuation.yield(Data(chunk.utf8)) }
                continuation.finish(throwing: ScriptedMac.TransportFailure())
            }
            return (HTTPResponse(status: 200, headers: ["X-RichOS-Challenge": "c-open"]), stream)
        case .open(let chunks):
            let stream = AsyncThrowingStream<Data, Error> { continuation in
                // The Mac's keep-alives arrive on this socket for as long as it is open; the phone
                // closing it is the only way it ends here.
                continuation.onTermination = { _ in Task { await self.markClosed() } }
                for chunk in chunks { continuation.yield(Data(chunk.utf8)) }
            }
            held += 1
            return (HTTPResponse(status: 200, headers: ["X-RichOS-Challenge": "c-open"]), stream)
        }
    }

    /// Streams handed out held open, and how many of those the phone has closed.
    private var held = 0
    private func markClosed() { closed += 1 }
    /// Streams open right now: held open and not yet closed by the phone.
    var open: Int { held - closed }
}

/// The Mac's JSON routes: `/api/challenge` offers a new challenge each time; the revocation probe
/// answers "not revoked". Every request is recorded.
actor LifecycleMac: HTTPTransport {
    private(set) var targets: [String] = []
    private var issued = 0

    func send(_ request: HTTPRequest, origin: String) async throws -> HTTPResponse {
        targets.append(request.method + " " + (request.target.components(separatedBy: "&auth=").first ?? request.target))
        issued += 1
        let challenge = ["X-RichOS-Challenge": "c-probe-\(issued)"]
        if request.target.contains("before=0") {
            return HTTPResponse(status: 200, headers: challenge, body: Data(#"{"messages":[],"more":false}"#.utf8))
        }
        return HTTPResponse(status: 404, headers: challenge)
    }
}

/// An identity store whose Keychain lookup waits until the test releases it: the window in which
/// the network effects' actor takes other effects while a `connect` is still waiting.
actor GatedIdentityStore: IdentityStore {
    private let inner = MemoryIdentityStore()
    private var released = false
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private(set) var asked = 0

    func signer(for origin: String) async throws -> any Signer {
        asked += 1
        if !released { await withCheckedContinuation { waiting.append($0) } }
        return await inner.signer(for: origin)
    }

    func forget(origin: String) async throws { await inner.forget(origin: origin) }

    func release() {
        released = true
        for continuation in waiting { continuation.resume() }
        waiting = []
    }
}

/// The back-off wait, observed: each wait is recorded and then lasts until it is canceled (a
/// minute of real time, which no test waits for), unless `instant`, when it returns at once — so a
/// retry loop that was not stopped would spin, and be seen.
actor Waits {
    private(set) var asked: [Int64] = []
    private(set) var canceled = 0
    let instant: Bool
    init(instant: Bool = false) { self.instant = instant }
    func record(_ ms: Int64) { asked.append(ms) }
    func cancel() { canceled += 1 }

    nonisolated var sleep: LiveConnection.Sleep {
        { ms in
            await self.record(ms)
            if self.instant { return }
            do { try await Task.sleep(nanoseconds: 60_000_000_000) } catch {
                await self.cancel()
                throw error
            }
        }
    }
}

/// Polls `condition` for up to two seconds of real time.
func becomes(_ condition: @Sendable () async -> Bool) async -> Bool {
    for _ in 0..<400 {
        if await condition() { return true }
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
    return await condition()
}

/// Whether `condition` holds throughout `ms` of real time (a negative check: something that must
/// NOT happen, given the time to happen).
func holds(_ ms: UInt64 = 250, _ condition: @Sendable () async -> Bool) async -> Bool {
    for _ in 0..<(ms / 5) {
        if !(await condition()) { return false }
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
    return await condition()
}

/// Backgrounding closes the Mac stream and stops every retry and keep-alive; returning reconnects
/// once, then backs off (the CEO's battery rule, 2026-09-24; PRD J10; Android `ConnectionOwnerTest`
/// on richos main `c5f04574`). The real reducer and the real network effects, a scripted Mac.
@Suite struct LifecycleTests {
    func paired() throws -> AppState { try Fixture.named("conv-empty").state }

    func host(_ network: NetworkEffects, state: AppState) async throws -> HeadlessHost {
        let host = try await HeadlessHost(storage: MemoryStorage(), handler: network)
        _ = try await host.replace(with: state)
        await network.setSink { action in _ = try? await host.dispatch(action) }
        return host
    }

    @Test func backgroundingClosesTheStreamAndNoRetryOrRequestFollows() async throws {
        let stream = LifecycleStream()
        let mac = LifecycleMac()
        let network = NetworkEffects(transport: mac, stream: stream, identities: MemoryIdentityStore(), clock: FixedClock(ms: 5),
                                     sleep: Waits(instant: true).sleep)
        let host = try await host(network, state: try paired())
        _ = try await host.dispatch(.foregrounded(at: 1))
        #expect(await becomes { await stream.open == 1 }, "on screen: one stream")

        _ = try await host.dispatch(.backgrounded(at: 2))
        #expect(await becomes { await stream.closed == 1 }, "the stream is closed when the app leaves the screen")
        let requests = await mac.targets.count
        let opens = await stream.opened.count
        // A retry loop still running would spin here: its waits return at once.
        #expect(await holds { let o = await stream.opened.count; let r = await mac.targets.count; return o == opens && r == requests },
                "no reconnect, no request in the background")
        let s = try await host.currentState()
        #expect(s.troubleSinceMs == nil && s.connectionNotice == nil, "no notice timer is owed in the background")
        #expect(TickSchedule.nextTick(s) == nil, "and nothing is owed a tick")
    }

    @Test func backgroundingDuringABackOffCancelsTheWait() async throws {
        let stream = LifecycleStream(fallback: .unreachable)
        let waits = Waits()
        let network = NetworkEffects(transport: LifecycleMac(), stream: stream, identities: MemoryIdentityStore(), clock: FixedClock(ms: 5),
                                     sleep: waits.sleep)
        let host = try await host(network, state: try paired())
        _ = try await host.dispatch(.foregrounded(at: 1))
        #expect(await becomes { await waits.asked == [1000] }, "the Mac is away: a 1 s wait is owed")
        _ = try await host.dispatch(.backgrounded(at: 2))
        #expect(await becomes { await waits.canceled == 1 }, "the wait is canceled, not left to fire")
        let opens = await stream.opened.count
        #expect(await holds { let o = await stream.opened.count; let w = await waits.asked.count; return o == opens && w == 1 })
    }

    /// A `connect` that waits for the Keychain lets the actor take the next effect. Before this
    /// change a `disconnect` taken in that window found no stream to stop, and the waiting connect
    /// then opened one: a Mac stream, retries and keep-alives running with the app in the background.
    @Test func aDisconnectWhileAConnectWaitsForTheKeychainWins() async throws {
        let stream = LifecycleStream()
        let identities = GatedIdentityStore()
        let network = NetworkEffects(transport: LifecycleMac(), stream: stream, identities: identities, clock: FixedClock(ms: 5),
                                     sleep: Waits(instant: true).sleep)
        await network.setSink { _ in }
        let s = try paired()
        async let connecting = network.handle(.connect, state: s)
        #expect(await becomes { await identities.asked == 1 })
        _ = await network.handle(.disconnect, state: s)
        await identities.release()
        _ = await connecting
        #expect(await holds { await stream.opened.isEmpty }, "the app left the screen: no stream opens")

        // The positive probe: the same harness sees a stream when one is wanted.
        _ = await network.handle(.connect, state: s)
        #expect(await becomes { await stream.open == 1 })
        _ = await network.handle(.disconnect, state: s)
        #expect(await becomes { await stream.open == 0 })
    }

    /// Two `connect`s (the launch's and the scene's) while the Keychain is slow: one owner. Before,
    /// both opened a stream and the first was orphaned — never stopped by a later `disconnect`.
    @Test func twoConnectsMakeOneOwnerAndBackgroundingClosesIt() async throws {
        let stream = LifecycleStream()
        let identities = GatedIdentityStore()
        let network = NetworkEffects(transport: LifecycleMac(), stream: stream, identities: identities, clock: FixedClock(ms: 5),
                                     sleep: Waits(instant: true).sleep)
        await network.setSink { _ in }
        let s = try paired()
        async let first = network.handle(.connect, state: s)
        async let second = network.handle(.connect, state: s)
        #expect(await becomes { await identities.asked == 2 })
        await identities.release()
        _ = await (first, second)
        #expect(await becomes { await stream.opened.count >= 1 })
        #expect(await holds { await stream.opened.count == 1 }, "one connection owner, one stream")
        _ = await network.handle(.disconnect, state: s)
        #expect(await becomes { await stream.open == 0 }, "backgrounding closes every stream there is")
    }

    /// Sage's review T9 (richos-hq `e642db4f` §0), reproduced here: a reconnect with `since=` is
    /// answered with only the frames it missed and no `hello` (`app/src-tauri/src/phone/routes.rs`,
    /// `Replay::Tail`). The phone marked itself connected only on a `hello`, so after any drop the
    /// quiet period ran out and "Reconnecting…" stayed on a healthy stream until the app next left
    /// the screen. A stream is up when it opens (HTTP 200): the reference's `accepted()`
    /// (`web/web-app/lib/link.js`) and Android's `Link(OPEN)` (`ConnectionOwner.kt`).
    @Test func aReconnectAnsweredWithOnlyTheMissedFramesIsConnected() async throws {
        let row = #"{"id":"turn_3:user","thread_id":"thr_5c1e","cursor":3,"role":"ceo","kind":"text","text":"On my way","complete":true}"#
        let stream = LifecycleStream([
            .dropping(chunks: [LifecycleStream.hello]),
            .open(chunks: ["id: 3\nevent: message\ndata: \(row)\n\n"]),
        ])
        let network = NetworkEffects(transport: LifecycleMac(), stream: stream, identities: MemoryIdentityStore(), clock: FixedClock(ms: 5),
                                     sleep: Waits(instant: true).sleep)
        let host = try await host(network, state: try paired())
        _ = try await host.dispatch(.foregrounded(at: 1))
        #expect(await becomes { let o = await stream.opened.count; let c = await stream.closed; return o == 2 && c == 0 },
                "dropped once, reopened, and the reopened stream stays")
        let resumed = try #require(await stream.opened.last)
        #expect(resumed.target.contains("since=1"), "the reopening asked for the tail: \(resumed.target)")
        #expect(await becomes { (try? await host.currentState())?.messages.contains { $0.id == "turn_3:user" } == true },
                "the tail arrived")
        let s = try await host.currentState()
        #expect(s.troubleSinceMs == nil, "the reopened stream is connected; no Reconnecting… is owed")
        #expect(s.connectionNotice == nil && TickSchedule.nextTick(s) == nil)
        _ = try await host.dispatch(.backgrounded(at: 9))
    }

    /// Back on screen after the challenge aged out (ten minutes in a pocket): ONE reconnect at once,
    /// re-signed with the challenge the Mac's refusal offered, and no back-off wait in front of the
    /// person; then, if the Mac is away, the usual back-off from 1 s (Android `ConnectionOwnerTest`
    /// "back on screen it reconnects at once, then backs off as before"). Before, the stale attempt
    /// was a failure: "connection lost", a revocation probe and a 1 s wait before the real one.
    @Test func backOnScreenItReconnectsAtOnceWithALiveChallengeThenBacksOff() async throws {
        let stream = LifecycleStream([
            .open(chunks: [LifecycleStream.hello]),
            .status(404, challenge: "c-fresh"),
            .open(chunks: [LifecycleStream.hello]),
            .unreachable,
        ], fallback: .unreachable)
        let waits = Waits()
        let network = NetworkEffects(transport: LifecycleMac(), stream: stream, identities: MemoryIdentityStore(), clock: FixedClock(ms: 5),
                                     sleep: waits.sleep)
        let host = try await host(network, state: try paired())
        _ = try await host.dispatch(.foregrounded(at: 1))
        #expect(await becomes { await stream.open == 1 })
        _ = try await host.dispatch(.backgrounded(at: 2))
        #expect(await becomes { await stream.open == 0 })

        _ = try await host.dispatch(.foregrounded(at: 3))
        #expect(await becomes { await stream.open == 1 }, "reconnected")
        let opened = await stream.opened
        #expect(opened.count == 3, "the stale attempt, then the re-signed one: \(opened.map(\.target))")
        #expect(opened.last?.target.contains(".c-fresh.") == true, "signed with the challenge the refusal offered")
        #expect(await waits.asked.isEmpty, "no back-off wait before the reconnect")
        #expect(try await host.currentState().troubleSinceMs == nil, "and no connection lost on the way")

        // The Mac goes away while the app is off screen: back on screen, one attempt, then 1 s.
        _ = try await host.dispatch(.backgrounded(at: 4))
        #expect(await becomes { await stream.open == 0 })
        _ = try await host.dispatch(.foregrounded(at: 5))
        #expect(await becomes { await waits.asked == [1000] }, "one attempt at once, then the back-off starts again at 1 s")
        #expect(await holds { await stream.opened.count == 4 }, "nothing more until the wait ends")
        _ = try await host.dispatch(.backgrounded(at: 6))
    }

    /// A relaunch holds no challenge (none is stored). The first attempt asks for one and opens the
    /// stream at once; before, it could not be signed, so it counted as a failure and waited 1 s.
    @Test func aColdStartOpensTheStreamAtOnce() async throws {
        let stream = LifecycleStream()
        let mac = LifecycleMac()
        let waits = Waits()
        let network = NetworkEffects(transport: mac, stream: stream, identities: MemoryIdentityStore(), clock: FixedClock(ms: 5),
                                     sleep: waits.sleep)
        let host = try await host(network, state: try paired())
        _ = try await host.dispatch(.foregrounded(at: 1))
        #expect(await becomes { await stream.open == 1 })
        #expect(await mac.targets == ["GET /api/challenge"], "one challenge, then the stream")
        #expect(await waits.asked.isEmpty)
        #expect(try await host.currentState().troubleSinceMs == nil)
        _ = try await host.dispatch(.backgrounded(at: 2))
    }

    static func hello(rows: [String]) -> String {
        "id: 7\nevent: hello\ndata: {\"challenge\":\"c-hello\",\"thread_id\":\"thr_5c1e\",\"capabilities\":[\"text\"],\"messages\":[\(rows.joined(separator: ","))]}\n\n"
    }

    /// Asked, locked the phone, came back after Rich finished. The stream that was carrying the reply
    /// is gone and the new one sends the finished reply as history, never as "finished": before, the
    /// three thinking dots (a full-rate animation) stayed under his answer until he next left the
    /// app, claiming Rich was still working.
    @Test func aReplyThatFinishedWhileAwayIsNotStillThinkingOnReturn() async throws {
        let answer = #"{"id":"turn_1:text:0","thread_id":"thr_5c1e","cursor":2,"role":"rich","kind":"text","text":"Thursday is clear.","complete":true}"#
        let stream = LifecycleStream([.open(chunks: [Self.hello(rows: [answer])])])
        let network = NetworkEffects(transport: LifecycleMac(), stream: stream, identities: MemoryIdentityStore(), clock: FixedClock(ms: 5),
                                     sleep: Waits(instant: true).sleep)
        let host = try await host(network, state: try Fixture.named("conv-replying").state)
        #expect(try await host.currentState().reply == .thinking)
        _ = try await host.dispatch(.backgrounded(at: 1))
        _ = try await host.dispatch(.foregrounded(at: 2))
        #expect(await becomes { (try? await host.currentState())?.messages.contains { $0.id == "turn_1:text:0" } == true })
        #expect(try await host.currentState().reply == nil, "the answer is there; nothing is still thinking")
        _ = try await host.dispatch(.backgrounded(at: 3))
    }

    /// The positive probe: a reply still being written when he comes back is shown as it is.
    @Test func aReplyStillBeingWrittenOnReturnIsShown() async throws {
        let partial = #"{"id":"turn_1:text:0","thread_id":"thr_5c1e","cursor":2,"role":"rich","kind":"text","text":"Thursday is","complete":false}"#
        let stream = LifecycleStream([.open(chunks: [Self.hello(rows: [partial])])])
        let network = NetworkEffects(transport: LifecycleMac(), stream: stream, identities: MemoryIdentityStore(), clock: FixedClock(ms: 5),
                                     sleep: Waits(instant: true).sleep)
        let host = try await host(network, state: try Fixture.named("conv-replying").state)
        _ = try await host.dispatch(.backgrounded(at: 1))
        _ = try await host.dispatch(.foregrounded(at: 2))
        #expect(await becomes { (try? await host.currentState())?.reply == .streaming(text: "Thursday is") })
        _ = try await host.dispatch(.backgrounded(at: 3))
    }

    /// A `disconnect` that lands between the new owner being recorded and its start must still win.
    @Test func aConnectionStoppedBeforeItStartedNeverStarts() async throws {
        let stream = LifecycleStream()
        let api = APIClient(origin: "https://mm1.tail1a2b3c.ts.net:8443", deviceID: "dev_8d4c57b7ff82", challenge: "c1",
                            signer: SoftwareSigner(key: Corpus.testKey), transport: LifecycleMac())
        let connection = LiveConnection(api: api, stream: stream, threadID: "thr_5c1e", sleep: Waits(instant: true).sleep, sink: { _ in })
        await connection.stop()
        await connection.start()
        #expect(await holds { await stream.opened.isEmpty })
    }
}
