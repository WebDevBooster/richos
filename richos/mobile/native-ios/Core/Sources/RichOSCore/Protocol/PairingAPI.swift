import Foundation

/// The bodies of `POST /api/pair` (contract §2.3, §2.5, §7.2) and the attachment routes (Echo's
/// Mac-side `22e59ed8`), serialized by hand so their key order is exactly the one the corpus and the
/// Mac's tests pin — a signed body is hashed, so its bytes are the protocol.
public enum PairingWire {
    /// The platform the Mac records for this phone (contract §2.3: native clients send it).
    public static let platform = "ios"
    /// The APNs topic of this app's development build (accepted by the Mac since `65952d16`).
    public static let apnsTopic = "dev.richos.native.ios"

    static func json(_ value: String) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        return String(decoding: (try? encoder.encode(value)) ?? Data("\"\"".utf8), as: UTF8.self)
    }

    /// `{"code","public_key_jwk":{"kty","crv","x","y"},"device_name","platform"}` — unsigned.
    public static func pairBody(code: String, identity: DeviceIdentity, deviceName: String) -> Data {
        let jwk = identity.jwk
        let key = "{\"kty\":\"EC\",\"crv\":\"P-256\",\"x\":\(json(jwk["x"]!)),\"y\":\(json(jwk["y"]!))}"
        return Data("{\"code\":\(json(code)),\"public_key_jwk\":\(key),\"device_name\":\(json(deviceName)),\"platform\":\(json(platform))}".utf8)
    }

    /// The six-word answer, signed (contract §2.5). `push_transport: "apns"` switches the Mac's
    /// record to native push, as the native reference does.
    public static func confirmationBody(deviceID: String, matches: Bool) -> Data {
        Data("{\"device_id\":\(json(deviceID)),\"fingerprint_confirmed\":\(matches),\"push_transport\":\"apns\"}".utf8)
    }

    /// Native push registration, APNs shape (contract §7.2; `platform` absent means APNs).
    public static func pushRegistrationBody(tokenHex: String, sandbox: Bool, previewKey: Data?, previews: Bool) -> Data {
        var fields = ["\"token\":\(json(tokenHex.lowercased()))", "\"environment\":\(json(sandbox ? "sandbox" : "production"))",
                      "\"topic\":\(json(apnsTopic))"]
        if let previewKey { fields.append("\"preview_key\":\(json(Base64URL.encode(previewKey)))") }
        fields.append("\"previews\":\(previews)")
        return Data("{\"native_push\":{\(fields.joined(separator: ","))}}".utf8)
    }

    public static let pushUnregistrationBody = Data("{\"native_push\":null}".utf8)

    /// A reply seen on the phone (contract §7.4).
    public static func replyReceiptBody(threadID: String, messageID: String) -> Data {
        Data("{\"seen_reply\":{\"thread\":\(json(threadID)),\"id\":\(json(messageID))}}".utf8)
    }

    /// One file of a message: `POST /api/messages?kind=attachment&client_id&attachment_id[&name]`.
    public static func attachmentUploadTarget(clientID: String, attachmentID: String, name: String?) -> String {
        var fields = [("kind", "attachment"), ("client_id", clientID), ("attachment_id", attachmentID)]
        if let name { fields.append(("name", name)) }
        return "/api/messages?" + fields.map { "\(Delivery.formEncode($0.0))=\(Delivery.formEncode($0.1))" }.joined(separator: "&")
    }

    /// The message that commits uploaded files; only ITS 200 means the Mac accepted the message.
    public static func attachmentCommitBody(clientID: String, threadID: String?, text: String?, files: [(id: String, sha256Hex: String)], sentAtISO: String) -> Data {
        var fields = ["\"client_id\":\(json(clientID))"]
        if let threadID { fields.append("\"thread_id\":\(json(threadID))") }
        fields.append("\"kind\":\"attachments\"")
        if let text, !text.isEmpty { fields.append("\"text\":\(json(text))") }
        fields.append("\"attachments\":[" + files.map { "{\"id\":\(json($0.id)),\"sha256\":\(json($0.sha256Hex))}" }.joined(separator: ",") + "]")
        fields.append("\"sent_at\":\(json(sentAtISO))")
        return Data("{\(fields.joined(separator: ","))}".utf8)
    }
}

/// The limits the Mac advertises for attachments (`hello` and the pairing answer since `194fcb75`).
public struct AttachmentLimits: Codable, Equatable, Sendable {
    public var maxFileBytes: Int
    public var maxFilesPerMessage: Int
    public var maxMessageBytes: Int
    public var uploadSeconds: Int
    public var mediaTypes: [String]
    enum CodingKeys: String, CodingKey {
        case maxFileBytes = "max_file_bytes", maxFilesPerMessage = "max_files_per_message", maxMessageBytes = "max_message_bytes"
        case uploadSeconds = "upload_seconds", mediaTypes = "media_types"
    }
}

/// `POST /api/pair`'s 200 answer (contract §2.3; additive fields from `194fcb75`).
public struct PairingAnswerWire: Decodable, Equatable, Sendable {
    public var deviceID: String
    public var caFingerprint: String
    public var challenge: String?
    public var apiBase: String?
    public var threadID: String?
    public var capabilities: [String]?
    public var protocolVersion: Int?
    public var attachmentLimits: AttachmentLimits?
    enum CodingKeys: String, CodingKey {
        case challenge, capabilities
        case deviceID = "device_id", caFingerprint = "ca_fingerprint_sha256", apiBase = "api_base", threadID = "thread_id"
        case protocolVersion = "protocol_version", attachmentLimits = "attachment_limits"
    }
}

/// The unsigned pairing exchange, as `conformance/vectors/pairing.json` `pair_exchanges` records it.
public enum PairingExchange {
    public struct Paired: Equatable, Sendable {
        public var answer: PairingAnswerWire
        /// The challenge the phone holds afterwards (the answer's, or the response header's).
        public var challenge: String?
        /// The paired origin; an `api_base` naming another origin is refused and this one kept.
        public var apiBase: String
        public var apiBaseRefusal: String?
    }

    public static func pair(link: PairLink, identity: DeviceIdentity, deviceName: String,
                            transport: any HTTPTransport) async -> Result<Paired, APIError> {
        let request = HTTPRequest(method: "POST", target: "/api/pair", headers: ["Content-Type": "application/json"],
                                  body: PairingWire.pairBody(code: link.code, identity: identity, deviceName: deviceName))
        let response: HTTPResponse
        do {
            response = try await transport.send(request, origin: link.origin)
        } catch {
            return .failure(APIError(reason: .unreachable, status: 0, retryable: true, aboutThisMessage: false))
        }
        guard response.status == 200, let answer = try? CoreJSON.decode(PairingAnswerWire.self, from: response.body) else {
            return .failure(response.status == 200 ? APIError(reason: .fault, status: 200, retryable: true, aboutThisMessage: false)
                                                    : APIClient.classify(response))
        }
        var refusal: String?
        if let advertised = answer.apiBase {
            do { _ = try MacAdvertisement.validateAPIBase(advertised, pairedOrigin: link.origin) } catch { refusal = "\(error)" }
        }
        return .success(Paired(answer: answer, challenge: answer.challenge ?? response.header("X-RichOS-Challenge"),
                               apiBase: link.origin, apiBaseRefusal: refusal))
    }
}
