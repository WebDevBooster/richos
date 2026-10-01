import Foundation
import Testing
@testable import RichOSCore
@testable import RichOSFixtures

/// A Mac that takes the first message and never answers it until the phone gives up on it; every
/// later delivery is accepted. The phone canceling a request ends it as URLSession's cancel does:
/// a transport failure.
actor QuietMacDelivery: EffectHandler {
    private(set) var asked: [String] = []
    private(set) var canceled = 0

    func handle(_ effect: Effect, state: AppState) async -> [Action] {
        guard case .deliver(let id) = effect else { return [] }
        asked.append(id)
        if asked.count == 1 {
            do { try await Task.sleep(nanoseconds: 60_000_000_000) } catch { canceled += 1 }
            return [.deliveryFailed(clientID: id, failure: .retryable(reason: "unreachable", afterMs: nil), at: 0)]
        }
        return [.deliveryAccepted(clientID: id, at: 0)]
    }
}

@MainActor struct SilentStreamOutboxTests {
    /// D5's second half: a message sent while the stream still looked open went to a Mac that no
    /// longer answered, and drew "Sending…" with a turning mark until the request's own 30 s timeout.
    /// Once the stream is known lost, the message waits, saying so, and goes again with the same id
    /// when the Mac is back (the Mac keeps one: `app/src-tauri/src/phone/delivery.rs`, `Duplicate`).
    @Test func aSendInFlightWhenTheStreamIsLostWaitsAndGoesOnceTheMacIsBack() async throws {
        let mac = QuietMacDelivery()
        var state = try Fixture.named("conv-empty").state
        state.linkOpen = true
        let store = AppStore(state: state, runner: EffectRunner(storage: MemoryStorage(), handler: mac))
        await store.apply(.compose(text: "Sent while the Mac went quiet")).value
        store.apply(.sendDraft(clientID: "c1", at: 1))
        #expect(await becomes { await mac.asked == ["c1"] })
        #expect(store.state.messages.last?.delivery == .sending)

        store.receive(.connectionLost(at: 2))
        #expect(await becomes { await MainActor.run { store.state.messages.last?.delivery == .waiting } },
                "Waiting to send, not Sending…")
        #expect(await mac.canceled == 1, "the request to the quiet Mac is given up")
        let waiting = try #require(store.state.outbox.first)
        #expect(waiting.state == .waiting && waiting.attempts == 0, "a lost stream is not a failed attempt")

        // The store stamps the give-up with the wall clock, as the app's clock stamps `connected`.
        store.receive(.connected(at: SystemClock().nowMs() + 1))
        #expect(await becomes { await MainActor.run { store.state.outbox.isEmpty } }, "delivered once the Mac is back")
        #expect(await mac.asked == ["c1", "c1"], "the same message again, under the same id")
        #expect(store.state.messages.last?.delivery == nil)
    }
}
