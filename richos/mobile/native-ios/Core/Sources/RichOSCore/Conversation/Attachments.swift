import Foundation

/// A photo or file on its way to the Mac (Echo's attachment intake, `4be5ad86`): uploaded one by one,
/// then committed by a message whose 200 is the ONLY acceptance. An upload's 200 means the Mac holds
/// the file, not that it took the message.
public struct OutboxFile: Codable, Equatable, Sendable {
    /// The Mac's `attachment_id`, fixed when the file was chosen and reused on every retry.
    public var id: String
    public var name: String
    public var mediaType: String
    public var byteCount: Int
    /// Lowercase hex SHA-256 of the bytes; the commit names each file by it.
    public var sha256: String
    /// Where the phone keeps its copy, relative to the attachment store's directory.
    public var path: String

    public init(id: String, name: String, mediaType: String, byteCount: Int, sha256: String, path: String) {
        self.id = id; self.name = name; self.mediaType = mediaType; self.byteCount = byteCount; self.sha256 = sha256; self.path = path
    }
}

/// What a bubble shows for one attached file.
public struct AttachmentRef: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var mediaType: String
    public var byteCount: Int
    public init(id: String, name: String, mediaType: String, byteCount: Int) {
        self.id = id; self.name = name; self.mediaType = mediaType; self.byteCount = byteCount
    }
    public var isPhoto: Bool { mediaType.hasPrefix("image/") }
}

/// A share from the Share extension ("Share to Rich", ceo-decisions §75), taken into the app's
/// outbox. Each message keeps the identifiers and the exact commit bytes the extension chose, so a
/// share the Mac already accepted comes back `duplicate`, never as a second message.
public struct SharedIntake: Codable, Equatable, Sendable {
    public struct Item: Codable, Equatable, Sendable {
        public var clientID: String
        /// The commit request's exact bytes, serialized once by the extension.
        public var commitBody: String
        /// The caption, when it rides on this message.
        public var text: String?
        public var files: [OutboxFile]
        public init(clientID: String, commitBody: String, text: String?, files: [OutboxFile]) {
            self.clientID = clientID; self.commitBody = commitBody; self.text = text; self.files = files
        }
    }
    public var messages: [Item]
    public var createdAt: Int64
    /// The extension already had every commit answered 200 ("Sent to Rich"): show it, never send it.
    public var alreadyAccepted: Bool
    public init(messages: [Item], createdAt: Int64, alreadyAccepted: Bool) {
        self.messages = messages; self.createdAt = createdAt; self.alreadyAccepted = alreadyAccepted
    }
}

/// The phone's copies of attached files. The app keeps them under Application Support; tests hold
/// bytes in memory.
public protocol AttachmentStore: Sendable {
    func bytes(atPath path: String) async throws -> Data
    func remove(path: String) async
}

public struct FileAttachmentStore: AttachmentStore {
    public let directory: URL
    public init(directory: URL) { self.directory = directory }

    /// A stored path is one or two plain components under the directory, never anything that
    /// climbs out of it.
    func url(_ path: String) throws -> URL {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !parts.isEmpty, parts.count <= 2, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw CoreError("attachment path '\(path)' is not inside the attachment store")
        }
        return directory.appendingPathComponent(path)
    }

    public func bytes(atPath path: String) async throws -> Data {
        try Data(contentsOf: try url(path))
    }

    /// Removes the file, and its message's folder once that is empty.
    public func remove(path: String) async {
        guard let file = try? url(path) else { return }
        try? FileManager.default.removeItem(at: file)
        let folder = file.deletingLastPathComponent()
        if folder.standardizedFileURL != directory.standardizedFileURL,
           (try? FileManager.default.contentsOfDirectory(atPath: folder.path))?.isEmpty == true {
            try? FileManager.default.removeItem(at: folder)
        }
    }
}

/// The Mac's row for an attachment message is the words it gave Rich (`attachments.rs` `describe`):
/// the caption, a blank line, `Attached from the phone (N files, saved on this Mac):` and one line per
/// file, `- <path on the Mac> (<media type>, <size> bytes)`. The rows carry no structured
/// attachments and no client id, so this reads the bubble back out of those words: the caption as
/// the text, one reference per file. Anything that does not match the shape exactly is left as text.
public enum AttachmentDescription {
    static let lead = "Attached from the phone ("

    public static func parse(_ text: String, rowID: String) -> (caption: String, files: [AttachmentRef])? {
        let lines = text.components(separatedBy: "\n")
        guard let headerIndex = lines.lastIndex(where: { $0.hasPrefix(lead) && $0.hasSuffix(", saved on this Mac):") }) else { return nil }
        let header = lines[headerIndex].dropFirst(lead.count).dropLast(", saved on this Mac):".count)
        let countWord = header.split(separator: " ")
        guard countWord.count == 2, let count = Int(countWord[0]), count >= 1,
              countWord[1] == (count == 1 ? "file" : "files") else { return nil }
        let fileLines = Array(lines[(headerIndex + 1)...])
        guard fileLines.count == count else { return nil }
        var files: [AttachmentRef] = []
        for (index, line) in fileLines.enumerated() {
            guard line.hasPrefix("- "), line.hasSuffix(" bytes)"), let open = line.range(of: " (", options: .backwards) else { return nil }
            let path = String(line[line.index(line.startIndex, offsetBy: 2)..<open.lowerBound])
            let inside = line[open.upperBound..<line.index(line.endIndex, offsetBy: -" bytes)".count)]
            let parts = inside.components(separatedBy: ", ")
            guard parts.count == 2, parts[0].contains("/"), let size = Int(parts[1]), size >= 0,
                  let name = path.split(separator: "/").last.map(String.init), !name.isEmpty else { return nil }
            files.append(AttachmentRef(id: "\(rowID)#\(index)", name: name, mediaType: parts[0], byteCount: size))
        }
        // The caption and the block are separated by one blank line; with no caption the block is all.
        let before = lines[..<headerIndex]
        if before.isEmpty { return ("", files) }
        guard before.count >= 2, before.last == "" else { return nil }
        return (before.dropLast().joined(separator: "\n"), files)
    }
}

