import CryptoKit
import Foundation
import Testing
@testable import RichOSCore

/// The shared conformance corpus (`richos/mobile/conformance/vectors`), read from the repository at
/// test time — never a copy, because a copy is the drift the corpus exists to catch. Every case is
/// iterated; no count is hard-coded (the corpus README, "Consuming it from Swift").
enum Corpus {
    static let directory = repositoryRoot.appendingPathComponent("richos/mobile/conformance/vectors")

    static func load(_ name: String) throws -> [String: Any] {
        let data = try Data(contentsOf: directory.appendingPathComponent("\(name).json"))
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        try #require(object["schema"] as? Int == 1, "\(name).json has an unknown schema; refusing to guess")
        return object
    }

    static func cases(_ file: [String: Any], _ key: String) throws -> [[String: Any]] {
        try #require(file[key] as? [[String: Any]])
    }

    /// The request body's bytes: UTF-8, base64 (WAV), or none.
    static func body(_ request: [String: Any]) -> Data? {
        guard let body = request["body"] as? [String: Any] else { return nil }
        if let utf8 = body["utf8"] as? String { return Data(utf8.utf8) }
        if let b64 = body["base64"] as? String { return Data(base64Encoded: b64) }
        return nil
    }

    /// The credential as sent: the Authorization header, or the `auth` query parameter decoded.
    static func credential(_ request: [String: Any]) -> String? {
        if let headers = request["headers"] as? [String: String], let auth = headers["Authorization"] { return auth }
        guard let target = request["target"] as? String, let q = target.firstIndex(of: "?") else { return nil }
        for part in target[target.index(after: q)...].split(separator: "&") where part.hasPrefix("auth=") {
            return String(part.dropFirst(5)).replacingOccurrences(of: "+", with: " ").removingPercentEncoding
        }
        return nil
    }

    static let testKey: P256.Signing.PrivateKey = {
        let keys = try! load("keys")
        let hex = keys["test_only_private_scalar_hex"] as! String
        var bytes = Data()
        var i = hex.startIndex
        while i < hex.endIndex { let j = hex.index(i, offsetBy: 2); bytes.append(UInt8(hex[i..<j], radix: 16)!); i = j }
        return try! P256.Signing.PrivateKey(rawRepresentation: bytes)
    }()
}

/// What the Mac does with a signed request as sent (`DeviceDesk::verify`): rebuild the signing string
/// from the wire and verify the raw signature. A test double, checked against the corpus verdicts.
enum MacVerifier {
    static func verify(_ request: [String: Any], publicKey: P256.Signing.PublicKey) -> (signingString: String?, accepted: Bool) {
        guard let credential = Corpus.credential(request),
              let parts = RequestSigning.parseAuthorization(credential),
              let method = request["method"] as? String, let target = request["target"] as? String else { return (nil, false) }
        let canonical = RequestSigning.canonicalString(challenge: parts.challenge, method: method, pathWithQuery: target, body: Corpus.body(request))
        guard let raw = Base64URL.decode(parts.signature), raw.count == 64,
              let signature = try? P256.Signing.ECDSASignature(rawRepresentation: raw) else { return (canonical, false) }
        return (canonical, publicKey.isValidSignature(signature, for: Data(canonical.utf8)))
    }
}

@Suite struct KeysConformance {
    @Test func theTestKeyDerivesThePublishedIdentity() throws {
        let keys = try Corpus.load("keys")
        let point = Corpus.testKey.publicKey.x963Representation
        #expect(Base64URL.encode(point) == keys["public_point_b64url"] as? String)
        let identity = DeviceIdentity(publicPoint: point)
        #expect(identity.deviceID == keys["device_id"] as? String)
        #expect(identity.jwk == keys["public_key_jwk"] as? [String: String])
        #expect(Base64URL.encode(Corpus.testKey.publicKey.derRepresentation) == keys["public_key_spki_b64url"] as? String)
    }
}

@Suite struct SigningConformance {
    let key = Corpus.testKey.publicKey

