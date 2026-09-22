import CryptoKit
import Foundation

/// Request signing, phone protocol contract §3 — checked case by case against
/// `richos/mobile/conformance/vectors/signing.json`, whose signatures the Mac's own verifier accepts.
///
/// The traps, each a conformance case: the fourth line is EMPTY when there is no body (not the hash
/// of zero bytes); the path is signed as sent on the wire (percent-encoding kept, `auth` removed);
/// the method is uppercased; the signature is RAW 64-byte r||s in base64url without padding —
/// `SecKeyCreateSignature` and Android's `SHA256withECDSA` return DER and must be converted.
public enum RequestSigning {
    /// `<challenge>\n<METHOD>\n<path?query minus auth>\n<sha256 hex of the body, or empty>`.
    public static func canonicalString(challenge: String, method: String, pathWithQuery: String, body: Data?) -> String {
        [challenge, method.uppercased(), signedPath(pathWithQuery), bodyHashHex(body)].joined(separator: "\n")
    }

    /// Lowercase hex SHA-256 of the body bytes, or the empty string when there are none.
    public static func bodyHashHex(_ body: Data?) -> String {
        guard let body, !body.isEmpty else { return "" }
        return SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined()
    }

    /// The path and query as sent, with the `auth` parameter removed and empty `&&` segments dropped
    /// (the Mac's `signed_path`, `phone/routes.rs`). Percent-encoding is never undone.
    public static func signedPath(_ target: String) -> String {
        guard let q = target.firstIndex(of: "?") else { return target }
        let path = String(target[..<q])
        let kept = target[target.index(after: q)...].split(separator: "&", omittingEmptySubsequences: true)
            .filter { !($0 == "auth" || $0.hasPrefix("auth=")) }
        return kept.isEmpty ? path : path + "?" + kept.joined(separator: "&")
    }

    /// `RichOS-Device <device_id>.<challenge>.<signature_b64url>`.
    public static func authorization(deviceID: String, challenge: String, signature: Data) -> String {
        "RichOS-Device \(deviceID).\(challenge).\(Base64URL.encode(signature))"
    }

    /// The Mac splits the credential from the right (`phone/device.rs`).
    public static func parseAuthorization(_ value: String) -> (deviceID: String, challenge: String, signature: String)? {
        guard value.hasPrefix("RichOS-Device ") else { return nil }
        let rest = value.dropFirst("RichOS-Device ".count)
        guard let last = rest.lastIndex(of: ".") else { return nil }
        let signature = String(rest[rest.index(after: last)...])
        let head = rest[..<last]
        guard let middle = head.lastIndex(of: ".") else { return nil }
        return (String(head[..<middle]), String(head[head.index(after: middle)...]), signature)
    }

    /// `GET /api/events` carries the credential as the LAST query parameter, `auth=<encoded>`
    /// (contract §3.2); a header on that route is ignored.
    public static func withQueryCredential(_ pathWithQuery: String, authorization: String) -> String {
        pathWithQuery + (pathWithQuery.contains("?") ? "&" : "?") + "auth=" + encodeURIComponent(authorization)
    }

    /// JavaScript's `encodeURIComponent`, which the reference client uses for every query value.
    public static func encodeURIComponent(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics.intersection(CharacterSet(charactersIn: Unicode.Scalar(0)...Unicode.Scalar(127)))
        allowed.insert(charactersIn: "-_.!~*'()")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    /// A DER `ECDSA-Sig-Value` as the raw 64-byte r||s the Mac requires.
    public static func rawSignature(fromDER der: Data) throws -> Data {
        try P256.Signing.ECDSASignature(derRepresentation: der).rawRepresentation
    }
}

/// base64url without padding (RFC 4648 §5), the encoding of every key and signature on the wire.
public enum Base64URL {
    public static func encode(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Accepts padded or unpadded input.
    public static func decode(_ text: String) -> Data? {
        var s = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        s = s.replacingOccurrences(of: "=", with: "")
        s += String(repeating: "=", count: (4 - s.count % 4) % 4)
        return Data(base64Encoded: s)
    }
}

/// This phone's identity toward the Mac, derived from its public key (contract §2.2).
public struct DeviceIdentity: Equatable, Sendable {
    /// The 65-byte uncompressed P-256 point.
    public var publicPoint: Data

    public init(publicPoint: Data) { self.publicPoint = publicPoint }

    /// `"dev_"` + lowercase hex of the first 6 bytes of SHA-256(point) — derived, never chosen.
    public var deviceID: String {
        "dev_" + SHA256.hash(data: publicPoint).prefix(6).map { String(format: "%02x", $0) }.joined()
    }

    /// `{"kty":"EC","crv":"P-256","x","y"}` with 32-byte coordinates in base64url.
    public var jwk: [String: String] {
        ["kty": "EC", "crv": "P-256",
         "x": Base64URL.encode(publicPoint.subdata(in: 1..<33)),
         "y": Base64URL.encode(publicPoint.subdata(in: 33..<65))]
    }
}

/// Signs canonical strings with this phone's key. The iPhone keeps a non-extractable key in the
/// Secure Enclave where it can (build plan §3.2); tests and the headless CLI use `SoftwareSigner`.
public protocol Signer: Sendable {
    func publicPoint() async throws -> Data
    /// Raw 64-byte r||s over SHA-256 of `message`.
    func sign(_ message: Data) async throws -> Data
}

/// A software P-256 key (CryptoKit). For tests, the headless CLI and the simulator.
public struct SoftwareSigner: Signer {
    private let key: P256.Signing.PrivateKey

    public init(key: P256.Signing.PrivateKey = .init()) { self.key = key }

    /// From a raw 32-byte scalar (the conformance corpus's published test key).
    public init(rawScalar: Data) throws { key = try P256.Signing.PrivateKey(rawRepresentation: rawScalar) }

    public func publicPoint() -> Data { key.publicKey.x963Representation }

    public func sign(_ message: Data) throws -> Data { try key.signature(for: message).rawRepresentation }
}

extension Signer {
    /// Signs one request and returns its credential. `pathWithQuery` is the wire form without `auth`.
    public func authorization(deviceID: String, challenge: String, method: String, pathWithQuery: String, body: Data?) async throws -> String {
        let canonical = RequestSigning.canonicalString(challenge: challenge, method: method, pathWithQuery: pathWithQuery, body: body)
        return RequestSigning.authorization(deviceID: deviceID, challenge: challenge, signature: try await sign(Data(canonical.utf8)))
    }
}
