import Foundation

/// The voice gesture's thresholds, exactly as round 12's NOTES.md "Motion" table gives them. They
/// live in the core so every one is a headless test, and the views only draw the result.
public enum VoiceGeometry {
    /// Touch-down to recording: the button squishes at once, nothing records for 200 ms.
    public static let pressDelayMs: Int64 = 200
    /// Upward travel that locks (Telegram 57 dp; round 12 60 pt).
    public static let lockDistance = 60.0
    /// Lock is refused once the finger has slid more than 30% of the cancel distance.
    public static let lockRefusedAfterCancelProgress = 0.3
    /// The dead zone before the circle follows a left slide: 12% of the width.
    public static let deadZoneFraction = 0.12
    /// A release after 55% of the cancel distance also cancels.
    public static let releaseCancelsAfterProgress = 0.55
    /// A recording shorter than this sends nothing (`voice-too-short`).
    public static let tooShortMs: Int64 = 500

    /// `min(35% of the width, 140 pt)`: cancel fires mid-slide at this distance.
    public static func cancelDistance(width: Double) -> Double { min(0.35 * width, 140) }
}