    @Test func everyValidRequestIsRebuiltExactlyAndVerifies() throws {
        let file = try Corpus.load("signing")
        for c in try Corpus.cases(file, "valid") {
            let name = c["name"] as? String ?? "?"
            let request = try #require(c["request"] as? [String: Any])
            let signed = try #require(request["signed"] as? [String: Any])
            let mac = try #require(request["mac"] as? [String: Any])
            // The client side: the canonical string from what we would send.
            let ours = RequestSigning.canonicalString(challenge: signed["challenge"] as! String, method: request["method"] as! String,
                                                      pathWithQuery: signed["path_with_query"] as! String, body: Corpus.body(request))
            #expect(ours == signed["signing_string"] as? String, "\(name): signing string")
            #expect(ours == mac["signing_string"] as? String, "\(name): the Mac computes the same")
            #expect(RequestSigning.bodyHashHex(Corpus.body(request)) == signed["body_sha256_hex"] as? String, "\(name): body hash")
            let signature = try #require(Base64URL.decode(signed["signature_b64url"] as! String))
            #expect(RequestSigning.authorization(deviceID: "dev_8d4c57b7ff82", challenge: signed["challenge"] as! String, signature: signature)
                    == signed["authorization"] as? String, "\(name): authorization")
            if signed["credential"] as? String == "query" {
                #expect(RequestSigning.withQueryCredential(signed["path_with_query"] as! String, authorization: signed["authorization"] as! String)
                        == request["target"] as? String, "\(name): the credential is the last query parameter")
            }
            // The Mac side: the request as sent verifies.
            #expect(MacVerifier.verify(request, publicKey: key).accepted, "\(name): verifies")
        }
    }

    @Test func everyInvalidRequestIsRefused() throws {
        for c in try Corpus.cases(try Corpus.load("signing"), "invalid") {
            #expect(!MacVerifier.verify(try #require(c["request"] as? [String: Any]), publicKey: key).accepted, "\(c["name"] ?? "?")")
        }
    }

    @Test func unusualButValidFormsAreAccepted() throws {
        for c in try Corpus.cases(try Corpus.load("signing"), "accepted_by_the_mac_though_unusual") {
            #expect(MacVerifier.verify(try #require(c["request"] as? [String: Any]), publicKey: key).accepted, "\(c["name"] ?? "?")")
        }
    }

    @Test func ourOwnSignaturesVerifyAndDERIsConverted() async throws {
        let signer = SoftwareSigner(key: Corpus.testKey)
        let auth = try await signer.authorization(deviceID: "dev_8d4c57b7ff82", challenge: "c", method: "get", pathWithQuery: "/api/events?thread_id=t", body: nil)
        let request: [String: Any] = ["method": "GET", "target": "/api/events?thread_id=t", "headers": ["Authorization": auth]]
        #expect(MacVerifier.verify(request, publicKey: key).accepted)
        let der = try Corpus.testKey.signature(for: Data("x".utf8)).derRepresentation
        #expect(try RequestSigning.rawSignature(fromDER: der).count == 64)
    }
}

/// `fingerprint.json`: the 256-word list this phone ships, and every `v2.cases` entry rebuilt from the
/// origin, the Mac's value byte for byte and the key's point. The v1 `cases` (the hash alone) belong to
/// the preserved iPhone app; this v2 phone has no v1 derivation to replay them through.
@Suite struct FingerprintConformance {
    @Test func theShippedWordListIsTheCorpusList() throws {
        let file = try Corpus.load("fingerprint")
        #expect(file["wordlist"] as? [String] == WordList.words)
        #expect(file["word_count"] as? Int == Fingerprint.wordCount)
        let joined = Data(WordList.words.joined(separator: "\n").utf8)
        #expect(SHA256.hash(data: joined).map { String(format: "%02x", $0) }.joined() == file["wordlist_sha256_of_newline_joined"] as? String)
    }

    @Test func everyV2CaseGivesTheRecordedInputAndWords() throws {
        let v2 = try #require(try Corpus.load("fingerprint")["v2"] as? [String: Any])
        #expect(v2["label"] as? String == Fingerprint.label)
        let cases = try Corpus.cases(v2, "cases")
        #expect(!cases.isEmpty)
        for c in cases {
            let name = c["name"] as? String ?? "?"
            let origin = try #require(c["origin"] as? String)
            let value = try #require(c["ca_fingerprint_sha256"] as? String)
            let point = try #require(c["device_point_b64url"] as? String)
            #expect(try Fingerprint.input(origin: origin, caFingerprintSHA256: value, devicePoint: point) == c["input_utf8"] as? String, "\(name): input")
            let words = try Fingerprint.words(origin: origin, caFingerprintSHA256: value, devicePoint: point)
            #expect(words == c["words"] as? [String] && words.joined(separator: " ") == c["phrase"] as? String, "\(name): words")
        }
    }

    /// The point is this phone's own key's: the corpus key's point is the one its v2 cases hash.
    @Test func thePointIsTheKeysUncompressedPointInBase64URL() throws {
        let keys = try Corpus.load("keys")
        #expect(Base64URL.encode(Corpus.testKey.publicKey.x963Representation) == keys["public_point_b64url"] as? String)
        let v2 = try #require(try Corpus.load("fingerprint")["v2"] as? [String: Any])
        #expect(try Corpus.cases(v2, "cases").first?["device_point_b64url"] as? String == keys["public_point_b64url"] as? String)
    }

    @Test func anAddressThatIsNotAnHTTPSOriginIsRefusedNotHashed() throws {
        for bad in ["http://mm1.tail1a2b3c.ts.net:8443", "mm1.tail1a2b3c.ts.net", "", "https://"] {
            #expect(throws: Fingerprint.Invalid.self, "\(bad)") { try Fingerprint.normalizeOrigin(bad) }
        }
        #expect(throws: Fingerprint.Invalid.self) { try Fingerprint.words(origin: "https://a.example", caFingerprintSHA256: "", devicePoint: "BA") }
        #expect(throws: Fingerprint.Invalid.self) { try Fingerprint.words(origin: "https://a.example", caFingerprintSHA256: "55:A7", devicePoint: "") }
        #expect(try Fingerprint.normalizeOrigin("HTTPS://Relay.Example:8443/") == "https://relay.example:8443")
    }
}

@Suite struct PairingLinkConformance {
    @Test func everyLinkIsAcceptedOrRefusedAsRecorded() throws {
        for c in try Corpus.cases(try Corpus.load("pairing"), "links") {
            let name = c["name"] as? String ?? "?"
            let input = c["input"] as? String ?? ""
            if c["accept"] as? Bool == true {
                let link = try PairLink.parse(input)
                #expect(link.origin == c["origin"] as? String && link.code == c["code"] as? String, "\(name)")
            } else {
                #expect(throws: PairLink.Refusal.self, "\(name)") { try PairLink.parse(input) }
            }
        }
    }
}
