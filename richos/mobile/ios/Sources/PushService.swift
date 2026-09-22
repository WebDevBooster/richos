import UIKit
import UserNotifications

// Apple transport only. Opt-in, registration retries and navigation are shared core actions.
final class PushService: NSObject, UNUserNotificationCenterDelegate {
    var emit: (([String: Any]) -> Void)?
    private var token: String?
    private var registrationFailed = false
    private var pending: [String: String]?
    override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            if settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional {
                DispatchQueue.main.async { UIApplication.shared.registerForRemoteNotifications() }
            }
        }
    }
    func info(_ reply: @escaping (Any?, String?) -> Void) {
        UNUserNotificationCenter.current().getNotificationSettings { [weak self] settings in
            DispatchQueue.main.async {
                guard let self else { reply(nil, "Notifications unavailable"); return }
                let permission: String
                switch settings.authorizationStatus {
                case .authorized, .provisional, .ephemeral: permission = "allowed"
                case .denied: permission = "denied"
                default: permission = "not-determined"
                }
                let preview: NotificationPreview.Settings
                do { preview = try NotificationPreview.load() } catch { reply(nil,"Notification previews could not be loaded."); return }
                var value: [String: Any] = ["permission": permission, "registrationFailed": self.registrationFailed, "previews":preview.previews]
                if permission == "allowed", let token = self.token, let topic = Bundle.main.bundleIdentifier {
                    #if DEBUG
                    let environment = "sandbox"
                    #else
                    let environment = "production"
                    #endif
                    var registration: [String:Any] = ["token":token,"topic":topic,"environment":environment,"previews":preview.previews]
                    if let key = preview.key { registration["preview_key"] = NotificationPreview.base64(key) }
                    value["registration"] = registration
                }
                reply(value, nil)
            }
        }
    }
    func request(_ reply: @escaping (Any?, String?) -> Void) {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { [weak self] granted, error in
            DispatchQueue.main.async {
                guard let self else { reply(nil, "Notifications unavailable"); return }
                if error != nil { reply(nil, "Apple notification permission could not be checked. Try again."); return }
                if granted { UIApplication.shared.registerForRemoteNotifications() }
                self.info(reply)
            }
        }
    }
    func registered(_ data: Data) {
        token = data.map { String(format: "%02x", $0) }.joined()
        registrationFailed = false
        emit?(["kind": "push-changed"])
    }
    func failed() { registrationFailed = true; emit?(["kind": "push-changed"]) }
    func receive(_ payload: [AnyHashable: Any]) {
        guard let value = payload["richos"] as? [String: String], value.count == 3,
              value["host"]?.range(of: "^[a-f0-9]{32}$", options: .regularExpression) != nil,
              value["thread"]?.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil,
              value["event"]?.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil else { return }
        pending = value; emit?(["kind": "push-open"])
    }
    func takeIncoming() -> [String: String]? { defer { pending = nil }; return pending }
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completion: @escaping () -> Void) {
        receive(response.notification.request.content.userInfo); completion()
    }
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completion: @escaping (UNNotificationPresentationOptions) -> Void) {
        // Foreground conversations already refresh through authenticated SSE.
        completion([])
    }
}
