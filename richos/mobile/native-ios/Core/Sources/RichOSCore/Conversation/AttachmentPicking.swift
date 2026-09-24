import Foundation

// Photos and files from the + menu (ceo-decisions §75; round 12.1 `attachments.html` groups 12-17).
//
// The Android core's model (native-android `RichCore.kt`: `Attach`, `RemoveAttachment`, and a send
// with pending attachments that takes the draft as their words; `checkAttachments` for the Mac's
// limits), on this core's outbox and courier, which already deliver files: upload each, then the
// commit's exact bytes (`Attachments.swift`). The platform presents Apple's pickers and stages what
// was chosen into the attachment store; the core decides everything else.

/// Where the + menu sends the person (`att-menu`).
public enum AttachSource: String, Codable, Equatable, Sendable {
    case photos, camera, files
}

/// A card above the composer about photos and files (round 12.1 group 17).
public enum AttachNotice: Codable, Equatable, Sendable {
    /// `att-too-large` / `att-unsupported`: refused before it reaches the tray.
    case refused(name: String, bytes: Int?, tooLarge: Bool)
    /// `att-denied-camera`.
    case cameraDenied
    /// `att-denied-photos` (only if the app ever reads the library itself; the system picker never asks).
    case photosDenied
    /// `att-mac-unsupported`: the paired Mac does not take attachments.
    case macUnsupported
}

extension ConversationReducer {
    /// The Mac's limits for the tray: what it advertised. `nil` means the Mac takes no attachments.
    static func attachLimits(_ s: AppState) -> AttachmentLimits? { s.attachmentLimits }

    static func reduceAttachments(_ s: inout AppState, _ action: Action, _ effects: inout [Effect]) {
        switch action {
        case .openAttachMenu:
            guard s.pairing == .paired, s.consentGiven, s.voice == nil else { return }
            s.attachMenuOpen = true
        case .closeAttachMenu:
            s.attachMenuOpen = false
        case .pickAttachments(let source):
            s.attachMenuOpen = false
            guard s.pairing == .paired, s.consentGiven else { return }
            guard let limits = attachLimits(s) else {
                s.attachNotice = .macUnsupported
                return
            }
            let room = limits.maxFilesPerMessage - s.pendingAttachments.count
            guard room > 0 else {
                s.toast = .attachLimit(limit: limits.maxFilesPerMessage)
                return
            }
            s.attachNotice = nil
            effects.append(.presentPicker(source, maxCount: source == .camera ? 1 : room))
        case .attachmentsPicked(let files):
            take(files, &s, &effects)
        case .attachmentRefused(let name, let bytes, let tooLarge):
            s.attachNotice = .refused(name: name, bytes: bytes, tooLarge: tooLarge)
        case .attachPermissionDenied(let source):
            s.attachNotice = source == .camera ? .cameraDenied : .photosDenied
        case .removePendingAttachment(let id):
            guard let i = s.pendingAttachments.firstIndex(where: { $0.id == id }) else { return }
            let file = s.pendingAttachments.remove(at: i)
            effects.append(.deleteAttachments(paths: [file.path]))
        case .dismissAttachNotice:
            s.attachNotice = nil
        default:
            break
        }
    }

    /// Into the tray, in the order chosen, each checked against what the Mac advertised (Android
    /// `checkAttachments`). A file refused, or past the limit, never enters the tray and its staged
    /// copy is removed.
    private static func take(_ files: [OutboxFile], _ s: inout AppState, _ effects: inout [Effect]) {
        guard !files.isEmpty else { return }
        var discard: [String] = []
        guard s.pairing == .paired, let limits = attachLimits(s) else {
            if s.pairing == .paired { s.attachNotice = .macUnsupported }
            effects.append(.deleteAttachments(paths: files.map(\.path)))
            return
        }
        for file in files {
            if s.pendingAttachments.contains(where: { $0.id == file.id }) { continue }
            if s.pendingAttachments.count >= limits.maxFilesPerMessage {
                s.toast = .attachLimit(limit: limits.maxFilesPerMessage)
                discard.append(file.path)
                continue
            }
            if file.byteCount > limits.maxFileBytes {
                s.attachNotice = .refused(name: file.name, bytes: file.byteCount, tooLarge: true)
                discard.append(file.path)
                continue
            }
            if !limits.mediaTypes.isEmpty, !limits.mediaTypes.contains(file.mediaType) {
                s.attachNotice = .refused(name: file.name, bytes: file.byteCount, tooLarge: false)
                discard.append(file.path)
                continue
            }
            // The photos travel together as one album message; keep that message inside the Mac's limit.
            if file.isPhoto {
                let album = s.pendingAttachments.filter(\.isPhoto).reduce(0) { $0 + $1.byteCount }
                if album + file.byteCount > limits.maxMessageBytes {
                    s.attachNotice = .refused(name: file.name, bytes: file.byteCount, tooLarge: true)
                    discard.append(file.path)
                    continue
                }
            }
            s.pendingAttachments.append(file)
        }
        if !discard.isEmpty { effects.append(.deleteAttachments(paths: discard)) }
    }

    /// The tray and the draft become outbox messages (round 12 attachments NOTES "Order of sending",
    /// the same plan the Share extension uses): the photos as one album, then each file as its own
    /// message; the words ride on the album, or on the last file. Client ids are derived from the one
    /// the send was stamped with, so the reducer stays pure and a replay is exact.
    static func sendAttachments(_ s: inout AppState, clientID: String, text: String, at: Int64, _ effects: inout [Effect]) -> Bool {
        let pending = s.pendingAttachments
        guard !pending.isEmpty else { return false }
        let photos = pending.filter(\.isPhoto)
        let others = pending.filter { !$0.isPhoto }
        var groups: [[OutboxFile]] = photos.isEmpty ? [] : [photos]
        groups += others.map { [$0] }
        guard s.outbox.count + groups.count <= outboxLimit else {
            s.toast = .outboxFull(limit: outboxLimit)
            return true
        }
        for (index, group) in groups.enumerated() {
            let id = index == 0 ? clientID : "\(clientID)-\(index + 1)"
            guard !s.outbox.contains(where: { $0.clientID == id }) else { continue }
            let carriesText = photos.isEmpty ? index == groups.count - 1 : index == 0
            let words = carriesText ? text : ""
            let body = PairingWire.attachmentCommitBody(clientID: id, threadID: s.mac?.threadID, text: words.isEmpty ? nil : words,
                                                        files: group.map { (id: $0.id, sha256Hex: $0.sha256) }, sentAtISO: isoMillis(at))
            s.outbox.append(OutboxItem(clientID: id, kind: .text, body: String(decoding: body, as: UTF8.self), queuedAt: at, files: group))
            let refs = group.map { AttachmentRef(id: $0.id, name: $0.name, mediaType: $0.mediaType, byteCount: $0.byteCount) }
            s.messages.append(Message(id: id, author: .me, text: words, sentAt: at, delivery: .waiting, clientID: id, attachments: refs, echoAfterCursor: s.messages.compactMap(\.cursor).max() ?? 0))
        }
        s.pendingAttachments = []
        s.draft = ""
        s.toast = nil
        s.following = true
        pump(&s, at: at, &effects)
        return true
    }
}

extension OutboxFile {
    public var isPhoto: Bool { mediaType.hasPrefix("image/") }
}
