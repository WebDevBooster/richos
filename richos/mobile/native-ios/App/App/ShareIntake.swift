import Foundation
import RichOSCore

/// The app's half of "Share to Rich" (ceo-decisions §75): a share the Share extension saved in the
/// App Group becomes the core's outbox items, with the extension's own client ids and commit bytes.
///
/// Order, so nothing shared is ever lost: copy the files into the app's own store, hand the core the
/// share, wait until the state holding it is on disk, and only then remove it from the Share inbox
/// (`SharePlatform.taken`). A crash anywhere before that leaves the share in the inbox, and taking it
/// again adds nothing (the core ignores client ids it already has). "Sent" appears only when the
/// Mac's commit answers 200, which the core's courier decides.
enum ShareIntake {
    /// Where the app keeps its copies of attached files until the Mac accepts them:
    /// `<clientID>/<attachmentID>-<name>` under Application Support, next to the app's state.
    static func attachmentsDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("RichOS/Attachments", isDirectory: true)
    }

    static func storedPath(clientID: String, item: SharedItem) -> String {
        "\(clientID)/\(item.id)-\(item.fileName)"
    }

    /// The core's view of a share. For a share still to be sent, each file is copied into the app's
    /// store first; a share the Mac already accepted needs no copies.
    static func intake(for envelope: ShareEnvelope, inbox: ShareInbox, directory: URL) throws -> SharedIntake {
        let accepted: Bool
        if case .sent = envelope.delivery { accepted = true } else { accepted = false }
        let fm = FileManager.default
        let messages = try envelope.messages.map { message -> SharedIntake.Item in
            let items = message.itemIDs.compactMap { id in envelope.items.first { $0.id == id } }
            guard items.count == message.itemIDs.count else { throw CoreError("share \(envelope.id) names a file it does not hold") }
            let files = try items.map { item -> OutboxFile in
                let path = storedPath(clientID: message.clientID, item: item)
                if !accepted {
                    guard let source = inbox.fileURL(for: item) else { throw CoreError("share file outside the inbox") }
                    let target = directory.appendingPathComponent(path)
                    // A copy already made for this attachment id is the same file, and the courier may
                    // be reading it: keep it. A new copy lands under its final name only when whole.
                    if !fm.fileExists(atPath: target.path) {
                        try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                        let partial = target.appendingPathExtension("part")
                        if fm.fileExists(atPath: partial.path) { try fm.removeItem(at: partial) }
                        try fm.copyItem(at: source, to: partial)
                        try fm.moveItem(at: partial, to: target)
                    }
                }
                return OutboxFile(id: item.id, name: item.fileName, mediaType: item.mediaType, byteCount: item.byteCount,
                                  sha256: item.sha256, path: path)
            }
            let body = (try? JSONSerialization.jsonObject(with: Data(message.commitBody.utf8))) as? [String: Any]
            return SharedIntake.Item(clientID: message.clientID, commitBody: message.commitBody,
                                     text: body?["text"] as? String, files: files)
        }
        return SharedIntake(messages: messages, createdAt: envelope.createdAtMs, alreadyAccepted: accepted)
    }

    /// One pass at a time: launch and becoming active can both ask at once.
    @MainActor private static var taking = false

    /// Takes every waiting share, oldest first. Called at launch and whenever the app becomes active.
    @MainActor
    static func takeWaiting(into store: AppStore, nowMs: Int64, inbox: ShareInbox? = .shared,
                            directory: URL = attachmentsDirectory()) async {
        #if DEBUG
        if store.effectsSuspended { return }
        #endif
        guard let inbox, !taking else { return }
        taking = true
        defer { taking = false }
        for envelope in SharePlatform.waiting(nowMs: nowMs, inbox: inbox) {
            let before = Set(store.state.messages.flatMap { [$0.id, $0.clientID].compactMap { $0 } })
            guard let intake = try? intake(for: envelope, inbox: inbox, directory: directory) else { continue }
            store.send(.takeShare(intake, at: nowMs))
            await store.settle()
            let held = Set(store.state.messages.flatMap { [$0.id, $0.clientID].compactMap { $0 } })
            let taken = intake.messages.allSatisfy { held.contains($0.clientID) }
            if taken, store.savesWrites {
                SharePlatform.taken(envelope, inbox: inbox)
            } else if !intake.alreadyAccepted {
                // Not taken (not paired, or the outbox is full): the share stays in the inbox, and the
                // copies made for it go, except those a message the core already had still uses.
                for message in intake.messages where !before.contains(message.clientID) && !held.contains(message.clientID) {
                    try? FileManager.default.removeItem(at: directory.appendingPathComponent(message.clientID, isDirectory: true))
                }
            }
        }
    }
}
