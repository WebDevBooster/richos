import Foundation
import Testing
@testable import RichOSCore
@testable import RichOSFixtures

/// `pairing.json` `pair_wait` (Sage's pair-v2 hypotheses review §1 and §2; Echo's handoff,
/// richos-hq `docs/verification/2026-09-24-pair-wait/HANDOFF.md`), replayed through the iOS core:
/// the wait asks with the phone's own signed "They match", sends `Prefer: wait=N` only to a Mac that
/// offers `pair-wait`, never asks twice within 7 s while that Mac holds, keeps today's schedule
/// otherwise, asks one last time at the deadline, and asks nothing off screen.
@Suite struct PairWaitConformance {
    static let origin = MacConfirmationConformance.origin

    func section() throws -> [String: Any] { try #require(try Corpus.load("pairing")["pair_wait"] as? [String: Any]) }

    /// A phone on the six words, paired by a Mac that does (or does not) offer `pair-wait`.
    func onTheWords(holds: Bool, bound seconds: Double? = nil) throws -> AppState {
        var s = try Fixture.named("pair-progress").state
        var answer = Scenario.answer
        answer.confirmWithinSeconds = seconds
        answer.offersPairWait = holds
        s = Reducer.reduce(s, .pairingAnswered(answer)).state
        s.mac?.deviceID = "dev_8d4c57b7ff82"
        return s
    }

    static func waitSeconds(_ effects: [Effect]) -> Int? {
        for effect in effects { if case .checkMacConfirmation(let seconds) = effect { return seconds } }
        return nil
    }

    /// The constants, read from the corpus rather than retyped; the app's request timeout outlasts
    /// the longest hold.
    @Test func theConstantsAreTheCorpusNumbers() throws {
        let c = try section()
        #expect(MacWait.pairWaitCapability == c["capability"] as? String)
        #expect(PairingWire.pairV2Capability == c["offered_beside"] as? String)
        #expect(MacWait.holdSecondsMax == c["hold_seconds_max"] as? Int)
        #expect(MacWait.minAskSpacingMs == Int64(try #require(c["min_ask_spacing_ms"] as? Int)))
        let mustExceed = try #require(c["request_timeout_must_exceed_ms"] as? Int)
        #expect(URLSessionTransport.defaultRequestTimeout * 1000 > Double(mustExceed),
                "a held ask must not time out on the phone before the Mac answers it")
        #expect(c["prefer_header"] as? String == "Prefer: wait=<seconds>")
    }

