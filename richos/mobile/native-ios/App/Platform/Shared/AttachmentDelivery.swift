import Foundation

// Compiled into the app, the Share extension, and the macOS platform tests. Foundation only.
//
// The phone's half of the Mac's attachment intake (Echo, `cc/echo-opus-m1` 22e59ed8), for one
// share: upload each file, then send the message that commits them. Only the commit's 200 means the
// Mac accepted the message (Echo's commit message: "an upload 200 means the file is held").
//
// Signing, the challenge, the origin and the connection are NOT here: they are the core's transport
// (stream I1), reached through `SignedTransport`. This file decides WHAT to send and what each answer
// means; it never touches a key.

/// One request to the paired Mac, before signing. `pathAndQuery` is the wire form, exactly as it
/// will be signed and sent (contract §3.1: the Mac verifies percent-encoding as sent).
struct SignedRequest: Equatable, Sendable {
    var method: String
    var pathAndQuery: String
    var contentType: String
    var body: Data
    /// The Mac allows 300 s for one upload (attachments.rs `UPLOAD_SECONDS`).
    var timeoutSeconds: Double
}

struct SignedResponse: Equatable, Sendable {
    var status: Int
    var body: Data
}

/// The core's signed connection to the paired Mac. A thrown error means no answer arrived.
protocol SignedTransport: Sendable {
    func send(_ request: SignedRequest) async throws -> SignedResponse
}

enum AttachmentDelivery {
    enum Outcome: Equatable, Sendable {
        /// Every message's commit answered 200 (including `duplicate: true`).
        case accepted
        /// No answer, 404, 429, or 503 `retry:true`: send again later with the same bytes.
        case retryLater
        /// A final answer that needs the person, in the Mac's words when it gave any.
        case refused(reason: String?)
        /// 403: this phone was removed from the Mac.
        case revoked
    }

    static func uploadPath(clientID: String, item: SharedItem) -> String {
        "/api/messages?kind=attachment&client_id=\(encode(clientID))&attachment_id=\(encode(item.id))&name=\(encode(item.fileName))"
    }

    /// Delivers every message of the share, in order. Stops at the first message that is not
    /// accepted: a later message must never overtake an earlier one (the reference outbox's rule 2).
    static func deliver(_ envelope: ShareEnvelope, inbox: ShareInbox, via transport: any SignedTransport) async -> Outcome {
        for message in envelope.messages {
            let outcome = await deliver(message, envelope: envelope, inbox: inbox, via: transport)
            guard outcome == .accepted else { return outcome }
        }
        return .accepted
    }

    private static func deliver(_ message: ShareMessage, envelope: ShareEnvelope, inbox: ShareInbox,
                                via transport: any SignedTransport) async -> Outcome {
        let items = message.itemIDs.compactMap { id in envelope.items.first { $0.id == id } }
        guard items.count == message.itemIDs.count else { return .refused(reason: nil) }
        var toUpload = items
        // Upload, commit; if the Mac says some files are missing (evicted, or an upload the phone
        // believed held), upload those and send the SAME commit bytes once more.
        for _ in 0..<2 {
            for item in toUpload {
                let uploaded = await upload(item, clientID: message.clientID, inbox: inbox, via: transport)
                guard uploaded == .accepted else { return uploaded }
            }
            let commit = SignedRequest(method: "POST", pathAndQuery: "/api/messages", contentType: "application/json",
                                       body: Data(message.commitBody.utf8), timeoutSeconds: 30)
            guard let answer = try? await transport.send(commit) else { return .retryLater }
            switch answer.status {
            case 200:
                return .accepted
            case 422:
                let refusal = Refusal(answer.body)
                guard refusal.retry == true, let missing = refusal.missing, !missing.isEmpty else {
                    return .refused(reason: refusal.reason)
                }
                toUpload = items.filter { missing.contains($0.id) }
                guard !toUpload.isEmpty else { return .refused(reason: refusal.reason) }
            default:
                return classify(answer)
            }
        }
        return .retryLater
    }

