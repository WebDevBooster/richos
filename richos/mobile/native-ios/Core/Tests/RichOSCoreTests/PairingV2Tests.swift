import CryptoKit
import Foundation
import Testing
@testable import RichOSCore
@testable import RichOSFixtures

/// The phone's key is the corpus's test key, so the signed probes verify against `keys.json`.
actor CorpusIdentityStore: IdentityStore {
    private var forgotten: [String] = []
    func signer(for origin: String) async throws -> any Signer { SoftwareSigner(key: Corpus.testKey) }
    func existingSigner(for origin: String) async throws -> (any Signer)? {
        forgotten.contains(origin) ? nil : SoftwareSigner(key: Corpus.testKey)
    }
    func forget(origin: String) async throws { forgotten.append(origin) }
    var forgottenOrigins: [String] { forgotten }
}

/// `pairing.json` `pair_v2.relay_scenario` and `mac_confirmation`, replayed through the iOS core.
@Suite struct MacConfirmationConformance {
    static let origin = "https://mm1.tail1a2b3c.ts.net:8443"

    func section() throws -> [String: Any] { try #require(try Corpus.load("pairing")["mac_confirmation"] as? [String: Any]) }

    /// A phone waiting for the press on the Mac, as the reducer leaves it after "They match".
    func waiting(bound seconds: Double?) throws -> AppState {
        var s = try Fixture.named("pair-progress").state
        var answer = Scenario.answer
        answer.confirmWithinSeconds = seconds
        s = Reducer.reduce(s, .pairingAnswered(answer)).state
        return Reducer.reduce(s, .confirmWords).state
    }

    /// The phone dials a relay; the Mac derives over its own origin; the two screens differ.
    @Test func throughARelayTheTwoScreensShowDifferentWords() async throws {
        let v2 = try #require(try Corpus.load("pairing")["pair_v2"] as? [String: Any])
        let scenario = try #require(v2["relay_scenario"] as? [String: Any])
        let dialed = try #require(scenario["phone_dialed"] as? String)
        let macOrigin = try #require(scenario["mac_origin"] as? String)
        let value = try #require(scenario["ca_fingerprint_sha256"] as? String)
        let point = try #require(scenario["device_point_b64url"] as? String)
        let phone = try Fingerprint.words(origin: dialed, caFingerprintSHA256: value, devicePoint: point)
        #expect(phone == scenario["phone_words"] as? [String], "the phone's words, over the origin it dialed")
        #expect(try Fingerprint.words(origin: macOrigin, caFingerprintSHA256: value, devicePoint: point) == scenario["mac_words"] as? [String],
                "the Mac's words, over its own origin")
        #expect(phone != scenario["mac_words"] as? [String], "the two screens differ")
        // Through the whole phone: a link to the relay, the real pairing request, the reducer's words.
        let request = try #require(scenario["request"] as? [String: Any])
        let answer = try #require(try Corpus.cases(v2, "exchanges").first?["mac_answers"] as? [[String: Any]])
        let mac = ScriptedMac(answer)
        let network = NetworkEffects(transport: mac, stream: ScriptedStream([]), identities: CorpusIdentityStore())
        let host = try await HeadlessHost(storage: MemoryStorage(), handler: network)
        let s = try await host.dispatch(.submitPairingLink(text: dialed + "/#pair=K7M2QX9H"))
        #expect(s.screen == .pairWords && s.fingerprintWords == phone, "the phone shows the relay's words, never the Mac's")
        let sent = try #require(await mac.requests.first)
        #expect(sent.method == request["method"] as? String && sent.target == request["target"] as? String)
        let ours = try #require(try JSONSerialization.jsonObject(with: sent.body ?? Data()) as? [String: Any])
        let theirs = try #require(try JSONSerialization.jsonObject(with: Corpus.body(request) ?? Data()) as? [String: Any])
        #expect(StreamConformance.same(ours["public_key_jwk"] as Any, theirs["public_key_jwk"] as Any) && ours["pairing_version"] as? Int == 2)
    }

