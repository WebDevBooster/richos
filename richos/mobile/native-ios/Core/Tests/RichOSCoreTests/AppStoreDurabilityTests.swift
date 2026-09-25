import Foundation
import Testing
import RichOSCore
import RichOSFixtures

private actor SaveGate: Storage {
    var files: [String: Data] = [:]
    var fail = false
    var pause = false
    var waiting: CheckedContinuation<Void, Never>?
    var started: CheckedContinuation<Void, Never>?
    var didStart = false
    func read(_ key: String) -> Data? { files[key] }
    func configure(fail: Bool = false, pause: Bool = false) {
        self.fail = fail; self.pause = pause; didStart = false
    }
    func write(_ key: String, _ data: Data) async throws {
        if pause {
            await withCheckedContinuation { continuation in
                waiting = continuation
                didStart = true
                started?.resume(); started = nil
            }
            pause = false
        }
        if fail { throw CoreError("disk full") }
        files[key] = data
    }
    func untilStarted() async {
        if !didStart { await withCheckedContinuation { started = $0 } }
    }
    func release() { waiting?.resume(); waiting = nil }
}

private actor DeliveryWitness: EffectHandler {
    let storage: SaveGate
    var delivered: [String] = []
    init(_ storage: SaveGate) { self.storage = storage }
    func handle(_ effect: Effect, state: AppState) async -> [Action] {
        if case .deliver(let id) = effect {
            let data = await storage.read(EffectRunner.stateKey)
            let saved = data.flatMap { try? CoreJSON.decode(AppState.Persisted.self, from: $0) }
            #expect(saved?.outbox.contains { $0.clientID == id } == true)
            delivered.append(id)
        }
        return []
    }
}

@MainActor struct AppStoreDurabilityTests {
    @Test func failedSaveKeepsDraftAndNeverDelivers() async throws {
        let storage = SaveGate()
        let witness = DeliveryWitness(storage)
        let store = AppStore(state: try Fixture.named("conv-empty").state,
                             runner: EffectRunner(storage: storage, handler: witness))
        await store.apply(.compose(text: "keep me")).value
        await storage.configure(fail: true)
        let send = store.apply(.sendDraft(clientID: "send-1", at: 100))
        #expect(store.state.draft == "keep me" && store.state.outbox.isEmpty)
        await send.value
        #expect(store.state.draft == "keep me" && store.state.outbox.isEmpty)
        #expect(store.persistenceProblem != nil)
        #expect(await witness.delivered.isEmpty)
        let restored = try await store.runner.load()
        #expect(restored?.draft == "keep me")
    }

    @Test func delayedSaveKeepsInputThenPublishesOnceAndPreservesSubsequentTyping() async throws {
        let storage = SaveGate()
        let witness = DeliveryWitness(storage)
        let store = AppStore(state: try Fixture.named("conv-empty").state,
                             runner: EffectRunner(storage: storage, handler: witness))
        await store.apply(.compose(text: "first")).value
        await storage.configure(pause: true)
        let send = store.apply(.sendDraft(clientID: "send-1", at: 100))
        await storage.untilStarted()
        #expect(store.state.draft == "first" && store.state.outbox.isEmpty)
        #expect(await witness.delivered.isEmpty)
        store.send(.sendDraft(clientID: "double-tap", at: 101))
        store.send(.compose(text: "second"))
        await storage.release()
        await send.value
        await store.settle()
        #expect(store.state.draft == "second")
        #expect(store.state.outbox.map(\.clientID) == ["send-1"])
        #expect(await witness.delivered == ["send-1"])
        #expect(try await store.runner.load()?.draft == "second")
    }

    @Test func aSecondComposedMessageDuringSaveIsNotDiscardedAsADoubleTap() async throws {
        let storage = SaveGate()
        let store = AppStore(state: try Fixture.named("conv-empty").state, runner: EffectRunner(storage: storage))
        await store.apply(.compose(text: "first")).value
        await storage.configure(pause: true)
        let send = store.apply(.sendDraft(clientID: "first", at: 100))
        await storage.untilStarted()
        store.send(.compose(text: "second"))
        store.send(.sendDraft(clientID: "second", at: 101))
        store.send(.sendDraft(clientID: "duplicate", at: 102))
        await storage.release()
        await send.value
        await store.settle()
        #expect(store.state.outbox.map(\.clientID) == ["first", "second"])
        #expect(store.state.draft.isEmpty)
    }

    @Test func failedDeliveryAuthorizationReturnsTheDurableMessageToWaiting() async throws {
        let storage = SaveGate()
        let witness = DeliveryWitness(storage)
        let store = AppStore(state: try Fixture.named("conv-empty").state,
                             runner: EffectRunner(storage: storage, handler: witness))
        await store.apply(.networkChanged(online: false, at: 1)).value
        await store.apply(.compose(text: "keep queued")).value
        await store.apply(.sendDraft(clientID: "queued", at: 2)).value
        await storage.configure(fail: true)
        await store.apply(.networkChanged(online: true, at: 3)).value
        // The Mac's stream answers: the queue would move, and the save that authorizes it fails.
        await store.apply(.connected(at: 4)).value
        #expect(store.persistenceProblem != nil)
        #expect(store.state.outbox.single?.state == .waiting)
        #expect(await witness.delivered.isEmpty)
        await storage.configure()
        await store.apply(.compose(text: "next draft")).value
        #expect(store.persistenceProblem == nil)
        #expect(TickSchedule.nextTick(store.state) != nil)
    }