extension ConversationReducer {
    /// Takes a share into the outbox, or, when the extension already had it accepted, into the
    /// conversation only. Idempotent by `clientID`. A share that would overflow the outbox is not
    /// taken; the app sees that (its client ids are absent) and leaves it in the Share inbox.
    static func take(_ intake: SharedIntake, _ s: inout AppState, at: Int64, _ effects: inout [Effect]) {
        guard s.pairing == .paired, s.consentGiven else { return }
        let fresh = intake.messages.filter { item in
            !s.messages.contains { $0.id == item.clientID || $0.clientID == item.clientID }
        }
        guard intake.alreadyAccepted || s.outbox.count + fresh.count <= outboxLimit else {
            s.toast = .outboxFull(limit: outboxLimit)
            return
        }
        for item in fresh {
            let refs = item.files.map { AttachmentRef(id: $0.id, name: $0.name, mediaType: $0.mediaType, byteCount: $0.byteCount) }
            s.messages.append(Message(id: item.clientID, author: .me, text: item.text ?? "", sentAt: intake.createdAt,
                                      delivery: intake.alreadyAccepted ? nil : .waiting, clientID: item.clientID, attachments: refs))
            if !intake.alreadyAccepted {
                s.outbox.append(OutboxItem(clientID: item.clientID, kind: .text, body: item.commitBody, queuedAt: intake.createdAt,
                                           files: item.files))
            }
        }
        guard !fresh.isEmpty else { return }
        s.following = true
        pump(&s, at: at, &effects)
    }

    /// The phone's copies are removed once the Mac accepted the message, or when it is discarded.
    static func releaseFiles(of item: OutboxItem, _ effects: inout [Effect]) {
        guard let files = item.files, !files.isEmpty else { return }
        effects.append(.deleteAttachments(paths: files.map(\.path)))
    }
}

extension Courier {
    /// Uploads every file of the item, then sends its commit's exact bytes. A commit refused 422
    /// naming missing files uploads those and resends the SAME bytes once (Echo's rule: only the
    /// commit's 200 is acceptance). There is no byte-range resume: a file is uploaded whole, and a
    /// retry of bytes the Mac already holds is answered `duplicate`.
    func deliverAttachments(_ item: OutboxItem, attempt: Int, at: Int64) async -> Result {
        func result(_ action: ClientAction, _ reason: String?) -> Result {
            Result(action: Courier.action(for: action, clientID: item.clientID, reason: reason, at: at), duplicate: false)
        }
        let files = item.files ?? []
        guard let store = attachments, let commit = item.body.map({ Data($0.utf8) }) else {
            return result(.finalForThisItem(reason: "These files are no longer on this iPhone."), nil)
        }
        var toUpload = files
        for _ in 0..<2 {
            for file in toUpload {
                guard let bytes = try? await store.bytes(atPath: file.path) else {
                    return result(.finalForThisItem(reason: "\(file.name) is no longer on this iPhone."), nil)
                }
                let target = PairingWire.attachmentUploadTarget(clientID: item.clientID, attachmentID: file.id, name: file.name)
                do {
                    let answer = try await api.signed("POST", target, body: bytes, contentType: file.mediaType)
                    guard (200..<300).contains(answer.status) else {
                        return result(ClientAction.classify(answer, attempt: attempt), APIClient.classify(answer).reason.rawValue)
                    }
                } catch {
                    return result(ClientAction.transportFailed(attempt: attempt), (error as? APIError)?.reason.rawValue ?? APIError.Reason.unreachable.rawValue)
                }
            }
            let answer: HTTPResponse
            do {
                answer = try await api.signed("POST", "/api/messages", body: commit, contentType: "application/json")
            } catch {
                return result(ClientAction.transportFailed(attempt: attempt), (error as? APIError)?.reason.rawValue ?? APIError.Reason.unreachable.rawValue)
            }
            let json = (try? JSONSerialization.jsonObject(with: answer.body)) as? [String: Any]
            if answer.status == 422, json?["retry"] as? Bool == true, let missing = json?["missing"] as? [String] {
                toUpload = files.filter { missing.contains($0.id) }
                // A 422 naming nothing the phone holds cannot be cured by sending again.
                if toUpload.isEmpty { return result(.finalForThisItem(reason: json?["reason"] as? String), nil) }
                continue
            }
            if (200..<300).contains(answer.status) {
                return Result(action: .deliveryAccepted(clientID: item.clientID, at: at), duplicate: json?["duplicate"] as? Bool == true)
            }
            return result(ClientAction.classify(answer, attempt: attempt), APIClient.classify(answer).reason.rawValue)
        }
        // Uploaded, and the Mac still names files as missing: try again later with the same bytes.
        return result(.retrySameBytes(afterMs: ConversationReducer.retryDelayMs(attempt: attempt)), "unreachable")
    }
}