    /// `wait_schedule_ms`, `max_requests_in_the_window` and `wait_bound_ms`, as numbers.
    @Test func theScheduleAndTheBoundAreTheCorpusNumbers() throws {
        let c = try section()
        let schedule = try Corpus.cases(c, "wait_schedule_ms")
        var at: Int64 = 0
        for step in schedule {
            let attempt = try #require(step["attempt"] as? Int)
            at += MacWait.delayMs(attempt: attempt)
            #expect(MacWait.delayMs(attempt: attempt) == Int64(try #require(step["delay_ms"] as? Int)), "attempt \(attempt): delay")
            #expect(at == Int64(try #require(step["asked_at_ms"] as? Int)), "attempt \(attempt): asked at")
        }
        #expect(at + MacWait.delayMs(attempt: schedule.count) > MacWait.windowMs, "no scheduled ask falls inside the window after the last")
        #expect(MacWait.maxRequests == c["max_requests_in_the_window"] as? Int && schedule.count == MacWait.maxRequests)
        let bounds = try #require(c["wait_bound_ms"] as? [String: Int])
        #expect(MacWait.boundMs(confirmWithinSeconds: 240) == Int64(try #require(bounds["from_answer_240_seconds"])))
        #expect(MacWait.boundMs(confirmWithinSeconds: 9999) == Int64(try #require(bounds["from_answer_9999_seconds"])))
        #expect(MacWait.boundMs(confirmWithinSeconds: nil) == Int64(try #require(bounds["when_the_mac_says_nothing"])))
        #expect(MacWait.boundMs(confirmWithinSeconds: 0) == MacWait.windowMs && MacWait.boundMs(confirmWithinSeconds: .nan) == MacWait.windowMs)
    }

    /// The whole wait through the reducer and the app's one timer on virtual time, for a Mac that does
    /// not offer `pair-wait`: a Mac that never gets its press is asked exactly at `asked_at_ms`, at
    /// most `max_requests_in_the_window` times inside the bound, then ONE last time at the bound
    /// (`pair_wait`, Sage's pair-v2 hypotheses review §2), and the wait then ends truthfully. A 240 s
    /// bound stops earlier.
    @Test func theWaitAsksOnTheScheduleOnlyAndEndsAtTheBound() throws {
        let c = try section()
        let expected = try Corpus.cases(c, "wait_schedule_ms").map { Int64(try #require($0["asked_at_ms"] as? Int)) }
        for (seconds, bound) in [(nil, MacWait.windowMs), (240.0, 240_000 as Int64)] {
            let t0: Int64 = 1_790_000_000_000
            var s = Reducer.reduce(try waiting(bound: seconds), .macConfirmation(.awaiting, at: t0)).state
            var asked: [Int64] = []
            var wakeups = 0
            while let due = TickSchedule.nextTick(s) {
                wakeups += 1
                let (next, effects) = Reducer.reduce(s, .tick(at: due))
                s = next
                if effects.contains(.checkMacConfirmation(waitSeconds: 0)) {
                    asked.append(due - t0)
                    s = Reducer.reduce(s, .macConfirmation(.awaiting, at: due)).state
                }
                #expect(wakeups <= expected.count + 2, "the timer does not spin")
                if wakeups > expected.count + 2 { break }
            }
            #expect(asked == expected.filter { $0 < bound } + [bound],
                    "bound \(bound): asked at the corpus's times inside the bound, then once at the bound")
            #expect(asked.count <= MacWait.maxRequests + 1)
            #expect(s.screen == .pairIntro && s.pairingProblem == .macAnswerExpired && s.mac == nil && s.macWait == nil,
                    "bound \(bound): the wait ended, truthfully, with nothing kept")
            #expect(TickSchedule.nextTick(s) == nil, "and nothing more is owed")
        }
    }

