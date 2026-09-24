import CryptoKit
import Foundation
import Testing
@testable import RichOSCore
@testable import RichOSFixtures

struct VoiceEchoTests {
    @Test(arguments: ["malformed", String(repeating: "0", count: 64)])
    func unrelatedTranscriptCannotConsumeVoice(hash: String) async throws {
        let mac = ScriptedMac([["status": 200, "body": ["text_sha256": hash]]])
        let api = APIClient(origin: "https://example.com", deviceID: "device", challenge: "challenge",
                            signer: SoftwareSigner(key: Corpus.testKey), transport: mac)
        var state = try Fixture.named("conv-empty").state
        let item = OutboxItem(clientID: "capture", kind: .voice, body: nil, recordingID: "capture", queuedAt: 1, state: .sending)
        state.outbox = [item]
        state.messages = [Message(id: "capture", author: .me, kind: .voice, text: "", sentAt: 1,
                                  delivery: .sending, durationMs: 4321, clientID: "capture")]
        let accepted = await Courier(api: api, recordings: MemoryRecordings(files: ["capture": Data([1,2])])).deliver(item, at: 3)
        state = Reducer.reduce(state, accepted.action).state
        state = Reducer.reduce(state, .messagesArrived([
            Message(id: "unrelated:user", author: .me, text: "An unrelated message", sentAt: 2, cursor: 1)
        ])).state
        #expect(state.outbox.isEmpty, "An optional malformed transcript hash must not retry an accepted Send")
        #expect(state.messages.count == 2)
        #expect(state.messages.first(where: { $0.id == "capture" })?.kind == .voice)
        #expect(state.messages.first(where: { $0.id == "unrelated:user" })?.clientID == nil)
    }

    @Test(arguments: [true, false]) func transcriptReceiptReconcilesVoiceAndPreservesPlayback(echoFirst: Bool) async throws {
        let text = "A fresh spoken message."
        let hash = SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
        let mac = ScriptedMac([["status": 200, "body": ["text_sha256": hash, "duplicate": false]]])
        let api = APIClient(origin: "https://example.com", deviceID: "device", challenge: "challenge",
                            signer: SoftwareSigner(key: Corpus.testKey), transport: mac)
        var state = try Fixture.named("conv-empty").state
        let item = OutboxItem(clientID: "capture", kind: .voice, body: nil, recordingID: "capture", queuedAt: 1, state: .sending)
        state.outbox = [item]
        state.messages = [Message(id: "capture", author: .me, kind: .voice, text: "", sentAt: 1,
                                  delivery: .sending, durationMs: 4321, levels: [0.2, 0.5], clientID: "capture")]
        let row = Message(id: "turn:user", author: .me, text: text, sentAt: 2, cursor: 1)
        let accepted = await Courier(api: api, recordings: MemoryRecordings(files: ["capture": Data([1,2])])).deliver(item, at: 3)
        for action: Action in echoFirst ? [.messagesArrived([row]), accepted.action] : [accepted.action, .messagesArrived([row])] {
            state = Reducer.reduce(state, action).state
        }
        #expect(state.outbox.isEmpty)
        #expect(state.messages.count == 1)
        #expect(state.messages.first?.id == "turn:user")
        #expect(state.messages.first?.kind == .voice && state.messages.first?.text == text)
        #expect(state.messages.first?.durationMs == 4321 && state.messages.first?.levels == [0.2, 0.5])
        state = try AppState(restoring: state.persisted)
        state = Reducer.reduce(state, .messagesArrived([row])).state
        #expect(state.messages.first?.kind == .voice, "replay must preserve voice identity even when the live row has no duration")
        let play = Reducer.reduce(state, .playRecording(id: "turn:user"))
        #expect(play.effects.contains(.playRecording(id: "capture")), "the original WAV remains playable after row replacement")
        let encoded = try CoreJSON.encode(accepted.action)
        #expect(try CoreJSON.decode(Action.self, from: encoded) == accepted.action)
    }
}
