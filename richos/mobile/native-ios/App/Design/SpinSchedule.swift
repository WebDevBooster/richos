import Foundation

/// When a looping spinner turns, and when it stops (Foundation only, so the headless checks in
/// `native-ios-ui.test.sh` prove it on this Mac).
///
/// The `.spin` ring (`Spinner`) and the "Sending…" mark (`SpinningIcon`) looped at the display's
/// full rate for as long as they were on screen — up to a request's 30 s timeout, or a minute for
/// the stream — and ignored Reduce Motion (Sage's review T4, richos-hq `e642db4f`). They follow the
/// Reconnecting dot's rule (`PulseSchedule`, the CEO's battery rule §81): turn as designed, then
/// rest, drawing nothing more until the state changes. A spinner rests at the last whole turn within
/// 10 s, so it stops where it started, without a jump. Under Reduce Motion it never turns.
enum SpinSchedule {
    /// How long a spinner may turn.
    static let turnFor: TimeInterval = 10

    /// When a spinner with one turn every `period` seconds rests: its last whole turn within 10 s.
    static func restsAt(period: TimeInterval) -> TimeInterval {
        max(1, (turnFor / period).rounded(.down)) * period
    }

    /// The spinner's angle in turns (0 at rest) `elapsed` seconds after it appeared.
    static func turn(elapsed: TimeInterval, period: TimeInterval) -> Double {
        guard elapsed > 0, elapsed < restsAt(period: period) else { return 0 }
        return (elapsed / period).truncatingRemainder(dividingBy: 1)
    }

    /// Whether the spinner still asks for frames. Once resting, or when Reduce Motion is on, it
    /// draws once.
    static func animates(elapsed: TimeInterval, period: TimeInterval, reduceMotion: Bool) -> Bool {
        !reduceMotion && elapsed < restsAt(period: period)
    }
}