    /// `awaiting_answer_classification`: the awaiting 409 is retried, never refused.
    @Test func theAwaitingAnswerIsWaitAndRetryNeverRefused() throws {
        let c = try section()
        let classification = try #require(c["awaiting_answer_classification"] as? [String: Any])
        let answer = try #require(classification["mac_answer"] as? [String: Any])
        let body = try #require(answer["body"] as? String)
        #expect(body == c["awaiting_body"] as? String)
        let response = HTTPResponse(status: try #require(answer["status"] as? Int), headers: answer["headers"] as? [String: String] ?? [:], body: Data(body.utf8))
        let required = try #require(classification["required"] as? [String: Any])
        #expect(required["client_action"] as? String == "retry_same_bytes_after_backoff")
        #expect(ClientAction.classify(response, attempt: 1) == .retrySameBytes(afterMs: Int64(try #require(required["retry_after_ms"] as? Int))),
                "a message waiting behind the press stays in the outbox and is retried")
        #expect(MacConfirmation.ofConfirmation(response) == .awaiting, "the wait goes on")
        #expect(APIClient.classify(response).retryable, "never final")
    }

    /// `phone_answer_while_waiting`: the phone's own "They match", signed exactly as recorded, is
    /// answered `awaiting_mac_confirmation: true`, and the phone waits.
    @Test func thePhonesOwnTheyMatchIsTheRecordedRequestAndStartsTheWait() async throws {
        let c = try section()
        let exchange = try #require(c["phone_answer_while_waiting"] as? [String: Any])
        let recorded = try #require((exchange["requests"] as? [[String: Any]])?.first)
        let signed = try #require(recorded["signed"] as? [String: Any])
        let outcome = try #require((exchange["outcome"] as? [String: Any])?["value"] as? [String: Any])
        var s = try waiting(bound: 300)
        s.mac?.deviceID = "dev_8d4c57b7ff82"
        let pairedMac = ScriptedMac([
            ["status": 200, "headers": ["X-RichOS-Challenge": signed["challenge"] as Any]],
            ["status": 200, "body": outcome, "headers": ["X-RichOS-Challenge": "next"]],
        ])
        let handler = NetworkEffects(transport: pairedMac, stream: ScriptedStream([]), identities: CorpusIdentityStore(), clock: FixedClock(ms: 5_000))
        let answers = await handler.handle(.confirmFingerprint(matches: true), state: s)
        #expect(answers == [.macConfirmation(.awaiting, at: 5_000)], "the Mac is still waiting for its own press")
        let sent = await pairedMac.requests
        #expect(sent.map(\.target) == ["/api/challenge", "/api/pair"], "a relaunched client asks for a challenge first, then signs")
        let ours = try #require(sent.last)
        #expect(ours.method == recorded["method"] as? String && ours.target == recorded["target"] as? String)
        #expect(ours.body == Corpus.body(recorded), "the recorded body, byte for byte")
        #expect(ours.headers["Content-Type"] == "application/json")
        let asSent: [String: Any] = ["method": ours.method, "target": ours.target, "headers": ours.headers,
                                     "body": ["utf8": String(decoding: ours.body ?? Data(), as: UTF8.self)]]
        let verdict = MacVerifier.verify(asSent, publicKey: Corpus.testKey.publicKey)
        #expect(verdict.accepted && verdict.signingString == (recorded["mac"] as? [String: Any])?["signing_string"] as? String,
                "the Mac's rebuild of the signing string is the recorded one, and our signature verifies")
        let next = Reducer.reduce(s, answers[0]).state
        #expect(next.screen == .pairAwaitingMac && next.macWait?.deadlineMs == 5_000 + 300_000 && next.macWait?.nextAskAtMs == 5_000 + 2_000)
    }

    /// `pair_wait.asks` answered to a wait in progress: the phone takes each recorded answer as
    /// recorded: still waiting, pressed, or refused (final). (The `probes` of this section describe
    /// the wait before `pair_wait` — a signed read of one backfill row — which the phone no longer
    /// makes; `PairWaitConformance` replays the asks' requests.)
    @Test func everyAskAnswerMovesTheWaitAsRecorded() async throws {
        let asks = try Corpus.cases(try #require(try Corpus.load("pairing")["pair_wait"] as? [String: Any]), "asks")
        #expect(asks.count == 6)
        for ask in asks {
            let name = ask["name"] as? String ?? "?"
            let recorded = try #require((ask["requests"] as? [[String: Any]])?.first)
            let signed = try #require(recorded["signed"] as? [String: Any])
            let mac = ScriptedMac([
                ["status": 200, "headers": ["X-RichOS-Challenge": signed["challenge"] as Any]],
                try #require(ask["mac_answer"] as? [String: Any]),
            ])
            let network = NetworkEffects(transport: mac, stream: ScriptedStream([]), identities: CorpusIdentityStore(), clock: FixedClock(ms: 9_000))
            var s = Reducer.reduce(try waiting(bound: 300), .macConfirmation(.awaiting, at: 1_000)).state
            s.mac?.deviceID = "dev_8d4c57b7ff82"
            s = Reducer.reduce(s, .tick(at: 3_000)).state
            #expect(s.macWait?.asking == true, "\(name): an ask is owed")
            let answers = await network.handle(.checkMacConfirmation(waitSeconds: 0), state: s)
            let outcome = try #require(ask["outcome"] as? [String: Any])
            let want: MacConfirmation = outcome["ok"] as? Bool == true ? (outcome["value"] as? Bool == true ? .confirmed : .awaiting) : .refused
            #expect(answers == [.macConfirmation(want, at: 9_000, askedAt: 9_000)], "\(name): \(want)")
            let after = Reducer.reduce(s, answers[0])
            switch want {
            case .confirmed:
                #expect(after.state.screen == .pairConsent && after.effects.contains(.connect), "\(name): paired, and the live connection opens")
            case .awaiting:
                #expect(after.state.screen == .pairAwaitingMac && after.state.macWait?.nextAskAtMs == 9_000 + 3_000, "\(name): the next probe on the schedule")
            case .refused:
                #expect(after.state.screen == .pairIntro && after.state.pairingProblem == .notAcceptedByMac
                        && after.effects.contains(.forgetIdentity(origin: Self.origin)), "\(name): final; nothing kept")
            }
        }
    }

    /// `refused_for_missing_pair_v2` through the whole phone: one signed "They do not match" so that
    /// Mac forgets the key, the key forgotten here, the person told to update the Mac, and no second
    /// pairing request (no fallback to v1).
    @Test func aMacWithoutPairV2IsToldToForgetTheKeyAndThePhoneSaysUpdate() async throws {
        let v2 = try #require(try Corpus.load("pairing")["pair_v2"] as? [String: Any])
        let old = try #require(try Corpus.cases(v2, "exchanges").first { $0["refused_for_missing_pair_v2"] as? Bool == true })
        var answers = try #require(old["mac_answers"] as? [[String: Any]])
        answers.append(["status": 200, "body": ["ok": true], "headers": ["X-RichOS-Challenge": "c2"]])
        let mac = ScriptedMac(answers)
        let identities = CorpusIdentityStore()
        let network = NetworkEffects(transport: mac, stream: ScriptedStream([]), identities: identities)
        let host = try await HeadlessHost(storage: MemoryStorage(), handler: network)
        let s = try await host.dispatch(.submitPairingLink(text: Self.origin + "/#pair=K7M2QX9H"))
        #expect(s.screen == .pairIntro && s.pairingProblem == .macNeedsUpdate && s.mac == nil && s.fingerprintWords.isEmpty)
        let sent = await mac.requests
        #expect(sent.count == 2 && sent.filter { $0.body.map { String(decoding: $0, as: UTF8.self).contains("\"code\"") } == true }.count == 1,
                "one pairing request, never a v1 retry")
        let refusal = try #require(sent.last)
        #expect(refusal.target == "/api/pair" && refusal.headers["Authorization"] != nil
                && refusal.body == PairingWire.confirmationBody(deviceID: "dev_8d4c57b7ff82", matches: false), "one signed They do not match")
        #expect(await identities.forgottenOrigins == [Self.origin], "the key is forgotten on this side too")
    }
}

