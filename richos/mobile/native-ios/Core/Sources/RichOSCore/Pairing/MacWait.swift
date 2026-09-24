import Foundation

/// **WAITING FOR THE PRESS ON THE MAC** (pairing v2; Sage's pairing review F1, §3.1 step 5; the
/// conformance corpus's `pairing.json` `mac_confirmation` and `pair_wait`).
///
/// After "They match" on the phone, the Mac still refuses everything this phone signs until the
/// person presses "They match" ON THE MAC too. The phone learns of that press by ASKING WITH ITS OWN
/// ANSWER: every ask is the phone's signed "They match" again, byte for byte, and the press on the
/// phone is the first ask (Sage's pair-v2 hypotheses review §1, "The fix" point 1). Every Mac with the
/// press answers it: still waiting, pressed, or its refusal. Because the ask is the answer, a first
/// "They match" lost on the way is delivered by the same request that learns of the press (§2c).
///
/// **A Mac that names `pair-wait`** in its pairing answer (ledger row S3's capability pattern) is
/// asked to hold the ask (`Prefer: wait=N`, at most 14 s and never past the deadline) and answers the
/// moment the person presses on the Mac, so the phone hears it within one round trip instead of at
/// its next scheduled ask (up to 15 s later). While that Mac holds, two asks never start less than
/// 7 s apart, so a relay that forges the capability degrades to one ask every 7 s, never a spin.
/// **A Mac that does not name it** is asked on ONE schedule and no other: 2, 3, 5, 8 and 13 seconds,
/// then every 15. Either way: never more than 22 asks after the press, never past the bound the Mac
/// gave (`confirm_within_seconds`, at most the five-minute window) except the last ask, and only
/// while the app is on screen — a person standing at his Mac, not a background refresh (the CEO's
/// battery rule, §81).
///
/// **At the deadline the phone asks ONE last time**, with no hold (Sage §2, "The fix" point 1), and
/// that answer decides: pressed is paired, a refusal is declined, anything else has expired. While
/// the Mac holds, that last ask still keeps the 7 s spacing, so it may go a few seconds after the
/// deadline. A relaunch that finds the deadline passed asks that last time too.
///
/// The numbers are the reference's (`web/web-app/lib/api.js` `macWaitDelayMs`, `macWaitBoundMs`,
/// `macWaitNextDelayMs`, `macWaitNextAskAt`); the corpus pins them and the tests replay it.
///
/// The core sets no timer. `nextAskAtMs` says when the next ask is owed, `TickSchedule` turns that
/// into the app's one timer while the app is on screen, and a `tick` at that moment asks. Leaving the
/// screen (`backgrounded`) clears it and the app cancels the ask in flight, so nothing is owed,
/// scheduled or retried off screen; coming back (`foregrounded`) asks again, no sooner than 7 s after
/// the previous ask while the Mac holds.
public struct MacWait: Codable, Equatable, Sendable {
    /// The first five waits, then `capMs` each.
    public static let delaysMs: [Int64] = [2_000, 3_000, 5_000, 8_000, 13_000]
    public static let capMs: Int64 = 15_000
    /// The Mac's own window for the press; a Mac that says more is not believed.
    public static let windowMs: Int64 = 300_000

    /// The wait before probe `attempt` (0 is the first).
    public static func delayMs(attempt: Int) -> Int64 {
        attempt >= 0 && attempt < delaysMs.count ? delaysMs[attempt] : capMs
    }

    /// The capability a Mac names, beside `pair-v2`, when it can hold an ask until the press on the
    /// Mac (`pair_wait.capability`).
    public static let pairWaitCapability = "pair-wait"
    /// The longest hold the phone asks for (`pair_wait.hold_seconds_max`): inside the 15 s between
    /// bytes the phone's routes already carry for the event stream (Sage §1, "Why 14 s").
    public static let holdSecondsMax = 14
    /// While the Mac holds, two asks never start closer together than this (`min_ask_spacing_ms`).
    public static let minAskSpacingMs: Int64 = 7_000

