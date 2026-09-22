import Foundation
import Testing
@testable import RichOSCore
@testable import RichOSFixtures

// Loop L1 (build plan §3.1): these run on this Mac with `bin/rios test`, no simulator.

/// The repository root, found from this file so the tests can read the shared JavaScript sources.
let repositoryRoot: URL = {
    var url = URL(fileURLWithPath: #filePath)
    for _ in 0..<7 { url.deleteLastPathComponent() }  // …/Core/Tests/RichOSCoreTests/CoreTests.swift → repo
    return url
}()

@Suite struct StateTests {
    @Test func aNewInstallIsUnpairedAndDark() {
        #expect(AppState.initial.pairing == .unpaired)
        #expect(AppState.initial.appearance == .dark)
        #expect(AppState.initial.screen == .pairIntro)
    }

    @Test func theScreenIsDerivedFromState() {
        var s = AppState()
        s.pairing = .paired
        #expect(s.screen == .pairConsent)  // consent comes before the first message
        s.consentGiven = true
        #expect(s.screen == .conversationEmpty)
        s.messages = Conversation.round12
        #expect(s.screen == .conversation)
        s.update = UpdateNotice(prominence: .required, version: "1.1", message: "")
        #expect(s.screen == .updateRequired)
        s.pairingProblem = .sessionNeedsNewerApp
        #expect(s.screen == .pairStale)
    }

    @Test func stateRoundTripsThroughJSONAndPrintsItsScreen() throws {
        let state = try Fixture.named("voice-locked").state
        let data = try CoreJSON.encode(state)
        #expect(try CoreJSON.decode(AppState.self, from: data) == state)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["screen"] as? String == "conv-populated")
    }

    @Test func onlyDurableFieldsArePersistedAndTransientOnesAreRebuilt() throws {
        let locked = try Fixture.named("voice-locked").state
        let restored = try AppState(restoring: locked.persisted)
        #expect(restored.voice == nil && restored.microphone == .unknown && restored.sheet == nil)
        #expect(restored.messages == locked.messages && restored.draft == locked.draft && restored.mac == locked.mac)
    }

    @Test func aMessageMidSendIsWaitingAfterARelaunch() throws {
        let pending = try Fixture.named("conv-pending").state
        let restored = try AppState(restoring: pending.persisted)
        #expect(!restored.messages.contains { $0.delivery == .sending })
        #expect(restored.unsentCount == pending.unsentCount)
    }

    @Test func aPairingInFlightIsNotPersistedAsAPairing() throws {
        let restored = try AppState(restoring: try Fixture.named("pair-progress").state.persisted)
        #expect(restored.pairing == .unpaired && restored.mac == nil)
    }

    @Test func fixtureTimesAreFixedInstantsOnTheRound12Day() {
        #expect(Date(timeIntervalSince1970: Double(Conversation.at(0, 0)) / 1000).ISO8601Format() == "2026-09-22T00:00:00Z")
    }

    @Test func theWaveformIsRound12sOwn() {
        // Values printed by Node running round 12's `waveFor` verbatim.
        let wave = Conversation.wave(count: 42, seed: 3)
        #expect(wave.count == 42)
        #expect(Array(wave.prefix(3)) == [0.3312579152606533, 0.29374138837623553, 0.8287466993687326])
        #expect(Array(Conversation.wave(count: 42, seed: 21).suffix(2)) == [0.36256801394150956, 0.6717289962131785])
    }
}

@Suite struct ActionTests {
    @Test func composeSetsTheDraftAndAsksToPersist() {
        let (next, effects) = Reducer.reduce(.initial, .compose(text: "Hello Rich"))
        #expect(next.draft == "Hello Rich")
        #expect(effects == [.persist])
    }

    @Test func aTransientChangeWritesNothing() {
        let (next, effects) = Reducer.reduce(.initial, .openSheet(.settings))
        #expect(next.sheet == .settings)
        #expect(effects.isEmpty)
    }

    @Test func actionsUseThePreservedCLIsJSONSpelling() throws {
        let compose = try CoreJSON.decode(Action.self, from: Data(#"{"type":"compose","text":"Hi"}"#.utf8))
        #expect(compose == .compose(text: "Hi"))
        let theme = try CoreJSON.decode(Action.self, from: Data(#"{"type":"set-appearance","appearance":"light"}"#.utf8))
        #expect(theme == .setAppearance(.light))
        #expect(String(decoding: try CoreJSON.encode(compose), as: UTF8.self) == #"{"text":"Hi","type":"compose"}"#)
    }

    @Test func everyActionRoundTripsThroughJSON() throws {
        let all: [Action] = [
            .compose(text: "x"), .setAppearance(.light), .openScanner, .closeScanner, .scanned(text: "x"),
            .submitPairingLink(text: "x"), .cameraPermission(.denied), .pairingAnswered(Scenario.answer), .pairingRefused,
            .confirmWords, .rejectWords, .acceptConsent, .dismissPairingProblem, .openSheet(.forget), .closeSheet,
        ]
        #expect(all.count == Action.knownTypes.count)
        for action in all {
            #expect(try CoreJSON.decode(Action.self, from: CoreJSON.encode(action)) == action)
        }
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

@Suite struct PairingTests {
    let link = "https://mm1.tail1a2b3c.ts.net:8443/#pair=K7M2QX9H"

    @Test func theReferenceClientsLinksParseToTheSameOriginAndCode() throws {
        // Contract fixtures/pairing.json "links": a tailnet link and a Connect link.
        let tailnet = try PairLink.parse(link)
        #expect(tailnet == PairLink(origin: "https://mm1.tail1a2b3c.ts.net:8443", code: "K7M2QX9H"))
        #expect(tailnet.route == .tailnet)
        let connect = try PairLink.parse("https://c-0123456789abcdef0123456789abcdef-g2.richos.ceo/#pair=K7M2QX9H")
        #expect(connect.origin == "https://c-0123456789abcdef0123456789abcdef-g2.richos.ceo" && connect.route == .connect)
        #expect(try PairLink.parse("https://MM1.tail1a2b3c.ts.net:443/#pair=K7M2QX9H").origin == "https://mm1.tail1a2b3c.ts.net")
    }

    @Test func theReferenceClientsRefusalsAreRefusedWithItsMessages() {
        // Contract fixtures/pairing.json "links_refused_by_reference_client", plus the whitespace rule.
        let refused = [
            ("http://mm1.tail1a2b3c.ts.net:8443/#pair=K7M2QX9H", PairLink.needsHTTPS),
            ("https://mm1.tail1a2b3c.ts.net:8443/x#pair=K7M2QX9H", PairLink.needsHTTPS),
            ("https://mm1.tail1a2b3c.ts.net:8443/#pair=A&pair=B", PairLink.needsOneCode),
            ("https://mm1.tail1a2b3c.ts.net:8443/?q=1#pair=K7M2QX9H", PairLink.needsHTTPS),
            ("https://mm1.tail1a2b3c.ts.net:8443/#pair=K7M2QX9H&x=1", PairLink.needsOneCode),
            ("https://user@mm1.tail1a2b3c.ts.net:8443/#pair=K7M2QX9H", PairLink.needsHTTPS),
            ("https://mm1.tail1a2b3c.ts.net:8443/#pair=", PairLink.needsOneCode),
            ("https://mm1.tail1a2b3c.ts.net:8443/#pair=K7M2 QX9H", PairLink.pasteWholeLink),
            ("not a link", PairLink.pasteWholeLink),
        ]
        for (text, message) in refused {
            #expect(throws: PairLink.Refusal(description: message), "\(text)") { try PairLink.parse(text) }
        }
    }

    @Test func theSixWordsAreComputedOnThePhoneFromTheMacsHex() throws {
        // Contract fixtures/fingerprint.json.
        let hex = "31:BD:24:BC:73:12:61:6B:6D:65:05:56:92:92:76:0D:F1:E8:6A:6B:26:DA:1A:85:2B:33:20:33:38:CB:4F:7B"
        #expect(try Fingerprint.words(fromHex: hex).joined(separator: " ") == "cobra morning cargo moose grape bonus")
        #expect(try Fingerprint.words(fromHex: "sha256: 31bd24bc7312") == Fingerprint.words(fromHex: hex))
        #expect(throws: Fingerprint.Invalid.self) { try Fingerprint.words(fromHex: "31:BD") }
    }

    @Test func theWordListIsTheWebAppsListByteForByte() throws {
        // `richos/web/web-app/lib/wordlist.js` is the source the Mac also mirrors (`phone/ca.rs`).
        let js = try String(contentsOf: repositoryRoot.appendingPathComponent("richos/web/web-app/lib/wordlist.js"), encoding: .utf8)
        let body = try #require(js.range(of: #"WORDS\s*=\s*(Object\.freeze\()?\["#, options: .regularExpression))
        let tail = js[body.upperBound...]
        let list = tail[..<tail.firstIndex(of: "]")!]
        let words = list.split(separator: ",").map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " \n\t'\"")) }.filter { !$0.isEmpty }
        #expect(words == WordList.words)
        #expect(WordList.words.count == 256)
    }

    @Test func pairingRefusesToStrandUnsentWorkForAnotherMac() throws {
        var s = try Fixture.named("pair-blocked").state
        s.pairingProblem = nil
        let (next, effects) = Reducer.reduce(s, .submitPairingLink(text: "https://other.tail1a2b3c.ts.net:8443/#pair=K7M2QX9H"))
        #expect(next.pairingProblem == .blockedByUnsentWork(count: 1))
        #expect(next.pairing == .paired && effects.isEmpty)
    }

    @Test func aDeniedCameraOpensItsExplanationNotTheScanner() {
        var s = AppState()
        s.camera = .denied
        let (next, _) = Reducer.reduce(s, .openScanner)
        #expect(next.scanner == nil && next.sheet == .cameraDenied)
    }

    @Test func aMacThatCannotStateItsFingerprintIsNotTrusted() throws {
        var s = try Fixture.named("pair-progress").state
        s.pairingProblem = nil
        let (next, effects) = Reducer.reduce(s, .pairingAnswered(PairAnswer(deviceID: "dev_x", fingerprintHex: "zz")))
        #expect(next.pairing == .unpaired && next.pairingProblem == .refused && effects.contains(.forgetIdentity))
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
        let storage = MemoryStorage()
        await storage.write(EffectRunner.stateKey, Data("not json".utf8))
        await #expect(throws: (any Error).self) { try await EffectRunner(storage: storage).load() }
        #expect(await storage.read(EffectRunner.stateKey) == Data("not json".utf8))
    }

    @Test func aStateSavedByANewerAppIsRecognizedAsNewer() async throws {
        let storage = MemoryStorage()
        await storage.write(EffectRunner.stateKey, Data(#"{"schema":3,"somethingNew":true}"#.utf8))
        do {
            _ = try await EffectRunner(storage: storage).load()
            Issue.record("a newer state loaded")
        } catch let error as StoredSchemaError {
            #expect(error.newer)
        }
    }
}

@Suite struct CommandTests {
    /// Every round-12 id that is an app screen on iPhone (67 less the two web-only and two lock-screen ids).
    static let round12AppScreens = """
    pair-intro pair-scanner pair-scanner-found pair-camera-denied pair-progress pair-words pair-refused pair-blocked \
    pair-stale pair-consent conv-empty conv-populated conv-pending conv-replying conv-streaming conv-playing-reply \
    conv-preparing-reply conv-older-loading conv-beginning conv-scrolled conv-focused conv-retry comp-idle comp-typing \
    comp-keyboard comp-disabled comp-too-long voice-press voice-permission voice-holding voice-slide-left voice-bin \
    voice-sent voice-too-short voice-slide-up voice-lock-transition voice-locked voice-locked-scrolled voice-locked-cancel \
    voice-locked-send voice-ceiling-warning voice-ceiling-reached voice-interrupted rec-card rec-unsupported rec-mic-denied \
    conn-reconnecting conn-offline conn-service conn-mac conn-revoked conn-incompatible conn-cached notif-offer \
    notif-settings settings settings-forget settings-forget-blocked upd-banner upd-dialog upd-blocking upd-feature-off \
    launch-cached
    """.split(separator: " ").map(String.init)

    @Test func thereIsOneFixturePerRound12AppScreen() {
        #expect(Self.round12AppScreens.count == 63)
        #expect(Fixture.all.map(\.name) == Self.round12AppScreens)
    }

    @Test func everyFixtureIsOnTheFullScreenSurfaceItsDesignShows() throws {
        let surfaces: [String: Screen] = [
            "pair-intro": .pairIntro, "pair-scanner": .pairScanner, "pair-scanner-found": .pairScanner,
            "pair-camera-denied": .pairIntro, "pair-progress": .pairProgress, "pair-words": .pairWords,
            "pair-refused": .pairIntro, "pair-stale": .pairStale, "pair-consent": .pairConsent,
            "conv-empty": .conversationEmpty, "conn-revoked": .connectionRevoked, "upd-blocking": .updateRequired,
        ]
        for fixture in Fixture.all {
            #expect(fixture.state.screen == surfaces[fixture.name] ?? .conversation, "\(fixture.name)")
        }
    }

    @Test func tooLongMeansOverTheLimit() throws {
        #expect(try Fixture.named("comp-too-long").state.draft.count > Limits.messageCharacters)
    }

    @Test func theDraftSurvivesARestartThroughStorage() async throws {
        let storage = MemoryStorage()
        let host = try await HeadlessHost(storage: storage)
        _ = try await CommandRunner.execute(Command(.fixture, name: "conv-empty"), on: host)
        _ = try await CommandRunner.execute(Command(.action, action: .compose(text: "Kept")), on: host)
        let fresh = try await HeadlessHost(storage: storage)
        #expect(try await fresh.currentState().draft == "Kept")
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
            return try CoreJSON.encode(try await CommandRunner.execute(Command(.scenario, name: "pair-by-scan"), on: host))
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