/// Leaving the foreground cancels the wait: no timer, retry or request is left behind, and a return
/// resumes it truthfully (CEO ruling §81; the PRD's §8 "lifecycle cancellation").
@Suite struct MacWaitLifecycleTests {
    static let origin = MacConfirmationConformance.origin

    func awaiting(deadline: Int64) -> AppState {
        var s = AppState()
        s.pairing = .awaitingMac
        s.mac = MacLink(origin: Self.origin, route: .tailnet, deviceID: "dev_8d4c57b7ff82", threadID: "thr_5c1e")
        s.fingerprintWords = ["gazelle", "coral", "lettuce", "grape", "kayak", "camera"]
        s.macWait = MacWait(boundMs: MacWait.windowMs, deadlineMs: deadline, paused: true)
        return s
    }

    @Test func offScreenNothingIsOwedAndALateAnswerIsDropped() throws {
        let t0: Int64 = 1_000_000
        var s = Reducer.reduce(awaiting(deadline: t0 + 300_000), .foregrounded(at: t0))
        #expect(s.effects == [.persist, .checkMacConfirmation(waitSeconds: 0)] && s.state.macWait?.asking == true, "on screen: one probe at once")
        let asked = s.state
        s = Reducer.reduce(asked, .backgrounded(at: t0 + 100))
        #expect(s.effects.isEmpty && s.state.macWait?.paused == true && s.state.macWait?.asking == false)
        #expect(TickSchedule.nextTick(s.state) == nil, "off screen: no timer is owed")
        let background = s.state
        for answer in [MacConfirmation.confirmed, .awaiting, .refused] {
            let late = Reducer.reduce(background, .macConfirmation(answer, at: t0 + 200))
            #expect(late.state == background && late.effects.isEmpty, "a \(answer) answer after leaving the screen is dropped")
        }
        for minute in 1...10 {
            let tick = Reducer.reduce(background, .tick(at: t0 + Int64(minute) * 60_000))
            #expect(tick.state == background && tick.effects.isEmpty, "no retry off screen")
        }
        // Back inside the bound: one probe at once. Past it: one last ask, and a "not yet" to it is the
        // end, truthfully (Sage's pair-v2 hypotheses review §2).
        let back = Reducer.reduce(background, .foregrounded(at: t0 + 60_000))
        #expect(back.effects == [.persist, .checkMacConfirmation(waitSeconds: 0)] && back.state.macWait?.requests == 2)
        let late = Reducer.reduce(background, .foregrounded(at: t0 + 300_000))
        #expect(late.effects == [.checkMacConfirmation(waitSeconds: 0)] && late.state.macWait?.finalAsk == true && late.state.macWait?.requests == 1)
        let ended = Reducer.reduce(late.state, .macConfirmation(.awaiting, at: t0 + 300_100))
        #expect(ended.state.pairingProblem == .macAnswerExpired && ended.effects.contains(.forgetIdentity(origin: Self.origin)))
    }

