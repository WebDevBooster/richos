// The app's half of "Share to Rich" (ceo-decisions §75), proven on a simulator with real files: a
// share the extension saved becomes outbox items with the extension's own client ids and commit
// bytes, and it leaves the Share inbox only once the state holding it is on disk. The core's half
// (the outbox, the courier, "Sent" only on the commit's 200) is proven headless in
// `Core/Tests/RichOSCoreTests/AttachmentTests.swift`; the extension's in `ShareExtension/Tests`.
import Foundation
import Testing
import RichOSCore
import RichOSFixtures
@testable import RichOSNative

/// Storage that refuses every write, as a full disk would.
private struct RefusingStorage: Storage {
    func read(_ key: String) async throws -> Data? { nil }
    func write(_ key: String, _ data: Data) async throws { throw CoreError("disk full") }
}

/// `ShareIntake.takeWaiting` holds one pass at a time, so these run one after another.
@Suite(.serialized) @MainActor
struct ShareIntakeTests {
    /// A fresh App Group stand-in, attachment store and state folder, all inside the test app's
    /// sandbox on a simulator this run created.
    struct Place {
        let root: URL
        var inbox: ShareInbox { ShareInbox(container: root.appendingPathComponent("group", isDirectory: true)) }
        var attachments: URL { root.appendingPathComponent("attachments", isDirectory: true) }
        var state: URL { root.appendingPathComponent("state", isDirectory: true) }

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("share-intake-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }

        func remove() { try? FileManager.default.removeItem(at: root) }

        func files(in directory: URL) -> [String] {
            let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey])
            var found: [String] = []
            while let url = enumerator?.nextObject() as? URL {
                guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
                found.append(String(url.standardizedFileURL.path.dropFirst(directory.standardizedFileURL.path.count + 1)))
            }
            return found.sorted()
        }
    }

    static let photoBytes = Data("not really a jpeg, but bytes the Mac hashes".utf8)
    static let pdfBytes = Data("%PDF-1.7 a plan".utf8)

    /// A photo and a PDF with a caption, written by the extension's own code: two messages, the album
    /// carrying the caption and the file on its own.
    static func share(in place: Place, nowMs: Int64 = 1_758_000_000_000) throws -> ShareEnvelope {
        let staged = place.root.appendingPathComponent("staged", isDirectory: true)
        try FileManager.default.createDirectory(at: staged, withIntermediateDirectories: true)
        let photo = staged.appendingPathComponent("IMG_0001.jpg"), pdf = staged.appendingPathComponent("Plan.pdf")
        try photoBytes.write(to: photo)
        try pdfBytes.write(to: pdf)
        return try place.inbox.write(caption: "From the walk",
                                     files: [StagedShareFile(url: photo, suggestedName: "IMG_0001.jpg", mediaType: "image/jpeg"),
                                             StagedShareFile(url: pdf, suggestedName: "Plan.pdf", mediaType: "application/pdf")],
                                     threadID: "thr_5c1e", nowMs: nowMs)
    }

    static func store(_ state: AppState, storage: any Storage) -> AppStore {
        AppStore(state: state, runner: EffectRunner(storage: storage))
    }

    static func paired() throws -> AppState { try Fixture.named("conv-empty").state }

    @Test func aShareBecomesTheCoresMessagesWithTheExtensionsIdsBytesAndOwnCopies() throws {
        let place = try Place()
        defer { place.remove() }
        let envelope = try Self.share(in: place)
        #expect(envelope.messages.count == 2, "the album, then the file")

        let intake = try ShareIntake.intake(for: envelope, inbox: place.inbox, directory: place.attachments)
        #expect(!intake.alreadyAccepted && intake.createdAt == envelope.createdAtMs)
        #expect(intake.messages.map(\.clientID) == envelope.messages.map(\.clientID), "the extension's own client ids")
        #expect(intake.messages.map(\.commitBody) == envelope.messages.map(\.commitBody), "the stored commit bytes, unchanged")
        #expect(intake.messages.map(\.text) == ["From the walk", nil], "the caption rides on the album only")

        for (message, taken) in zip(envelope.messages, intake.messages) {
            let items = message.itemIDs.compactMap { id in envelope.items.first { $0.id == id } }
            #expect(taken.files.map(\.id) == items.map(\.id) && taken.files.map(\.sha256) == items.map(\.sha256))
            for file in taken.files {
                #expect(file.path == "\(message.clientID)/\(file.id)-\(file.name)")
                let copy = try Data(contentsOf: place.attachments.appendingPathComponent(file.path))
                let item = try #require(items.first { $0.id == file.id })
                let original = try Data(contentsOf: try #require(place.inbox.fileURL(for: item)))
                #expect(copy == original, "the app's copy is the shared bytes")
            }
        }
        #expect(!place.files(in: place.attachments).contains { $0.hasSuffix(".part") }, "no half-copied file is left")
    }

    @Test func aShareTheMacAlreadyAcceptedCopiesNothing() throws {
        let place = try Place()
        defer { place.remove() }
        let sent = try place.inbox.markSent(try Self.share(in: place), atMs: 1_758_000_000_500)
        let intake = try ShareIntake.intake(for: sent, inbox: place.inbox, directory: place.attachments)
        #expect(intake.alreadyAccepted, "shown as sent, never sent again")
        #expect(place.files(in: place.attachments).isEmpty, "nothing to upload, so nothing copied")
    }

    @Test func aCopyAlreadyMadeIsKeptBecauseTheCourierMayBeReadingIt() throws {
        let place = try Place()
        defer { place.remove() }
        let envelope = try Self.share(in: place)
        let first = try ShareIntake.intake(for: envelope, inbox: place.inbox, directory: place.attachments)
        let path = place.attachments.appendingPathComponent(first.messages[0].files[0].path)
        let marker = Data("the copy the courier is uploading".utf8)
        try marker.write(to: path)
        _ = try ShareIntake.intake(for: envelope, inbox: place.inbox, directory: place.attachments)
        #expect(try Data(contentsOf: path) == marker)
    }

    @Test func aShareNamingAFileItDoesNotHoldIsRefused() throws {
        let place = try Place()
        defer { place.remove() }
        var envelope = try Self.share(in: place)
        envelope.messages[1].itemIDs.append("not-in-this-share")
        #expect(throws: CoreError.self) { try ShareIntake.intake(for: envelope, inbox: place.inbox, directory: place.attachments) }
    }

    @Test func aTakenShareIsSavedFirstThenLeavesTheInbox() async throws {
        let place = try Place()
        defer { place.remove() }
        let envelope = try Self.share(in: place)
        let storage = FileStorage(directory: place.state)
        let store = Self.store(try Self.paired(), storage: storage)

        await ShareIntake.takeWaiting(into: store, nowMs: 1_758_000_001_000, inbox: place.inbox, directory: place.attachments)

        let ids = envelope.messages.map(\.clientID)
        #expect(store.state.outbox.map(\.clientID) == ids, "into the outbox with the extension's client ids")
        #expect(store.state.outbox.map(\.body) == envelope.messages.map(\.commitBody), "with its stored commit bytes")
        #expect(!store.state.messages.contains { ids.contains($0.id) && $0.delivery == nil }, "nothing says Sent before the Mac's 200")
        #expect(place.inbox.loadAll().isEmpty, "removed from the Share inbox once taken")
        #expect(place.files(in: place.attachments).count == 2, "the app holds its own copies")

        // What a relaunch finds: the share is in the saved state, not only in memory.
        try await store.reloadFromStorage()
        #expect(store.state.outbox.map(\.clientID) == ids && store.state.outbox.map(\.body) == envelope.messages.map(\.commitBody))
        #expect(store.state.outbox.flatMap { $0.files ?? [] }.count == 2)
    }

    @Test func aShareFoundAgainAfterACrashAddsNothingAndKeepsTheCopies() async throws {
        let place = try Place()
        defer { place.remove() }
        let envelope = try Self.share(in: place)
        let shareDirectory = place.inbox.root.appendingPathComponent(envelope.id, isDirectory: true)
        let kept = place.root.appendingPathComponent("kept-share", isDirectory: true)
        try FileManager.default.copyItem(at: shareDirectory, to: kept)
        let store = Self.store(try Self.paired(), storage: FileStorage(directory: place.state))
        await ShareIntake.takeWaiting(into: store, nowMs: 1_758_000_001_000, inbox: place.inbox, directory: place.attachments)
        let messages = store.state.messages.count, outbox = store.state.outbox

        // The app stopped after saving and before removing the share: it is in the inbox again.
        try FileManager.default.copyItem(at: kept, to: shareDirectory)
        #expect(place.inbox.loadAll().map(\.id) == [envelope.id])
        await ShareIntake.takeWaiting(into: store, nowMs: 1_758_000_002_000, inbox: place.inbox, directory: place.attachments)
        #expect(store.state.messages.count == messages && store.state.outbox == outbox, "taking it again adds nothing")
        #expect(place.inbox.loadAll().isEmpty)
        #expect(place.files(in: place.attachments).count == 2, "the copies the outbox uses are kept")
    }

    @Test func aShareThatCannotBeTakenStaysInTheInboxAndItsCopiesGo() async throws {
        let place = try Place()
        defer { place.remove() }
        let envelope = try Self.share(in: place)
        let store = Self.store(.initial, storage: FileStorage(directory: place.state))
        await ShareIntake.takeWaiting(into: store, nowMs: 1_758_000_001_000, inbox: place.inbox, directory: place.attachments)
        #expect(store.state.outbox.isEmpty, "not paired: nothing is sent")
        #expect(place.inbox.loadAll().map(\.id) == [envelope.id], "the share waits in the inbox")
        #expect(place.files(in: place.attachments).isEmpty, "the copies made for it are removed")
    }

    @Test func aShareIsNeverReleasedWhenTheStateCouldNotBeSaved() async throws {
        let place = try Place()
        defer { place.remove() }
        let envelope = try Self.share(in: place)
        let store = Self.store(try Self.paired(), storage: RefusingStorage())
        await ShareIntake.takeWaiting(into: store, nowMs: 1_758_000_001_000, inbox: place.inbox, directory: place.attachments)
        #expect(!store.savesWrites)
        #expect(place.inbox.loadAll().map(\.id) == [envelope.id], "an unsaved share stays where the extension put it")
    }
}
