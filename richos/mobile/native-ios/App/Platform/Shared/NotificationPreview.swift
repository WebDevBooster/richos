import CryptoKit
import Foundation
import Security

// Compiled into the app, the notification service extension, and the macOS platform tests.
//
// THE DESIGN IS THE PRESERVED APP'S, PORTED (richos/mobile/ios/Shared/NotificationPreview.swift,
// read at aa8d28e3 and never modified): the Mac seals the first 240 characters of Rich's reply with a
// key only this phone holds; APNs and the hosted relay carry ciphertext; the extension opens it on
// the phone with no network round trip. Any failure — no key, previews off, tampering, a device still
// locked since restart — leaves Apple's generic "Rich has replied." (phone protocol contract §7.3).
// What changed in the port: named errors instead of one NSError, the Keychain item's service name
// (this app is a different app), and the Keychain access is a value type a test can point anywhere.

/// Opens a sealed reply preview. Pure: bytes in, text out.
enum NotificationPreview {
    /// The associated-data prefix; the thread and event references follow on their own lines.
    static let context = "richos-preview-v1"
    /// base64url characters of ciphertext plus tag: 240 characters of UTF-8 at most 4 bytes each
    /// is 960 bytes, plus the 16-byte tag, is 976 bytes, is 1,302 base64url characters.
    static let maxBodyCharacters = 1302

    enum Failure: Error, Equatable {
        /// No `richos` references, or they are not the hashes the Mac sends.
        case references
        /// No `preview`, the wrong version, or a malformed nonce or body.
        case envelope
        /// The key is not 32 bytes.
        case key
        /// Authentication failed: wrong key, or the ciphertext was moved to another reply.
        case authentication
        /// Decrypted to nothing, or to bytes that are not UTF-8.
        case plaintext
    }

    /// The reply's first 240 characters, or a `Failure`. `payload` is the notification's
    /// `userInfo` exactly as delivered.
    static func decrypt(_ payload: [AnyHashable: Any], key: Data) throws -> String {
        guard key.count == 32 else { throw Failure.key }
        guard let target = NotificationTarget(userInfo: payload) else { throw Failure.references }
        guard let preview = payload["preview"] as? [String: Any], (preview["v"] as? Int) == 1,
              let nonceText = preview["nonce"] as? String, let bodyText = preview["body"] as? String,
              bodyText.count <= maxBodyCharacters,
              let nonce = Base64URL.decode(nonceText), nonce.count == 12,
              let body = Base64URL.decode(bodyText), body.count >= 16 else { throw Failure.envelope }
        let box: AES.GCM.SealedBox
        do {
            box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: nonce), ciphertext: body.dropLast(16), tag: body.suffix(16))
        } catch {
            throw Failure.envelope
        }
        let associated = Data("\(context)\n\(target.thread)\n\(target.event)".utf8)
        let plain: Data
        do {
            plain = try AES.GCM.open(box, using: SymmetricKey(data: key), authenticating: associated)
        } catch {
            throw Failure.authentication
        }
        guard let text = String(data: plain, encoding: .utf8), !text.isEmpty else { throw Failure.plaintext }
        return text
    }
}

/// The phone's reply-preview settings, in ONE Keychain item the app writes and the notification
/// extension reads. A Keychain item rather than a file in the App Group, because it holds a key:
/// it never leaves this device (`…ThisDeviceOnly`), is not in backups, and is readable after the
/// first unlock so a notification that arrives with the phone locked can still be opened.
struct PreviewKeyStore: Sendable {
    struct Settings: Codable, Equatable, Sendable {
        /// The person's "Show what Rich said" choice (round-12 `notif-settings`). On by default.
        var previews = true
        /// The Mac's API origin the key belongs to. A different Mac gets a new key.
        var origin: String?
        /// 32 random bytes, sent once to the Mac in the push registration (contract §7.2).
        var key: Data?
    }

    enum Failure: Error, Equatable {
        case keychain(OSStatus)
        case corrupt
    }

    var service = "richos.native.notification-preview.v1"
    var account = "settings"
    /// The shared Keychain group, or `nil` to use this process's default group. The simulator
    /// has no Keychain sharing between an app and its extension without a signing team, so it
    /// uses the default group there (the preserved app did the same); on a device the group is
    /// required for the extension to see the key at all.
    var accessGroup: String?

    static var shared: PreviewKeyStore {
        #if targetEnvironment(simulator)
        return PreviewKeyStore(accessGroup: nil)
        #else
        return PreviewKeyStore(accessGroup: PlatformIdentity.keychainGroup)
        #endif
    }

    private func query() -> [String: Any] {
        var value: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: account]
        if let accessGroup { value[kSecAttrAccessGroup as String] = accessGroup }
        return value
    }

    /// The saved settings, or the defaults (previews on, no key) when nothing is saved.
    func load() throws -> Settings {
        var request = query()
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &item)
        if status == errSecItemNotFound { return Settings() }
        guard status == errSecSuccess, let data = item as? Data else { throw Failure.keychain(status) }
        guard let settings = try? JSONDecoder().decode(Settings.self, from: data) else { throw Failure.corrupt }
        return settings
    }

    func save(_ settings: Settings) throws {
        let data = try JSONEncoder().encode(settings)
        let attributes: [String: Any] = [kSecValueData as String: data,
                                         kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let status = SecItemUpdate(query() as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query()
            attributes.forEach { item[$0.key] = $0.value }
            let added = SecItemAdd(item as CFDictionary, nil)
            guard added == errSecSuccess else { throw Failure.keychain(added) }
        } else if status != errSecSuccess {
            throw Failure.keychain(status)
        }
    }

    /// Makes sure a key exists for `origin`, creating a fresh one for a new Mac, and returns the
    /// settings to register with (the key goes to the Mac as `preview_key`).
    @discardableResult
    func configure(origin: String) throws -> Settings {
        var settings = try load()
        if settings.origin != origin || settings.key?.count != 32 {
            settings.origin = origin
            settings.key = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
            try save(settings)
        }
        return settings
    }

    /// Mirrors the person's preview choice so the extension honors it even before the Mac hears.
    func setPreviews(_ enabled: Bool) throws {
        var settings = try load()
        guard settings.previews != enabled else { return }
        settings.previews = enabled
        try save(settings)
    }

    /// "Forget this phone": the key goes with the pairing.
    func erase() throws {
        let status = SecItemDelete(query() as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw Failure.keychain(status) }
    }
}

/// base64url without padding, the form the Mac uses for nonces, bodies and the preview key.
enum Base64URL {
    static func encode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func decode(_ text: String) -> Data? {
        guard text.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }) else { return nil }
        let standard = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        return Data(base64Encoded: standard + String(repeating: "=", count: (4 - standard.count % 4) % 4))
    }
}