    /// Coming and going cannot beat the ceiling: at most `max_requests_in_the_window` probes in one wait.
    @Test func comingAndGoingNeverExceedsTheCeiling() {
        let t0: Int64 = 1_000_000
        var s = awaiting(deadline: t0 + 300_000)
        var probes = 0
        for i in 0..<100 {
            let at = t0 + Int64(i) * 1_000
            let front = Reducer.reduce(s, .foregrounded(at: at))
            probes += front.effects.filter { $0 == .checkMacConfirmation(waitSeconds: 0) }.count
            s = Reducer.reduce(front.state, .backgrounded(at: at + 500)).state
        }
        #expect(probes == MacWait.maxRequests && s.pairing == .awaitingMac)
        // A Mac that holds is asked no more often than every 7 s, however often the screen comes back.
        var held = awaiting(deadline: t0 + 300_000)
        held.macWait?.holds = true
        var asks: [Int64] = []
        for i in 0..<100 {
            let at = t0 + Int64(i) * 1_000
            var front = Reducer.reduce(held, .foregrounded(at: at))
            if let due = front.state.macWait?.nextAskAtMs, due <= at + 500 { front = Reducer.reduce(front.state, .tick(at: due)) }
            if front.effects.contains(where: { if case .checkMacConfirmation = $0 { return true }; return false }) { asks.append(at) }
            held = Reducer.reduce(front.state, .backgrounded(at: at + 500)).state
        }
        #expect(zip(asks.dropFirst(), asks).allSatisfy { $0 - $1 >= MacWait.minAskSpacingMs } && asks.count == 15,
                "asks at \(asks.map { $0 - t0 })")
    }

    /// Nor can relaunching: the probe count and the deadline survive a restart.
    @Test func relaunchingNeverExceedsTheCeilingOrOutlivesTheBound() throws {
        let t0: Int64 = 1_000_000
        var s = awaiting(deadline: t0 + 300_000)
        var probes = 0
        for i in 0..<100 {
            let front = Reducer.reduce(s, .foregrounded(at: t0 + Int64(i) * 1_000))
            probes += front.effects.filter { $0 == .checkMacConfirmation(waitSeconds: 0) }.count
            s = try AppState(restoring: front.state.persisted)  // the process is killed and relaunched
            #expect(s.macWait?.deadlineMs == t0 + 300_000 && s.macWait?.paused == true)
        }
        #expect(probes == MacWait.maxRequests && s.macWait?.requests == MacWait.maxRequests)
        // Past the bound a relaunch asks once more, and that ask decides.
        let late = Reducer.reduce(s, .foregrounded(at: t0 + 300_000))
        #expect(late.effects == [.checkMacConfirmation(waitSeconds: 0)] && late.state.macWait?.finalAsk == true)
        let ended = Reducer.reduce(late.state, .macConfirmation(.awaiting, at: t0 + 300_100)).state
        #expect(ended.pairingProblem == .macAnswerExpired && TickSchedule.nextTick(ended) == nil)
    }

    /// An alert or Control Center passing over the app is not a return: the schedule stands.
    @Test func anAlertOverTheAppDoesNotAskAgain() {
        let t0: Int64 = 1_000_000
        var s = Reducer.reduce(awaiting(deadline: t0 + 300_000), .foregrounded(at: t0)).state
        s = Reducer.reduce(s, .macConfirmation(.awaiting, at: t0 + 100)).state
        let again = Reducer.reduce(s, .foregrounded(at: t0 + 500))
        #expect(again.state == s && again.effects.isEmpty)
    }

    /// The real store and network effects: a probe in flight when the app leaves the screen is
    /// canceled, sends nothing more and changes nothing; the return asks once and pairs.
    @MainActor @Test func theStoreCancelsTheProbeInFlightAndResumesOnReturn() async throws {
        let mac = GatedMac()
        // Once paired, the live stream opens and stays open (so it makes no revocation probe of its own).
        let stream = LifecycleStream()
        let network = NetworkEffects(transport: mac, stream: stream, identities: PairedMemoryIdentityStore(),
                                     clock: FixedClock(ms: 2_000_000), sleep: { _ in throw CancellationError() })
        await network.setSink { _ in }
        let t0: Int64 = 1_000_000
        let store = AppStore(state: awaiting(deadline: t0 + 300_000), runner: EffectRunner(storage: MemoryStorage(), handler: network))
        store.becameActive(at: t0)
        #expect(store.state.macWait?.asking == true)
        try await mac.untilWaiting(1)
        store.wentToBackground(at: t0 + 100)
        #expect(store.state.macWait?.paused == true && TickSchedule.nextTick(store.state) == nil)
        await mac.release(HTTPResponse(status: 200, headers: ["X-RichOS-Challenge": "c1"]))
        await store.settle()
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(await mac.targets == ["GET /api/challenge"], "the canceled probe sent nothing after the app left the screen")
        #expect(store.state.pairing == .awaitingMac && store.state.macWait?.paused == true && store.state.macWait?.asking == false,
                "its answer changed nothing")
        // Back on screen: one probe, answered 200 — pressed on the Mac.
        await mac.answerFreely()
        store.becameActive(at: t0 + 60_000)
        for _ in 0..<200 where store.state.pairing != .paired { try await Task.sleep(nanoseconds: 5_000_000) }
        #expect(store.state.pairing == .paired && store.state.screen == .pairConsent && store.state.macWait == nil)
        let probes = await mac.targets.filter { $0 == "POST /api/pair" }
        #expect(probes == ["POST /api/pair"], "exactly one ask after the return: the phone's own They match")
        // Leave nothing running: off screen the live stream closes.
        store.wentToBackground(at: t0 + 61_000)
        var waited = 0
        while await stream.open > 0, waited < 200 { waited += 1; try await Task.sleep(nanoseconds: 5_000_000) }
        #expect(await stream.open == 0)
    }
}

