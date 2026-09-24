import Foundation
import Testing
import RichOSCore
import RichOSFixtures

private actor CompletionStorage: Storage {
    var values: [String: Data] = [:]
    func read(_ key: String) -> Data? { values[key] }
    func write(_ key: String, _ data: Data) { values[key] = data }
}

private actor CompletionGate: EffectHandler {
    var delivered: [String] = []
    var releaseFirst: CheckedContinuation<Void, Never>?
    var didStart = false
    var startWaiter: CheckedContinuation<Void, Never>?
    func handle(_ effect: Effect, state: AppState) async -> [Action] {
        guard case .deliver(let id) = effect else { return [] }
        delivered.append(id)
        if delivered.count == 1 {
            await withCheckedContinuation { continuation in
                releaseFirst = continuation
                didStart = true
                startWaiter?.resume(); startWaiter = nil
            }
        }
        return [.deliveryAccepted(clientID: id, at: 100)]
    }
    func started() async {
        if !didStart { await withCheckedContinuation { startWaiter = $0 } }
    }
    func release() { releaseFirst?.resume(); releaseFirst = nil }
}

@MainActor struct CompletionTests {
    @Test func alreadySubmittedMessagesCanCompleteAfterBackgrounding() async throws {
        let storage = CompletionStorage()
        let gate = CompletionGate()
        var state = try Fixture.named("conv-empty").state
        state.outbox = (1...5).map { OutboxItem(clientID: "message-\($0)", kind: .text, body: "{}", queuedAt: Int64($0)) }
        let store = AppStore(state: state, runner: EffectRunner(storage: storage, handler: gate))
        let delivery = store.apply(.foregrounded(at: 100))
        await gate.started()
        store.wentToBackground(at: 101)
        await gate.release()
        await delivery.value
        // Each accepted receipt schedules the next production effect through the store.
        for _ in 0..<100 { await Task.yield(); await store.settle() }
        #expect(await gate.delivered == ["message-1", "message-2", "message-3"])
        #expect(store.state.outbox.map(\.clientID) == ["message-4", "message-5"])
        #expect(store.state.outbox.allSatisfy { $0.state == .waiting })
        let budget = try #require(await storage.read("completion-budget.json"))
        #expect(try CoreJSON.decode([Int64].self, from: budget).count == 1)
    }

    @Test func simultaneousReservationsCannotOverwriteEachOther() async throws {
        let runner = EffectRunner(storage: CompletionStorage(), clock: FixedClock(ms: 10_000))
        let tokens = await withTaskGroup(of: Int64?.self, returning: [Int64].self) { group in
            for _ in 0..<20 { group.addTask { await runner.reserveCompletion() } }
            var tokens: [Int64] = []
            for await token in group { if let token { tokens.append(token) } }
            return tokens
        }
        #expect(tokens.count == 6)
        #expect(Set(tokens).count == 6)
    }

    @Test func hourlyBudgetSurvivesRestartAndClockRollback() async throws {
        let storage = CompletionStorage()
        let runner = EffectRunner(storage: storage, clock: FixedClock(ms: 10_000))
        for _ in 0..<6 { #expect(await runner.reserveCompletion() != nil) }
        #expect(await runner.reserveCompletion() == nil)
        let restarted = EffectRunner(storage: storage, clock: FixedClock(ms: 9_000))
        #expect(await restarted.reserveCompletion() == nil)
        let later = EffectRunner(storage: storage, clock: FixedClock(ms: 3_610_010))
        #expect(await later.reserveCompletion() != nil)
    }

    @Test func foregroundCompletionRefundsButDailyExhaustionDoesNotResetHourly() async throws {
        let storage = CompletionStorage()
        let runner = EffectRunner(storage: storage, clock: FixedClock(ms: 10_000))
        let token = try #require(await runner.reserveCompletion())
        await runner.refundCompletion(token)
        for hour in 0..<4 {
            let window = EffectRunner(storage: storage, clock: FixedClock(ms: Int64(hour) * 3_600_010 + 10_000))
            for _ in 0..<6 { #expect(await window.reserveCompletion() != nil) }
        }
        let exhausted = EffectRunner(storage: storage, clock: FixedClock(ms: 15_000_000))
        #expect(await exhausted.reserveCompletion() == nil)
    }
}
