import CryptoKit
import Foundation
import UniformTypeIdentifiers

// Compiled into the app, the Share extension, and the macOS platform tests. Foundation only.
//
// "Share to Rich" (ceo-decisions §75; round-12 `attachments-NOTES.md` "Share Extension honesty"):
// the extension writes what was shared into the App Group FIRST, then tries to send it, and says
// "Sent to Rich" only when the Mac's commit answered 200. Anything else stays in the inbox and the
// app sends it, with the same identifiers, so a retry is a duplicate on the Mac, never a second
// message.
//
// COPY THE DESIGN of T3 Code's share inbox (adoption ledger §2.8 E3; T3 Code at
// 2eb6a53343ffb4ce747617746ee85433115ad18f, `apps/swift-ios/Extensions/Shared/ShareInbox.swift`,
// MIT License, Copyright (c) 2026 T3 Tools Inc.): one directory per share, files copied in first, a
// manifest written atomically last, reads that ignore a directory without a manifest, and removal
// and file lookup that refuse any path outside the inbox. Why it fits RichOS: a share extension is
// a short-lived process the system may end at any moment, and the app must find either a whole
// share or none. What is RichOS's own: the identifiers are fixed at share time and the commit body
// is serialized once (the Mac's receipt binds its exact bytes, contract §5.2), and T3's "the
// extension never sends" is replaced by §75's "send now, or say Saved".

/// What the Mac accepts, from its own table (`richos/app/src-tauri/src/phone/attachments.rs`,
/// `cc/echo-opus-m1` at 22e59ed8; advertised in `hello` as `attachment_limits` at 194fcb75).
/// These replace round 12's proposed 100 MB (attachments NOTES gap A1).
enum AttachmentRules {
    static let maxFileBytes = 25 * 1024 * 1024          // 26,214,400
    static let maxFilesPerMessage = 10
    static let maxMessageBytes = 100 * 1024 * 1024
    /// The Mac's model reads JPEG, PNG, GIF and WebP; it stores HEIC as HEIC. So the phone sends a
    /// HEIC photo as a JPEG no longer than this on its long edge (Echo, 22e59ed8 "NOT DONE, SAID").
    static let photoLongEdge = 2576

    /// The thirteen media types the Mac accepts, each with the identifiers a phone reports for it.
    static let accepted: [(mediaType: String, types: [String], ext: String)] = [
        ("image/jpeg", ["public.jpeg"], "jpg"),
        ("image/png", ["public.png"], "png"),
        ("image/heic", ["public.heic"], "heic"),
        ("image/heif", ["public.heif"], "heif"),
        ("image/gif", ["com.compuserve.gif"], "gif"),
        ("image/webp", ["org.webmproject.webp"], "webp"),
        ("application/pdf", ["com.adobe.pdf"], "pdf"),
        ("text/plain", ["public.plain-text", "public.utf8-plain-text"], "txt"),
        ("text/markdown", ["net.daringfireball.markdown"], "md"),
        ("text/csv", ["public.comma-separated-values-text"], "csv"),
        ("application/vnd.openxmlformats-officedocument.wordprocessingml.document", ["org.openxmlformats.wordprocessingml.document"], "docx"),
        ("application/vnd.openxmlformats-officedocument.spreadsheetml.sheet", ["org.openxmlformats.spreadsheetml.sheet"], "xlsx"),
        ("application/vnd.openxmlformats-officedocument.presentationml.presentation", ["org.openxmlformats.presentationml.presentation"], "pptx"),
    ]

    /// The Mac's media type for a type identifier, or `nil` when the Mac would refuse it. An exact
    /// match first; then conformance, for the system's own subtypes (a camera's `public.jpeg`
    /// variants). Legacy Office (`.doc`, `.xls`, `.ppt`) and iWork are refused by the Mac, so here.
    static func mediaType(forTypeIdentifier identifier: String) -> String? {
        if let row = accepted.first(where: { $0.types.contains(identifier) }) { return row.mediaType }
        guard let type = UTType(identifier) else { return nil }
        for row in accepted {
            for name in row.types {
                if let known = UTType(name), type.conforms(to: known) { return row.mediaType }
            }
        }
        return nil
    }

    static func isPhoto(_ mediaType: String) -> Bool { mediaType.hasPrefix("image/") }

    static func fileExtension(forMediaType mediaType: String) -> String {
        accepted.first { $0.mediaType == mediaType }?.ext ?? "bin"
    }