/// How a pairing that did not happen is told (Urban's review of the pairing words, 2026-09-24).
@Suite struct PairingEndingTests {
    /// State 4: "They do not match" on the phone is the one security decision in pairing, so it ends
    /// on a card that says it stopped, never on a plain intro that looks like a reset.
    @Test func theyDoNotMatchSaysItStoppedAndNothingWasPaired() throws {
        for start in ["pair-words", "pair-awaiting-mac"] {
            let (next, effects) = Reducer.reduce(try Fixture.named(start).state, .rejectWords)
            #expect(next.screen == .pairIntro && next.pairingProblem == .wordsRejected && next.mac == nil, "\(start)")
            #expect(effects.contains(.confirmFingerprint(matches: false)) && effects.contains(.forgetIdentity(origin: "https://mm1.tail1a2b3c.ts.net:8443")))
        }
    }

    /// Question 1: the card is still there after opening the scanner and backing out, and the moment
    /// a new code is read it goes.
    @Test func backingOutOfTheScannerKeepsTheCardAndANewCodeClearsIt() throws {
        for name in ["pair-mac-update", "pair-mac-refused", "pair-mac-expired", "pair-words-rejected", "pair-refused", "pair-unreachable"] {
            var s = try Fixture.named(name).state
            let card = s.pairingProblem
            s.camera = .granted
            s = Reducer.reduce(s, .openScanner).state
            #expect(s.screen == .pairScanner, "\(name): the scanner opens")
            let backedOut = Reducer.reduce(s, .closeScanner).state
            #expect(backedOut.screen == .pairIntro && backedOut.pairingProblem == card, "\(name): the card is still there")
            let scanned = Reducer.reduce(s, .scanned(text: Scenario.link)).state
            #expect(scanned.pairingProblem == nil && scanned.pairing == .connecting, "\(name): a new code clears it")
        }
    }
}

