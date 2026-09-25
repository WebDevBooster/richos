import Foundation

/// THE APP'S ONE TIMER, as a rule the core owns (the Android `AppStore`'s one timer, richos main
/// `c5f04574`; the reference queue's rule 5: the core sets no timer, it says when time is owed).
///
/// `tick` moves four things and nothing else: a recording that is running (the press delay and the
/// ceiling), the quiet period before "Reconnecting…", an outbox item's retry, and pairing v2's next
/// probe for the press on the Mac (`MacWait`). `nextTick` says
/// when the next tick would change one of them, or `nil` when nothing needs time. An idle app is
/// owed nothing, so the app sleeps: no periodic wakeup, no new state, no frame (the CEO's battery
/// rule, 2026-09-24, `richos/mobile/AGENTS.md` "Wakeups and timers").
///
/// The rule the app relies on (a test): a tick at or after the time returned leaves a state whose
/// next tick is later, or `nil`. So a timer restarted only when this value changes cannot spin.
public enum TickSchedule {
    /// While a recording runs, the cadence that drives the press delay, the ceiling and the state's
    /// `nowMs` (Android `VOICE_TICK_MS`).
    public static let voiceCadenceMs: Int64 = 100

    /// When the next `tick` is owed (milliseconds since 1970), or `nil` when nothing in `s` needs time.
    public static func nextTick(_ s: AppState) -> Int64? {
        [voice(s), notice(s), outbox(s), macWait(s)].compactMap { $0 }.min()
    }

    /// Pairing v2's next probe for the press on the Mac (`MacWait`): owed only while the phone waits
    /// on screen with no probe in flight. Off screen (`paused`) nothing is owed, so nothing wakes.
    static func macWait(_ s: AppState) -> Int64? {
        guard s.pairing == .awaitingMac, let w = s.macWait, !w.paused, !w.asking else { return nil }
        return w.nextAskAtMs
    }

    /// A recording that is running: pressed, held or locked. One that has ENDED is not running — its
    /// end plays on the screen's own clock, and a tick then would only restamp the time (Android's
    /// `AppStoreIdleTest`: ten new states a second, forever, after a tap on the microphone). Nothing
    /// runs while the system asks for the microphone. The ticks sit on a grid from the press, so a
    /// finger's moves, which restamp `nowMs`, never push the next one away.
    static func voice(_ s: AppState) -> Int64? {
        guard let v = s.voice, s.sheet != .microphonePrompt else { return nil }
        switch v.phase {
        case .pressed, .held, .locked:
            let elapsed = max(0, v.nowMs - v.startedAtMs)
            return v.startedAtMs + (elapsed / voiceCadenceMs + 1) * voiceCadenceMs
        case .ending:
            return nil
        }
    }

    /// A routine drop shows nothing for `ConnectionReducer.quietMs`; the tick that ends the quiet
    /// period is owed once, at its end (Android `noticeDueInMs`).
    static func notice(_ s: AppState) -> Int64? {
        guard let since = s.troubleSinceMs, s.connectionNotice == nil else { return nil }
        return since + ConnectionReducer.quietMs
    }

    /// The outbox head's retry, under exactly the conditions `ConversationReducer.pump` would move it:
    /// paired, the Mac's stream open, nothing in flight, the phone online and the Mac not incompatible.
    /// With the stream down nothing is owed: the stream's own back-off asks the Mac, and `connected`
    /// moves the queue (I06).
    static func outbox(_ s: AppState) -> Int64? {
        guard s.pairing == .paired, s.linkOpen, !s.outbox.contains(where: { $0.state == .sending }) else { return nil }
        switch s.connectionNotice {
        case .phoneOffline?, .incompatible?: return nil
        default: break
        }
        return s.outbox.first(where: { $0.state == .waiting })?.notBefore
    }
}
