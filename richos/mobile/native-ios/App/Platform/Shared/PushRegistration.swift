import Foundation

// Compiled into the app and the macOS platform tests. Foundation only.

/// The body of the signed `POST /api/pair` that registers this phone for reply notifications
/// (phone protocol contract §7.2), and the reading of its answer.
///
/// APNs shape, unchanged by the Mac's FCM work (Echo, `cc/echo-opus-m1` 65952d16):
/// `{"native_push":{"token","environment","topic","preview_key"?,"previews"?}}`; `null` unregisters.
/// The topic is this app's bundle identifier, which the Mac must list (it lists
/// `dev.richos.native.ios` since 65952d16; a production identifier is one more entry there and in
/// the Worker's `APNS_TOPICS`).
enum PushRegistration {
    enum Environment: String, Sendable {
        case sandbox, production
    }

    /// This build's APNs environment: Debug builds are signed for development push, Release for
    /// production (the entitlement's `aps-environment`, `Release/platform.yml`).
    static var buildEnvironment: Environment {
        #if DEBUG
        return .sandbox
        #else
        return .production
        #endif
    }

    /// Lowercase hex, the only form the Mac accepts (32 to 512 characters).
    static func token(_ deviceToken: Data) -> String {
        deviceToken.map { String(format: "%02x", $0) }.joined()
    }

    static func body(token: String, environment: Environment, topic: String, previewKey: Data?, previews: Bool) throws -> Data {
        guard (32...512).contains(token.utf8.count),
              token.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw CocoaError(.coderInvalidValue)
        }
        var push: [String: Any] = ["token": token, "environment": environment.rawValue, "topic": topic, "previews": previews]
        if let previewKey {
            guard previewKey.count == 32 else { throw CocoaError(.coderInvalidValue) }
            push["preview_key"] = Base64URL.encode(previewKey)
        }
        return try JSONSerialization.data(withJSONObject: ["native_push": push], options: [.sortedKeys])
    }

    static let unregisterBody = Data(#"{"native_push":null}"#.utf8)

    enum Answer: Equatable, Sendable {
        /// 200: registered (or unregistered), with the Mac's push host id to check taps against.
        case registered(hostID: String?, registered: Bool)
        /// 422 `unsupported`: this Mac cannot send notifications.
        case unsupported
        /// 503 `unreachable`: the relay could not be reached; retry from Settings.
        case unreachable(message: String?)
        /// 404 (a registration the Mac refused, or the usual stale challenge) and anything else.
        case failed(status: Int)
    }

    /// The contract's answers (§7.2; fixtures `push.json` "native_push_responses").
    static func answer(status: Int, body: Data) -> Answer {
        let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        switch status {
        case 200:
            let host = object?["host_id"] as? String
            let valid = host.map { $0.utf8.count == 32 && $0.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } } ?? false
            return .registered(hostID: valid ? host : nil, registered: object?["registered"] as? Bool ?? false)
        case 422 where object?["reason"] as? String == "unsupported":
            return .unsupported
        case 503:
            return .unreachable(message: object?["message"] as? String)
        default:
            return .failed(status: status)
        }
    }
}
