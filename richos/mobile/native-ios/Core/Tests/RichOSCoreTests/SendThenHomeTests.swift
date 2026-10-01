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
actor SendThenHomeMac: EffectHandler {
    private(set) var delivered: [String] = []
    private(set) var started: [String] = []
    private(set) var canceled = 0
    private let holdFirst: Bool
    private var release: CheckedContinuation<Void, Never>?

    init(holdFirst: Bool = false) { self.holdFirst = holdFirst }

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
}
