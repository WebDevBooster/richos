import Foundation

/// Notifications and Settings, round-12 groups 8 and 9.
///
/// Notifications are opt-in and asked once, in a card with a real "Not now" (`notif-offer`); every
/// status is a sentence in Settings (`notif-settings`). Forgetting the pairing is refused while unsent
/// work exists (`settings-forget-blocked`), and otherwise is local: notifications are turned off
/// first, then the key and the pairing go (contract §2.6; the preserved client's order).
enum SettingsReducer {
    static func reduce(_ s: inout AppState, _ action: Action, _ effects: inout [Effect]) {
        switch action {
        case .turnOnNotifications:
            guard s.pairing == .paired, s.notifications.status != .on, s.notifications.status != .turningOn else { return }
            s.notifications.status = .turningOn
            effects.append(.requestNotifications(previews: s.notifications.previews))
        case .notificationsResult(let status):
            s.notifications.status = status
            if status == .on { s.notifications.offerDismissed = true }
        case .turnOffNotifications:
            guard s.notifications.status == .on || s.notifications.status == .turningOn else { return }
            s.notifications.status = .off
            effects.append(.unregisterNotifications)
        case .dismissNotificationOffer:
            s.notifications.offerDismissed = true
        case .setPreviews(let on):
            guard s.notifications.previews != on else { return }
            s.notifications.previews = on
            if s.notifications.status == .on { effects.append(.requestNotifications(previews: on)) }
        case .forgetPairing:
            guard s.pairing == .paired || s.pairing == .revoked else { return }
            s.sheet = s.outbox.isEmpty ? .forget : .forgetBlocked
        case .confirmForget:
            guard s.sheet == .forget, s.outbox.isEmpty else { return }
            if s.notifications.status == .on || s.notifications.status == .turningOn { effects.append(.unregisterNotifications) }
            effects.append(.disconnect)
            if let origin = s.mac?.origin { effects.append(.forgetIdentity(origin: origin)) }
            // His recordings are kept: nothing unsent is ever discarded silently.
            let kept = s.keptRecordings
            let appearance = s.appearance
            s = AppState()
            s.keptRecordings = kept
            s.appearance = appearance
        case .openSystemSettings:
            effects.append(.openSystemSettings)
        default:
            break
        }
    }
}

/// Update notices, round-12 group 10, from the hosted policy (contract §5.10; PRD §9.1). A banner and
/// a dialog can be dismissed; a required update cannot, but Support and the reassurance stay.
enum UpdateReducer {
    static func reduce(_ s: inout AppState, _ action: Action, _ effects: inout [Effect]) {
        switch action {
        case .updatePolicy(let notice, let voicePaused):
            s.update = notice
            if voicePaused {
                s.voiceAvailability = .pausedByPolicy
            } else if s.voiceAvailability == .pausedByPolicy {
                s.voiceAvailability = .available
            }
        case .dismissUpdate:
            guard let notice = s.update, notice.prominence != .required else { return }
            s.update = nil
        case .openAppStore:
            effects.append(.openAppStore)
        case .openSupport:
            effects.append(.openSupport)
        case .checkForUpdates:
            effects.append(.openAppStore)
        case .openPrivacyPolicy:
            effects.append(.openPrivacyPolicy)
        default:
            break
        }
    }
}

/// iOS's own notification permission, as the app reads it on coming to the front.
public enum SystemNotificationPermission: String, Sendable {
    /// Never asked (the app has no entry under iPhone Settings > Notifications yet).
    case notDetermined
    case denied
    /// Authorized, provisional or ephemeral.
    case allowed
}

/// The way back from iPhone Settings (I04; Android's `reconcileNow`, `Notifications.kt`). On launch
/// and each return to the front the app reads iOS's answer once and tells the core only what changed:
/// allowed again after a denial registers again (no prompt: iOS already said yes) instead of staying
/// "Off in iPhone Settings" for good; turned off in iPhone Settings while on reads as denied, with its
/// Open Settings button. Nothing is asked here and nothing repeats: an answer that matches the state
/// changes nothing, and "Not now" (never asked) is left alone. "On" was iOS's own yes, so an ambiguous
/// "never asked" read leaves it alone too (as Android, whose only reading is granted or not).
public enum NotificationPermissionCheck {
    public static func action(system: SystemNotificationPermission, state: AppState) -> Action? {
        guard state.pairing == .paired else { return nil }
        switch (state.notifications.status, system) {
        case (.denied, .allowed):
            return .turnOnNotifications
        case (.denied, .notDetermined):
            // iPhone Settings has no entry to send the person to: the app's own switch is the way on.
            return .notificationsResult(.off)
        case (.on, .denied), (.serviceUnavailable, .denied):
            return .notificationsResult(.denied)
        default:
            return nil
        }
    }
}
