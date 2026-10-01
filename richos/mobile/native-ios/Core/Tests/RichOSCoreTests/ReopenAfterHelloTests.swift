import Foundation
import Testing
@testable import RichOSCore
@testable import RichOSFixtures

/// The Mac's event stream as its hub answers a resume (`app/src-tauri/src/phone/stream.rs`
/// `replay_after_marked`): no `since` gets a `hello` whose id is the hub's cursor; a `since` the hub can
/// answer gets the frames after it, which may be NONE; one it cannot gets a `hello`. And an opening with
/// no frames is answered the way the Mac's listener answers it: no response head until the stream's
/// first bytes, which are its keep-alive 15 s later. The headless lab measured exactly that with this
/// core and the production listener (`Tools/LabPhone`, `--away-before 11`: "answered 200 after
/// 15059 ms", the reply in the state 15.3 s after the return). Here the held answer simply never comes
/// while the test watches, and it is counted.
actor HubLikeStream: EventStreamTransport {
    /// The hub's cursor: the last one it issued, or the conversation's row count it was seeded with.
    private let cursor: Int
    /// The frames the hub holds, as (cursor, wire).
    private let frames: [(cursor: Int, wire: String)]
    /// Frames that come live on the first stream, after its opening (published while the phone watched).
    private var live: [String]
    private(set) var opened: [HTTPRequest] = []
    /// Openings with nothing in them: answered only at the Mac's keep-alive.
    private(set) var heldForTheKeepAlive = 0

    init(cursor: Int, frames: [(cursor: Int, wire: String)] = [], live: [String] = []) {
        self.cursor = cursor
        self.frames = frames
        self.live = live
    }

    static func row(_ cursor: Int) -> String {
        let data = #"{"id":"turn_\#(cursor):user","thread_id":"thr_5c1e","cursor":\#(cursor),"role":"ceo","kind":"text","text":"row \#(cursor)","complete":true}"#
        return "id: \(cursor)\nevent: message\ndata: \(data)\n\n"
    }

    private func hello() -> String {
        "id: \(cursor)\nevent: hello\ndata: {\"challenge\":\"c-hello\",\"thread_id\":\"thr_5c1e\",\"capabilities\":[\"text\"],\"messages\":[]}\n\n"
    }

    /// What the hub sends for `since` (`replay_after_marked`, the parts these tests reach).
    private func opening(since: Int?) -> [String] {
        guard let since, since <= cursor else { return [hello()] }
        guard let oldest = frames.map(\.cursor).min() else { return since == cursor ? [] : [hello()] }
        guard oldest <= since + 1 else { return [hello()] }
        return frames.filter { $0.cursor > since }.map(\.wire)
    }

    func open(_ request: HTTPRequest, origin: String) async throws -> (response: HTTPResponse, bytes: AsyncThrowingStream<Data, Error>) {
        opened.append(request)
        let since = request.target.components(separatedBy: "since=").dropFirst().first
            .flatMap { Int($0.prefix { $0.isNumber }) }
        let chunks = opening(since: since) + live
        live = []
        if chunks.isEmpty {
            heldForTheKeepAlive += 1
            // No head until the keep-alive: far longer than any test waits, ended by the phone closing it.
            try await Task.sleep(nanoseconds: 60_000_000_000)
        }
        let stream = AsyncThrowingStream<Data, Error> { continuation in
            for chunk in chunks { continuation.yield(Data(chunk.utf8)) }
        }
        return (HTTPResponse(status: 200), stream)
    }
}

/// iPhone re-walk 4 (2026-10-01): one return of seven showed the reply 17.11 s after the app was
/// reopened. The headless lab reproduced a 15.3 s return with this core against the production
/// listener: the phone's last frame was a `hello`, it resumed from that `hello`'s id minus one, the
/// Mac held no frame after it, and the empty opening was not answered until the keep-alive.
@Suite struct ReopenAfterHelloTests {
    func host(_ network: NetworkEffects) async throws -> HeadlessHost {
        let host = try await HeadlessHost(storage: MemoryStorage(), handler: network)
        _ = try await host.replace(with: try Fixture.named("conv-empty").state)
        await network.setSink { action in _ = try? await host.dispatch(action) }
        return host
    }

