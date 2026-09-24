import CryptoKit
import Foundation
import Testing
@testable import RichOSCore
@testable import RichOSFixtures

/// PRD J4 (`2026-09-24-richconnect-perceived-speed-and-no-annoyance.md` §3): one row per sent
/// message from the tap to the Mac's acknowledgement; §6 counts a duplicate row and a rearranging
/// screen as annoyances. A sent message is ONE line that changes in place, pending -> accepted ->
/// echoed, whichever of the HTTP acceptance and the stream echo reaches the phone first, and
/// through replay and relaunch. The Android rule it must match: `EchoReconciliationTest.kt`
/// (richos main `c29f996a`).
@Suite struct EchoBeforeAcceptanceTests {
    static let earlier = [
        Message(id: "t1:user", author: .me, text: "where are we?", sentAt: 1, cursor: 1),
        Message(id: "t1:text:0", author: .rich, text: "On it.", sentAt: 2, cursor: 2),
    ]

    func row(_ id: String, _ cursor: Int, _ text: String, at: Int64, author: Message.Author = .me,
             attachments: [AttachmentRef]? = nil) -> Message {
        Message(id: id, author: author, text: text, sentAt: at, cursor: cursor, attachments: attachments)
    }

    func start() throws -> AppState {
        var s = try Fixture.named("conv-empty").state
        s = Reducer.reduce(s, .messagesArrived(Self.earlier)).state
        return s
    }

    /// The lines that show `text`, by their on-screen identity, in the order they are drawn: the
    /// list draws `Transcript.visible` keyed by `Message.lineID` (`ScreenModel.swift`, `Rows.swift`).
    func shown(_ s: AppState, _ text: String) -> [String] {
        Transcript.visible(s).filter { $0.text == text }.map(\.lineID)
    }

    /// Every line of yours, by its on-screen identity.
    func mine(_ s: AppState) -> [String] {
        Transcript.visible(s).filter { $0.author == .me }.map(\.lineID)
    }

    func send(_ s: inout AppState, _ text: String, _ clientID: String, at: Int64) -> [Effect] {
        s.draft = text
        let next = Reducer.reduce(s, .sendDraft(clientID: clientID, at: at))
        s = next.state
        return next.effects
    }

    func apply(_ s: inout AppState, _ action: Action) -> [Effect] {
        let next = Reducer.reduce(s, action)
        s = next.state
        return next.effects
    }

    @Test func echoedBeforeTheAcceptanceTheMessageIsNeverOnScreenTwice() throws {
        var s = try start()
        _ = send(&s, "fast Mac", "c1", at: 10)
        #expect(shown(s, "fast Mac") == ["c1"], "pending at the tap")
        _ = apply(&s, .messagesArrived([row("t2:user", 3, "fast Mac", at: 11)]))
        #expect(shown(s, "fast Mac") == ["c1"], "the echo beat the HTTP answer: one line, the same identity")
        _ = apply(&s, .deliveryAccepted(clientID: "c1", at: 12))
        #expect(shown(s, "fast Mac") == ["c1"], "accepted after its echo: still one line")
        #expect(s.outbox.isEmpty)
        _ = apply(&s, .messagesArrived([row("t2:text:0", 4, "Reply.", at: 13, author: .rich)]))
        #expect(s.messages.map(\.text) == ["where are we?", "On it.", "fast Mac", "Reply."])
    }

    @Test func acceptedBeforeTheEchoTheMessageKeepsOneIdentity() throws {
        var s = try start()
        _ = send(&s, "Managed probe three", "c1", at: 10)
        let pending = shown(s, "Managed probe three")
        #expect(pending == ["c1"])
        _ = apply(&s, .deliveryAccepted(clientID: "c1", at: 11))
        #expect(shown(s, "Managed probe three") == pending, "accepted, not yet echoed: the same line")
        _ = apply(&s, .messagesArrived([row("t2:user", 3, "Managed probe three", at: 12)]))
        #expect(shown(s, "Managed probe three") == pending, "echoed: still the same line, changed in place")
    }

