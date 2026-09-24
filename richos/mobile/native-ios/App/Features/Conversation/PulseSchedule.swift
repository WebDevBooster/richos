import Foundation

/// When the gold dot beside "Reconnecting…" breathes, and when it stops (Foundation only, so the
/// headless checks in `native-ios-ui.test.sh` prove it on this Mac).
///
/// Round 12's pulse is 0.35 to 1 and back in 1.4 s. A Mac can stay asleep for hours, and a dot that
/// redraws the screen for that long drains the battery (Andy measured the Android twin at 31 frames
/// a second). The lead's decision, the same on both phones (Android `RichMotion.PULSE_FOR_MS`,
/// `cc/andy-opus-idle1` 0b4fabba): breathe as designed for 10 seconds, finish on a rise, then rest at
/// full opacity, drawing nothing more, until the state changes. A new "Reconnecting…" is a new dot,
/// and it breathes again.
enum PulseSchedule {
    /// One full breath, trough to trough (round 12: 700 ms each way).
    static let cycle: TimeInterval = 1.4
    /// How long it breathes before it rests.
    static let breatheFor: TimeInterval = 10
    /// The first peak at or after `breatheFor`: 10.5 s, the same moment Android's 15th 700 ms leg ends.
    static let restsAt: TimeInterval = {
        let firstPeak = cycle / 2
        return firstPeak + (((breatheFor - firstPeak) / cycle).rounded(.up)) * cycle
    }()
    static let restingOpacity = 1.0

    /// The dot's opacity `elapsed` seconds after it appeared: 0.35 at the start of each breath, 1 at
    /// its middle; from `restsAt` on, full opacity.
    static func opacity(elapsed: TimeInterval) -> Double {
        guard elapsed < restsAt else { return restingOpacity }
        let t = max(0, elapsed).truncatingRemainder(dividingBy: cycle) / cycle
        return 0.35 + 0.65 * (0.5 - 0.5 * cos(t * 2 * .pi))
    }

    /// Whether the dot still asks for frames. Once resting, or when Reduce Motion is on, it draws once.
    static func animates(elapsed: TimeInterval, reduceMotion: Bool) -> Bool {
        !reduceMotion && elapsed < restsAt
    }
}
