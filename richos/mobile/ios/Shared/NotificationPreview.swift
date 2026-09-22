import Foundation
import CryptoKit
import Security

// Shared only by this app and its notification extension. The relay gets ciphertext.
enum NotificationPreview {
    struct Settings: Codable { var previews = true; var origin: String?; var key: Data? }
    static func query() -> [String: Any] {
        var value: [String: Any] = [kSecClass as String:kSecClassGenericPassword,
            kSecAttrService as String:"richos.notification-preview.v1", kSecAttrAccount as String:"settings"]
        #if !targetEnvironment(simulator)
        if let group = Bundle.main.object(forInfoDictionaryKey:"PreviewKeychainGroup") as? String { value[kSecAttrAccessGroup as String] = group }
        #endif
        return value
    }
    static func load() throws -> Settings {
        var request = query(); request[kSecReturnData as String] = true
        var item: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &item)
        if status == errSecItemNotFound { return Settings() }
        guard status == errSecSuccess, let data = item as? Data else { throw failure() }
        return try JSONDecoder().decode(Settings.self, from:data)
    }
    static func save(_ settings: Settings) throws {
        let data = try JSONEncoder().encode(settings)
        let attributes: [String: Any] = [kSecValueData as String:data, kSecAttrAccessible as String:kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let status = SecItemUpdate(query() as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query(); attributes.forEach { item[$0.key] = $0.value }
            guard SecItemAdd(item as CFDictionary,nil) == errSecSuccess else { throw failure() }
        } else if status != errSecSuccess { throw failure() }
    }
    static func configure(origin:String) throws {
        var settings = try load()
        if settings.origin != origin || settings.key == nil {
            settings.origin = origin
            settings.key = SymmetricKey(size:.bits256).withUnsafeBytes { Data($0) }
            try save(settings)
        }
    }
    static func setPreviews(_ enabled:Bool) throws { var settings = try load(); settings.previews = enabled; try save(settings) }
    static func base64(_ data:Data) -> String { data.base64EncodedString().replacingOccurrences(of:"+",with:"-").replacingOccurrences(of:"/",with:"_").replacingOccurrences(of:"=",with:"") }
    static func decode(_ value:String) -> Data? {
        let text = value.replacingOccurrences(of:"-",with:"+").replacingOccurrences(of:"_",with:"/")
        return Data(base64Encoded:text + String(repeating:"=", count:(4-text.count%4)%4))
    }
    static func decrypt(_ payload:[AnyHashable:Any], key:Data) throws -> String {
        guard key.count == 32, let refs = payload["richos"] as? [String:String],
              let thread = refs["thread"], let event = refs["event"],
              thread.range(of:"^[a-f0-9]{64}$",options:.regularExpression) != nil,
              event.range(of:"^[a-f0-9]{64}$",options:.regularExpression) != nil,
              let preview = payload["preview"] as? [String:Any], preview["v"] as? Int == 1,
              let nonceText = preview["nonce"] as? String, let bodyText = preview["body"] as? String,
              bodyText.count <= 1302, let nonce = decode(nonceText), nonce.count == 12,
              let body = decode(bodyText), body.count >= 16 else { throw failure() }
        let box = try AES.GCM.SealedBox(nonce:AES.GCM.Nonce(data:nonce), ciphertext:body.dropLast(16), tag:body.suffix(16))
        let plain = try AES.GCM.open(box, using:SymmetricKey(data:key), authenticating:Data("richos-preview-v1\n\(thread)\n\(event)".utf8))
        guard let text = String(data:plain,encoding:.utf8), !text.isEmpty else { throw failure() }
        return text
    }
    static func failure() -> NSError { NSError(domain:"RichOS.NotificationPreview",code:1,userInfo:[NSLocalizedDescriptionKey:"Notification previews are unavailable."]) }
}
