import Testing
@testable import RichOSCore
@testable import RichOSFixtures

struct OfflineGatingTests {
    @Test func offlineStopsConnectionAndTimerAndReturnRequestsOnlyOneConnection() throws {
        let s = try Fixture.named("conv-retry").state
        let (offline, effects) = Reducer.reduce(s, .networkChanged(online: false, at: 100))
        #expect(effects.contains(.disconnect))
        #expect(TickSchedule.nextTick(offline) == nil)
        let (_, foregroundEffects) = Reducer.reduce(offline, .foregrounded(at: 200))
        #expect(!foregroundEffects.contains(.connect))
        let (online, restored) = Reducer.reduce(offline, .networkChanged(online: true, at: 300))
        #expect(restored.filter { $0 == .connect }.count == 1)
        let (_, duplicate) = Reducer.reduce(online, .networkChanged(online: true, at: 301))
        #expect(!duplicate.contains(.connect))
        #expect(online.connectionNotice != .phoneOffline)
    }
}