    private static func upload(_ item: SharedItem, clientID: String, inbox: ShareInbox,
                               via transport: any SignedTransport) async -> Outcome {
        guard let url = inbox.fileURL(for: item), let bytes = try? Data(contentsOf: url) else {
            return .refused(reason: "This file is no longer on your iPhone.")
        }
        let request = SignedRequest(method: "POST", pathAndQuery: uploadPath(clientID: clientID, item: item),
                                    contentType: item.mediaType, body: bytes, timeoutSeconds: 300)
        guard let answer = try? await transport.send(request) else { return .retryLater }
        return answer.status == 200 ? .accepted : classify(answer)
    }

    /// The contract's status table (§4.2) as it applies to these two requests.
    static func classify(_ answer: SignedResponse) -> Outcome {
        let refusal = Refusal(answer.body)
        switch answer.status {
        case 200: return .accepted
        case 403: return .revoked
        case 409, 413, 422: return .refused(reason: refusal.reason ?? (answer.status == 413 ? "This file is larger than your Mac accepts." : nil))
        case 503: return refusal.retry == true ? .retryLater : .refused(reason: refusal.reason)
        default: return .retryLater   // 404 (a stale challenge or a restarted Mac), 429, anything unknown
        }
    }

    private struct Refusal {
        var retry: Bool?
        var reason: String?
        var missing: [String]?
        init(_ body: Data) {
            let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
            retry = object?["retry"] as? Bool
            reason = object?["reason"] as? String
            missing = object?["missing"] as? [String]
        }
    }

    /// RFC 3986 unreserved characters pass; everything else is percent-encoded, so a name like
    /// "Q3 plan & notes.pdf" cannot change the query's structure.
    static func encode(_ text: String) -> String {
        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return text.addingPercentEncoding(withAllowedCharacters: unreserved) ?? ""
    }
}

/// What the Share sheet says after Send (round-12 `share-sent`, `share-saved`).
enum ShareOutcome: Equatable, Sendable {
    /// The Mac accepted it: "Sent to Rich".
    case sent
    /// Kept on the phone for the app to send: "Saved for Rich", with the honest reason.
    case saved(SavedReason)

    enum SavedReason: Equatable, Sendable {
        /// The phone has no connection.
        case offline
        /// No acceptance within the wait (round-12 gap A6: 3 s), or no answer at all.
        case notConfirmed
        /// This build cannot send from the extension (no signed connection to the Mac yet).
        case cannotSendHere
        /// The Mac gave a final answer; the app shows it on the message.
        case refused(String?)
    }
}

/// Send now, but never wait more than `waitMs` (round-12 attachments gap A6: "up to 3 s for the
/// Mac's acceptance, then Saved for Rich. Keeps Sent true").
enum ShareAttempt {
    static let waitMs: Int64 = 3000

    static func run(_ envelope: ShareEnvelope, inbox: ShareInbox, transport: (any SignedTransport)?,
                    online: Bool, waitMs: Int64 = waitMs) async -> ShareOutcome {
        guard online else { return .saved(.offline) }
        guard let transport else { return .saved(.cannotSendHere) }
        // Whichever finishes first answers. Not a task group: a group waits for every child, so a
        // transport slow to notice cancellation would hold the sheet past the promised wait.
        let first = FirstAnswer()
        return await withCheckedContinuation { (continuation: CheckedContinuation<ShareOutcome, Never>) in
            let delivery = Task {
                let outcome = await AttachmentDelivery.deliver(envelope, inbox: inbox, via: transport)
                if await first.claim() { continuation.resume(returning: Self.outcome(outcome)) }
            }
            Task {
                try? await Task.sleep(nanoseconds: UInt64(max(0, waitMs)) * 1_000_000)
                if await first.claim() {
                    delivery.cancel()
                    continuation.resume(returning: .saved(.notConfirmed))
                }
            }
        }
    }

    static func outcome(_ delivery: AttachmentDelivery.Outcome) -> ShareOutcome {
        switch delivery {
        case .accepted: return .sent
        case .refused(let reason): return .saved(.refused(reason))
        case .retryLater, .revoked: return .saved(.notConfirmed)
        }
    }

    private actor FirstAnswer {
        private var taken = false
        func claim() -> Bool {
            defer { taken = true }
            return !taken
        }
    }
}
