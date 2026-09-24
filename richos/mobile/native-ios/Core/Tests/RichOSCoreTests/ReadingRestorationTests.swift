import Testing
@testable import RichOSCore
@testable import RichOSFixtures

struct ReadingRestorationTests {
    @Test func coldRestoreKeepsTheSettledAnchorAndNewRepliesDoNotResumeFollowing() throws {
        let s = try Fixture.named("conv-populated").state
        let anchor = ReadingAnchor(messageID: s.messages[0].id, offset: 32)
        let (reading, effects) = Reducer.reduce(s, .rememberReading(anchor))
        #expect(effects.contains(.persist))
        let restored = try AppState(restoring: reading.persisted)
        #expect(restored.readingAnchor == anchor)
        #expect(!restored.following)
        let (latest, _) = Reducer.reduce(restored, .setFollowing(true))
        #expect(latest.readingAnchor == nil)
    }
}
