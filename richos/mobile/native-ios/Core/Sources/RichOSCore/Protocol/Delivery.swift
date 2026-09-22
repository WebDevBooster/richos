import Foundation

/// How an outbox item goes on the wire (contract §5.2 text, §5.3 voice), and the courier that sends
/// it and turns the Mac's answer into the reducer's next action. Checked against
/// `conformance/vectors/retry.json` (every attempt carries the same bytes) and `voice.json`.
public enum Delivery {
    /// `application/x-www-form-urlencoded` as `URLSearchParams` writes it — the reference builds the
    /// voice query that way (a space is `+`; everything but `*-._` and ASCII alphanumerics is encoded).
    public static func formEncode(_ value: String) -> String {
        var out = ""
        for byte in Array(value.utf8) {
            switch byte {
            case UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "A")...UInt8(ascii: "Z"), UInt8(ascii: "0")...UInt8(ascii: "9"),
                 UInt8(ascii: "*"), UInt8(ascii: "-"), UInt8(ascii: "."), UInt8(ascii: "_"):
                out.append(Character(Unicode.Scalar(byte)))
            case UInt8(ascii: " "):
                out.append("+")
            default:
                out += String(format: "%%%02X", byte)
            }
        }
        return out
    }

    /// A number as JavaScript's `String(n)` writes it for these values: `12`, `3.5`, `0.005`.
    public static func jsNumber(_ value: Double) -> String {
        if value == value.rounded(), abs(value) < 1e15 { return String(Int64(value)) }
        return "\(value)"
    }

    /// `POST /api/messages?client_id&thread_id&kind=voice&codec&sample_rate[&seconds]&sent_at`, in
    /// that order (contract §5.3). Fixed when the message is queued and resent unchanged.
    public static func voiceTarget(clientID: String, threadID: String?, seconds: Double?, sentAtISO: String,
                                   codec: String = "wav16k", sampleRate: Int = 16000) -> String {
        var fields = [("client_id", clientID)]
        if let threadID { fields.append(("thread_id", threadID)) }
        fields += [("kind", "voice"), ("codec", codec), ("sample_rate", String(sampleRate))]
        if let seconds { fields.append(("seconds", jsNumber(seconds))) }
        fields.append(("sent_at", sentAtISO))
        return "/api/messages?" + fields.map { "\(formEncode($0.0))=\(formEncode($0.1))" }.joined(separator: "&")
    }
}

/// Recorded audio by recording id (the kept or sent WAV files). The app keeps them as protected
/// files; tests hold bytes in memory.
public protocol RecordingStore: Sendable {
    func wavBytes(id: String) async throws -> Data
}

/// Sends one outbox item and returns the action its answer means.
public struct Courier: Sendable {
    public let api: APIClient
    public let recordings: (any RecordingStore)?
    public let attachments: (any AttachmentStore)?

    public init(api: APIClient, recordings: (any RecordingStore)? = nil, attachments: (any AttachmentStore)? = nil) {
        self.api = api
        self.recordings = recordings
        self.attachments = attachments
    }

    public struct Result: Sendable {
        public var action: Action
        /// The Mac answered `duplicate: true` (a retry it had already accepted).
        public var duplicate: Bool
    }

    public func deliver(_ item: OutboxItem, at: Int64) async -> Result {
        let attempt = item.attempts + 1
        if let files = item.files, !files.isEmpty { return await deliverAttachments(item, attempt: attempt, at: at) }
        let target = item.target ?? "/api/messages"
        let body: Data?
        let contentType: String
        switch item.kind {
        case .text:
            body = item.body.map { Data($0.utf8) }
            contentType = "application/json"
        case .voice:
            guard let id = item.recordingID, let store = recordings, let bytes = try? await store.wavBytes(id: id) else {
                return Result(action: .deliveryFailed(clientID: item.clientID, failure: .refused(reason: "the recording is missing on this phone"), at: at), duplicate: false)
            }
            body = bytes
            contentType = "audio/wav"
        }
        let clientAction: ClientAction
        var duplicate = false
        var reason: String?
        do {
            let response = try await api.signed("POST", target, body: body, contentType: contentType)
            clientAction = ClientAction.classify(response, attempt: attempt)
            if (200..<300).contains(response.status) {
                duplicate = ((try? JSONSerialization.jsonObject(with: response.body)) as? [String: Any])?["duplicate"] as? Bool == true
            } else {
                reason = APIClient.classify(response).reason.rawValue
            }
        } catch {
            clientAction = ClientAction.transportFailed(attempt: attempt)
            reason = (error as? APIError)?.reason.rawValue ?? APIError.Reason.unreachable.rawValue
        }
        return Result(action: Self.action(for: clientAction, clientID: item.clientID, reason: reason, at: at), duplicate: duplicate)
    }

    /// The reducer's action for a classified answer.
    static func action(for clientAction: ClientAction, clientID: String, reason: String?, at: Int64) -> Action {
        switch clientAction {
        case .delivered:
            return .deliveryAccepted(clientID: clientID, at: at)
        case .retrySameBytes(let afterMs):
            return .deliveryFailed(clientID: clientID, failure: .retryable(reason: reason, afterMs: afterMs), at: at)
        case .finalForThisItem(let why):
            return .deliveryFailed(clientID: clientID, failure: .refused(reason: why ?? reason), at: at)
        case .finalStopQueue(let why):
            return .deliveryFailed(clientID: clientID, failure: .refusedStopQueue(reason: why ?? reason), at: at)
        case .phoneForgotten:
            return .deliveryFailed(clientID: clientID, failure: .revoked, at: at)
        }
    }
}
