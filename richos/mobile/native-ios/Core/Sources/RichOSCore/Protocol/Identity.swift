import CryptoKit
import Foundation
#if canImport(Security)
import Security
#endif

/// This phone's signing key for one paired origin (contract §2.2: one key per origin, never
/// exported). The app, the Share extension and the notification service reach the same key through
/// one Keychain access group, which is why it lives in the core rather than in the app target.
public protocol IdentityStore: Sendable {
    /// The key for `origin`, created on first use. Pairing is the only caller that may create one.
    func signer(for origin: String) async throws -> any Signer
    /// The key for `origin` only when this phone already holds it; `nil` when it does not. A paired
    /// origin whose key is gone (the app's files restored from a backup onto a phone whose Keychain
    /// never held it, or the item erased) must be paired again, visibly: a new key the Mac has never
    /// seen would sign every request as a stranger (security review I-2).
    func existingSigner(for origin: String) async throws -> (any Signer)?
    /// Discards the key for `origin` ("They do not match", Forget this phone).
    func forget(origin: String) async throws
}

/// Keys held in memory — tests and the headless CLI.
public actor MemoryIdentityStore: IdentityStore {
    private var keys: [String: SoftwareSigner] = [:]
    public init() {}
    public func signer(for origin: String) -> any Signer {
        if let key = keys[origin] { return key }
        let key = SoftwareSigner()
        keys[origin] = key
        return key
    }
    public func existingSigner(for origin: String) -> (any Signer)? { keys[origin] }
    public func forget(origin: String) { keys[origin] = nil }
}

#if canImport(Security)
/// The device key in the Keychain, as the preserved app keeps it (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`,
/// one per origin). In the Secure Enclave where the hardware has one — the private key cannot leave
/// it — and as a software P-256 key otherwise (the simulator). Either way only its handle or its
/// sealed bytes are stored; the key never reaches the app's own files.
public struct KeychainIdentityStore: IdentityStore {
    /// `dev.richos.native.ios.identity.<origin>`.
    public let service: String
    /// The shared access group, when the entitlement is present (I3's extensions); `nil` otherwise.
    public let accessGroup: String?

    public init(service: String = "dev.richos.native.ios.identity", accessGroup: String? = nil) {
        self.service = service
        self.accessGroup = accessGroup
    }

    public func signer(for origin: String) async throws -> any Signer {
        if let stored = try read(origin) { return try Self.signer(from: stored) }
        let (signer, representation) = try Self.create()
        try write(origin, representation)
        return signer
    }

    public func existingSigner(for origin: String) async throws -> (any Signer)? {
        try read(origin).map(Self.signer(from:))
    }

    public func forget(origin: String) async throws {
        var query = base(origin)
        query.removeValue(forKey: kSecReturnData as String)
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw CoreError("could not remove the key (\(status))") }
    }

    // A one-byte prefix says which kind of key the stored bytes are.
    private static let enclaveTag: UInt8 = 1
    private static let softwareTag: UInt8 = 2

    private static func create() throws -> (any Signer, Data) {
        if SecureEnclave.isAvailable {
            let key = try SecureEnclave.P256.Signing.PrivateKey()
            return (EnclaveSigner(key: key), Data([enclaveTag]) + key.dataRepresentation)
        }
        let key = P256.Signing.PrivateKey()
        return (SoftwareSigner(key: key), Data([softwareTag]) + key.rawRepresentation)
    }

    private static func signer(from stored: Data) throws -> any Signer {
        guard let tag = stored.first else { throw CoreError("the stored key is empty") }
        let body = stored.dropFirst()
        switch tag {
        case enclaveTag: return EnclaveSigner(key: try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: body))
        case softwareTag: return SoftwareSigner(key: try P256.Signing.PrivateKey(rawRepresentation: body))
        default: throw CoreError("the stored key has an unknown kind")
        }
    }

    private func base(_ origin: String) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: origin,
        ]
        if let accessGroup { query[kSecAttrAccessGroup as String] = accessGroup }
        return query
    }

    private func read(_ origin: String) throws -> Data? {
        var query = base(origin)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw CoreError("could not read the key (\(status))") }
        return data
    }

    private func write(_ origin: String, _ data: Data) throws {
        var query = base(origin)
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw CoreError("could not store the key (\(status))") }
    }
}

/// A Secure Enclave key: signs inside the enclave; CryptoKit returns the raw r||s the Mac requires.
public struct EnclaveSigner: Signer {
    let key: SecureEnclave.P256.Signing.PrivateKey
    public func publicPoint() -> Data { key.publicKey.x963Representation }
    public func sign(_ message: Data) throws -> Data { try key.signature(for: message).rawRepresentation }
}
#endif