    /// The Mac's own identifier rule (`attachments.rs` `valid_id`): 1 to 128 of `A-Za-z0-9_-`.
    static func isValidID(_ id: String) -> Bool {
        !id.isEmpty && id.utf8.count <= 128 && id.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 95 || $0 == 45
        }
    }
}

/// One photo or file in a share, as stored in the inbox.
struct SharedItem: Codable, Equatable, Identifiable, Sendable {
    /// The Mac's `attachment_id`: fixed at share time, reused on every retry.
    var id: String
    var fileName: String
    var mediaType: String
    /// Relative to the App Group container, always inside the inbox (`ShareInbox.fileURL`).
    var relativePath: String
    var byteCount: Int
    /// Lowercase hex SHA-256 of the stored bytes; the commit names each file by it.
    var sha256: String

    var isPhoto: Bool { AttachmentRules.isPhoto(mediaType) }
}

/// One message the share becomes (attachments NOTES "Order of sending": the photos as one album
/// message, then each file as its own message; the caption rides on the album, or on the last file).
struct ShareMessage: Codable, Equatable, Sendable {
    /// The Mac's `client_id`: the idempotency key, chosen once.
    var clientID: String
    var itemIDs: [String]
    /// The commit request's exact bytes, serialized ONCE, resent byte for byte (contract §5.2).
    var commitBody: String
}

struct ShareEnvelope: Codable, Equatable, Identifiable, Sendable {
    static let schemaVersion = 1

    enum Delivery: Codable, Equatable, Sendable {
        /// In the inbox, not yet accepted: the app sends it.
        case saved
        /// Every message's commit answered 200 at this time (ms since 1970).
        case sent(atMs: Int64)
    }

    var schemaVersion: Int
    /// A lowercase UUID: the inbox directory's name.
    var id: String
    var createdAtMs: Int64
    var caption: String
    var threadID: String
    var items: [SharedItem]
    var messages: [ShareMessage]
    var delivery: Delivery

    var totalBytes: Int { items.reduce(0) { $0 + $1.byteCount } }
}

/// A file the extension has already copied out of the host app's provider into its own temporary
/// directory (a provider's URL is valid only inside its callback), with what it knows about it.
struct StagedShareFile: Sendable {
    var url: URL
    var suggestedName: String?
    var mediaType: String
}

enum ShareInboxError: Error, Equatable {
    case noSharedContainer
    case nothingToSend
    case tooMany(count: Int)
    case tooLarge(fileName: String, bytes: Int)
    case unsupported(fileName: String)
    case notPaired
}

/// The crash-safe hand-off between the Share extension and the app.
struct ShareInbox: Sendable {
    static let relativeRoot = "Library/Application Support/RichOS/SharedInbox"
    static let manifestName = "manifest.json"
    static let startedName = "started"

    /// The App Group container (or a test directory).
    var container: URL

    static var shared: ShareInbox? { PlatformIdentity.sharedContainer.map { ShareInbox(container: $0) } }

    var root: URL { container.appendingPathComponent(Self.relativeRoot, isDirectory: true) }

