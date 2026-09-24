import CryptoKit
import Foundation

/// A pairing link from the Mac: `<origin>/#pair=<code>` (phone protocol contract §2.1).
///
/// The rules are the reference client's, one for one (`richos/mobile/core/client.js`
/// `pairingLink`), including its three messages, so the native app refuses exactly what the preserved
/// app refuses. A scanned QR code only ever becomes text for this parser; the app never follows it.
public struct PairLink: Equatable, Codable, Sendable {
    /// `https://host[:port]`, lowercased host, default port omitted — the API base for this pairing.
    public var origin: String
    public var code: String

    /// Which of the two routes the link names. The link decides, not the phone (contract §1, §6):
    /// a Mac serves one route per pairing.
    public var route: Route {
        guard let host = URLComponents(string: origin)?.host else { return .other }
        if host.hasSuffix(".ts.net") { return .tailnet }
        if host.range(of: #"^c-[0-9a-f]{32}-g[0-9]+\.richos\.ceo$"#, options: .regularExpression) != nil { return .connect }
        return .other
    }

    public enum Route: String, Codable, Sendable { case tailnet, connect, other }

    public struct Refusal: Error, Equatable, CustomStringConvertible, Sendable {
        public var description: String
    }

    static let pasteWholeLink = "Paste the complete HTTPS pairing link from your Mac"
    static let needsHTTPS = "Pairing requires an HTTPS origin"
    static let needsOneCode = "The link needs one pairing code"

    public static func parse(_ text: String) throws -> PairLink {
        guard text.utf16.count <= 4096,
              !text.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) || $0 == "\\" }),
              let url = URLComponents(string: text), url.scheme != nil, url.host != nil else {
            throw Refusal(description: pasteWholeLink)
        }
        let path = url.percentEncodedPath
        guard url.scheme?.lowercased() == "https", url.user == nil, url.password == nil,
              path == "/" || path.isEmpty, (url.percentEncodedQuery ?? "").isEmpty,
              let host = url.host, !host.isEmpty else {
            throw Refusal(description: needsHTTPS)
        }
        // URLSearchParams semantics over the fragment: '&'-separated, '+' is a space, then decoded.
        let pairs = (url.percentEncodedFragment ?? "").split(separator: "&", omittingEmptySubsequences: true).map { part -> (String, String) in
            let kv = part.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            func decode(_ s: Substring) -> String {
                (String(s).replacingOccurrences(of: "+", with: " ").removingPercentEncoding) ?? String(s)
            }
            return (decode(kv[0]), kv.count > 1 ? decode(kv[1]) : "")
        }
        guard pairs.allSatisfy({ $0.0 == "pair" }), pairs.count == 1, let code = pairs.first?.1, !code.isEmpty else {
            throw Refusal(description: needsOneCode)
        }
        var origin = "https://\(host.lowercased())"
        if let port = url.port, port != 443 { origin += ":\(port)" }
        return PairLink(origin: origin, code: code)
    }
}

/// The six-word check, v2 (`pair-v2`; contract §2.4, Sage's pairing review F2). The PHONE computes
/// the words, so a Mac can never send words that do not belong to it, and they bind three things
/// behind a label:
///
///     SHA-256("RICHCONNECT-PAIR-V2\n" + origin + "\n" + ca_fingerprint_sha256 + "\n" + point)
///
/// - `origin`: the origin THIS PHONE DIALED, never one the Mac advertised. A relay is a different
///   origin, so the two screens show different words (`pairing.json` `relay_scenario`).
/// - `ca_fingerprint_sha256`: the pair answer's field, byte for byte as the Mac sent it.
/// - `point`: this phone's own public key, the 65-byte uncompressed P-256 point, base64url without
///   padding. The Mac hashes the key IT registered, so a device that redeemed the code first makes
///   the two screens differ.
///
/// The first six digest bytes index `WordList`. The rule is the reference's
/// (`richos/web/web-app/lib/fingerprint.js` `wordsV2`) and the Mac's (`phone/words.rs`); the corpus's
/// `fingerprint.json` `v2.cases` pin it. A v2 phone NEVER shows the old words over the hash alone,
/// which bind nothing about the connection, and never falls back to them.
public enum Fingerprint {
    public static let wordCount = 6
    public static let label = "RICHCONNECT-PAIR-V2"

    public struct Invalid: Error, Equatable, CustomStringConvertible, Sendable {
        public var description: String
    }

    /// `https://host[:port]`, lowercase, default port omitted, no path — `URL.origin`'s rule, which
    /// the Mac's `normalize_origin` mirrors. Anything that is not an https origin is refused rather
    /// than hashed: a phrase over a malformed origin is a phrase nobody can reproduce.
    public static func normalizeOrigin(_ text: String) throws -> String {
        guard let url = URLComponents(string: text), url.scheme?.lowercased() == "https",
              var host = url.host?.lowercased(), !host.isEmpty else {
            throw Invalid(description: "pairing needs an https address")
        }
        if host.contains(":"), !host.hasPrefix("[") { host = "[\(host)]" }
        var origin = "https://\(host)"
        if let port = url.port, port != 443 { origin += ":\(port)" }
        return origin
    }

    /// The exact text the words are the hash of.
    public static func input(origin: String, caFingerprintSHA256: String, devicePoint: String) throws -> String {
        guard !caFingerprintSHA256.isEmpty else { throw Invalid(description: "the Mac sent no fingerprint") }
        guard !devicePoint.isEmpty else { throw Invalid(description: "this phone has no key to name") }
        return "\(label)\n\(try normalizeOrigin(origin))\n\(caFingerprintSHA256)\n\(devicePoint)"
    }

    /// The six words this phone shows.
    public static func words(origin: String, caFingerprintSHA256: String, devicePoint: String) throws -> [String] {
        let text = try input(origin: origin, caFingerprintSHA256: caFingerprintSHA256, devicePoint: devicePoint)
        return SHA256.hash(data: Data(text.utf8)).prefix(wordCount).map { WordList.words[Int($0)] }
    }
}