/// A Mac whose answers wait until the test releases them, then answers every request at once.
actor GatedMac: HTTPTransport {
    private(set) var targets: [String] = []
    private var waiting: [CheckedContinuation<HTTPResponse, Never>] = []
    private var free = false

    func send(_ request: HTTPRequest, origin: String) async throws -> HTTPResponse {
        targets.append(request.method + " " + (request.target.components(separatedBy: "&auth=").first ?? request.target))
        if free {
            // The Mac has been pressed: the wait's ask is answered `{"ok":true}`, anything else as usual.
            let body = request.target == "/api/pair" ? #"{"ok":true}"# : #"{"messages":[],"more":false}"#
            return HTTPResponse(status: 200, headers: ["X-RichOS-Challenge": "c-\(targets.count)"], body: Data(body.utf8))
        }
        return await withCheckedContinuation { waiting.append($0) }
    }

    func untilWaiting(_ count: Int) async throws {
        for _ in 0..<400 where waiting.count < count { try await Task.sleep(nanoseconds: 5_000_000) }
        #expect(waiting.count >= count, "the probe reached the Mac")
    }

    func release(_ response: HTTPResponse) {
        for continuation in waiting { continuation.resume(returning: response) }
        waiting = []
    }

    func answerFreely() { free = true }
}
