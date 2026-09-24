import Foundation
import Testing
import RichOSCore
import RichOSFixtures

private actor HistoryStorage: Storage {
    func read(_ key: String) -> Data? { nil }
    func write(_ key: String, _ data: Data) {}
}

private actor HistoryRequest: EffectHandler {
    var started = false
    var waiter: CheckedContinuation<Void, Never>?
    var cancelled = false
    func handle(_ effect: Effect, state: AppState) async -> [Action] {
        guard case .loadOlder = effect else { return [] }
        started = true
        waiter?.resume(); waiter = nil
        do { try await Task.sleep(for: .seconds(60)) }
        catch { cancelled = true }
        // Even a misbehaving adapter returning a result after cancellation must not close history.
        return [.olderLoaded([], reachedBeginning: true)]
    }
    func untilStarted() async {
        if !started { await withCheckedContinuation { waiter = $0 } }
    }
}

@MainActor struct HistoryLifecycleTests {
    @Test func backgroundCancelsThePageAndRejectsItsLateResult() async throws {
        let handler = HistoryRequest()
        var state = try Fixture.named("conv-populated").state
        state.history.loadingOlder = false
        state.history.reachedBeginning = false
        let store = AppStore(state: state, runner: EffectRunner(storage: HistoryStorage(), handler: handler))
        let load = store.apply(.loadOlder)
        await handler.untilStarted()
        #expect(store.state.history.loadingOlder)
        await store.apply(.backgrounded(at: 100)).value
        await load.value
        #expect(await handler.cancelled)
        #expect(!store.state.history.loadingOlder)
        #expect(!store.state.history.reachedBeginning)
    }
}