    func linkOpen(_ host: HeadlessHost) async -> Bool { (try? await host.currentState().linkOpen) == true }

    /// Paired, nothing said yet: the hub has issued nothing, so its first `hello` is id 0. A return
    /// resumed from there asked for `since=0`, which the hub answers with nothing.
    @Test func aReturnAfterOnlyAHelloIsConnectedAtOnce() async throws {
        let stream = HubLikeStream(cursor: 0)
        let network = NetworkEffects(transport: LifecycleMac(), stream: stream, identities: PairedMemoryIdentityStore(),
                                     clock: FixedClock(ms: 5), sleep: Waits(instant: true).sleep)
        let host = try await host(network)
        _ = try await host.dispatch(.foregrounded(at: 1))
        #expect(await becomes { await linkOpen(host) }, "the first stream opens on its hello")
        // Wait until the hello has reached the sink before taking the checkpoint.
        #expect(await becomes { (try? await host.currentState().voiceAvailability) == .unsupportedByMac })
        _ = try await host.dispatch(.backgrounded(at: 2))
        _ = try await host.dispatch(.foregrounded(at: 3))
        #expect(await becomes { await stream.opened.count == 2 })
        #expect(await becomes { await linkOpen(host) }, "the return is connected without waiting for the Mac's keep-alive")
        #expect(await stream.heldForTheKeepAlive == 0, "no opening the Mac answers only at its keep-alive")
        let resumed = try #require(await stream.opened.last)
        #expect(!resumed.target.contains("since="), "after a hello the stream asks for a hello: \(resumed.target)")
        _ = try await host.dispatch(.backgrounded(at: 4))
    }

    /// The hub's cursor seeded from the conversation's row count, above every frame it holds (a `hello`
    /// built after turns the hub never streamed): the same empty answer for `hello` id minus one.
    @Test func aReturnAfterAHelloAboveTheHubsFramesIsConnectedAtOnce() async throws {
        let stream = HubLikeStream(cursor: 5, frames: [(1, HubLikeStream.row(1)), (2, HubLikeStream.row(2))])
        let network = NetworkEffects(transport: LifecycleMac(), stream: stream, identities: PairedMemoryIdentityStore(),
                                     clock: FixedClock(ms: 5), sleep: Waits(instant: true).sleep)
        let host = try await host(network)
        _ = try await host.dispatch(.foregrounded(at: 1))
        #expect(await becomes { (try? await host.currentState().voiceAvailability) == .unsupportedByMac })
        _ = try await host.dispatch(.backgrounded(at: 2))
        _ = try await host.dispatch(.foregrounded(at: 3))
        #expect(await becomes { await stream.opened.count == 2 })
        #expect(await becomes { await linkOpen(host) })
        #expect(await stream.heldForTheKeepAlive == 0)
        _ = try await host.dispatch(.backgrounded(at: 4))
    }

    /// The tail resume is kept wherever it works: after a live frame the return still asks for that
    /// frame minus one, and the hub's answer repeats it, so the opening is never empty.
    @Test func aReturnAfterALiveFrameStillResumesFromTheTail() async throws {
        let stream = HubLikeStream(cursor: 4, frames: [(4, HubLikeStream.row(4))], live: [HubLikeStream.row(4)])
        let network = NetworkEffects(transport: LifecycleMac(), stream: stream, identities: PairedMemoryIdentityStore(),
                                     clock: FixedClock(ms: 5), sleep: Waits(instant: true).sleep)
        let host = try await host(network)
        _ = try await host.dispatch(.foregrounded(at: 1))
        // The first stream: the hello (id 4), then the Mac's row 4 live.
        #expect(await becomes { (try? await host.currentState())?.messages.contains { $0.id == "turn_4:user" } == true })
        _ = try await host.dispatch(.backgrounded(at: 2))
        _ = try await host.dispatch(.foregrounded(at: 3))
        #expect(await becomes { await stream.opened.count == 2 })
        #expect(await becomes { await linkOpen(host) })
        #expect(await stream.heldForTheKeepAlive == 0)
        let resumed = try #require(await stream.opened.last)
        #expect(resumed.target.contains("since=3"), "the return resumes one frame before the last live one: \(resumed.target)")
        _ = try await host.dispatch(.backgrounded(at: 4))
    }
}
