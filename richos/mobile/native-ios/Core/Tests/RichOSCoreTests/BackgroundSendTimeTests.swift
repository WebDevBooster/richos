import Foundation
import Testing
@testable import RichOSCore
@testable import RichOSFixtures

/// The OS's extra background time, observed (`UIApplication.beginBackgroundTask` in the app).
@MainActor final class RecordedBackgroundTime: BackgroundContinuation {
    private(set) var events: [String] = []
    private var expired: (@MainActor @Sendable () -> Void)?
    var held: Bool { events.last == "begin" }

    func begin(expired: @escaping @MainActor @Sendable () -> Void) {
        events.append("begin")
        self.expired = expired
    }

    func end() {
        events.append("end")
        expired = nil
    }

    /// iOS takes the time back: it calls the expiration handler, which ends the task.
    func expire() {
        let handler = expired
        handler?()
        if held { end() }
    }
}

/// iPhone walk D3, the platform half: iOS suspends an app moments after Home unless it asks for time
/// (`UIApplication.beginBackgroundTask`). The core asks at the Send, on screen, and gives the time
/// back the moment the batch is answered or its bound runs out.
@MainActor struct BackgroundSendTimeTests {
    func store(_ storage: any Storage, _ mac: SendThenHomeMac) throws -> AppStore {
        var state = try Fixture.named("conv-empty").state
        state.linkOpen = true
        return AppStore(state: state, runner: EffectRunner(storage: storage, handler: mac))
    }

    func settle(_ store: AppStore) async {
        for _ in 0..<100 { await Task.yield(); await store.settle() }
    }

    /// The app asks iOS for time when the Send is pressed, on screen, and gives it back the moment the
    /// Mac has the message: without it iOS suspends the app moments after Home, with the request
    /// still on its way.
    @Test func iOSIsAskedForTimeAtSendAndGivenItBackWhenTheMacHasIt() async throws {
        let storage = HeldStorage()
        let mac = SendThenHomeMac(holdFirst: true)
        let time = RecordedBackgroundTime()
        let store = try store(storage, mac)
        store.backgroundContinuation = time
        await store.apply(.compose(text: "home race three")).value
        store.apply(.sendDraft(clientID: "c1", at: 1))
        #expect(time.events == ["begin"], "asked at the Send, while still on screen")
        #expect(await becomes { await mac.started == ["c1"] })
        store.wentToBackground(at: 2)
        await store.settle()
        #expect(time.held, "still held while the request is on its way")
        // The Mac answers; saving that answer is slow.
        await storage.holdNextWrite(of: EffectRunner.stateKey)
        await mac.releaseFirst()
        #expect(await becomes { await storage.holding }, "the Mac's answer is being saved")
        #expect(await holds { await MainActor.run { time.events == ["begin"] } },
                "still held until the answer is on disk: suspended first, the phone kept the message marked unsent")
        await storage.release()
        await settle(store)
        #expect(await mac.delivered == ["c1"])
        #expect(time.events == ["begin", "end"], "given back once the Mac has it and that is saved")
        let saved = try #require(await storage.read(EffectRunner.stateKey))
        #expect(try CoreJSON.decode(AppState.Persisted.self, from: saved).outbox.isEmpty)
    }

    /// iOS takes the time back before the Mac answers: the request is given up, the message waits on
    /// the phone (it goes on the next return), and nothing is left running.
    @Test func whenIOSTakesTheTimeBackTheMessageWaitsAndNothingRuns() async throws {
        let mac = SendThenHomeMac(holdFirst: true)
        let time = RecordedBackgroundTime()
        let store = try store(MemoryStorage(), mac)
        store.backgroundContinuation = time
        await store.apply(.compose(text: "home race four")).value
        store.apply(.sendDraft(clientID: "c1", at: 1))
        #expect(await becomes { await mac.started == ["c1"] })
        store.wentToBackground(at: 2)
        time.expire()
        await settle(store)
        #expect(await mac.canceled == 1, "the request is given up")
        #expect(store.state.outbox.first?.state == .waiting, "the message waits on the phone")
        #expect(time.events == ["begin", "end"])
        #expect(await holds { await mac.started.count == 1 }, "and nothing is sent while hidden")
    }

    /// Nothing to send now (the Mac's stream is not open, so the message waits): the time asked for at
    /// the Send is given back at once, never left held.
    @Test func aSendThatWaitsGivesTheTimeBackAtOnce() async throws {
        let mac = SendThenHomeMac()
        let time = RecordedBackgroundTime()
        var state = try Fixture.named("conv-empty").state
        state.linkOpen = false
        let store = AppStore(state: state, runner: EffectRunner(storage: MemoryStorage(), handler: mac))
        store.backgroundContinuation = time
        await store.apply(.compose(text: "waiting")).value
        await store.apply(.sendDraft(clientID: "c1", at: 1)).value
        await settle(store)
        #expect(time.events == ["begin", "end"])
        #expect(await mac.started.isEmpty)
    }
}
