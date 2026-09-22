import UserNotifications

final class NotificationService: UNNotificationServiceExtension {
    private var finish: ((UNNotificationContent) -> Void)?
    private var fallback: UNNotificationContent?
    override func didReceive(_ request:UNNotificationRequest, withContentHandler contentHandler:@escaping (UNNotificationContent) -> Void) {
        finish = contentHandler; fallback = request.content
        guard let content = request.content.mutableCopy() as? UNMutableNotificationContent else { complete(request.content); return }
        // Missing keys, a disabled preview, tampering or first-unlock restrictions
        // leave the generic alert intact. No network round trip delays the alert.
        if let settings = try? NotificationPreview.load(), settings.previews,
           let key = settings.key, let text = try? NotificationPreview.decrypt(content.userInfo,key:key) { content.body = text }
        complete(content)
    }
    private func complete(_ content:UNNotificationContent) { let handler = finish; finish = nil; handler?(content) }
    override func serviceExtensionTimeWillExpire() { if let fallback { complete(fallback) } }
}
