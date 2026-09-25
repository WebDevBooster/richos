import Foundation
import Testing
@testable import RichOSCore
@testable import RichOSFixtures

/// A Mac that answers by route, whatever the order of requests — for flows where the live stream
/// and the outbox run concurrently.
actor RoutedMac: HTTPTransport {
    private(set) var requests: [HTTPRequest] = []
    let pairAnswer: Data

    init(pairAnswer: Data) { self.pairAnswer = pairAnswer }

    func send(_ request: HTTPRequest, origin: String) async throws -> HTTPResponse {
        requests.append(request)
        let challenge = ["X-RichOS-Challenge": "Xqra0YQOgVJ9WLmQy9eYs1LSoxDt1Ggv"]
        let body = request.body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        switch (request.method, request.target) {
        case ("POST", "/api/pair") where body["code"] != nil:
            return HTTPResponse(status: 200, headers: challenge, body: pairAnswer)
        case ("POST", "/api/pair"):
            return HTTPResponse(status: 200, headers: challenge, body: Data(#"{"ok":true}"#.utf8))
        case ("POST", "/api/messages"):
            let id = body["client_id"] as? String ?? "?"
            return HTTPResponse(status: 200, headers: challenge, body: Data(#"{"message_id":"intake_1","cursor":5,"thread_id":"thr_5c1e","accepted_at":"2026-09-22T13:00:00.412Z","duplicate":false,"client_id":"\#(id)"}"#.utf8))
        default:
            return HTTPResponse(status: 404, headers: challenge)
        }
    }
}

@Suite struct NetworkEffectsTests {
    /// Waits until `condition` holds for the host's state (the live stream delivers asynchronously).
    func eventually(_ host: HeadlessHost, _ condition: @Sendable (AppState) -> Bool) async throws -> AppState {
        for _ in 0..<400 {
            let state = try await host.currentState()
            if condition(state) { return state }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        return try await host.currentState()
    }

    @Test func pairConfirmStreamAndSendAgainstAScriptedMac() async throws {
        let exchange = try #require(try Corpus.cases(try Corpus.load("pairing"), "pair_exchanges").first)
        let answer = try JSONSerialization.data(withJSONObject: try #require((exchange["mac_answers"] as? [[String: Any]])?.first?["body"]))
        let mac = RoutedMac(pairAnswer: answer)
        let wire = try Corpus.cases(try Corpus.load("events"), "wire_cases")[0]["wire_utf8"] as? String ?? ""
        // The stream stays open after the turn, as a Mac's does: the outbox moves only on an open one.
        let stream = LifecycleStream([.open(chunks: [wire])])
        let identities = MemoryIdentityStore()
        let network = NetworkEffects(transport: mac, stream: stream, identities: identities, clock: FixedClock(ms: 100),
                                     sleep: { _ in throw CancellationError() })
        let host = try await HeadlessHost(storage: MemoryStorage(), handler: CompositeEffectHandler([network]))
        await network.setSink { action in _ = try? await host.dispatch(action) }

        let origin = "https://mm1.tail1a2b3c.ts.net:8443"
        var s = try await host.dispatch(.submitPairingLink(text: origin + "/#pair=K7M2QX9H"))
        #expect(s.screen == .pairWords && s.mac?.deviceID != nil, "the Mac answered; the six words are on screen")
        // v2 words over the origin this phone dialed, the Mac's value and THIS phone's own key.
        let point = Base64URL.encode(try await identities.signer(for: origin).publicPoint())
        #expect(s.fingerprintWords == (try Fingerprint.words(origin: origin, caFingerprintSHA256: "55:A7:F7:36:2C:07:CD:F4:EE:17:5B:6A:47:D1:0A:0D:62:9B:E7:AF:5F:99:0C:15:B6:5A:88:D1:33:2D:63:87",
                                                             devicePoint: point)))
        // This scripted Mac answers the phone's "They match" with `{"ok":true}`: its own press came first.
        s = try await host.dispatch(.confirmWords)
        #expect(s.pairing == .paired && s.macWait == nil, "the Mac had already been pressed: paired at once")
        s = try await host.dispatch(.acceptConsent)
        s = try await eventually(host) { $0.messages.contains { $0.id == "turn_9:text:0" } }
        #expect(s.messages.map(\.id) == ["turn_8:user", "turn_8:text:0", "turn_9:user", "turn_9:text:0"], "the stream built the conversation")
        #expect(s.reply == nil && s.screen == .conversation)

        s = try await host.dispatch(.compose(text: "Thanks"))
        s = try await host.dispatch(.sendDraft(clientID: "c1", at: 200))
        #expect(s.outbox.isEmpty && s.messages.last?.id == "c1" && s.messages.last?.delivery == nil, "delivered through the courier")

        let sent = await mac.requests
        #expect(sent.map(\.target) .prefix(2) == ["/api/pair", "/api/pair"])
        let pairBody = try #require(try JSONSerialization.jsonObject(with: sent[0].body ?? Data()) as? [String: Any])
        #expect(pairBody["platform"] as? String == "ios" && pairBody["pairing_version"] as? Int == 2 && sent[0].headers["Authorization"] == nil)
        #expect(String(decoding: sent[1].body ?? Data(), as: UTF8.self).contains(#""fingerprint_confirmed":true"#) && sent[1].headers["Authorization"] != nil)
        #expect(sent.contains { $0.target == "/api/messages" && String(decoding: $0.body ?? Data(), as: UTF8.self).contains(#""text":"Thanks""#) })
        _ = try await host.dispatch(.backgrounded(at: 300))
    }

    @Test func notificationRegistrationWaitsForTheTokenAndKeepsTheHostID() async throws {
        actor PushMac: HTTPTransport {
            var bodies: [String] = []
            func send(_ request: HTTPRequest, origin: String) async throws -> HTTPResponse {
                bodies.append(String(decoding: request.body ?? Data(), as: UTF8.self))
                return HTTPResponse(status: 200, headers: ["X-RichOS-Challenge": "c"],
                                    body: Data(#"{"ok":true,"registered":true,"host_id":"0123456789abcdef0123456789abcdef"}"#.utf8))
            }
        }
        let mac = PushMac()
        // The phone that paired with the fixture's Mac holds its key.
        let identities = MemoryIdentityStore()
        _ = await identities.signer(for: try #require(try Fixture.named("notif-offer").state.mac?.origin))
        let network = NetworkEffects(transport: mac, stream: ScriptedStream([]), identities: identities)
        await network.setPreviewKeyProvider { _, _ in Data(repeating: 7, count: 32) }
        let host = try await HeadlessHost(storage: MemoryStorage(), handler: network)
        _ = try await CommandRunner.execute(Command(.fixture, name: "notif-offer"), on: host)
        var s = try await host.dispatch(.turnOnNotifications)
        #expect(s.notifications.status == .turningOn, "no token yet: registration waits")
        for action in await network.setPushToken(String(repeating: "ab", count: 32), sandbox: true, state: s) {
            s = try await host.dispatch(action)
        }
        #expect(s.notifications.status == .on && s.notifications.hostID == "0123456789abcdef0123456789abcdef")
        let body = try #require(await mac.bodies.last)
        #expect(body.contains(#""topic":"dev.richos.connect""#) && body.contains(#""environment":"sandbox""#))
        #expect(try AppState(restoring: s.persisted).notifications.hostID == s.notifications.hostID, "the host id survives a relaunch")
    }

    @Test func noMacAtPairingSaysSoInsteadOfRefused() async throws {
        let network = NetworkEffects(transport: ScriptedMac([["transport": true]]), stream: ScriptedStream([]), identities: MemoryIdentityStore())
        let host = try await HeadlessHost(storage: MemoryStorage(), handler: network)
        let s = try await host.dispatch(.submitPairingLink(text: "https://mm1.tail1a2b3c.ts.net:8443/#pair=K7M2QX9H"))
        #expect(s.screen == .pairIntro && s.pairingProblem == .macUnreachable)
    }

    @Test func theyDoNotMatchForgetsTheKey() async throws {
        let identities = MemoryIdentityStore()
        let exchange = try #require(try Corpus.cases(try Corpus.load("pairing"), "pair_exchanges").first)
        let answer = try JSONSerialization.data(withJSONObject: try #require((exchange["mac_answers"] as? [[String: Any]])?.first?["body"]))
        let network = NetworkEffects(transport: RoutedMac(pairAnswer: answer), stream: ScriptedStream([]), identities: identities)
        let host = try await HeadlessHost(storage: MemoryStorage(), handler: network)
        _ = try await host.dispatch(.submitPairingLink(text: "https://mm1.tail1a2b3c.ts.net:8443/#pair=K7M2QX9H"))
        let before = try await identities.signer(for: "https://mm1.tail1a2b3c.ts.net:8443").publicPoint()
        let s = try await host.dispatch(.rejectWords)
        let after = try await identities.signer(for: "https://mm1.tail1a2b3c.ts.net:8443").publicPoint()
        #expect(s.screen == .pairIntro && before != after, "the key was discarded; a new pairing gets a new one")
    }

    /// Security review I-2: the app's files came back from a backup, the Keychain item did not
    /// (`…ThisDeviceOnly`). The phone is paired to a Mac it holds no key for. It shows "Pair again";
    /// it never mints a new key and signs as a stranger, and nothing unsent is dropped.
    @Test func aPairedPhoneWhoseKeyIsGoneIsToldToPairAgain() async throws {
        let origin = "https://mm1.tail1a2b3c.ts.net:8443"
        let mac = RoutedMac(pairAnswer: Data())
        let network = NetworkEffects(transport: mac, stream: ScriptedStream([]), identities: MemoryIdentityStore(),
                                     clock: FixedClock(ms: 100), sleep: { _ in throw CancellationError() })
        await network.setSink { _ in }
        var restored = AppState()
        restored.pairing = .paired
        restored.consentGiven = true
        restored.mac = MacLink(origin: origin, route: .connect, deviceID: "dev_7", threadID: "thr_5c1e", name: "Alex’s Mac")
        var (state, effects) = Reducer.reduce(restored, .compose(text: "Still here after the restore"))
        (state, effects) = Reducer.reduce(state, .sendDraft(clientID: "c_restored", at: 900))
        let queued = try #require(state.outbox.first?.clientID)
        (state, effects) = Reducer.reduce(state, .foregrounded(at: 1_000))
        #expect(effects.contains(.connect))
        var answers: [Action] = []
        for effect in effects where effect != .persist { answers += await network.handle(effect, state: state) }
        answers += await network.handle(.deliver(clientID: queued), state: state)
        for action in answers { state = Reducer.reduce(state, action).state }
        #expect(state.pairing == .revoked && state.screen == .connectionRevoked, "the person is told to pair again")
        #expect(state.outbox.map(\.clientID) == [queued], "his unsent message is kept for after pairing")
        #expect(await mac.requests.isEmpty, "nothing was signed with a key the Mac has never seen")
    }
}
