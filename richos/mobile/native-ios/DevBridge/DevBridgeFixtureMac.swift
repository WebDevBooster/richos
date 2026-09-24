// DEVELOPMENT ONLY. Compiled only in Debug: this file is wrapped in `#if DEBUG` AND excluded from
// Release by `EXCLUDED_SOURCE_FILE_NAMES: "DevBridge*.swift"` in `project.yml`.
//
// A STAND-IN MAC FOR THE WAIT FOR THE PRESS ON THE MAC, for gesture tests on interactive fixtures
// (`-rios-interactive-fixture YES`). Interactive fixtures run the real core, storage and clock with
// no network, so an ask of the wait (`Effect.checkMacConfirmation`) is never answered there. With
// `-rios-fixture-mac <behavior>` this answers it the way a Mac would, at the effect seam, so a UI
// test can see the screens a held ask produces (`pairing.json` `pair_wait.answers`):
//
//   unreachable      every ask is answered "no answer" at once (the phone cannot reach its Mac)
//   holds            a `pair-wait` Mac that is never pressed: each ask is held for its `Prefer`
//                    seconds, then answered still waiting
//   press-after-<ms> the same Mac, pressed <ms> after its first ask arrives: an ask held across
//                    that moment is answered pressed then, and any later ask at once
//
// Holds sleep with `Task.sleep`, so the app's cancellation on leaving the screen ends them at once.
// Every other effect is left undone, exactly as without it.
#if DEBUG
import Foundation
import RichOSCore

actor DevBridgeFixtureMac: EffectHandler {
    enum Behavior: Equatable, Sendable {
        case unreachable
        case holds
        case pressAfter(ms: Int64)
    }

    static let argument = "rios-fixture-mac"

    /// The behavior named on the launch command line, or `nil`: no stand-in, every ask unanswered.
    static func fromLaunchArguments() -> DevBridgeFixtureMac? {
        guard let raw = UserDefaults.standard.string(forKey: argument) else { return nil }
        switch raw {
        case "unreachable": return DevBridgeFixtureMac(.unreachable)
        case "holds": return DevBridgeFixtureMac(.holds)
        default:
            if raw.hasPrefix("press-after-"), let ms = Int64(raw.dropFirst("press-after-".count)), ms >= 0 {
                return DevBridgeFixtureMac(.pressAfter(ms: ms))
            }
            print("rios: fixture Mac refused: '\(raw)'; known: unreachable, holds, press-after-<ms>")
            return nil
        }
    }

    private let behavior: Behavior
    private var pressedAt: Date?

    init(_ behavior: Behavior) { self.behavior = behavior }

    nonisolated func handles(_ effect: Effect) -> Bool {
        if case .checkMacConfirmation = effect { return true }
        return false
    }

    func handle(_ effect: Effect, state: AppState) async -> [Action] {
        guard case .checkMacConfirmation(let waitSeconds) = effect else { return [] }
        let askedAt = SystemClock().nowMs()
        let answer: MacConfirmation
        switch behavior {
        case .unreachable:
            answer = .awaiting
        case .holds:
            _ = await hold(seconds: waitSeconds, until: nil)
            answer = .awaiting
        case .pressAfter(let ms):
            if pressedAt == nil { pressedAt = Date().addingTimeInterval(Double(ms) / 1000) }
            answer = await hold(seconds: waitSeconds, until: pressedAt) ? .confirmed : .awaiting
        }
        if Task.isCancelled { return [] }
        return [.macConfirmation(answer, at: SystemClock().nowMs(), askedAt: askedAt)]
    }

    /// Holds for `seconds` or until `press`, whichever comes first; `true` when the press came.
    private func hold(seconds: Int, until press: Date?) async -> Bool {
        let end = Date().addingTimeInterval(Double(max(0, seconds)))
        let stop = press.map { min($0, end) } ?? end
        let wait = stop.timeIntervalSinceNow
        if wait > 0 {
            do { try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) } catch { return false }
        }
        guard let press else { return false }
        return Date() >= press
    }
}
#endif