    /// Copies the staged files into a new share directory, fixes every identifier, serializes each
    /// message's commit body once, and writes the manifest last. On any failure the directory is
    /// removed, so a half-written share never exists. The staged files are the caller's to remove.
    func write(caption: String, files: [StagedShareFile], threadID: String, nowMs: Int64,
               id: String = UUID().uuidString.lowercased(),
               newID: () -> String = { UUID().uuidString.lowercased() }) throws -> ShareEnvelope {
        guard !files.isEmpty else { throw ShareInboxError.nothingToSend }
        guard files.count <= AttachmentRules.maxFilesPerMessage else { throw ShareInboxError.tooMany(count: files.count) }
        let directory = root.appendingPathComponent(id, isDirectory: true)
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            // When this share began, so the app can tell a share still being written from one whose
            // writer died (`sweepIncomplete`) without reading file dates (a required-reason API).
            try Data(String(nowMs).utf8).write(to: directory.appendingPathComponent(Self.startedName), options: .atomic)
            var items: [SharedItem] = []
            for (index, file) in files.enumerated() {
                let fallback = "shared-\(index + 1).\(AttachmentRules.fileExtension(forMediaType: file.mediaType))"
                let name = Self.safeFileName(file.suggestedName, fallback: fallback)
                guard AttachmentRules.accepted.contains(where: { $0.mediaType == file.mediaType }) else {
                    throw ShareInboxError.unsupported(fileName: name)
                }
                let data = try Data(contentsOf: file.url)
                guard !data.isEmpty else { throw ShareInboxError.unsupported(fileName: name) }
                guard data.count <= AttachmentRules.maxFileBytes else {
                    throw ShareInboxError.tooLarge(fileName: name, bytes: data.count)
                }
                let itemID = newID()
                let stored = "\(itemID)-\(name)"
                try data.write(to: directory.appendingPathComponent(stored), options: .atomic)
                items.append(SharedItem(id: itemID, fileName: name, mediaType: file.mediaType,
                                        relativePath: "\(Self.relativeRoot)/\(id)/\(stored)", byteCount: data.count,
                                        sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()))
            }
            let messages = try Self.plan(items: items, caption: caption, threadID: threadID, sentAtMs: nowMs, newID: newID)
            let envelope = ShareEnvelope(schemaVersion: ShareEnvelope.schemaVersion, id: id, createdAtMs: nowMs,
                                         caption: caption, threadID: threadID, items: items, messages: messages, delivery: .saved)
            try Self.encoder.encode(envelope).write(to: directory.appendingPathComponent(Self.manifestName), options: .atomic)
            return envelope
        } catch {
            try? fm.removeItem(at: directory)
            throw error
        }
    }

    /// The album, then each file, each with its commit body serialized now.
    static func plan(items: [SharedItem], caption: String, threadID: String, sentAtMs: Int64,
                     newID: () -> String) throws -> [ShareMessage] {
        let photos = items.filter(\.isPhoto)
        let files = items.filter { !$0.isPhoto }
        var groups: [[SharedItem]] = photos.isEmpty ? [] : [photos]
        groups += files.map { [$0] }
        let text = caption.trimmingCharacters(in: .whitespacesAndNewlines)
        var bytesInMessage = 0
        return try groups.enumerated().map { index, group in
            bytesInMessage = group.reduce(0) { $0 + $1.byteCount }
            guard bytesInMessage <= AttachmentRules.maxMessageBytes else {
                throw ShareInboxError.tooLarge(fileName: group[0].fileName, bytes: bytesInMessage)
            }
            // The caption rides on the album (the first group when there are photos), otherwise on
            // the last file.
            let carriesCaption = photos.isEmpty ? index == groups.count - 1 : index == 0
            let clientID = newID()
            let body = commitBody(clientID: clientID, threadID: threadID, text: carriesCaption && !text.isEmpty ? text : nil,
                                  items: group, sentAtMs: sentAtMs)
            return ShareMessage(clientID: clientID, itemIDs: group.map(\.id), commitBody: body)
        }
    }

    /// `{"client_id","thread_id","kind":"attachments","text"?,"attachments":[{"id","sha256"}],"sent_at"}`
    /// (Echo, 22e59ed8). Keys sorted so the same inputs always give the same bytes.
    static func commitBody(clientID: String, threadID: String, text: String?, items: [SharedItem], sentAtMs: Int64) -> String {
        struct Ref: Encodable { var id: String; var sha256: String }
        struct Body: Encodable {
            var client_id: String
            var thread_id: String
            var kind = "attachments"
            var text: String?
            var attachments: [Ref]
            var sent_at: String
        }
        let body = Body(client_id: clientID, thread_id: threadID, text: text,
                        attachments: items.map { Ref(id: $0.id, sha256: $0.sha256) }, sent_at: iso8601(ms: sentAtMs))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: (try? encoder.encode(body)) ?? Data(), as: UTF8.self)
    }

    /// ISO 8601 UTC with milliseconds, the Mac's own timestamp form (contract §8).
    static func iso8601(ms: Int64) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: Date(timeIntervalSince1970: Double(ms) / 1000))
    }

    /// Every complete share, oldest first. A directory without a readable manifest is a share the
    /// extension did not finish; it is skipped here and removed by `sweepIncomplete`.
    func loadAll() -> [ShareEnvelope] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: root.path) else { return [] }
        return names.compactMap { name -> ShareEnvelope? in
            guard UUID(uuidString: name) != nil else { return nil }
            let manifest = root.appendingPathComponent(name).appendingPathComponent(Self.manifestName)
            guard let data = try? Data(contentsOf: manifest),
                  let envelope = try? Self.decoder.decode(ShareEnvelope.self, from: data),
                  envelope.schemaVersion == ShareEnvelope.schemaVersion, envelope.id == name else { return nil }
            return envelope
        }
        .sorted { ($0.createdAtMs, $0.id) < ($1.createdAtMs, $1.id) }
    }

    /// Removes shares whose writer never finished: no manifest, and started more than `graceMs` ago
    /// (or with no start mark at all). A share still being written is left alone. Returns the ids.
    @discardableResult
    func sweepIncomplete(nowMs: Int64, graceMs: Int64 = 10 * 60 * 1000) -> [String] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: root.path) else { return [] }
        var removed: [String] = []
        for name in names where UUID(uuidString: name) != nil && name == name.lowercased() {
            let directory = root.appendingPathComponent(name, isDirectory: true)
            guard !fm.fileExists(atPath: directory.appendingPathComponent(Self.manifestName).path) else { continue }
            let started = (try? Data(contentsOf: directory.appendingPathComponent(Self.startedName)))
                .flatMap { Int64(String(decoding: $0, as: UTF8.self)) } ?? 0
            guard nowMs - started > graceMs else { continue }
            if (try? fm.removeItem(at: directory)) != nil { removed.append(name) }
        }
        return removed.sorted()
    }

    /// Records that the Mac accepted every message of this share.
    func markSent(_ envelope: ShareEnvelope, atMs: Int64) throws -> ShareEnvelope {
        var sent = envelope
        sent.delivery = .sent(atMs: atMs)
        let manifest = try directory(for: envelope.id).appendingPathComponent(Self.manifestName)
        try Self.encoder.encode(sent).write(to: manifest, options: .atomic)
        return sent
    }

    /// Removes one share once the app has taken it into its own outbox.
    func remove(id: String) throws {
        let directory = try directory(for: id)
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        try FileManager.default.removeItem(at: directory)
    }

    /// The stored file for an item, or `nil` for any path that would leave the inbox.
    func fileURL(for item: SharedItem) -> URL? {
        let inbox = root.standardizedFileURL.resolvingSymlinksInPath().path
        let url = container.appendingPathComponent(item.relativePath).standardizedFileURL.resolvingSymlinksInPath()
        guard url.path.hasPrefix(inbox + "/") else { return nil }
        return url
    }

    private func directory(for id: String) throws -> URL {
        guard UUID(uuidString: id) != nil, id == id.lowercased() else { throw ShareInboxError.nothingToSend }
        return root.appendingPathComponent(id, isDirectory: true)
    }

    /// A name with one path component and no control characters, at most 96 characters.
    static func safeFileName(_ proposed: String?, fallback: String) -> String {
        // The last component by splitting, never through URL(fileURLWithPath:), which resolves ".."
        // against the process's working directory.
        let trimmed = proposed?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let last = trimmed.split(separator: "/").last.map(String.init) ?? ""
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-_ ()"))
        let cleaned = String(String.UnicodeScalarView(last.unicodeScalars.filter(allowed.contains)).prefix(96))
        guard !cleaned.isEmpty, cleaned != ".", cleaned != "..", !cleaned.hasPrefix(".") else { return fallback }
        return cleaned
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()
    private static let decoder = JSONDecoder()
}