    /// Identical words sent twice, each echo beating its acceptance, an old identical row replayed,
    /// and a relaunch through the real persistence path in between. Delivery stays exactly-once:
    /// the only repeat is the relaunch's re-send of the same bytes, which the Mac deduplicates by
    /// `client_id`.
    @Test func identicalWordsSentTwiceStayTwoLinesThroughEarlyEchoReplayAndRelaunch() async throws {
        let storage = MemoryStorage()
        var runner = EffectRunner(storage: storage, clock: FixedClock(ms: 1_000))
        var s = try start()
        let old = row("t0:user", 3, "again", at: 3)
        _ = apply(&s, .messagesArrived([old]))
        var delivered: [String] = []
        func step(_ effects: [Effect]) async throws {
            delivered += effects.compactMap { if case .deliver(let id) = $0 { return id } else { return nil } }
            try await runner.run([.persist], state: s)
        }
        try await step(send(&s, "again", "c1", at: 10))
        try await step(send(&s, "again", "c2", at: 11))
        let keys = shown(s, "again")
        #expect(keys == ["t0:user", "c1", "c2"], "the old row and both new messages")
        let c2Body = s.outbox.first { $0.clientID == "c2" }?.body

        let first = row("t2:user", 4, "again", at: 12)
        try await step(apply(&s, .messagesArrived([first])))
        #expect(shown(s, "again") == keys, "the first echo beat its acceptance: still three lines")
        try await step(apply(&s, .messagesArrived([old])))
        #expect(shown(s, "again") == keys, "an old row replayed cannot consume a new send")
        try await step(apply(&s, .deliveryAccepted(clientID: "c1", at: 13)))
        #expect(shown(s, "again") == keys, "the first acceptance after its echo")

        // Relaunch: a new runner over the same storage, as a new process reads it.
        runner = EffectRunner(storage: storage, clock: FixedClock(ms: 1_000))
        s = try #require(try await runner.load())
        #expect(shown(s, "again") == keys, "relaunched between the two echoes: the same lines in the same order")
        try await step(apply(&s, .messagesArrived(Self.earlier + [old, first])))
        #expect(shown(s, "again") == keys, "a replayed snapshot cannot consume the second send")
        try await step(apply(&s, .tick(at: 20)))
        #expect(s.outbox.first { $0.clientID == "c2" }?.body == c2Body, "the re-send carries the same bytes")

        let second = row("t3:user", 5, "again", at: 21)
        try await step(apply(&s, .messagesArrived([second])))
        #expect(shown(s, "again") == keys, "the second echo beat its acceptance after the relaunch")
        try await step(apply(&s, .deliveryAccepted(clientID: "c2", at: 22)))
        #expect(shown(s, "again") == keys, "both echoed and accepted: three lines, the same three identities")
        #expect(s.messages.filter { $0.text == "again" }.map(\.id) == ["t0:user", "t2:user", "t3:user"])
        #expect(s.outbox.isEmpty)
        #expect(delivered == ["c1", "c2", "c2"], "each message is sent once; c2 again only after the relaunch")
    }

    @Test func aLostAcknowledgementShowsOneLineAndTheRetryIsTheSameMessage() throws {
        var s = try start()
        let firstTry = send(&s, "ack lost", "c1", at: 10)
        #expect(firstTry.contains(.deliver(clientID: "c1")))
        let body = s.outbox.first?.body
        _ = apply(&s, .deliveryFailed(clientID: "c1", failure: .retryable(reason: "unreachable"), at: 11))
        #expect(s.outbox.first?.state == .waiting, "the Mac's answer never came: a retry is owed")
        _ = apply(&s, .messagesArrived([row("t2:user", 3, "ack lost", at: 12)]))
        #expect(shown(s, "ack lost") == ["c1"], "the echo proves the Mac has it: one line")
        let retry = apply(&s, .retryNow(at: 13))
        #expect(retry.contains(.deliver(clientID: "c1")))
        #expect(s.outbox.count == 1 && s.outbox.first?.body == body, "the retry is the same bytes, never a second message")
        #expect(shown(s, "ack lost") == ["c1"])
        _ = apply(&s, .deliveryAccepted(clientID: "c1", at: 14))
        #expect(shown(s, "ack lost") == ["c1"])
        #expect(s.outbox.isEmpty)
    }

