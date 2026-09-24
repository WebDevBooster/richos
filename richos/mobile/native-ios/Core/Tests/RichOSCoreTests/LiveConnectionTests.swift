import Foundation
import Testing
@testable import RichOSCore
@testable import RichOSFixtures

/// A stream endpoint that answers each open from a script: a response head and the bytes to send.
actor ScriptedStream: EventStreamTransport {
    struct Opening { var response: HTTPResponse; var chunks: [Data] }
    private var script: [Opening]
    private(set) var opened: [HTTPRequest] = []

    init(_ script: [Opening]) { self.script = script }

    func open(_ request: HTTPRequest, origin: String) async throws -> (response: HTTPResponse, bytes: AsyncThrowingStream<Data, Error>) {
        opened.append(request)
        guard !script.isEmpty else { throw ScriptedMac.TransportFailure() }
        let next = script.removeFirst()
        let stream = AsyncThrowingStream<Data, Error> { continuation in
            for chunk in next.chunks { continuation.yield(chunk) }
            continuation.finish()
        }
        return (next.response, stream)
    }
}

/// Collects what the connection tells the store.
actor Collected {
    var actions: [Action] = []
    var sleeps: [Int64] = []
    func add(_ action: Action) { actions.append(action) }
    func slept(_ ms: Int64) { sleeps.append(ms) }
}

@Suite struct LiveConnectionTests {
    func wire(_ index: Int) throws -> Data {
        let cases = try Corpus.cases(try Corpus.load("events"), "wire_cases")
        return Data((cases[index]["wire_utf8"] as? String ?? "").utf8)
    }

    @Test func incompatibleProtocolEndsWithoutAnyRetryAndDoesNotCheckpointItsCursor() async throws {
        let stream = ScriptedStream([.init(response: HTTPResponse(status: 200), chunks: [
            Data("id: 2\nevent: hello\ndata: {\"protocol_version\":2,\"messages\":[]}\n\n".utf8)
        ])])
        let api = APIClient(origin: "https://mac.example", deviceID: "device", challenge: "c",
                            signer: SoftwareSigner(key: Corpus.testKey), transport: ScriptedMac([]))
        let seen = Collected()
        let connection = LiveConnection(api: api, stream: stream, threadID: "t",
                                        sleep: { await seen.slept($0) }, sink: { await seen.add($0) })
        await connection.start(); await connection.finished()
        #expect(await stream.opened.count == 1)
        #expect(await seen.sleeps.isEmpty)
        #expect(await seen.actions.contains(.macCapabilities(text: false, voice: false)))
        #expect(await connection.stopAndCheckpoint().lastFrameID == nil)
    }

    @Test func aWholeTurnReachesTheStoreAsActionsThenARevocationStops() async throws {
        let turn = try wire(0)
        let bytes = [UInt8](turn)
        let chunks = stride(from: 0, to: bytes.count, by: 7).map { Data(bytes[$0..<min($0 + 7, bytes.count)]) }
        let stream = ScriptedStream([
            .init(response: HTTPResponse(status: 200), chunks: chunks),
            .init(response: HTTPResponse(status: 403, body: Data(#"{"revoked":true}"#.utf8)), chunks: []),
        ])
        // The Mac answers the challenge probe and the revocation probe (not revoked the first time).
        let mac = ScriptedMac([
            ["status": 404, "body": "", "headers": ["X-RichOS-Challenge": "c2"]],
            ["status": 404, "body": "", "headers": ["X-RichOS-Challenge": "c2"]],
        ])
        let api = APIClient(origin: "https://mm1.tail1a2b3c.ts.net:8443", deviceID: "dev_8d4c57b7ff82", challenge: "c1",
                            signer: SoftwareSigner(key: Corpus.testKey), transport: mac)
        let seen = Collected()
        let connection = LiveConnection(api: api, stream: stream, threadID: "thr_5c1e", clock: FixedClock(ms: 7),
                                        sleep: { await seen.slept($0) }, sink: { await seen.add($0) })
        await connection.start()
        await connection.finished()

        let actions = await seen.actions
        #expect(actions.first == .connected(at: 7))
        #expect(actions.contains(.macCapabilities(text: true, voice: true)))
        #expect(actions.contains(.replyStarted))
        #expect(actions.contains(.replyDelta(text: "The numbers ")))
        #expect(actions.contains(.replyDelta(text: "The numbers are in.")))
        let finished = actions.compactMap { if case .replyFinished(let m) = $0 { return m } else { return nil } }
        #expect(finished.map(\.text) == ["The numbers are in."])
        let arrived = actions.flatMap { if case .messagesArrived(let m) = $0 { return m } else { return [] } }
        #expect(arrived.map(\.id) == ["turn_8:user", "turn_8:text:0", "turn_9:user"])
        #expect(actions.suffix(2) == [.connectionLost(at: 7), .pairingRevoked], "the stream ended, then the Mac said revoked")
        #expect(await seen.sleeps == [1000], "one retry wait before the second attempt")
        // Every stream request is signed in the query, and the retry resumes from the last cursor minus one.
        let opened = await stream.opened
        #expect(opened.count == 2 && opened.allSatisfy { $0.target.contains("&auth=RichOS-Device%20dev_8d4c57b7ff82.") })
        #expect(opened[0].target.hasPrefix("/api/events?thread_id=thr_5c1e&auth="))
        #expect(opened[1].target.hasPrefix("/api/events?thread_id=thr_5c1e&since=3&auth="))
        #expect(await api.challenge == "c2", "the challenge was refreshed before the retry")
    }

    @Test func theStoreTurnsTheStreamIntoTheConversation() async throws {
        // The same actions, applied by the reducer: the phone's bubble is replaced by the Mac's row.
        var s = try Fixture.named("conv-empty").state
        s.draft = "and the numbers?"
        s = Reducer.reduce(s, .sendDraft(clientID: "c9", at: 1)).state
        s = Reducer.reduce(s, .deliveryAccepted(clientID: "c9", at: 2)).state
        #expect(s.messages.map(\.id) == ["c9"])
        let row = Message(id: "turn_9:user", author: .me, text: "and the numbers?", sentAt: 3, clientID: "c9")
        s = Reducer.reduce(s, .messagesArrived([row])).state
        #expect(s.messages.map(\.id) == ["turn_9:user"], "the Mac's row retires the phone's bubble by clientID")
        s = Reducer.reduce(s, .replyStarted).state
        #expect(s.reply == .thinking)
        s = Reducer.reduce(s, .replyDelta(text: "The numbers ")).state
        #expect(s.reply == .streaming(text: "The numbers "))
        s = Reducer.reduce(s, .replyFinished(Message(id: "turn_9:text:0", author: .rich, text: "The numbers are in.", sentAt: 4))).state
        #expect(s.reply == nil && s.messages.last?.text == "The numbers are in.")
    }

    @Test func aRevocationOnTheStreamIsTheTakeover() throws {
        let s = Reducer.reduce(try Fixture.named("conv-retry").state, .pairingRevoked).state
        #expect(s.screen == .connectionRevoked && s.outbox.count == 1 && s.connectionNotice == nil)
    }
}

/// A clock that always says the same time.
struct FixedClock: Clock {
    var ms: Int64
    func nowMs() -> Int64 { ms }
}
