import Foundation
import RichOSCore

/// "Hold the button while you speak." stays its full `Motion.tooShortLineMs` (round 12: one calm
/// line, then it goes), although the core clears its toast when the ending settles 150 ms in, so the
/// microphone is free again at once. A new recording takes its place. Nothing here decides: it only
/// keeps a line on screen that the core already said.
///
/// A port of Android's `withTooShortLine` (`RichApp.kt`). The screen holds the latched recording id
/// in its own state; these two functions are the whole rule, so a unit test can read it.
enum TooShortLine {
    /// The recording whose too-short ending is playing now, which starts (or restarts) the line.
    /// A posed fixture (`posed`: the screen's `VoiceClock.isPose`) draws at its own instant and
    /// never latches (Android: a review frame's own `voiceMomentMs` wins).
    static func ending(_ voice: VoiceSession?, posed: Bool) -> String? {
        guard let voice, case .ending(.tooShort) = voice.phase, !posed else { return nil }
        return voice.id
    }

    /// The model with the line shown while `line` is latched: only while no newer recording has
    /// started and nothing else already speaks in that place (on the iPhone every other one-line
    /// notice is a core toast).
    static func apply(_ line: String?, to model: ScreenModel) -> ScreenModel {
        guard let line, model.voice == nil || model.voice?.id == line, model.toast == nil else { return model }
        var shown = model
        shown.toast = .tooShort
        return shown
    }
}
