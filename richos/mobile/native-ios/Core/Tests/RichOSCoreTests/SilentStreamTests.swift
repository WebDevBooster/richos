import Foundation
import Testing
@testable import RichOSCore
@testable import RichOSFixtures

/// The silence wait on a clock the test moves: each wait ends when the test has advanced the clock
/// past it, or throws when it is canceled (a byte arrived and the wait was started again).
actor SilenceClock {
    private(set) var now: Int64 = 0
    private(set) var asked: [Int64] = []
    /// Waits started and not yet ended (ran out or canceled).
    private(set) var active = 0
    func start(_ ms: Int64) -> Int64 { asked.append(ms); active += 1; return now + ms }
    func end() { active -= 1 }
    func advance(_ ms: Int64) { now += ms }
    func due(_ at: Int64) -> Bool { now >= at }

    nonisolated var wait: LiveConnection.Sleep {
        { ms in
            let at = await self.start(ms)
            do {
                while !(await self.due(at)) { try await Task.sleep(nanoseconds: 2_000_000) }
            } catch {
                await self.end()
                throw error
            }
            await self.end()
        }
    }
}

/// The Mac's stream, held open: the test writes each chunk when it chooses (a frame, a keep-alive),
/// and sees when the phone closes it.
actor PushedStream: EventStreamTransport {
    private var current: AsyncThrowingStream<Data, Error>.Continuation?
    private(set) var opened = 0
    private(set) var closed = 0

    func open(_ request: HTTPRequest, origin: String) async throws -> (response: HTTPResponse, bytes: AsyncThrowingStream<Data, Error>) {
        opened += 1
        let stream = AsyncThrowingStream<Data, Error> { continuation in
            current = continuation
            continuation.onTermination = { _ in Task { await self.markClosed() } }
            continuation.yield(Data(LifecycleStream.hello.utf8))
        }
        return (HTTPResponse(status: 200, headers: ["X-RichOS-Challenge": "c-open"]), stream)
    }

    func push(_ chunk: String) { current?.yield(Data(chunk.utf8)) }
    private func markClosed() { closed += 1 }
}

/// iPhone walk D5 (richos-hq `docs/verification/2026-10-01-iphone-walk/README.md`, "Defects"): with
/// the app open and the Mac no longer answering, nothing said so for at least 26 s, and a message
/// sent meanwhile showed "Sending…" instead of "Waiting to send". The Mac writes `: keep-alive` after
/// every 15 s without a frame (`app/src-tauri/src/phone/mod.rs` `KEEPALIVE_MS`, `listen.rs`
/// `open_stream`), yet the phone's only silence detector was the stream request's 60 s idle timeout
/// (`URLSessionTransport.open`).
@Suite struct SilentStreamTests {
    func connection(_ stream: PushedStream, silence: SilenceClock, seen: Collected) -> LiveConnection {
        let api = APIClient(origin: "https://mm1.tail1a2b3c.ts.net:8443", deviceID: "dev_8d4c57b7ff82", challenge: "c1",
                            signer: SoftwareSigner(key: Corpus.testKey), transport: LifecycleMac())
        return LiveConnection(api: api, stream: stream, threadID: "thr_5c1e", clock: FixedClock(ms: 7),
                              sleep: Waits(instant: true).sleep, silence: silence.wait, sink: { await seen.add($0) })
    }

    static func lost(_ actions: [Action]) -> Bool {
        actions.contains { if case .connectionLost = $0 { return true } else { return false } }
    }

    @Test func aStreamSilentLongerThanTheMacsKeepAliveIsDroppedAndReopened() async throws {
        let stream = PushedStream()
        let silence = SilenceClock()
        let seen = Collected()
        let live = connection(stream, silence: silence, seen: seen)
        await live.start()
        #expect(await becomes { await seen.actions.contains(.connected(at: 7)) })
        // The hello has been read (its capabilities reached the store) and the wait started after it.
        #expect(await becomes { await seen.actions.contains(.macCapabilities(text: true, voice: false)) })
        #expect(await becomes { await silence.active == 1 }, "one silence wait while the stream is open")
        let armed = await silence.asked.count
        #expect(LiveConnection.silenceLimitMs == 20_000, "one keep-alive (15 s) and 5 s for the route")
        #expect(await silence.asked.allSatisfy { $0 == LiveConnection.silenceLimitMs })

        // Healthy: a keep-alive inside the limit starts the wait again.
        await silence.advance(15_000)
        await stream.push(": keep-alive 1790000015000\n\n")
        #expect(await becomes { await silence.asked.count == armed + 1 })
        await silence.advance(10_000)
        #expect(await holds { !Self.lost(await seen.actions) }, "25 s after the hello, 10 s after the keep-alive: still up")

        // The Mac stops answering: nothing more arrives, and 20 s after the last keep-alive it is lost.
        await silence.advance(10_000)
        #expect(await becomes { Self.lost(await seen.actions) }, "the silence is reported as a lost connection")
        #expect(await becomes { await stream.closed == 1 }, "the silent stream is closed, not left open")
        #expect(await becomes { await stream.opened == 2 }, "and the owner opens a new one on its back-off")
        await live.stop()
        #expect(await becomes { await stream.closed == 2 })
    }

    @Test func aStreamThatEndsStopsItsSilenceWait() async throws {
        let stream = PushedStream()
        let silence = SilenceClock()
        let seen = Collected()
        let live = connection(stream, silence: silence, seen: seen)
        await live.start()
        #expect(await becomes { await silence.asked.count == 2 })
        await live.stop()
        #expect(await becomes { await stream.closed == 1 })
        #expect(await becomes { await silence.active == 0 }, "no wait outlives the stream it watched")
        let asked = await silence.asked.count
        await silence.advance(60_000)
        #expect(await holds { let count = await silence.asked.count; let active = await silence.active; return count == asked && active == 0 },
                "nothing is armed again: no timer while no stream is open (the battery rule)")
    }
}
