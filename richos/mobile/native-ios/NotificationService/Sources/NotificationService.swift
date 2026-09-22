import UserNotifications

/// Opens the sealed reply preview on the phone before the alert shows (PRD §5, contract §7.3).
///
/// Runs only for notifications the relay marked `mutable-content`, which it does only when the Mac
/// sealed a preview. It never touches the network, so it adds nothing to the alert's arrival time.
/// Every failure — previews switched off, no key yet, a key for a different Mac, tampering, the
/// Keychain still locked after a restart — delivers Apple's generic "Rich has replied." unchanged.
/// The design and its fail-closed rules are the preserved app's
/// (`richos/mobile/ios/NotificationExtension/NotificationService.swift`, not modified).
final class NotificationService: UNNotificationServiceExtension {
    private var contentHandler: ((UNNotificationContent) -> Void)?
    private var original: UNNotificationContent?

    override func didReceive(_ request: UNNotificationRequest,
                             withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        self.contentHandler = contentHandler
        original = request.content
        complete(Self.rewrite(request.content) { try PreviewKeyStore.shared.load() })
    }

    /// The whole decision, separate from the extension's lifecycle so the platform tests run it on
    /// this Mac with settings they supply (no Keychain).
    static func rewrite(_ content: UNNotificationContent,
                        settings: () throws -> PreviewKeyStore.Settings) -> UNNotificationContent {
        guard let mutable = content.mutableCopy() as? UNMutableNotificationContent,
              let settings = try? settings(), settings.previews, let key = settings.key,
              let text = try? NotificationPreview.decrypt(content.userInfo, key: key) else { return content }
        mutable.body = text
        // Replies from the same conversation stack together on the lock screen.
        if let target = NotificationTarget(userInfo: content.userInfo) { mutable.threadIdentifier = target.thread }
        return mutable
    }

    override func serviceExtensionTimeWillExpire() {
        if let original { complete(original) }
    }

    private func complete(_ content: UNNotificationContent) {
        let handler = contentHandler
        contentHandler = nil
        handler?(content)
    }
}