    /// `next_delay_cases`: every case, exactly.
    @Test func everyNextDelayIsTheCorpus() throws {
        let cases = try Corpus.cases(try section(), "next_delay_cases")
        #expect(cases.count == 70)
        for c in cases {
            let attempt = try #require(c["attempt"] as? Int)
            let took = Int64(try #require(c["previous_ask_took_ms"] as? Int))
            let holds = try #require(c["mac_offers_pair_wait"] as? Bool)
            let want = Int64(try #require(c["next_ask_after_ms"] as? Int))
            #expect(MacWait.nextDelayMs(attempt: attempt, tookMs: took, holds: holds) == want,
                    "attempt \(attempt), took \(took) ms, holds \(holds)")
        }
    }

    /// `last_ask_cases`: the last ask goes at the deadline, and while the Mac holds it keeps 7 s spacing.
    @Test func everyLastAskIsTheCorpus() throws {
        let cases = try Corpus.cases(try section(), "last_ask_cases")
        #expect(cases.count == 4)
        for c in cases {
            let got = MacWait.nextAskAt(attempt: try #require(c["attempt"] as? Int),
                                        askedAt: Int64(try #require(c["previous_ask_at_ms"] as? Int)),
                                        answeredAt: Int64(try #require(c["previous_answer_at_ms"] as? Int)),
                                        until: Int64(try #require(c["deadline_ms"] as? Int)),
                                        holds: try #require(c["mac_offers_pair_wait"] as? Bool))
            #expect(got == Int64(try #require(c["next_ask_at_ms"] as? Int)), "\(c["name"] as? String ?? "?")")
        }
    }

    /// `asks[]`: each ask is the recorded signed request — the phone's own They match, byte for byte,
    /// with `Prefer` present if and only if the ask holds, and outside the signature — and each
    /// recorded answer ends as recorded.
    @Test func everyAskIsTheRecordedRequestAndEndsAsRecorded() async throws {
        let asks = try Corpus.cases(try section(), "asks")
        #expect(asks.count == 6)
        for ask in asks {
            let name = ask["name"] as? String ?? "?"
            let seconds = try #require(ask["wait_seconds"] as? Int)
            let recorded = try #require((ask["requests"] as? [[String: Any]])?.first)
            let signed = try #require(recorded["signed"] as? [String: Any])
            let macAnswer = try #require(ask["mac_answer"] as? [String: Any])
            let mac = ScriptedMac([["status": 200, "headers": ["X-RichOS-Challenge": signed["challenge"] as Any]], macAnswer])
            let network = NetworkEffects(transport: mac, stream: ScriptedStream([]), identities: CorpusIdentityStore(), clock: FixedClock(ms: 9_000))
            var s = Reducer.reduce(try onTheWords(holds: seconds > 0), .confirmWords).state
            s.mac?.deviceID = "dev_8d4c57b7ff82"
            let answers = await network.handle(.checkMacConfirmation(waitSeconds: seconds), state: s)
            let sent = await mac.requests
            #expect(sent.map(\.target) == ["/api/challenge", "/api/pair"], "\(name): a challenge, then the ask")
            let ours = try #require(sent.last)
            let headers = try #require(recorded["headers"] as? [String: String])
            #expect(ours.method == recorded["method"] as? String && ours.target == recorded["target"] as? String, "\(name)")
            #expect(Set(ours.headers.keys) == Set(headers.keys), "\(name): exactly the recorded headers, \(ours.headers.keys.sorted())")
            #expect(ours.headers["Content-Type"] == headers["Content-Type"] && ours.headers["Prefer"] == headers["Prefer"],
                    "\(name): Prefer is \(headers["Prefer"] ?? "absent")")
            #expect(ours.body == Corpus.body(recorded), "\(name): the phone's own They match, byte for byte")
            let verdict = MacVerifier.verify(["method": ours.method, "target": ours.target, "headers": ours.headers,
                                              "body": ["utf8": String(decoding: ours.body ?? Data(), as: UTF8.self)]],
                                             publicKey: Corpus.testKey.publicKey)
            #expect(verdict.accepted && verdict.signingString == signed["signing_string"] as? String,
                    "\(name): the recorded signing string, Prefer outside it, and our signature verifies")
            let outcome = try #require(ask["outcome"] as? [String: Any])
            let want: MacConfirmation
            if outcome["ok"] as? Bool == true {
                want = outcome["value"] as? Bool == true ? .confirmed : .awaiting
            } else {
                want = .refused
                let reason = (outcome["error"] as? [String: Any])?["reason"] as? String
                let response = HTTPResponse(status: try #require(macAnswer["status"] as? Int))
                #expect(APIClient.classify(response).reason.rawValue == reason || reason == "revoked", "\(name): \(reason ?? "?")")
            }
            #expect(answers == [.macConfirmation(want, at: 9_000, askedAt: 9_000)], "\(name): \(want)")
        }
    }

    /// `answers`: every answer shape takes the recorded action, the 409 included.
    @Test func everyAnswerShapeIsClassifiedAsRecorded() throws {
        let answers = try #require(try section()["answers"] as? [String: [String: Any]])
        let want: [String: MacConfirmation] = ["pressed": .confirmed, "still_waiting": .awaiting, "still_waiting_as_409": .awaiting,
                                              "refused_on_the_mac": .refused, "window_closed": .refused]
        for (name, expected) in want {
            let a = try #require(answers[name])
            let body: Data
            switch a["body"] {
            case let text as String: body = Data(text.utf8)
            case let object?: body = try JSONSerialization.data(withJSONObject: object)
            case nil: body = Data()
            }
            #expect(MacConfirmation.ofConfirmation(HTTPResponse(status: try #require(a["status"] as? Int), body: body)) == expected, "\(name)")
        }
        #expect(answers["unreachable"]?["status"] is NSNull, "unreachable is no answer at all: the network effect waits on it")
    }

    /// `wait_plans`: the whole wait through the reducer and the app's one timer on a fake clock, over
    /// a Mac that is never pressed: exactly the recorded asks, holds and final ask, then the end.
    @Test func everyWaitPlanIsTheCorpus() throws {
        let plans = try Corpus.cases(try section(), "wait_plans")
        #expect(plans.count == 3)
        let t0: Int64 = 1_790_000_000_000
        for plan in plans {
            let name = plan["name"] as? String ?? "?"
            let holds = try #require(plan["mac_offers_pair_wait"] as? Bool)
            let forged = name.contains("forges")
            var (s, effects) = Reducer.reduce(try onTheWords(holds: holds), .confirmWords)
            var t = t0
            var asked: [[String: Any]] = []
            var wakeups = 0
            while let seconds = Self.waitSeconds(effects) {
                asked.append(["at_ms": t - t0, "prefer_wait_seconds": seconds > 0 ? seconds as Any : NSNull(), "final": s.macWait?.finalAsk == true])
                // A Mac that holds answers when the hold runs out; a forged capability, or none, at once.
                let answeredAt = t + (holds && !forged ? Int64(seconds) * 1000 : 0)
                s = Reducer.reduce(s, .macConfirmation(.awaiting, at: answeredAt, askedAt: t)).state
                effects = []
                guard let due = TickSchedule.nextTick(s) else { break }
                wakeups += 1
                if wakeups > 60 { Issue.record("\(name): the timer spins"); break }
                t = due
                (s, effects) = Reducer.reduce(s, .tick(at: due))
            }
            let expected = try Corpus.cases(plan, "asks")
            #expect(asked.count == plan["total_asks"] as? Int && asked.count == expected.count, "\(name): \(asked.count) asks")
            for (i, (ours, theirs)) in zip(asked, expected).enumerated() {
                #expect(ours["at_ms"] as? Int64 == Int64(try #require(theirs["at_ms"] as? Int)), "\(name) ask \(i): at \(ours["at_ms"] ?? "?")")
                #expect((ours["prefer_wait_seconds"] as? Int) == (theirs["prefer_wait_seconds"] as? Int), "\(name) ask \(i): Prefer")
                #expect(ours["final"] as? Bool == theirs["final"] as? Bool, "\(name) ask \(i): final")
            }
            let gaps = zip(asked.dropFirst(), asked).map { ($0["at_ms"] as? Int64 ?? 0) - ($1["at_ms"] as? Int64 ?? 0) }
            #expect(gaps.min() == Int64(try #require(plan["smallest_gap_between_asks_ms"] as? Int)), "\(name): the smallest gap")
            #expect(s.screen == .pairIntro && s.pairingProblem == .macAnswerExpired && s.macWait == nil && s.mac == nil,
                    "\(name): the last ask was answered still waiting, so the wait ended, truthfully")
            #expect(TickSchedule.nextTick(s) == nil, "\(name): and nothing more is owed")
        }
    }

    /// The Mac's pairing answer decides whether the phone asks it to hold: `pair-wait` beside
    /// `pair-v2` in `capabilities` (ledger row S3), through the real pairing exchange.
    @Test func thePairingAnswerSaysWhetherTheMacHolds() async throws {
        let v2 = try #require(try Corpus.load("pairing")["pair_v2"] as? [String: Any])
        let exchange = try #require(try Corpus.cases(v2, "exchanges").first { $0["refused_for_missing_pair_v2"] as? Bool != true })
        let answers = try #require(exchange["mac_answers"] as? [[String: Any]])
        for holds in [true, false] {
            var scripted = answers
            if !holds, var body = scripted[0]["body"] as? [String: Any] {
                body["capabilities"] = (body["capabilities"] as? [String] ?? []).filter { $0 != MacWait.pairWaitCapability }
                scripted[0]["body"] = body
            }
            let network = NetworkEffects(transport: ScriptedMac(scripted), stream: ScriptedStream([]), identities: CorpusIdentityStore())
            let host = try await HeadlessHost(storage: MemoryStorage(), handler: network)
            let s = try await host.dispatch(.submitPairingLink(text: Self.origin + "/#pair=K7M2QX9H"))
            #expect(s.screen == .pairWords && s.macWait?.holds == holds, "offers pair-wait: \(holds)")
            let (_, effects) = Reducer.reduce(s, .confirmWords)
            #expect(Self.waitSeconds(effects) == (holds ? MacWait.holdSecondsMax : 0), "the press asks with Prefer only to a Mac that holds")
        }
    }
}

/// The wait's life on the phone, around the vectors: the press is the first ask, leaving the
/// screen cancels, the return keeps the spacing while the Mac holds, and the last ask decides.
@Suite struct PairWaitLifecycleTests {
    static let origin = MacConfirmationConformance.origin

    func holding(deadline: Int64, holds: Bool = true, requests: Int = 0) -> AppState {
        var s = AppState()
        s.pairing = .awaitingMac
        s.mac = MacLink(origin: Self.origin, route: .tailnet, deviceID: "dev_8d4c57b7ff82", threadID: "thr_5c1e")
        s.fingerprintWords = ["gazelle", "coral", "lettuce", "grape", "kayak", "camera"]
        s.macWait = MacWait(boundMs: MacWait.windowMs, deadlineMs: deadline, requests: requests, paused: true, holds: holds)
        return s
    }

    /// The press is the first ask: the same signed They match, held by a Mac that offers it, for no
    /// longer than the bound the Mac gave; the next ask counts from the press.
    @Test func thePressIsTheFirstAskAndHoldsOnlyWhereOffered() throws {
        for (holds, seconds, want) in [(true, nil as Double?, 14), (true, 10.0, 10), (false, nil, 0)] {
            var s = try Fixture.named("pair-progress").state
            var answer = Scenario.answer
            answer.confirmWithinSeconds = seconds
            answer.offersPairWait = holds
            s = Reducer.reduce(s, .pairingAnswered(answer)).state
            let (asked, effects) = Reducer.reduce(s, .confirmWords)
            #expect(effects == [.persist, .checkMacConfirmation(waitSeconds: want)], "holds \(holds), bound \(seconds ?? 300) s")
            #expect(!effects.contains(.confirmFingerprint(matches: true)), "the press is not a separate request any more")
            #expect(asked.macWait?.asking == true && asked.macWait?.requests == 0 && asked.screen == .pairAwaitingMac)
            // The Mac held it for as long as it was asked: the deadline counts from the press, and the
            // next ask goes at once. A Mac that does not hold answered at once: today's 2 s.
            let t0: Int64 = 1_000_000
            let answeredAt = t0 + Int64(want) * 1_000
            let held = Reducer.reduce(asked, .macConfirmation(.awaiting, at: answeredAt, askedAt: t0)).state
            let bound = MacWait.boundMs(confirmWithinSeconds: seconds)
            #expect(held.macWait?.deadlineMs == t0 + bound, "the bound counts from the press, not from the held answer")
            #expect(held.macWait?.nextAskAtMs == (holds ? answeredAt : t0 + 2_000), "holds: at once; otherwise today's 2 s")
        }
    }

    /// A Mac that holds is never asked twice within 7 s: not after a quick answer, and not on a
    /// return to the screen. A Mac that does not hold keeps today's rule: the return asks at once.
    @Test func leavingCancelsAndTheReturnKeepsTheSpacingWhileTheMacHolds() {
        let t0: Int64 = 1_000_000
        for holds in [true, false] {
            var (s, effects) = Reducer.reduce(holding(deadline: t0 + 300_000, holds: holds), .foregrounded(at: t0))
            #expect(PairWaitConformance.waitSeconds(effects) == (holds ? 14 : 0), "on screen: one ask at once")
            s = Reducer.reduce(s, .backgrounded(at: t0 + 2_000)).state
            #expect(s.macWait?.asking == false && s.macWait?.paused == true && TickSchedule.nextTick(s) == nil, "off screen: nothing owed")
            (s, effects) = Reducer.reduce(s, .foregrounded(at: t0 + 3_000))
            if holds {
                #expect(PairWaitConformance.waitSeconds(effects) == nil && s.macWait?.nextAskAtMs == t0 + 7_000,
                        "back within 7 s of the last ask: the ask waits for the spacing")
                (s, effects) = Reducer.reduce(s, .tick(at: t0 + 7_000))
                #expect(PairWaitConformance.waitSeconds(effects) == 14, "then it asks, held again")
            } else {
                #expect(PairWaitConformance.waitSeconds(effects) == 0, "a Mac that does not hold: the return asks at once")
            }
            // A quick answer from a Mac that says it holds (a forged capability) still waits 7 s.
            let quick = Reducer.reduce(s, .macConfirmation(.awaiting, at: (holds ? t0 + 7_050 : t0 + 3_050), askedAt: holds ? t0 + 7_000 : t0 + 3_000)).state
            // Holds: the third ask's quick answer still leaves 7 s between asks. Not holding: today's 5 s.
            #expect(quick.macWait?.nextAskAtMs == (holds ? t0 + 7_000 + 7_000 : t0 + 3_050 + 5_000), "holds \(holds)")
        }
    }

    /// The last ask decides (Sage §2): at the deadline (or, while the Mac holds, 7 s after the previous
    /// ask), with no Prefer. Pressed means paired, a refusal means declined, anything else expired.
    @Test func theLastAskDecides() {
        let t0: Int64 = 1_000_000
        let deadline = t0 + 300_000
        for (answer, pairing, problem) in [(MacConfirmation.confirmed, Pairing.paired, nil as PairingProblem?),
                                           (.refused, .unpaired, .notAcceptedByMac), (.awaiting, .unpaired, .macAnswerExpired)] {
            // The press landed after the phone's last scheduled ask: at the ceiling, the next ask is the last.
            var s = Reducer.reduce(holding(deadline: deadline, holds: false, requests: MacWait.maxRequests), .foregrounded(at: t0 + 290_000)).state
            #expect(s.macWait?.asking == false && s.macWait?.nextAskAtMs == deadline, "at the ceiling the phone waits for the deadline")
            let (last, effects) = Reducer.reduce(s, .tick(at: deadline))
            #expect(effects == [.checkMacConfirmation(waitSeconds: 0)] && last.macWait?.finalAsk == true, "one last ask, no Prefer")
            s = Reducer.reduce(last, .macConfirmation(answer, at: deadline + 80, askedAt: deadline)).state
            #expect(s.pairing == pairing && s.pairingProblem == problem && TickSchedule.nextTick(s) == nil, "\(answer)")
        }
    }

    /// A relaunch that finds the deadline already passed asks once too — while a Mac that holds keeps
    /// the 7 s spacing it asks at once, because nothing from before the relaunch is in flight.
    @Test func aRelaunchPastTheDeadlineAsksOnceMore() throws {
        let t0: Int64 = 1_000_000
        for holds in [true, false] {
            let restored = try AppState(restoring: holding(deadline: t0 + 300_000, holds: holds, requests: 7).persisted)
            #expect(restored.macWait?.holds == holds && restored.macWait?.requests == 7 && restored.macWait?.paused == true,
                    "whether the Mac holds survives a relaunch")
            let (s, effects) = Reducer.reduce(restored, .foregrounded(at: t0 + 400_000))
            #expect(effects.contains(.checkMacConfirmation(waitSeconds: 0)) && s.macWait?.finalAsk == true && s.screen == .pairAwaitingMac,
                    "past the deadline: one last ask, with no hold")
            let heard = Reducer.reduce(s, .macConfirmation(.confirmed, at: t0 + 400_100, askedAt: t0 + 400_000)).state
            #expect(heard.pairing == .paired, "pressed on the Mac while the app was closed: paired")
            // Canceled by leaving the screen, the last ask is asked again on the return, never more often.
            let away = Reducer.reduce(s, .backgrounded(at: t0 + 400_050)).state
            let back = Reducer.reduce(away, .foregrounded(at: t0 + 420_000))
            #expect(back.effects.contains(.checkMacConfirmation(waitSeconds: 0)) && back.state.macWait?.finalAsk == true)
        }
    }