    @Test func aMessageTheMacRefusedKeepsItsOwnLineBesideAnIdenticalRow() throws {
        var s = try start()
        _ = send(&s, "needs you", "c1", at: 10)
        _ = apply(&s, .deliveryFailed(clientID: "c1", failure: .refused(reason: "conflict"), at: 11))
        _ = apply(&s, .messagesArrived([row("t2:user", 3, "needs you", at: 12)]))
        #expect(shown(s, "needs you") == ["t2:user", "c1"], "Try again and Discard stay reachable")
    }

    @Test(arguments: [true, false]) func photosAreMatchedByCaptionAndCountInEitherOrder(echoFirst: Bool) throws {
        var s = try start()
        s.attachmentLimits = AttachmentPickingTests.limits
        let files = (1...2).map { n in
            OutboxFile(id: "att\(n)", name: "IMG_\(n).jpg", mediaType: "image/jpeg", byteCount: 1_000,
                       sha256: String(repeating: "a", count: 64), path: "pending/att\(n)-IMG_\(n).jpg")
        }
        _ = apply(&s, .attachmentsPicked(files))
        _ = send(&s, "look", "c1", at: 10)
        #expect(shown(s, "look") == ["c1"])
        // The same words without the files are a different message.
        _ = apply(&s, .messagesArrived([row("t2:user", 3, "look", at: 11)]))
        #expect(shown(s, "look") == ["t2:user", "c1"])
        let described = (1...2).map { AttachmentRef(id: "/Users/x/IMG_\($0).jpg", name: "IMG_\($0).jpg", mediaType: "image/jpeg", byteCount: 1_000) }
        let echo = Action.messagesArrived([row("t3:user", 4, "look", at: 12, attachments: described)])
        let accepted = Action.deliveryAccepted(clientID: "c1", at: 13)
        for action in echoFirst ? [echo, accepted] : [accepted, echo] {
            _ = apply(&s, action)
            #expect(shown(s, "look") == ["t2:user", "c1"], "echoFirst=\(echoFirst): one line for the album at every step")
        }
        #expect(s.messages.last?.attachments?.map(\.id) == ["att1", "att2"], "the phone's own references outlive its bubble")
    }

    /// A voice message is matched to its echo by the transcript the Mac made, which the phone only
    /// learns from the receipt (`text_sha256`). An echo that beats the receipt cannot be recognized
    /// yet: the Mac's row carries `client_id: null` (`phone/rows.rs`), so nothing on the phone ties
    /// it to the recording. Android has the same limit (`Echoes.provisional` never matches voice).
    @Test(arguments: [true, false]) func aVoiceMessageEndsAsOneLineWithTheRecordingsIdentity(echoFirst: Bool) throws {
        let transcript = "call the bank"
        let hash = SHA256.hash(data: Data(transcript.utf8)).map { String(format: "%02x", $0) }.joined()
        var s = try start()
        s.outbox = [OutboxItem(clientID: "v1", kind: .voice, body: nil, recordingID: "v1", queuedAt: 10, state: .sending)]
        s.messages.append(Message(id: "v1", author: .me, kind: .voice, text: "", sentAt: 10, delivery: .sending,
                                  durationMs: 4500, levels: [0.2, 0.5], clientID: "v1", echoAfterCursor: 2, echoAfterMessageID: "t1:text:0"))
        let echo = Action.messagesArrived([row("t2:user", 3, transcript, at: 11)])
        let accepted = Action.deliveryAccepted(clientID: "v1", at: 12, textSHA256: hash)
        #expect(mine(s) == ["t1:user", "v1"])
        if echoFirst {
            _ = apply(&s, echo)
            withKnownIssue("an echo that beats the voice receipt has no transcript hash to match yet") {
                #expect(mine(s) == ["t1:user", "v1"])
            }
            _ = apply(&s, accepted)
        } else {
            _ = apply(&s, accepted)
            #expect(mine(s) == ["t1:user", "v1"], "accepted, not yet echoed")
            _ = apply(&s, echo)
        }
        #expect(mine(s) == ["t1:user", "v1"], "echoFirst=\(echoFirst): one line, the recording's identity")
        #expect(s.messages.last?.kind == .voice && s.messages.last?.durationMs == 4500)
    }
}
