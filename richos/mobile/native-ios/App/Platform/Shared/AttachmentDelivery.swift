import Foundation
import RichOSCore

// Compiled into the app, the Share extension, and the macOS platform tests.
//
// The phone's half of the Mac's attachment intake (Echo, `cc/echo-opus-m1` 22e59ed8), for one
// share: upload each file, then send the message that commits them. Only the commit's 200 means the
// Mac accepted the message (Echo's commit message: "an upload 200 means the file is held").
//
// Signing, the challenge, the origin and the connection are the core's `APIClient`; the upload target,
// the commit body and the classification of an answer are the core's too (`PairingWire`,
// `ClientAction`, stream I1). This file only decides the ORDER: every file of a message, then its
// commit, one message after another, and what a 422 naming missing files means.

/// A signed request to the paired Mac and its answer, whatever the status. The core's `APIClient`
/// is the real one (signing, the challenge rule and its one re-sign, the origin); tests use a fake.
protocol MacRequests: Sendable {
    func send(_ method: String, _ target: String, body: Data, contentType: String) async throws -> HTTPResponse
}

extension APIClient: MacRequests {
    func send(_ method: String, _ target: String, body: Data, contentType: String) async throws -> HTTPResponse {
        try await signed(method, target, body: body, contentType: contentType)
    }
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
        PairingWire.attachmentUploadTarget(clientID: clientID, attachmentID: item.id, name: item.fileName)
    }

    /// Delivers every message of the share, in order. Stops at the first message that is not
    /// accepted: a later message must never overtake an earlier one (the reference outbox's rule 2).
    static func deliver(_ envelope: ShareEnvelope, inbox: ShareInbox, via transport: any MacRequests) async -> Outcome {
        for message in envelope.messages {
            let outcome = await deliver(message, envelope: envelope, inbox: inbox, via: transport)
            guard outcome == .accepted else { return outcome }
        }
        return .accepted
    }

    private static func deliver(_ message: ShareMessage, envelope: ShareEnvelope, inbox: ShareInbox,
                                via transport: any MacRequests) async -> Outcome {
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
            guard let answer = try? await transport.send("POST", "/api/messages", body: Data(message.commitBody.utf8),
                                                         contentType: "application/json") else { return .retryLater }
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
                               via transport: any MacRequests) async -> Outcome {
        guard let url = inbox.fileURL(for: item), let bytes = try? Data(contentsOf: url) else {
            return .refused(reason: "This file is no longer on your iPhone.")
        }
        guard let answer = try? await transport.send("POST", uploadPath(clientID: clientID, item: item), body: bytes,
                                                     contentType: item.mediaType) else { return .retryLater }
        return answer.status == 200 ? .accepted : classify(answer)
    }

    /// The core's classification (`ClientAction`, stream I1), in the share's terms. A 403/404 that
    /// survived the client's one re-sign stops the core's queue; here it means "not accepted now",
    /// and the app's outbox takes it from there.
    static func classify(_ answer: HTTPResponse) -> Outcome {
        switch ClientAction.classify(answer, attempt: 1) {
        case .delivered: return .accepted
        case .retrySameBytes, .finalStopQueue: return .retryLater
        case .finalForThisItem(let reason): return .refused(reason: reason)
        case .phoneForgotten: return .revoked
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

    static func run(_ envelope: ShareEnvelope, inbox: ShareInbox, transport: (any MacRequests)?,
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
