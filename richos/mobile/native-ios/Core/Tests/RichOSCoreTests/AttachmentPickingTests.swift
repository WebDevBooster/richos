import Foundation
import Testing
@testable import RichOSCore
@testable import RichOSFixtures

/// The + menu's Photos, Camera and Files (App Store listing drafts, blocker 5): each reaches Apple's
/// picker, what is chosen waits in the tray within the Mac's limits (25 MiB a file, 10 a message),
/// and Send turns the tray and the words into outbox messages the courier already delivers.
@Suite struct AttachmentPickingTests {
    static let limits: AttachmentLimits = {
        let json = #"{"max_file_bytes":26214400,"max_files_per_message":10,"max_message_bytes":104857600,"upload_seconds":300,"media_types":["image/jpeg","image/png","application/pdf"]}"#
        return try! JSONDecoder().decode(AttachmentLimits.self, from: Data(json.utf8))
    }()

    func paired(limits: AttachmentLimits? = Self.limits) -> AppState {
        var s = try! Fixture.named("conv-populated").state
        s.attachmentLimits = limits
        return s
    }

    func photo(_ n: Int, bytes: Int = 1_000) -> OutboxFile {
        OutboxFile(id: "att\(n)", name: "IMG_\(n).jpg", mediaType: "image/jpeg", byteCount: bytes, sha256: String(repeating: "a", count: 64), path: "pending/att\(n)-IMG_\(n).jpg")
    }

    func pdf(_ n: Int, bytes: Int = 2_000) -> OutboxFile {
        OutboxFile(id: "doc\(n)", name: "Brief \(n).pdf", mediaType: "application/pdf", byteCount: bytes, sha256: String(repeating: "b", count: 64), path: "pending/doc\(n)-Brief.pdf")
    }

    @Test func thePlusOpensTheMenuAndEachRowAsksForItsPicker() {
        let open = Reducer.reduce(paired(), .openAttachMenu).state
        #expect(open.attachMenuOpen)
        for source in [AttachSource.photos, .files] {
            let (next, effects) = Reducer.reduce(open, .pickAttachments(source))
            #expect(!next.attachMenuOpen)
            #expect(effects == [.presentPicker(source, maxCount: 10)])
        }
        // The camera takes one photo at a time.
        #expect(Reducer.reduce(open, .pickAttachments(.camera)).effects == [.presentPicker(.camera, maxCount: 1)])
    }

    @Test func aMacThatTakesNoAttachmentsSaysSoInsteadOfOpeningAPicker() {
        let (next, effects) = Reducer.reduce(paired(limits: nil), .pickAttachments(.photos))
        #expect(next.attachNotice == .macUnsupported)
        #expect(effects.filter { $0 != .persist }.isEmpty)
    }

    @Test func pickedFilesWaitInTheTrayInOrder() {
        let next = Reducer.reduce(paired(), .attachmentsPicked([photo(1), pdf(1), photo(2)])).state
        #expect(next.pendingAttachments.map(\.id) == ["att1", "doc1", "att2"])
    }

    @Test func tenAtATimeTheEleventhIsRefusedAndItsCopyRemoved() {
        var s = paired()
        s = Reducer.reduce(s, .attachmentsPicked((1...10).map { photo($0) })).state
        #expect(s.pendingAttachments.count == 10)
        let (full, effects) = Reducer.reduce(s, .attachmentsPicked([photo(11)]))
        #expect(full.pendingAttachments.count == 10)
        #expect(full.toast == .attachLimit(limit: 10))
        #expect(effects.contains(.deleteAttachments(paths: ["pending/att11-IMG_11.jpg"])))
        // And the menu does not open a picker with no room.
        #expect(Reducer.reduce(full, .pickAttachments(.photos)).effects.filter { $0 != .persist }.isEmpty)
    }

    @Test func overTwentyFiveMegabytesIsRefusedBeforeTheTray() {
        let big = pdf(9, bytes: 26_214_401)
        let (next, effects) = Reducer.reduce(paired(), .attachmentsPicked([big]))
        #expect(next.pendingAttachments.isEmpty)
        #expect(next.attachNotice == .refused(name: big.name, bytes: big.byteCount, tooLarge: true))
        #expect(effects.contains(.deleteAttachments(paths: [big.path])))
        // Exactly the limit is accepted.
        #expect(Reducer.reduce(paired(), .attachmentsPicked([pdf(8, bytes: 26_214_400)])).state.pendingAttachments.count == 1)
    }

    @Test func aTypeTheMacRefusesNeverEntersTheTray() {
        let zip = OutboxFile(id: "z", name: "Archive.zip", mediaType: "application/zip", byteCount: 10, sha256: "c", path: "pending/z-Archive.zip")
        let next = Reducer.reduce(paired(), .attachmentsPicked([zip])).state
        #expect(next.pendingAttachments.isEmpty)
        #expect(next.attachNotice == .refused(name: "Archive.zip", bytes: 10, tooLarge: false))
    }