    @Test func typingBehindAFailedSendCannotOverwriteTheOriginalMessage() async throws {
        let storage = SaveGate()
        let store = AppStore(state: try Fixture.named("conv-empty").state, runner: EffectRunner(storage: storage))
        await store.apply(.compose(text: "first message")).value
        await storage.configure(fail: true, pause: true)
        let send = store.apply(.sendDraft(clientID: "first", at: 100))
        await storage.untilStarted()
        store.send(.compose(text: "second message"))
        store.send(.sendDraft(clientID: "second", at: 101))
        await storage.release(); await send.value; await store.settle()
        #expect(store.state.draft == "first message\n\nsecond message")
        #expect(store.state.outbox.isEmpty)
        #expect(store.persistenceProblem != nil)
    }

    @Test func backgroundDuringSaveDoesNotStartDelivery() async throws {
        let storage = SaveGate()
        let witness = DeliveryWitness(storage)
        let store = AppStore(state: try Fixture.named("conv-empty").state,
                             runner: EffectRunner(storage: storage, handler: witness))
        await store.apply(.compose(text: "send later")).value
        await storage.configure(pause: true)
        let send = store.apply(.sendDraft(clientID: "send-1", at: 100))
        await storage.untilStarted()
        store.wentToBackground(at: 101)
        await storage.release()
        await send.value
        await store.settle()
        #expect(await witness.delivered.isEmpty)
        #expect(store.state.outbox.single?.state == .waiting)
    }
}

private extension Array {
    var single: Element? { count == 1 ? first : nil }
}

private actor RecordingWitness: EffectHandler {
    let storage: SaveGate
    let fail: Bool
    var starts = 0
    var recoveries = 0
    init(_ storage: SaveGate, fail: Bool = false) { self.storage = storage; self.fail = fail }
    func handle(_ effect: Effect, state: AppState) async -> [Action] {
        if case .startRecording(let id) = effect {
            starts += 1
            let data = await storage.read(EffectRunner.stateKey)
            let saved = data.flatMap { try? CoreJSON.decode(AppState.Persisted.self, from: $0) }
            #expect(saved?.activeRecording?.id == id)
            return fail ? [.voiceStartFailed(id: id)] : []
        }
        return []
    }
    func recoverRecording(_ recording: KeptRecording) -> KeptRecording? {
        recoveries += 1
        var recovered = recording
        recovered.durationMs = 1_234
        return recovered
    }
}

@MainActor struct RecordingDurabilityTests {
    private func ready() throws -> AppState {
        var state = try Fixture.named("conv-empty").state
        state.microphone = .granted
        state.voiceAvailability = .available
        return state
    }

    @Test func captureStartsAfterJournalAndCrashRecoveryIsUnsentAndIdempotent() async throws {
        let storage = SaveGate()
        let recorder = RecordingWitness(storage)
        let runner = EffectRunner(storage: storage, handler: recorder)
        let store = AppStore(state: try ready(), runner: runner)
        let task = store.apply(.voiceStartLocked(id: "crash", width: 386, at: 1_000))
        #expect(store.state.voice == nil)
        await task.value
        #expect(store.state.voice?.phase == .locked)
        #expect(await recorder.starts == 1)
        let restored = try await runner.load()
        #expect(restored?.voice == nil && restored?.outbox.isEmpty == true)
        #expect(restored?.keptRecordings.single?.durationMs == 1_234)
        #expect(try await runner.load()?.keptRecordings.count == 1)
        #expect(await recorder.recoveries == 1)
    }

    @Test func failedCaptureDoesNotClaimRecordingOrCreateAnEmptyMessage() async throws {
        let storage = SaveGate()
        let recorder = RecordingWitness(storage, fail: true)
        let store = AppStore(state: try ready(), runner: EffectRunner(storage: storage, handler: recorder))
        await store.apply(.voiceStartLocked(id: "failure", width: 386, at: 1_000)).value
        #expect(store.state.voice == nil && store.state.outbox.isEmpty && store.state.keptRecordings.isEmpty)
        #expect(store.recordingProblem?.contains("microphone could not start") == true)
        #expect(store.persistenceProblem == nil && store.ticking)
        #expect(try await store.runner.load()?.keptRecordings.isEmpty == true)
    }

    @Test func backgroundDuringSlowJournalNeverStartsTheMicrophone() async throws {
        let storage = SaveGate()
        let recorder = RecordingWitness(storage)
        let store = AppStore(state: try ready(), runner: EffectRunner(storage: storage, handler: recorder))
        await storage.configure(pause: true)
        let start = store.apply(.voiceStartLocked(id: "late", width: 386, at: 1_000))
        await storage.untilStarted()
        store.wentToBackground(at: 1_001)
        await storage.release()
        await start.value
        await store.settle()
        #expect(await recorder.starts == 0)
        #expect(store.state.voice == nil && store.state.keptRecordings.isEmpty)
    }
}