    /// `Prefer: wait=N` for an ask with `leftMs` to the deadline: `min(14, whole seconds left)` to a
    /// Mac that holds; 0, meaning no `Prefer`, to one that does not, or once no whole second is left.
    public static func holdSeconds(holds: Bool, leftMs: Int64) -> Int {
        guard holds, leftMs >= 1_000 else { return 0 }
        return Int(min(Int64(holdSecondsMax), leftMs / 1_000))
    }

    /// How long after an answer the next ask goes (`next_delay_cases`; the reference's
    /// `macWaitNextDelayMs`). `tookMs` is how long the previous ask took from sending to its answer.
    /// Not holding: today's schedule. Holding, and the answer took 7 s or more: at once, because the
    /// Mac held it. Holding, and it came sooner: the schedule, but never less than keeps 7 s between
    /// the two asks.
    public static func nextDelayMs(attempt: Int, tookMs: Int64, holds: Bool) -> Int64 {
        let scheduled = delayMs(attempt: attempt)
        guard holds else { return scheduled }
        let took = max(0, tookMs)
        if took >= minAskSpacingMs { return 0 }
        return max(scheduled, minAskSpacingMs - took)
    }

    /// When the next ask goes (`last_ask_cases`; the reference's `macWaitNextAskAt`): `nextDelayMs`
    /// after the answer, and never later than the deadline, where the last ask goes.
    public static func nextAskAt(attempt: Int, askedAt: Int64, answeredAt: Int64, until: Int64, holds: Bool) -> Int64 {
        let next = answeredAt + nextDelayMs(attempt: attempt, tookMs: answeredAt - askedAt, holds: holds)
        return next <= until ? next : lastAskAt(askedAt: askedAt, until: until, holds: holds)
    }

    /// The last ask: at the deadline, or, while the Mac holds, no sooner than 7 s after the previous
    /// ask. Its answer is as settled as one at the deadline, because the phone's deadline is at or
    /// after the Mac's own `confirm_by` (Sage §2b).
    public static func lastAskAt(askedAt: Int64?, until: Int64, holds: Bool) -> Int64 {
        guard holds, let askedAt else { return until }
        return max(until, askedAt + minAskSpacingMs)
    }

    /// How long the wait may last, from the pair answer's `confirm_within_seconds`. A Mac that says
    /// nothing (or nothing usable) gets the window; a Mac that says more than the window is capped.
    public static func boundMs(confirmWithinSeconds seconds: Double?) -> Int64 {
        guard let seconds, seconds.isFinite, seconds > 0 else { return windowMs }
        return min(Int64((seconds * 1000).rounded(.down)), windowMs)
    }

    /// The most asks one wait makes after the press, the last ask aside: every scheduled ask that
    /// falls inside the window. Derived from the schedule rather than typed (the corpus's
    /// `max_requests_in_the_window` is 22). A Mac that holds never reaches it inside the window
    /// (21 held asks of 14 s), and a forged `pair-wait` reaches exactly it (`pair_wait.wait_plans`).
    public static let maxRequests: Int = {
        var count = 0, at: Int64 = 0
        while at + delayMs(attempt: count) <= windowMs {
            at += delayMs(attempt: count)
            count += 1
        }
        return count
    }()

    /// This pairing's bound, from the Mac's pair answer (persisted with the pairing).
    public var boundMs: Int64
    /// When the wait ends, ms since 1970: the moment of the press on the phone (the first ask) plus
    /// the bound. `nil` until the Mac answers that ask (persisted, so a relaunch inside the bound
    /// resumes).
    public var deadlineMs: Int64?
    /// Asks sent after the press, the last ask aside; never more than `maxRequests`, relaunches
    /// included (persisted).
    public var requests: Int
    /// TRANSIENT. When the next ask is owed; `nil` while one is in flight, while the app is off
    /// screen, and before the Mac has answered the press.
    public var nextAskAtMs: Int64?
    /// TRANSIENT. An ask is on its way; its answer is the only one taken.
    public var asking: Bool
    /// TRANSIENT. The app is off screen: nothing is asked or scheduled until it returns.
    public var paused: Bool
    /// The Mac named `pair-wait` in its pairing answer: asks carry `Prefer: wait=N` and keep 7 s
    /// apart (persisted with the pairing, so a relaunch asks the same way).
    public var holds: Bool
    /// TRANSIENT. When the latest ask started, a canceled one included: the return to the screen
    /// keeps 7 s from it while the Mac holds. `nil` until the press is answered (the press on the
    /// phone carries no time) or the app leaves the screen, whichever comes first.
    public var lastAskAtMs: Int64?
    /// TRANSIENT. The ask in flight is the last one: whatever it hears ends the wait.
    public var finalAsk: Bool