    /// The real store and network effects: a held ask is canceled when the app leaves the screen and
    /// its answer changes nothing; the return inside 7 s asks nothing until the spacing allows.
    @MainActor @Test func theStoreCancelsTheHeldAskAndTheReturnKeepsTheSpacing() async throws {
        let mac = HoldingMac()
        let network = NetworkEffects(transport: mac, stream: LifecycleStream(), identities: PairedMemoryIdentityStore(),
                                     clock: FixedClock(ms: 1_000_000), sleep: { _ in throw CancellationError() })
        await network.setSink { _ in }
        let t0: Int64 = 1_000_000
        let store = AppStore(state: holding(deadline: t0 + 300_000), runner: EffectRunner(storage: MemoryStorage(), handler: network))
        store.becameActive(at: t0)
        #expect(store.state.macWait?.asking == true)
        try await mac.untilHeld(1)
        #expect(await mac.prefers == ["wait=14"], "the ask is held with Prefer: wait=14")
        store.wentToBackground(at: t0 + 2_000)
        #expect(store.state.macWait?.paused == true && TickSchedule.nextTick(store.state) == nil)
        await mac.release(HTTPResponse(status: 200, headers: ["X-RichOS-Challenge": "c1"], body: Data(#"{"ok":true}"#.utf8)))
        await store.settle()
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(store.state.pairing == .awaitingMac && store.state.macWait?.asking == false, "the canceled ask's answer changed nothing")
        store.becameActive(at: t0 + 3_000)
        await store.settle()
        #expect(store.state.macWait?.asking == false && store.state.macWait?.nextAskAtMs == t0 + 7_000,
                "back within 7 s: the next ask waits for the spacing")
        #expect(await mac.asks == 1, "no second ask yet")
    }
}

/// A Mac that holds every ask until the test releases it, recording each ask's `Prefer`.
actor HoldingMac: HTTPTransport {
    private(set) var prefers: [String] = []
    private(set) var asks = 0
    private var held: [CheckedContinuation<HTTPResponse, Never>] = []

    func send(_ request: HTTPRequest, origin: String) async throws -> HTTPResponse {
        if request.target == "/api/challenge" { return HTTPResponse(status: 200, headers: ["X-RichOS-Challenge": "c0"]) }
        asks += 1
        prefers.append(request.headers["Prefer"] ?? "none")
        return await withCheckedContinuation { held.append($0) }
    }

    func untilHeld(_ count: Int) async throws {
        for _ in 0..<400 where held.count < count { try await Task.sleep(nanoseconds: 5_000_000) }
        #expect(held.count >= count, "the ask reached the Mac")
    }

    func release(_ response: HTTPResponse) {
        for continuation in held { continuation.resume(returning: response) }
        held = []
    }
}
