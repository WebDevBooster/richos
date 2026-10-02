import Foundation
import RichOSCore
import Testing
@testable import RichOSNative

/// A refused voice message (iPhone re-walk 4, light-48) showed "Not sent · needs attention" without
/// the Mac's reason, which the phone held on the message's outbox item (`lastReason`).
@Suite("Refusal reason")
struct RefusalReasonTests {
    private static let heard = "I could not hear speech in that recording. Your recording is still on your phone."

    private static func refusedVoice(_ reason: String?) -> AppState {
        var s = AppState()
        s.pairing = .paired
        s.messages = [Message(id: "v1", author: .me, kind: .voice, text: "", sentAt: 1_000, delivery: .needsAttention, durationMs: 4_000)]
        s.outbox = [OutboxItem(clientID: "v1", kind: .voice, body: nil, recordingID: "rec_v1", queuedAt: 1_000,
                               state: .blocked, lastReason: reason)]
        return s
    }

    @Test func aRefusedVoiceMessageCarriesTheMacsSentence() throws {
        let row = try #require(ScreenModel(state: Self.refusedVoice(Self.heard)).thread.rows.first { $0.id == "v1" })
        #expect(row.delivery == .needsAttention)
        #expect(row.refusal == Self.heard)
    }

    /// Without a sentence from the Mac the item keeps the phone's own one-word classification, which
    /// is not shown.
    @Test(arguments: ["refused", "fault", "unreachable", "too large", "link-lost", "the recording is missing on this phone", "", nil] as [String?])
    func aClassificationIsNotShown(_ reason: String?) throws {
        let row = try #require(ScreenModel(state: Self.refusedVoice(reason)).thread.rows.first { $0.id == "v1" })
        #expect(row.refusal == nil)
    }

    /// A message still waiting to be sent says nothing of an earlier retryable reason.
    @Test func aWaitingMessageShowsNoReason() throws {
        var s = Self.refusedVoice(Self.heard)
        s.messages[0].delivery = .waiting
        s.outbox[0].state = .waiting
        let row = try #require(ScreenModel(state: s).thread.rows.first { $0.id == "v1" })
        #expect(row.refusal == nil)
    }
}
