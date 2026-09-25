import RichOSCore
import UIKit
@preconcurrency import UserNotifications

/// Apple's side of reply notifications for the app: the permission, the device token, and the tap.
///
/// What this does NOT do: send the registration to the Mac. That is a signed `POST /api/pair`
/// through the core's `APIClient` with the core's `PairingWire.pushRegistrationBody` (stream I1):
/// `PlatformEffects` asks `authorize()`, the network handler then calls `configurePreviews` for the
/// key and sends the body; the answer (`PushRegistration.answer`) goes back as `.notificationsResult`.
@MainActor
final class NotificationPlatform: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationPlatform()

    /// The latest APNs token, lowercase hex; `nil` until iOS gives one.
    private(set) var token: String?
    /// Called when the token arrives or changes, so the core can (re-)register with the Mac.
    var onToken: ((String) -> Void)? {
        didSet {
            // APNs can answer while the local store is still loading. Deliver that
            // token when the listener arrives, without waiting for another OS callback.
            if let token { onToken?(token) }
        }
    }
    /// Called when iOS could not register with Apple (no network to Apple, or no push entitlement).
    var onRegistrationFailed: (() -> Void)?
    /// Called for a tap on a RichOS reply notification (after strict parsing).
    var onOpen: ((NotificationTarget) -> Void)?

    /// Called from `didFinishLaunching`: becomes the delegate before any tap can be delivered, and
    /// re-registers when permission already exists (a token can change across launches).
    func start() {
        UNUserNotificationCenter.current().delegate = self
        Task {
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            if [.authorized, .provisional, .ephemeral].contains(settings.authorizationStatus) {
                UIApplication.shared.registerForRemoteNotifications()
            }
        }
    }

    /// The system question, asked once, only after the person chose "Turn on" (round-12 `notif-offer`).
    func authorize() async -> Notifications.Status {
        do {
            let granted = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
            guard granted else { return .denied }
            UIApplication.shared.registerForRemoteNotifications()
            return .turningOn
        } catch {
            return .appleUnavailable
        }
    }

    /// iOS's answer as it stands, read without asking anything (`NotificationPermissionCheck`, I04).
    func systemPermission() async -> SystemNotificationPermission {
        switch await UNUserNotificationCenter.current().notificationSettings().authorizationStatus {
        case .authorized, .provisional, .ephemeral: return .allowed
        case .denied: return .denied
        case .notDetermined: return .notDetermined
        @unknown default: return .notDetermined
        }
    }

    /// The key the Mac seals previews with, for this Mac, and the person's preview choice, mirrored
    /// into the Keychain item the notification service extension reads.
    func configurePreviews(origin: String, previews: Bool) throws -> PreviewKeyStore.Settings {
        let store = PreviewKeyStore.shared
        var settings = try store.configure(origin: origin)
        if settings.previews != previews {
            try store.setPreviews(previews)
            settings.previews = previews
        }
        return settings
    }

    func registered(deviceToken: Data) {
        let value = PushRegistration.token(deviceToken)
        guard value != token else { return }
        token = value
        onToken?(value)
    }

    // MARK: UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let userInfo = response.notification.request.content.userInfo
        if let target = NotificationTarget(userInfo: userInfo) {
            // Kept for a cold launch: the store may not exist yet (the mailbox is consumed once it does).
            NotificationRouteMailbox.shared.put(target)
            Task { @MainActor in NotificationPlatform.shared.deliverPending() }
        }
        completionHandler()
    }

    /// In the foreground the conversation is already live on screen; an alert would repeat it.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([])
    }

    /// Hands a waiting tap to whoever is listening; a no-op until then.
    func deliverPending() {
        guard let onOpen, let target = NotificationRouteMailbox.shared.take() else { return }
        onOpen(target)
    }

    // MARK: Read replies leave Notification Center (D04)

    /// Takes the notifications of replies the person has read out of Notification Center, however the
    /// app was opened. A tapped notification is already gone (iOS removes it); the others read with it
    /// follow here. Called only while the app is on screen and only when what is read changed
    /// (`RichOSNativeApp`); one read of the delivered list, one removal, no timer.
    func withdrawRead(_ read: ReadReplies.Read, hostID: String?) {
        guard hostID != nil else { return }  // not registered with this Mac: nothing can be ours
        let center = UNUserNotificationCenter.current()
        Task {
            let delivered = await center.deliveredNotifications()
                .map { (identifier: $0.request.identifier, userInfo: $0.request.content.userInfo) }
            let read = NotificationWithdrawal.identifiers(of: delivered, read: read, hostID: hostID)
            if !read.isEmpty { center.removeDeliveredNotifications(withIdentifiers: read) }
        }
    }

    /// Every RichOS notification leaves Notification Center: notifications were turned off, or the
    /// Mac was forgotten. The app posts nothing else, so this is all of its delivered notifications.
    func withdrawAll() {
        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
    }
}

/// The app delegate the SwiftUI app adopts for the two callbacks SwiftUI has no equivalent for.
/// Wired by one line in `RichOSNativeApp` (`@UIApplicationDelegateAdaptor`), requested of stream I1.
final class PlatformAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        NotificationPlatform.shared.start()
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        NotificationPlatform.shared.registered(deviceToken: deviceToken)
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        // The core shows `notif-settings` "Apple could not be reached" from `.appleUnavailable`.
        NotificationPlatform.shared.onRegistrationFailed?()
    }
}
