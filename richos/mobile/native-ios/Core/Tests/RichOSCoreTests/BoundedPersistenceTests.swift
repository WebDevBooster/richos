import Foundation
import Testing
@testable import RichOSCore

private actor MeasuredStorage: Storage {
    var values: [String: Data] = [:]
    var counts: [String: Int] = [:]
    var failHistory = false
    func read(_ key: String) -> Data? { values[key] }
    func write(_ key: String, _ data: Data) throws {
        if key == EffectRunner.historyKey && failHistory { throw CoreError("cache unavailable") }
        values[key] = data; counts[key, default: 0] += 1
    }
    func failCache() { failHistory = true }
}

struct BoundedPersistenceTests {
    @Test func tenThousandMessagesDoNotEnterKeystrokeWrites() async throws {
        let storage = MeasuredStorage(), state = AppState()
        let runner = EffectRunner(storage: storage)
        var s = state
        s.messages = (0..<10_000).map { Message(id: "m\($0)", author: .rich, text: "message \($0)", sentAt: Int64($0)) }
        try await runner.run([.persist], state: s)
        for i in 0..<100 {
            s.draft = "draft \(i)"
            try await runner.run([.persist], state: s)
        }
        #expect(await storage.counts[EffectRunner.historyKey] == 1)
        #expect(await storage.values[EffectRunner.stateKey]!.count < 4_096)
        let restored = try #require(await runner.load())
        #expect(restored.messages.count == 100)
        #expect(restored.messages.first?.id == "m9900")
        #expect(restored.draft == "draft 99")
    }

    @Test func aSettledOldAnchorIsCachedImmediatelyWithoutHistoryGaps() async throws {
        let storage = MeasuredStorage()
        let runner = EffectRunner(storage: storage, clock: FixedClock(ms: 1_000))
        var state = AppState()
        state.messages = (0..<10_000).map { Message(id: "m\($0)", author: .rich, text: "message \($0)", sentAt: Int64($0)) }
        try await runner.run([.persist], state: state)
        state.following = false
        state.readingAnchor = ReadingAnchor(messageID: "m50", offset: 12)
        try await runner.run([.persist], state: state)
        let restored = try #require(await runner.load())
        #expect(restored.readingAnchor?.messageID == "m50")
        #expect(restored.messages.contains { $0.id == "m50" })
        #expect(zip(restored.messages, restored.messages.dropFirst()).allSatisfy { $1.sentAt == $0.sentAt + 1 })
        #expect(restored.messages.last?.id == "m9999")
        #expect(restored.messages.count <= 10_000)
        #expect(await storage.values[EffectRunner.stateKey]!.count < 4096)
    }

    @Test func disposableCacheFailureDoesNotTurnCommittedWorkIntoAFailedSave() async throws {
        let storage = MeasuredStorage()
        await storage.failCache()
        let runner = EffectRunner(storage: storage)
        var state = AppState()
        state.draft = "keep me"
        try await runner.run([.persist], state: state)
        #expect(try await runner.load()?.draft == "keep me")
    }

    @Test func legacyHistoryStillLoadsBeforeMigration() async throws {
        let storage = MeasuredStorage()
        var state = AppState()
        state.draft = "legacy draft"
        state.messages = [Message(id: "old", author: .rich, text: "old", sentAt: 0)]
        try await storage.write(EffectRunner.stateKey, CoreJSON.encode(state.persisted))
        let runner = EffectRunner(storage: storage)
        #expect(try await runner.load()?.messages == state.messages)
        try await runner.run([.persist], state: state)
        #expect(try await runner.load()?.messages == state.messages)
    }
}
