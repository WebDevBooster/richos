import Foundation
import Testing
@testable import RichOSCore
@testable import RichOSFixtures

/// Storage whose next write of one key waits until the test releases it: a slow disk at the exact
/// moment the test chooses.
actor HeldStorage: Storage {
    private var files: [String: Data] = [:]
    private var holdKey: String?
    private var held: CheckedContinuation<Void, Never>?
    private(set) var holding = false

    func read(_ key: String) -> Data? { files[key] }

    func write(_ key: String, _ data: Data) async {
        if key == holdKey {
            holdKey = nil
            holding = true
            await withCheckedContinuation { held = $0 }
            holding = false
        }
        files[key] = data
    }

    func holdNextWrite(of key: String) { holdKey = key }
    func release() { held?.resume(); held = nil }
}

/// The Mac's message route. `holdFirst`: the first delivery is answered only when the test releases
/// it (or gives up when the phone cancels it, as URLSession's cancel does); every other is accepted.
/// `faultFirst`: the released first delivery is answered with a transient fault, as the managed
/// route answered a request held across a Mac that went quiet (the phone's log, re-walk D3).
actor SendThenHomeMac: EffectHandler {
    private(set) var delivered: [String] = []
    private(set) var started: [String] = []
    private(set) var canceled = 0
    private let holdFirst: Bool
    private let faultFirst: Bool
    private var release: CheckedContinuation<Void, Never>?

    init(holdFirst: Bool = false, faultFirst: Bool = false) {
        self.holdFirst = holdFirst || faultFirst
        self.faultFirst = faultFirst
    }

    func handle(_ effect: Effect, state: AppState) async -> [Action] {
        guard case .deliver(let id) = effect else { return [] }
        started.append(id)
        if holdFirst, started.count == 1 {
            let answered: Bool = await withTaskCancellationHandler {
                await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in release = c }
                return !Task.isCancelled
            } onCancel: {
                Task { await self.releaseFirst() }
            }
            guard answered else {
                canceled += 1
                return [.deliveryFailed(clientID: id, failure: .retryable(reason: "unreachable", afterMs: nil), at: 0)]
            }
            if faultFirst {
                return [.deliveryFailed(clientID: id, failure: .retryable(reason: "fault", afterMs: nil), at: 0)]
            }
        }
        delivered.append(id)
        return [.deliveryAccepted(clientID: id, at: 0)]
    }

    func releaseFirst() { release?.resume(); release = nil }
}

/// iPhone walk D3 (richos-hq `docs/verification/2026-10-01-iphone-walk/README.md`, "Defects"): type a
/// message, press Send, press Home at once. In 1 of 5 attempts the message stayed on the phone while
/// it was hidden and reached the Mac only when the app was next opened. Two causes, each made
/// deterministic here: the core refused the send when Home arrived before the Send was saved or
/// before its background lease was written, and the app never asked iOS for time to finish it.
@MainActor struct SendThenHomeTests {
    func store(_ storage: any Storage, _ mac: SendThenHomeMac) throws -> AppStore {
        var state = try Fixture.named("conv-empty").state
        state.linkOpen = true
        return AppStore(state: state, runner: EffectRunner(storage: storage, handler: mac))
    }

    func settle(_ store: AppStore) async {
        for _ in 0..<100 { await Task.yield(); await store.settle() }
    }

    /// Home pressed while the Send is still being saved: the message was refused as "background
    /// budget" before it was ever tried, although it was sent on screen.
    @Test func homeWhileTheSendIsBeingSavedStillDeliversIt() async throws {
        let storage = HeldStorage()
        let mac = SendThenHomeMac()
        let store = try store(storage, mac)
        await store.apply(.compose(text: "home race one")).value
        await storage.holdNextWrite(of: EffectRunner.stateKey)
        let sending = store.apply(.sendDraft(clientID: "c1", at: 1))
        #expect(await becomes { await storage.holding }, "the Send is being saved")
        store.wentToBackground(at: 2)
        await storage.release()
        await sending.value
        await settle(store)
        #expect(await mac.delivered == ["c1"], "the message left the phone while it was hidden")
        #expect(store.state.outbox.isEmpty)
        let lease = try #require(await storage.read("completion-budget.json"))
        #expect(try CoreJSON.decode([Int64].self, from: lease).count == 1, "one bounded lease, spent")
    }

