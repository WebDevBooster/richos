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
            // What is already delivered goes too, the Telegram way (D04).
            effects.append(.withdrawNotifications)
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
            // Whatever the setting says now, nothing about a forgotten Mac stays on this phone (D04).
            effects.append(.withdrawNotifications)
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
