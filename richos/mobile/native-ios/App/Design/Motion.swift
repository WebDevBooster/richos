import SwiftUI

/// Round 12's motion, in SwiftUI (`round-12/NOTES.md` "Motion — the numbers, for SwiftUI"; the three
/// curves are `app.css` lines 22–24). Durations are the NOTES' milliseconds; nothing here is tuned by
/// eye.
enum Motion {
    /// `cubic-bezier(.34, 1.56, .64, 1)` — the overshooting spring of the lock badge, dialogs and the
    /// ghost that flies into a sent voice bubble.
    static func spring(_ ms: Double) -> Animation { .timingCurve(0.34, 1.56, 0.64, 1, duration: ms / 1000) }
    /// `cubic-bezier(.22, 1, .36, 1)` — rows, cards and sheets entering.
    static func outQuint(_ ms: Double) -> Animation { .timingCurve(0.22, 1, 0.36, 1, duration: ms / 1000) }
    /// `cubic-bezier(.45, 0, .55, 1)` — pulses, nudges, the timer's roll out.
    static func inOut(_ ms: Double) -> Animation { .timingCurve(0.45, 0, 0.55, 1, duration: ms / 1000) }

    /// Rows enter with a 10 pt rise and 0.96 → 1 scale over 320 ms.
    static let rowIn = outQuint(320)
    /// Sheets: 380 ms.
    static let sheet = outQuint(380)
    /// Dialogs: 320 ms spring from 0.9.
    static let dialog = spring(320)
    /// Cards above the composer: 320 ms (toasts 280 ms).
    static let card = outQuint(320)
    static let toast = outQuint(280)
    /// "Hold the button while you speak." stays 1.8 s (Android `RichMotion.TOO_SHORT_LINE_MS`).
    static let tooShortLineMs: Double = 1_800
    /// The Latest pill: 280 ms.
    static let latest = outQuint(280)
    /// The mic → send arrow cross-fade while typing, and at the lock (70 ms).
    static let glyphMorph = Animation.easeOut(duration: 0.07)

    /// Voice gesture numbers (NOTES "Motion"). Kept here so the view and its tests read one table;
    /// the thresholds that decide outcomes are the core's (build plan §3.2), these are how they look.
    enum Voice {
        /// The circle's resting size inside the capsule.
        static let orbDiameter: CGFloat = 44
        /// Touch-down squish.
        static let pressScale: CGFloat = 0.9
        /// The swell: 44 → 2.2× in 75 ms, then a 200 ms settle 2.2 → 2.0 → 2.2.
        static let heldScale: CGFloat = 2.2
        static let swellMs: Double = 75
        static let settleMs: Double = 200
        /// Breathing: scale = 2.2 + 0.7 × level.
        static let breath: CGFloat = 0.7
        /// The lock pill rests 96 pt above the anchor, the closed badge 72 pt.
        static let pillRest: CGFloat = 96
        static let pillLocked: CGFloat = 72
        static let lockDistance: CGFloat = 60
        /// Slide-left dead zone: 12% of the width; the circle shrinks to 58% at the cancel point.
        static let deadZone: CGFloat = 0.12
        static let shrinkAtCancel: CGFloat = 0.42
        /// Cancel distance: min(35% of the width, 140 pt).
        static func cancelDistance(width: CGFloat) -> CGFloat { min(0.35 * width, 140) }
        /// Red dot period, the hint's nudge, the timer digit roll.
        static let dotPeriod: Double = 1.25
        static let nudge: CGFloat = 9
        static let nudgePeriod: Double = 2.0
        static let rollMs: Double = 140
        /// The bin ritual (from hold): 850 ms; the locked cancel: 950 ms.
        static let binMs: Double = 850
        static let lockedCancelMs: Double = 950
        /// Send: the circle collapses over 120 ms while its ghost flies 320 ms into the bubble.
        static let collapseMs: Double = 120
        static let ghostMs: Double = 320
    }
}

extension View {
    /// Round 12's row entrance: from 10 pt lower, 96% scale and transparent.
    func rowEntrance() -> some View {
        transition(.asymmetric(
            insertion: .modifier(active: RowEntrance(progress: 0), identity: RowEntrance(progress: 1)),
            removal: .opacity))
    }
}

private struct RowEntrance: ViewModifier {
    let progress: CGFloat
    func body(content: Content) -> some View {
        content
            .opacity(progress)
            .scaleEffect(0.96 + 0.04 * progress)
            .offset(y: 10 * (1 - progress))
    }
}
