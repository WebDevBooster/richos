import Foundation
import RichOSCore

// Compiled into the app and the macOS platform tests. Foundation only.

/// The platform facts of the signed `POST /api/pair` that registers this phone for reply
/// notifications (phone protocol contract §7.2) — the token's form and this build's APNs environment —
/// and the reading of its answer. The BODY is the core's (`RichOSCore.PairingWire.pushRegistrationBody`,
/// stream I1), so its bytes have one author. The permanent topic `dev.richos.connect` must
/// also be enabled in the Worker's private `APNS_TOPICS` configuration.
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