    /// Home pressed while the background lease for the send is being written: the batch was marked
    /// expired before it began.
    @Test func homeWhileTheLeaseIsBeingWrittenStillDeliversIt() async throws {
        let storage = HeldStorage()
        let mac = SendThenHomeMac(holdFirst: true)
        let store = try store(storage, mac)
        await store.apply(.compose(text: "home race two")).value
        await storage.holdNextWrite(of: "completion-budget.json")
        store.apply(.sendDraft(clientID: "c1", at: 1))
        #expect(await becomes { await storage.holding }, "the lease is being written")
        store.wentToBackground(at: 2)
        await storage.release()
        #expect(await becomes { await mac.started == ["c1"] }, "the request goes, hidden, within the lease")
        await mac.releaseFirst()
        await settle(store)
        #expect(await mac.delivered == ["c1"], "the message left the phone while it was hidden")
        #expect(store.state.outbox.isEmpty)
    }

    /// iPhone re-walk D3 on the phone (2026-10-01, three of three in-flight tries, the phone's own
    /// log): the request sent on screen was still in flight at Home and came back a transient fault
    /// about 1.4 s into the 5 s bound. The batch then ended with the message unsent and gave the
    /// background time back, and the message waited until the app was next opened: a waiting message
    /// is moved only by the tick or by `connected`, and off screen there is no stream for either.
    /// The fault must go again, under the same id, inside the bound it already holds.
    @Test func aFaultWhileHiddenGoesAgainInsideTheBound() async throws {
        let storage = HeldStorage()
        let mac = SendThenHomeMac(faultFirst: true)
        let store = try store(storage, mac)
        let log = SendLogLines()
        store.sendLog = { line in Task { await log.add(line) } }
        await store.apply(.compose(text: "fault while hidden")).value
        store.apply(.sendDraft(clientID: "c1", at: 1))
        #expect(await becomes { await mac.started == ["c1"] }, "the request is in flight on screen")
        store.wentToBackground(at: 2)
        #expect(await becomes { await log.has("hidden: 5 s bound started") }, "the bound is running")
        await mac.releaseFirst()
        #expect(await within(4_000) { await mac.delivered == ["c1"] }, "the message left the phone while it was hidden")
        await settle(store)
        #expect(await mac.started == ["c1", "c1"], "once more, under the same id")
        #expect(await mac.delivered == ["c1"], "delivered exactly once")
        #expect(store.state.outbox.isEmpty)
        #expect(await log.has("batch ended: after leaving the screen, still to send 0"))
    }

    /// The Honor's hung send, on the iPhone's code (andy-sonnet-hungsend1 read it): Wi-Fi drops under a
    /// request in flight at Home, the socket stays up, the transport's own timeout is 30 s, so the
    /// request never faults inside the 5 s bound, the fault retry above never runs, and the message
    /// waits for the app to reopen. Hidden, a request gets its own 2 s deadline: it is cut and the
    /// same message goes again under the same id, inside the bound.
    @Test func aRequestThatHangsWhileHiddenIsCutAndGoesAgainInsideTheBound() async throws {
        let storage = HeldStorage()
        let mac = SendThenHomeMac(holdFirst: true)
        let store = try store(storage, mac)
        await store.apply(.compose(text: "hung while hidden")).value
        store.apply(.sendDraft(clientID: "c1", at: 1))
        #expect(await becomes { await mac.started == ["c1"] }, "the request is in flight on screen")
        store.wentToBackground(at: 2)
        // Never released: the network is gone and nothing answers.
        #expect(await within(4_500) { await mac.delivered == ["c1"] }, "the message left the phone inside the 5 s bound")
        await settle(store)
        #expect(await mac.started == ["c1", "c1"], "once more, under the same id")
        #expect(await mac.delivered == ["c1"], "delivered exactly once")
        #expect(store.state.outbox.isEmpty)
    }
}

/// The store's `sendLog` lines, collected for a test.
actor SendLogLines {
    private(set) var lines: [String] = []
    func add(_ line: String) { lines.append(line) }
    func has(_ line: String) -> Bool { lines.contains(line) }
}

/// Polls `condition` for up to `ms` of real time.
func within(_ ms: UInt64, _ condition: @Sendable () async -> Bool) async -> Bool {
    for _ in 0..<(ms / 5) {
        if await condition() { return true }
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
    return await condition()
}