    public init(boundMs: Int64 = MacWait.windowMs, deadlineMs: Int64? = nil, requests: Int = 0,
                nextAskAtMs: Int64? = nil, asking: Bool = false, paused: Bool = false, holds: Bool = false,
                lastAskAtMs: Int64? = nil, finalAsk: Bool = false) {
        self.boundMs = boundMs; self.deadlineMs = deadlineMs; self.requests = requests
        self.nextAskAtMs = nextAskAtMs; self.asking = asking; self.paused = paused
        self.holds = holds; self.lastAskAtMs = lastAskAtMs; self.finalAsk = finalAsk
    }

    private enum CodingKeys: String, CodingKey {
        case boundMs, deadlineMs, requests, nextAskAtMs, asking, paused, holds, lastAskAtMs, finalAsk
    }

    /// Lenient for the fields `pair-wait` added, so a state written before them still loads.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        boundMs = try c.decode(Int64.self, forKey: .boundMs)
        deadlineMs = try c.decodeIfPresent(Int64.self, forKey: .deadlineMs)
        requests = try c.decode(Int.self, forKey: .requests)
        nextAskAtMs = try c.decodeIfPresent(Int64.self, forKey: .nextAskAtMs)
        asking = try c.decode(Bool.self, forKey: .asking)
        paused = try c.decode(Bool.self, forKey: .paused)
        holds = try c.decodeIfPresent(Bool.self, forKey: .holds) ?? false
        lastAskAtMs = try c.decodeIfPresent(Int64.self, forKey: .lastAskAtMs)
        finalAsk = try c.decodeIfPresent(Bool.self, forKey: .finalAsk) ?? false
    }
}

/// What the Mac says about the person's "They match" press ON THE MAC.
public enum MacConfirmation: String, Codable, Sendable {
    /// Pressed on the Mac: this phone is paired.
    case confirmed
    /// Not yet (the awaiting answer), or no answer this time (unreachable, a fault): ask again. As the
    /// answer to the last ask, the wait has expired.
    case awaiting
    /// Final: the Mac forgot this phone ("They do not match" on the Mac, or its window closed).
    case refused

    /// The Mac's answer to the phone's own signed "They match" (`fingerprint_confirmed: true`), which
    /// is every ask of the wait (`pair_wait.answers`): 200 `{"ok":true,"awaiting_mac_confirmation":true}`
    /// until the press on the Mac, 200 `{"ok":true}` once it has been pressed, the awaiting 409 some
    /// routes give, a 403 revoked after "They do not match" on the Mac, a 404 once the window closed.
    /// Anything that is not a final refusal waits (the reference's `macAnswer`).
    public static func ofConfirmation(_ response: HTTPResponse) -> MacConfirmation {
        let json = (try? JSONSerialization.jsonObject(with: response.body)) as? [String: Any]
        if response.status == 200 {
            return json?["ok"] as? Bool == true && json?["awaiting_mac_confirmation"] as? Bool != true ? .confirmed : .awaiting
        }
        return ofRefusal(response)
    }

    /// `awaiting_answer_classification`: the awaiting 409 is authenticated and retryable, never a
    /// refusal. Revoked (403 `{"revoked":true}`) and the flat 403/404 are final.
    private static func ofRefusal(_ response: HTTPResponse) -> MacConfirmation {
        switch APIClient.classify(response).reason {
        case .revoked, .refused: return .refused
        case .unreachable, .fault: return .awaiting
        }
    }
}
