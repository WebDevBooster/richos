import Foundation

/// **WAITING FOR THE PRESS ON THE MAC** (pairing v2; Sage's pairing review F1, §3.1 step 5; the
/// conformance corpus's `pairing.json` `mac_confirmation`).
///
/// After "They match" on the phone, the Mac still refuses everything this phone signs until the
/// person presses "They match" ON THE MAC too, and says so with a retryable 409
/// `{"awaiting_mac_confirmation":true}`. The phone asks again on ONE schedule and no other: 2, 3, 5,
/// 8 and 13 seconds, then every 15, never past the bound the Mac gave (`confirm_within_seconds`, at
/// most the five-minute window), and only while the app is on screen. That is at most 22 requests in
/// the five minutes and none before the first 2 s: a person standing at his Mac, not a background
/// refresh (the CEO's battery rule, §81). The numbers are the reference's (`web/web-app/lib/api.js`
/// `macWaitDelayMs`, `macWaitBoundMs`); the corpus pins them and the tests replay it.
///
/// The core sets no timer. `nextAskAtMs` says when the next probe is owed, `TickSchedule` turns that
/// into the app's one timer while the app is on screen, and a `tick` at that moment asks. Leaving the
/// screen (`backgrounded`) clears it, so nothing is owed, scheduled or retried off screen; coming back
/// (`foregrounded`) asks at once or, past the bound, ends the wait truthfully.
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

    /// How long the wait may last, from the pair answer's `confirm_within_seconds`. A Mac that says
    /// nothing (or nothing usable) gets the window; a Mac that says more than the window is capped.
    public static func boundMs(confirmWithinSeconds seconds: Double?) -> Int64 {
        guard let seconds, seconds.isFinite, seconds > 0 else { return windowMs }
        return min(Int64((seconds * 1000).rounded(.down)), windowMs)
    }

    /// The most probes one wait makes: every scheduled ask that falls inside the window. Derived from
    /// the schedule rather than typed (the corpus's `max_requests_in_the_window` is 22).
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
    /// When the wait ends, ms since 1970: the Mac's answer to the phone's own "They match" plus the
    /// bound. `nil` until that answer arrives (persisted, so a relaunch inside the bound resumes).
    public var deadlineMs: Int64?
    /// TRANSIENT. Probes sent in this wait; never more than `maxRequests`.
    public var requests: Int
    /// TRANSIENT. When the next probe is owed; `nil` while one is in flight, while the app is off
    /// screen, and before the Mac has answered the phone's own "They match".
    public var nextAskAtMs: Int64?
    /// TRANSIENT. A probe is on its way; its answer is the only one taken.
    public var asking: Bool
    /// TRANSIENT. The app is off screen: nothing is asked or scheduled until it returns.
    public var paused: Bool

    public init(boundMs: Int64 = MacWait.windowMs, deadlineMs: Int64? = nil, requests: Int = 0,
                nextAskAtMs: Int64? = nil, asking: Bool = false, paused: Bool = false) {
        self.boundMs = boundMs; self.deadlineMs = deadlineMs; self.requests = requests
        self.nextAskAtMs = nextAskAtMs; self.asking = asking; self.paused = paused
    }
}

/// What the Mac says about the person's "They match" press ON THE MAC.
public enum MacConfirmation: String, Codable, Sendable {
    /// Pressed on the Mac: this phone is paired.
    case confirmed
    /// Not yet (the awaiting answer), or no answer this time (unreachable, a fault): ask again on the
    /// schedule. Never final.
    case awaiting
    /// Final: the Mac forgot this phone ("They do not match" on the Mac, or its window closed).
    case refused

    /// The Mac's answer to the phone's own signed "They match" (`fingerprint_confirmed: true`):
    /// 200 `{"ok":true,"awaiting_mac_confirmation":true}` until the press on the Mac, 200 `{"ok":true}`
    /// once it has been pressed. Anything that is not a final refusal waits, because the wait asks
    /// the Mac itself (the reference's `pair-confirm` handler).
    public static func ofConfirmation(_ response: HTTPResponse) -> MacConfirmation {
        let json = (try? JSONSerialization.jsonObject(with: response.body)) as? [String: Any]
        if response.status == 200 {
            return json?["ok"] as? Bool == true && json?["awaiting_mac_confirmation"] as? Bool != true ? .confirmed : .awaiting
        }
        return ofRefusal(response)
    }

    /// The Mac's answer to one probe, `GET /api/events?thread_id=…&before=0&limit=1` signed in the
    /// query (the reference's `macConfirmed`): answered at all is the press; the awaiting 409 is not
    /// yet; a refusal is final; any other failure waits on the same schedule.
    public static func ofProbe(_ response: HTTPResponse) -> MacConfirmation {
        (200..<300).contains(response.status) ? .confirmed : ofRefusal(response)
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
