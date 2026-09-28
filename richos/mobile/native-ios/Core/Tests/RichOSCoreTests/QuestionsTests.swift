import Foundation
import Testing
@testable import RichOSCore
@testable import RichOSFixtures

@Suite struct QuestionsTests {
    let wire = #"{"id":"q","thread_id":"general","cursor":1,"role":"rich","kind":"question","text":"When?","complete":true,"question":{"id":"q","thread_id":"general","text":"When should the release ship?","options":[{"id":"a","label":"Ship today","description":"Earlier fixes"},{"id":"b","label":"Ship tomorrow","description":"More testing"}],"multiple":false,"free_answer":true,"recommended":"b","state":"open","revision":0,"delivered":false}}"#
    @Test func offlineAnswerUsesExistingOutboxAndPreservesDraftAcrossRestart() throws {
        let row = try JSONDecoder().decode(StreamRow.self, from: Data(wire.utf8))
        var s = try Fixture.named("conv-empty").state
        s.connectionNotice = .phoneOffline
        s.mac?.questionAnswers = true
        s.draft = "An unrelated message"
        s = Reducer.reduce(s, .messagesArrived([row.message])).state
        #expect(s.outbox.count == 1) // Receipt of the foreground stream, not a timer.
        #expect(s.outbox[0].clientID == "seen-question:q")
        s = Reducer.reduce(s, .answerQuestion(id: "q", options: ["a"], text: "", revision: nil, clientID: "tap", at: 1)).state
        #expect(s.outbox.count == 2)
        let body = s.outbox[1].body
        #expect(s.outbox[1].questionID == "q")
        #expect(s.draft == "An unrelated message")
        let roundtrip = try JSONDecoder().decode(OutboxItem.self, from: JSONEncoder().encode(s.outbox[1]))
        #expect(roundtrip.body == body)
        #expect(roundtrip.localQuestionAnswer?.method == "phone_tap")
        #expect(roundtrip.localQuestionAnswer?.option_ids == ["a"])
        s = Reducer.reduce(s, .answerQuestion(id: "q", options: ["b"], text: "", revision: nil, clientID: "double-tap", at: 2)).state
        #expect(s.outbox.count == 2)
        s = Reducer.reduce(s, .messagesArrived([row.message])).state
        #expect(s.outbox.count == 2)
    }
    @Test func authoritativeReceiptReplacesCardAndDeletionKeepsAnswer() throws {
        var q = try JSONDecoder().decode(StreamRow.self, from: Data(wire.utf8)).question!
        var s = try Fixture.named("conv-empty").state
        s.connectionNotice = .phoneOffline
        s.mac?.questionAnswers = true
        var m = Message(id: "q", author: .rich, text: "When?", sentAt: 0); m.question = q
        s.messages = [m]
        s = Reducer.reduce(s, .answerQuestion(id: "q", options: [], text: "Next Tuesday", revision: nil, clientID: "typed", at: 1)).state
        s = Reducer.reduce(s, .deliveryFailed(clientID: "typed", failure: .refused(reason: "This conversation was deleted. Your answer is saved on this phone."), at: 2)).state
        #expect(s.outbox[0].state == .blocked)
        #expect(s.outbox[0].localQuestionAnswer?.method == "phone_typed")
        #expect(s.outbox[0].body!.contains("Next Tuesday"))
        q.state = "answered"; q.revision = 1
        s = Reducer.reduce(s, .questionAnswered(clientID: "typed", question: q, at: 3)).state
        #expect(s.outbox.isEmpty)
        #expect(s.messages[0].question?.revision == 1)
    }
    @Test func explicitOfflineEditReplacesOnlyAnUnattemptedAnswer() throws {
        let row = try JSONDecoder().decode(StreamRow.self, from: Data(wire.utf8))
        var s = try Fixture.named("conv-empty").state
        s.connectionNotice = .phoneOffline; s.mac?.questionAnswers = true; s.messages = [row.message]
        s = Reducer.reduce(s, .answerQuestion(id: "q", options: ["a"], text: "", revision: nil, clientID: "first", at: 1)).state
        s = Reducer.reduce(s, .answerQuestion(id: "q", options: ["b"], text: "", revision: 0, clientID: "edited", at: 2)).state
        #expect(s.outbox.count == 1)
        #expect(s.outbox[0].questionAnswerText == "Ship tomorrow")
        #expect(s.outbox[0].clientID == "edited")
        s.outbox[0].attempts = 1
        let saved = s.outbox[0]
        s = Reducer.reduce(s, .answerQuestion(id: "q", options: ["a"], text: "", revision: 0, clientID: "uncertain", at: 3)).state
        #expect(s.outbox == [saved])
    }
    /// Rich's ruling on escalation esc-20260927T220629Z-cbc90040: a job that ended before any back
    /// end took his answer says so, and only then; "On its way to Rich" would never again be true.
    @Test func aJobThatStoppedBeforeRichGotTheAnswerSaysSoOnlyWhenFlagged() throws {
        let stopped = "This job stopped before Rich got your answer."
        var q = try JSONDecoder().decode(StreamRow.self, from: Data(wire.utf8)).question!
        #expect(q.ended_before_taken == nil) // An older Mac never sends it.
        q.state = "answered"; q.revision = 1; q.handoff_started = true
        #expect(q.savedStatus == "On its way to Rich")
        let flagged = wire.replacingOccurrences(of: #""delivered":false"#, with: #""delivered":false,"ended_before_taken":true"#)
        var ended = try JSONDecoder().decode(StreamRow.self, from: Data(flagged.utf8)).question!
        #expect(ended.ended_before_taken == true)
        ended.state = "answered"; ended.revision = 1; ended.handoff_started = true
        #expect(ended.savedStatus == stopped)
        ended.waiting_for_turn = true
        #expect(ended.savedStatus == stopped)
        // The Mac never publishes both, but a delivered card says only that Rich has it.
        ended.delivered = true
        #expect(ended.savedStatus == "Rich has your answer")
        q.waiting_for_turn = true
        #expect(q.savedStatus == "It reaches Rich when his current reply ends")
        q.remaining = 1
        #expect(q.savedStatus == "Waiting for the remaining answers")
    }
    @Test func absentCapabilityCannotQueueAnAnswer() throws {
        var s = try Fixture.named("conv-empty").state
        s.messages = [try JSONDecoder().decode(StreamRow.self, from: Data(wire.utf8)).message]
        s.mac?.questionAnswers = false
        s = Reducer.reduce(s, .answerQuestion(id: "q", options: ["a"], text: "", revision: nil, clientID: "tap", at: 1)).state
        #expect(s.outbox.isEmpty)
    }

}
