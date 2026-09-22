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

/// The six-word fingerprint check (contract §2.4): the PHONE computes the words from the hex the Mac
/// sends, so a Mac can never send words that do not belong to its certificate. The rule is the
/// reference's (`richos/web/web-app/lib/fingerprint.js`): the first six digest bytes index `WordList`.
public enum Fingerprint {
    public static let wordCount = 6

    public struct Invalid: Error, Equatable, CustomStringConvertible, Sendable {
        public var description: String
    }

    /// Accepts bare or colon/space/dash-separated hex, any case, with or without a `SHA-256` label.
    public static func bytes(fromHex text: String) throws -> [UInt8] {
        var cleaned = text.trimmingCharacters(in: .whitespaces)
        if let label = cleaned.range(of: #"^sha-?256\s*[:=]?\s*"#, options: [.regularExpression, .caseInsensitive]) {
            cleaned.removeSubrange(label)
        }
        cleaned = cleaned.filter { !$0.isWhitespace && $0 != ":" && $0 != "-" }
        guard !cleaned.isEmpty, cleaned.allSatisfy(\.isHexDigit) else { throw Invalid(description: "that is not a hexadecimal fingerprint") }
        guard cleaned.count % 2 == 0 else { throw Invalid(description: "a hexadecimal fingerprint has an even number of characters") }
        guard cleaned.count >= wordCount * 2 else { throw Invalid(description: "a fingerprint needs at least \(wordCount) bytes") }
        var out: [UInt8] = []
        var index = cleaned.startIndex
        while index < cleaned.endIndex {
            let next = cleaned.index(index, offsetBy: 2)
            out.append(UInt8(cleaned[index..<next], radix: 16)!)
            index = next
        }
        return out
    }

    public static func words(fromHex text: String) throws -> [String] {
        try bytes(fromHex: text).prefix(wordCount).map { WordList.words[Int($0)] }
    }
}
