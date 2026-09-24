import Testing
@testable import RichOSCore
@testable import RichOSFixtures

@Suite struct MessageReconciliationTests {
    @Test(arguments: [true, false]) func echoAndAcceptanceCanArriveInEitherOrder(echoFirst: Bool) throws {
        var s = try Fixture.named("conv-empty").state
        s.draft = "one message"
        s = Reducer.reduce(s, .sendDraft(clientID: "c1", at: 1)).state
        let echo = Action.messagesArrived([Message(id: "turn1:user", author: .me, text: "one message", sentAt: 2, cursor: 1)])
        let accepted = Action.deliveryAccepted(clientID: "c1", at: 3)
        for action in echoFirst ? [echo, accepted] : [accepted, echo] { s = Reducer.reduce(s, action).state }
        #expect(s.outbox.isEmpty)
        #expect(s.messages.map(\.id) == ["turn1:user"])
        #expect(s.messages.first?.delivery == nil)
    }

    @Test func repeatedWordsRemainSeparateThroughReplayedRowsAndRelaunch() throws {
        var s = try Fixture.named("conv-empty").state
        let old = Message(id: "old:user", author: .me, text: "again", sentAt: 0, cursor: 1)
        s = Reducer.reduce(s, .messagesArrived([old])).state
        for n in 1...2 {
            s.draft = "again"
            s = Reducer.reduce(s, .sendDraft(clientID: "c\(n)", at: Int64(n))).state
            s = Reducer.reduce(s, .deliveryAccepted(clientID: "c\(n)", at: Int64(n))).state
        }
        s = Reducer.reduce(s, .messagesArrived([old])).state
        #expect(s.messages.count == 3, "an old row cannot consume a new Send with identical text")
        let first = Message(id: "turn1:user", author: .me, text: "again", sentAt: 3, cursor: 2)
        s = Reducer.reduce(s, .messagesArrived([first])).state
        #expect(s.messages.count == 3, "one echo retires exactly one local bubble")
        s = try AppState(restoring: s.persisted)
        s = Reducer.reduce(s, .messagesArrived([old, first])).state
        #expect(s.messages.count == 3, "replay cannot consume the second Send")
        let second = Message(id: "turn2:user", author: .me, text: "again", sentAt: 4, cursor: 3)
        s = Reducer.reduce(s, .messagesArrived([second])).state
        #expect(s.messages.map(\.id) == ["old:user", "turn1:user", "turn2:user"])
    }
}
