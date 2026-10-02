import Foundation
import Testing
@testable import RichOSCore
@testable import RichOSFixtures

/// A network that takes requests and never answers them (Wi-Fi joined but not yet passing traffic, a
/// route that went dead under the phone): every request is recorded and then hangs until it is
/// canceled. With the phone's 30 s request timeout (`URLSessionTransport.defaultRequestTimeout`),
/// each one stands 30 s in front of whatever waits on it.
actor StalledMac: HTTPTransport {
    private(set) var targets: [String] = []
    func send(_ request: HTTPRequest, origin: String) async throws -> HTTPResponse {
        targets.append(request.method + " " + (request.target.components(separatedBy: "?").first ?? request.target))
        try await Task.sleep(nanoseconds: 60_000_000_000)
        throw URLError(.timedOut)
    }
}

/// The Mac's JSON routes for a phone it has removed: the revocation probe answers 403 `{"revoked":true}`.
actor RemovedPhoneMac: HTTPTransport {
    private(set) var targets: [String] = []
    func send(_ request: HTTPRequest, origin: String) async throws -> HTTPResponse {
        targets.append(request.method + " " + (request.target.components(separatedBy: "&auth=").first ?? request.target))
        return HTTPResponse(status: 403, headers: ["X-RichOS-Challenge": "c1"], body: Data(#"{"revoked":true}"#.utf8))
    }
}

/// The Mac's stream for these tests: each open answers from `plan` (then `.open` with a hello). `.hang`
/// is an open whose answer never comes (a route that died under it): it ends only when the phone gives
/// it up. Every open and every close is counted.
actor RouteStream: EventStreamTransport {
    enum Answer: Sendable { case open, hang, unreachable, dropping }
    private var plan: [Answer]
    private(set) var opened: [HTTPRequest] = []
    private(set) var closed = 0
    private(set) var abandoned = 0
    init(_ plan: [Answer]) { self.plan = plan }

    func open(_ request: HTTPRequest, origin: String) async throws -> (response: HTTPResponse, bytes: AsyncThrowingStream<Data, Error>) {
        opened.append(request)
        let answer = plan.isEmpty ? .open : plan.removeFirst()
        switch answer {
        case .unreachable:
            throw ScriptedMac.TransportFailure()
        case .hang:
            do { try await Task.sleep(nanoseconds: 60_000_000_000) } catch { abandoned += 1; throw error }
            throw ScriptedMac.TransportFailure()
        case .dropping:
            let stream = AsyncThrowingStream<Data, Error> { continuation in
                continuation.yield(Data(LifecycleStream.hello.utf8))
                continuation.finish(throwing: ScriptedMac.TransportFailure())
            }
            return (HTTPResponse(status: 200, headers: ["X-RichOS-Challenge": "c-open"]), stream)
        case .open:
            let stream = AsyncThrowingStream<Data, Error> { continuation in
                continuation.onTermination = { _ in Task { await self.markClosed() } }
                continuation.yield(Data(LifecycleStream.hello.utf8))
            }
            return (HTTPResponse(status: 200, headers: ["X-RichOS-Challenge": "c-open"]), stream)
        }
    }
    private func markClosed() { closed += 1 }
}

/// The second wait andy-opus-resume1 found on Android, checked on the iPhone (2026-10-01).
///
/// Second: requests on the way to the stream. After any failed or dropped stream the owner asked
/// "was this phone removed" (`LiveConnection.probeRevoked`, a signed GET) and, before the next
/// attempt, for a new challenge (`APIClient.probeChallenge`), each with the 30 s request timeout, and
/// neither cut short by "Try now" or a route coming up (`wake` ends only the back-off wait). On a
/// stalled network that is up to a minute between the failure and the next open, in front of a
/// person who has just come back. Neither request is needed there: the Mac answers a removed phone's
/// stream open itself with 403 `{"revoked":true}` (`app/src-tauri/src/phone/device.rs`, `Refusal::Revoked`
/// "answered before any bucket"), which the owner already reads, and a stale challenge is answered with
/// a 404 offering the new one, which the owner already re-signs with at once (`openSigned`).
@Suite struct ReturnStreamProbeTests {
    static let origin = "https://mm1.tail1a2b3c.ts.net:8443"

    func owner(_ stream: RouteStream, http: any HTTPTransport, waits: Waits, seen: Collected) -> LiveConnection {
        let api = APIClient(origin: Self.origin, deviceID: "dev_8d4c57b7ff82", challenge: "c1",
                            signer: SoftwareSigner(key: Corpus.testKey), transport: http)
        return LiveConnection(api: api, stream: stream, threadID: "thr_5c1e", clock: FixedClock(ms: 7),
                              sleep: waits.sleep, sink: { await seen.add($0) })
    }

    @Test func aStreamThatFailsIsOpenedAgainWithNoRequestInFrontOfIt() async throws {
        let stream = RouteStream([.unreachable, .open])
        let http = StalledMac()
        let seen = Collected()
        let live = owner(stream, http: http, waits: Waits(instant: true), seen: seen)
        await live.start()
        #expect(await becomes { await stream.opened.count == 2 }, "the next open follows the 1 s back-off, not a stalled request")
        let asked = await http.targets
        #expect(asked.isEmpty, "no challenge or revocation request on the way: \(asked)")
        #expect(await becomes { await seen.actions.contains(.connected(at: 7)) })
        await live.stop()
    }

    @Test func aStreamThatDropsIsOpenedAgainWithNoRequestInFrontOfIt() async throws {
        let stream = RouteStream([.dropping, .open])
        let http = StalledMac()
        let seen = Collected()
        let live = owner(stream, http: http, waits: Waits(instant: true), seen: seen)
        await live.start()
        #expect(await becomes { await stream.opened.count == 2 })
        let asked = await http.targets
        #expect(asked.isEmpty, "no challenge or revocation request on the way: \(asked)")
        await live.stop()
    }

    /// The guard that must stay green: a Mac that ANSWERS the open with a refusal is still asked
    /// whether this phone was removed, and a removed phone is told so.
    @Test func aRefusedOpenStillAsksWhetherThisPhoneWasRemoved() async throws {
        let stream = LifecycleStream([.status(404, challenge: "c1")], fallback: .status(404, challenge: "c1"))
        let http = RemovedPhoneMac()
        let seen = Collected()
        let api = APIClient(origin: Self.origin, deviceID: "dev_8d4c57b7ff82", challenge: "c1",
                            signer: SoftwareSigner(key: Corpus.testKey), transport: http)
        let live = LiveConnection(api: api, stream: stream, threadID: "thr_5c1e", clock: FixedClock(ms: 7),
                                  sleep: Waits(instant: true).sleep, sink: { await seen.add($0) })
        await live.start()
        #expect(await becomes { await seen.actions.contains(.pairingRevoked) })
        #expect(await http.targets.contains { $0.contains("before=0") })
        await live.stop()
    }
}