/// What the Share extension needs to know about the app's pairing, written by the app into the App
/// Group whenever it changes (`App/Platform/ShareContextMirror.swift`). The extension never reads
/// the app's own state file: two processes writing one file is how unsent work gets lost.
struct ShareContext: Codable, Equatable, Sendable {
    static let fileName = "share-context.json"

    var paired: Bool
    /// "Alex’s Mac", for "Goes to Rich on Alex’s Mac"; `nil` until the Mac says.
    var macName: String?
    /// The conversation a share lands in (the Mac refuses an unknown one).
    var threadID: String?
    /// The Mac advertised `attachments` in its capabilities (Echo, 194fcb75).
    var macAcceptsAttachments: Bool
    /// The app's own appearance setting, `dark` or `light` (`AppState.appearance`), so the sheet
    /// matches the app rather than the system. Dark when unknown (ceo-decisions §15).
    var appearance: String = "dark"

    static let unpaired = ShareContext(paired: false, macName: nil, threadID: nil, macAcceptsAttachments: false)

    static func read(container: URL) -> ShareContext {
        let url = container.appendingPathComponent(fileName)
        guard let data = try? Data(contentsOf: url), let value = try? JSONDecoder().decode(ShareContext.self, from: data) else {
            return .unpaired
        }
        return value
    }

    func write(container: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        try encoder.encode(self).write(to: container.appendingPathComponent(Self.fileName), options: .atomic)
    }
}
