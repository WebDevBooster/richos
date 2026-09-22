import Foundation
import Testing
@testable import RichOSCore
@testable import RichOSFixtures

/// Attached files held as bytes, recording what was removed.
actor MemoryAttachments: AttachmentStore {
    var files: [String: Data]
    private(set) var removed: [String] = []
    init(_ files: [String: Data]) { self.files = files }
    func bytes(atPath path: String) async throws -> Data {
        guard let data = files[path] else { throw CoreError("no file at \(path)") }
        return data
    }
    func remove(path: String) async {
        files[path] = nil
        removed.append(path)
    }
}

/// A Mac with the attachment intake (`richos/app/src-tauri/src/phone/routes.rs`): each upload is
/// answered 200; each commit answers the next scripted status, 200 when the script runs out.
actor AttachmentMac: HTTPTransport {
    private(set) var requests: [HTTPRequest] = []
    var commits: [(Int, String)]
    init(commits: [(Int, String)]) { self.commits = commits }

    func send(_ request: HTTPRequest, origin: String) async throws -> HTTPResponse {
        requests.append(request)
        let challenge = ["X-RichOS-Challenge": "Xqra0YQOgVJ9WLmQy9eYs1LSoxDt1Ggv"]
        if request.target == "/api/challenge" { return HTTPResponse(status: 204, headers: challenge) }
        if request.target.contains("kind=attachment&") {
            return HTTPResponse(status: 200, headers: challenge, body: Data(#"{"attachment_id":"x","duplicate":false}"#.utf8))
        }
        let (status, body) = commits.isEmpty
            ? (200, #"{"message_id":"intake_1","cursor":5,"thread_id":"thr_5c1e","accepted_at":"2026-09-22T13:00:00.412Z","attachments":[],"duplicate":false}"#)
            : commits.removeFirst()
        return HTTPResponse(status: status, headers: challenge, body: Data(body.utf8))
    }
}

@Suite struct AttachmentTests {
    static let photo = OutboxFile(id: "p1", name: "IMG_0001.jpg", mediaType: "image/jpeg", byteCount: 4, sha256: String(repeating: "a", count: 64), path: "c1/p1-IMG_0001.jpg")
    static let pdf = OutboxFile(id: "f1", name: "Plan.pdf", mediaType: "application/pdf", byteCount: 3, sha256: String(repeating: "b", count: 64), path: "c2/f1-Plan.pdf")

    static func commit(_ clientID: String, _ files: [OutboxFile], text: String?) -> String {
        String(decoding: PairingWire.attachmentCommitBody(clientID: clientID, threadID: "thr_5c1e", text: text,
                                                          files: files.map { ($0.id, $0.sha256) }, sentAtISO: "2026-09-22T13:00:00.000Z"), as: UTF8.self)
    }

    static func intake(accepted: Bool = false) -> SharedIntake {
        SharedIntake(messages: [
            .init(clientID: "c1", commitBody: commit("c1", [photo], text: "From the walk"), text: "From the walk", files: [photo]),
            .init(clientID: "c2", commitBody: commit("c2", [pdf], text: nil), text: nil, files: [pdf]),
        ], createdAt: 1_000, alreadyAccepted: accepted)
    }

    static func paired() throws -> AppState { try Fixture.named("conv-empty").state }

    @Test func aShareGoesIntoTheOutboxWithItsOwnIdsAndBytes() throws {
        let (s, effects) = Reducer.reduce(try Self.paired(), .takeShare(Self.intake(), at: 2_000))
        #expect(s.outbox.map(\.clientID) == ["c1", "c2"], "its own client ids, in the share's order")
        #expect(s.outbox[0].body == Self.intake().messages[0].commitBody, "the stored commit bytes, unchanged")
        #expect(s.outbox[0].files == [Self.photo] && s.outbox[1].files == [Self.pdf])
        #expect(s.messages.suffix(2).map(\.delivery) == [.sending, .waiting], "the first is on its way; nothing says Sent yet")
        #expect(s.messages.last?.attachments?.map(\.name) == ["Plan.pdf"] && s.messages[s.messages.count - 2].text == "From the walk")
        #expect(effects.contains(.persist) && effects.contains(.deliver(clientID: "c1")), "saved before anything is sent")
        #expect(try AppState(restoring: s.persisted).outbox.map(\.files) == s.outbox.map(\.files), "the files survive a relaunch")

        let (again, _) = Reducer.reduce(s, .takeShare(Self.intake(), at: 3_000))
        #expect(again.outbox.count == 2 && again.messages.count == s.messages.count, "taking the same share twice adds nothing")
    }

    @Test func aShareTheMacAlreadyAcceptedIsShownNotSent() throws {
        let (s, effects) = Reducer.reduce(try Self.paired(), .takeShare(Self.intake(accepted: true), at: 2_000))
        #expect(s.outbox.isEmpty && !effects.contains { if case .deliver = $0 { return true } else { return false } })
        #expect(s.messages.suffix(2).allSatisfy { $0.delivery == nil })
    }

    @Test func aShareIsNotTakenUnpairedOrIntoAFullOutbox() throws {
        var unpaired = try Self.paired()
        unpaired.pairing = .unpaired
        #expect(Reducer.reduce(unpaired, .takeShare(Self.intake(), at: 1)).0.outbox.isEmpty)
        var full = try Self.paired()
        full.outbox = (0..<99).map { OutboxItem(clientID: "q\($0)", kind: .text, body: "{}", queuedAt: 0, state: .blocked) }
        let (s, _) = Reducer.reduce(full, .takeShare(Self.intake(), at: 1))
        #expect(s.outbox.count == 99 && s.toast == .outboxFull(limit: 100), "left in the Share inbox, not half-taken")
    }

    @Test func uploadsThenCommitAndOnlyTheCommits200IsAcceptance() async throws {
        let store = MemoryAttachments(["c1/p1-IMG_0001.jpg": Data("jpeg".utf8), "c2/f1-Plan.pdf": Data("pdf".utf8)])
        let missing = #"{"accepted":false,"retry":true,"missing":["p1"],"reason":"Some files have not reached your Mac yet."}"#
        let mac = AttachmentMac(commits: [(422, missing), (503, #"{"retry":true}"#)])
        let network = NetworkEffects(transport: mac, stream: ScriptedStream([]), identities: MemoryIdentityStore(), attachments: store)
        let host = try await HeadlessHost(storage: MemoryStorage(), handler: network)
        _ = try await host.replace(with: try Self.paired())

        var s = try await host.dispatch(.takeShare(Self.intake(), at: 2_000))
        // First attempt: upload, commit 422 missing p1, upload p1 again, the SAME bytes again: 503.
        #expect(s.outbox.map(\.clientID) == ["c1", "c2"] && s.messages.first { $0.id == "c1" }?.delivery == .waiting,
                "uploads answered 200 and still not Sent: only the commit's 200 is")
        s = try await host.dispatch(.retryNow(at: 9_000))
        s = try await host.dispatch(.retryNow(at: 9_500))
        #expect(s.outbox.isEmpty && s.messages.suffix(2).allSatisfy { $0.delivery == nil }, "both commits answered 200")

        let sent = await mac.requests.filter { $0.target != "/api/challenge" }
        let targets = sent.map(\.target).map { $0.components(separatedBy: "&auth=")[0] }
        #expect(targets.filter { $0 == "/api/messages" }.count == 4)
        #expect(targets[0].hasPrefix("/api/messages?kind=attachment&client_id=c1&attachment_id=p1"))
        #expect(targets[1] == "/api/messages" && targets[2].contains("attachment_id=p1") && targets[3] == "/api/messages")
        let commits = sent.filter { $0.target == "/api/messages" && String(decoding: $0.body ?? Data(), as: UTF8.self).contains(#""client_id":"c1""#) }
        #expect(commits.count == 3 && Set(commits.map(\.body)).count == 1, "every commit of c1 carries the same bytes")
        #expect(sent[0].headers["Content-Type"] == "image/jpeg" && sent[0].body == Data("jpeg".utf8))
        #expect(await store.removed == ["c1/p1-IMG_0001.jpg", "c2/f1-Plan.pdf"], "the phone's copies go once the Mac accepted")
    }

    @Test func aFileMissingOnThePhoneBlocksOnlyItsMessage() async throws {
        let store = MemoryAttachments(["c2/f1-Plan.pdf": Data("pdf".utf8)])
        let network = NetworkEffects(transport: AttachmentMac(commits: []), stream: ScriptedStream([]), identities: MemoryIdentityStore(), attachments: store)
        let host = try await HeadlessHost(storage: MemoryStorage(), handler: network)
        _ = try await host.replace(with: try Self.paired())
        let s = try await host.dispatch(.takeShare(Self.intake(), at: 2_000))
        #expect(s.outbox.map(\.clientID) == ["c1"] && s.outbox[0].state == .blocked)
        #expect(s.outbox[0].lastReason == "IMG_0001.jpg is no longer on this iPhone." && s.messages.last?.delivery == nil)
        let (discarded, effects) = Reducer.reduce(s, .discardMessage(id: "c1"))
        #expect(discarded.outbox.isEmpty && effects.contains(.deleteAttachments(paths: ["c1/p1-IMG_0001.jpg"])))
    }

    @Test func theMacsRowReadsBackAsCaptionAndFilesAndRetiresTheBubble() throws {
        let words = "From the walk\n\nAttached from the phone (2 files, saved on this Mac):\n- /Users/a/Library/RichOS/attachments/thr_5c1e/c1/IMG_0001.jpg (image/jpeg, 4 bytes)\n- /Users/a/x (y)/Plan (1).pdf (application/pdf, 3 bytes)"
        let parsed = try #require(AttachmentDescription.parse(words, rowID: "turn_9:user"))
        #expect(parsed.caption == "From the walk" && parsed.files.map(\.name) == ["IMG_0001.jpg", "Plan (1).pdf"])
        #expect(parsed.files.map(\.byteCount) == [4, 3] && parsed.files[1].mediaType == "application/pdf")
        #expect(AttachmentDescription.parse("Attached from the phone (1 file, saved on this Mac):\n- /a/b.png (image/png, 9 bytes)", rowID: "r")?.caption == "")
        for text in ["Attached from the phone (2 files, saved on this Mac):\n- /a/b.png (image/png, 9 bytes)",
                     "words\nAttached from the phone (1 file, saved on this Mac):\n- /a/b.png (image/png, 9 bytes)",
                     "Attached from the phone (1 files, saved on this Mac):\n- /a/b.png (image/png, 9 bytes)",
                     "Attached from the phone (1 file, saved on this Mac):\n- /a/b.png (image/png, many bytes)", "plain words"] {
            #expect(AttachmentDescription.parse(text, rowID: "r") == nil, "not the Mac's exact shape: stays text")
        }

        let row = StreamRow(id: "turn_9:user", threadID: "thr_5c1e", cursor: 9, role: "ceo", text: "Photo\n\nAttached from the phone (1 file, saved on this Mac):\n- /m/IMG_0001.jpg (image/jpeg, 4 bytes)", complete: true)
        #expect(row.message.text == "Photo" && row.message.attachments?.count == 1)
        var s = try Self.paired()
        s.messages.append(Message(id: "c1", author: .me, text: "Photo", sentAt: 1, clientID: "c1",
                                  attachments: [AttachmentRef(id: "p1", name: "IMG_0001.jpg", mediaType: "image/jpeg", byteCount: 4)]))
        s.messages.append(Message(id: "t1", author: .me, text: "Photo", sentAt: 2, clientID: "t1"))
        let (merged, _) = Reducer.reduce(s, .messagesArrived([row.message]))
        #expect(!merged.messages.contains { $0.id == "c1" } && merged.messages.contains { $0.id == "t1" },
                "the photo's bubble is retired by its row; a text bubble with the same words is not")
        #expect(merged.messages.first { $0.id == "turn_9:user" }?.attachments?.first?.id == "p1", "the phone's own file ids are kept")
    }

    @Test func theStoreRefusesPathsOutsideIt() async throws {
        let store = FileAttachmentStore(directory: URL(fileURLWithPath: "/nonexistent-richos-test"))
        for path in ["../x", "/etc/hosts", "a/../../b", "a/b/c", ""] {
            await #expect(throws: CoreError.self) { _ = try await store.bytes(atPath: path) }
        }
    }
}