    @Test func permissionDeniedShowsItsCard() {
        #expect(Reducer.reduce(paired(), .attachPermissionDenied(.camera)).state.attachNotice == .cameraDenied)
        #expect(Reducer.reduce(paired(), .attachPermissionDenied(.photos)).state.attachNotice == .photosDenied)
        let dismissed = Reducer.reduce(Reducer.reduce(paired(), .attachPermissionDenied(.camera)).state, .dismissAttachNotice).state
        #expect(dismissed.attachNotice == nil)
    }

    @Test func removingATrayItemDeletesItsStagedCopy() {
        let s = Reducer.reduce(paired(), .attachmentsPicked([photo(1), photo(2)])).state
        let (next, effects) = Reducer.reduce(s, .removePendingAttachment(id: "att1"))
        #expect(next.pendingAttachments.map(\.id) == ["att2"])
        #expect(effects.contains(.deleteAttachments(paths: ["pending/att1-IMG_1.jpg"])))
    }

    @Test func sendTurnsTheTrayAndTheWordsIntoAnAlbumThenEachFile() throws {
        var s = Reducer.reduce(paired(), .attachmentsPicked([photo(1), pdf(1), photo(2)])).state
        s.draft = "For the offsite expenses."
        let (next, effects) = Reducer.reduce(s, .sendDraft(clientID: "c1", at: 5_000))
        #expect(next.pendingAttachments.isEmpty)
        #expect(next.draft.isEmpty)
        let items = next.outbox.suffix(2)
        #expect(items.map(\.clientID) == ["c1", "c1-2"])
        #expect(items.map { $0.files?.map(\.id) ?? [] } == [["att1", "att2"], ["doc1"]])
        // The words ride on the album; the commit names each file by its hash, bytes fixed once.
        let album = try #require(JSONSerialization.jsonObject(with: Data(items.first!.body!.utf8)) as? [String: Any])
        #expect(album["kind"] as? String == "attachments")
        #expect(album["text"] as? String == "For the offsite expenses.")
        #expect((album["attachments"] as? [[String: String]])?.map { $0["id"] } == ["att1", "att2"])
        let file = try #require(JSONSerialization.jsonObject(with: Data(items.last!.body!.utf8)) as? [String: Any])
        #expect(file["text"] == nil)
        // The bubbles are there at once, waiting, with what they carry.
        #expect(next.messages.suffix(2).map { $0.attachments?.count ?? 0 } == [2, 1])
        #expect(effects.contains(.deliver(clientID: "c1")))
    }

    @Test func filesAloneCarryTheWordsOnTheLastOne() throws {
        var s = Reducer.reduce(paired(), .attachmentsPicked([pdf(1), pdf(2)])).state
        s.draft = "Both contracts."
        let next = Reducer.reduce(s, .sendDraft(clientID: "c9", at: 1)).state
        let bodies = next.outbox.suffix(2).map { (try? JSONSerialization.jsonObject(with: Data($0.body!.utf8))) as? [String: Any] }
        #expect(bodies.first??["text"] == nil)
        #expect(bodies.last??["text"] as? String == "Both contracts.")
    }

    @Test func aTrayWithoutWordsStillSends() {
        let s = Reducer.reduce(paired(), .attachmentsPicked([photo(1)])).state
        let next = Reducer.reduce(s, .sendDraft(clientID: "c2", at: 1)).state
        #expect(next.outbox.last?.clientID == "c2")
        #expect(next.messages.last?.text == "")
    }

    @Test func theTrayIsKeptAcrossARelaunch() throws {
        let s = Reducer.reduce(paired(), .attachmentsPicked([photo(1)])).state
        let restored = try AppState(restoring: s.persisted)
        #expect(restored.pendingAttachments == s.pendingAttachments)
        // A state saved before the tray existed still loads.
        var old = s.persisted
        old.pendingAttachments = nil
        #expect(try AppState(restoring: old).pendingAttachments.isEmpty)
    }

    @Test func theCourierDeliversATrayMessageLikeAShare() {
        // The outbox item is the same shape `take` makes for a share: files plus exact commit bytes.
        var s = Reducer.reduce(paired(), .attachmentsPicked([photo(1)])).state
        s = Reducer.reduce(s, .sendDraft(clientID: "c3", at: 1)).state
        let item = s.outbox.last!
        #expect(item.kind == .text && item.files?.count == 1 && item.body != nil)
        // Accepted: the phone's copy goes.
        let (_, effects) = Reducer.reduce(s, .deliveryAccepted(clientID: "c3", at: 2))
        #expect(effects.contains(.deleteAttachments(paths: ["pending/att1-IMG_1.jpg"])))
    }
}
