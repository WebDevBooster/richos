import Foundation
import Testing
@testable import RichOSCore
@testable import RichOSFixtures

// Loop L1 (build plan §3.1): these run on this Mac with `bin/rios test`, no simulator.

@Suite struct StateTests {
    @Test func aNewInstallIsUnpairedAndDark() {
        #expect(AppState.initial.pairing == .unpaired)
        #expect(AppState.initial.appearance == .dark)
        #expect(AppState.initial.screen == .pairIntro)
    }

    @Test func theScreenIsDerivedFromPairingAndMessages() {
        #expect(AppState(pairing: .confirming).screen == .pairWords)
        #expect(AppState(pairing: .revoked).screen == .connectionRevoked)
        #expect(AppState(pairing: .paired).screen == .conversationEmpty)
        #expect(AppState(pairing: .paired, messages: Conversation.round12).screen == .conversation)
    }

    @Test func stateRoundTripsThroughJSONAndPrintsItsScreen() throws {
        let state = try Fixture.named("conv-populated").state
        let data = try CoreJSON.encode(state)
        #expect(try CoreJSON.decode(AppState.self, from: data) == state)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["screen"] as? String == "conv-populated")
    }

    @Test func anUnknownSchemaIsRefusedNotReset() throws {
        var object = try #require(try JSONSerialization.jsonObject(with: CoreJSON.encode(AppState.initial)) as? [String: Any])
        object["schema"] = 99
        let data = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: DecodingError.self) { try CoreJSON.decode(AppState.self, from: data) }
    }

    @Test func fixtureTimesAreFixedInstantsOnTheRound12Day() {
        // 2026-09-22T00:00:00Z, so a fixture renders identically on every run.
        #expect(Date(timeIntervalSince1970: Double(Conversation.day) / 1000).ISO8601Format() == "2026-09-22T00:00:00Z")
    }
}

@Suite struct ActionTests {
    @Test func composeSetsTheDraftAndAsksToPersist() {
        let (next, effects) = Reducer.reduce(.initial, .compose(text: "Hello Rich"))
        #expect(next.draft == "Hello Rich")
        #expect(effects == [.persist])
    }

    @Test func aNoOpActionAsksForNothing() {
        let (next, effects) = Reducer.reduce(.initial, .setAppearance(.dark))
        #expect(next == .initial)
        #expect(effects.isEmpty)
    }

    @Test func actionsUseThePreservedCLIsJSONSpelling() throws {
        let compose = try CoreJSON.decode(Action.self, from: Data(#"{"type":"compose","text":"Hi"}"#.utf8))
        #expect(compose == .compose(text: "Hi"))
        let theme = try CoreJSON.decode(Action.self, from: Data(#"{"type":"set-appearance","appearance":"light"}"#.utf8))
        #expect(theme == .setAppearance(.light))
        #expect(String(decoding: try CoreJSON.encode(compose), as: UTF8.self) == #"{"text":"Hi","type":"compose"}"#)
    }

    @Test func anUnknownActionNamesTheKnownOnes() throws {
        do {
            _ = try CoreJSON.decode(Action.self, from: Data(#"{"type":"fly"}"#.utf8))
            Issue.record("an unknown action decoded")
        } catch let DecodingError.dataCorrupted(context) {
            #expect(context.debugDescription.contains("known: compose, set-appearance"))
        }
    }
}

@Suite struct StorageTests {
    func scratch() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("rios-core-tests-\(UUID().uuidString)")
    }

    @Test func fileStorageWritesAtomicallyAndReadsBack() async throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let storage = FileStorage(directory: dir)
        #expect(try await storage.read("state.json") == nil)
        try await storage.write("state.json", Data("x".utf8))
        #expect(try await storage.read("state.json") == Data("x".utf8))
    }

    @Test func fileStorageRefusesAKeyThatEscapesItsDirectory() async {
        let storage = FileStorage(directory: scratch())
        await #expect(throws: CoreError.self) { try await storage.write("../escape", Data()) }
        await #expect(throws: CoreError.self) { try await storage.write(".hidden", Data()) }
    }

    @Test func aCorruptStoredStateThrowsAndIsLeftIntact() async throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let storage = FileStorage(directory: dir)
        try await storage.write(EffectRunner.stateKey, Data("not json".utf8))
        await #expect(throws: (any Error).self) { try await EffectRunner(storage: storage).load() }
        #expect(try await storage.read(EffectRunner.stateKey) == Data("not json".utf8))
    }
}

@Suite struct CommandTests {
    @Test func everyFixtureIsReachableByItsRound12ScreenName() throws {
        for fixture in Fixture.all {
            #expect(fixture.state.screen.rawValue == fixture.name)
        }
    }

    @Test func theDraftSurvivesARestartThroughStorage() async throws {
        let storage = MemoryStorage()
        let host = try await HeadlessHost(storage: storage)
        _ = try await CommandRunner.execute(Command(.fixture, name: "conv-empty"), on: host)
        _ = try await CommandRunner.execute(Command(.action, action: .compose(text: "Kept")), on: host)
        let fresh = try await HeadlessHost(storage: storage)
        #expect(await fresh.currentState().draft == "Kept")
    }

    @Test func everyScenarioPassesItsOwnChecks() async throws {
        for scenario in Scenario.all {
            let host = try await HeadlessHost(storage: MemoryStorage())
            let result = try await CommandRunner.execute(Command(.scenario, name: scenario.name), on: host)
            #expect(result.name == scenario.name)
            #expect(result.trace?.count == scenario.steps.count)
        }
    }

    @Test func aScenarioTraceIsIdenticalOnEveryRun() async throws {
        func run() async throws -> Data {
            let host = try await HeadlessHost(storage: MemoryStorage())
            return try CoreJSON.encode(try await CommandRunner.execute(Command(.scenario, name: "compose-draft"), on: host))
        }
        #expect(try await run() == run())
    }

    @Test func aMalformedRequestIsAStructuredRefusalNotACrash() async throws {
        let host = try await HeadlessHost(storage: MemoryStorage())
        for request in [#"{"command":"fixture","name":"nope"}"#, #"{"command":"teleport"}"#, "not json", #"{"command":"action"}"#] {
            let response = try CoreJSON.decode(CommandResponse.self, from: await CommandRunner.respond(to: Data(request.utf8), on: host))
            #expect(!response.ok)
            #expect(response.error != nil)
        }
        let unknown = try CoreJSON.decode(CommandResponse.self, from: await CommandRunner.respond(to: Data(#"{"command":"fixture","name":"nope"}"#.utf8), on: host))
        #expect(unknown.error?.contains("known: pair-intro") == true)
    }
}
