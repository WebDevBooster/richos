import Foundation
import Testing
@testable import RichOSCore
@testable import RichOSFixtures

/// The third wait andy-opus-resume1 found on Android, checked on the iPhone (2026-10-01).
///
/// A network change without a reported loss. The app's path monitor reports every change, but
/// the core acted only on "offline" and "back online": Wi-Fi to cellular, a network joined or Tailscale
/// changing left the stream on the old route, noticed only by the 20 s silence limit
/// (`LiveConnection.silenceLimitMs`), and an open in flight on the old route hung for its own 20 s.
@Suite struct RouteChangeTests {
    func host(_ network: NetworkEffects) async throws -> HeadlessHost {
        let host = try await HeadlessHost(storage: MemoryStorage(), handler: network)
        // On screen and paired, the stream not yet open: what the app is the moment it comes back.
        var s = try Fixture.named("conv-empty").state
        s.linkOpen = false
        _ = try await host.replace(with: s)
        await network.setSink { action in _ = try? await host.dispatch(action) }
        return host
    }

    func linkOpen(_ host: HeadlessHost) async -> Bool { (try? await host.currentState().linkOpen) == true }


    @Test func aRouteChangeReplacesAnOpenStreamAtOnce() async throws {
        let stream = RouteStream([.open, .open])
        let mac = LifecycleMac()
        let waits = Waits()
        let network = NetworkEffects(transport: mac, stream: stream, identities: PairedMemoryIdentityStore(),
                                     clock: FixedClock(ms: 5), sleep: waits.sleep)
        let host = try await host(network)
        _ = try await host.dispatch(.foregrounded(at: 1))
        #expect(await becomes { await linkOpen(host) })
        #expect(await becomes { (try? await host.currentState().voiceAvailability) == .unsupportedByMac })
        let before = await mac.targets.count

        // Wi-Fi to cellular with the app open: the path changed, nothing reported a loss.
        _ = try await host.dispatch(.networkChanged(online: true, at: 2))
        #expect(await becomes { await stream.opened.count == 2 }, "a new stream on the new route, at once")
        #expect(await becomes { await stream.closed == 1 }, "and the one on the old route is closed")
        #expect(await becomes { await linkOpen(host) })
        #expect(await waits.asked.isEmpty, "no back-off wait in front of it")
        let asked = await mac.targets
        #expect(asked.count == before, "and no request: \(asked)")
        _ = try await host.dispatch(.backgrounded(at: 3))
        #expect(await becomes { await stream.closed == 2 })
    }

    @Test func aRouteChangeAbandonsAnOpenThatHangsOnTheOldRoute() async throws {
        let stream = RouteStream([.hang, .open])
        let network = NetworkEffects(transport: LifecycleMac(), stream: stream, identities: PairedMemoryIdentityStore(),
                                     clock: FixedClock(ms: 5), sleep: Waits().sleep)
        let host = try await host(network)
        _ = try await host.dispatch(.foregrounded(at: 1))
        #expect(await becomes { await stream.opened.count == 1 })
        _ = try await host.dispatch(.networkChanged(online: true, at: 2))
        #expect(await becomes { await stream.opened.count == 2 }, "the hung open is given up and a new one made at once")
        #expect(await becomes { await stream.abandoned == 1 })
        #expect(await becomes { await linkOpen(host) })
        _ = try await host.dispatch(.backgrounded(at: 3))
    }

    @Test func aRouteChangeDuringTheBackOffTriesAtOnce() async throws {
        let stream = RouteStream([.unreachable, .open])
        let waits = Waits()
        let network = NetworkEffects(transport: LifecycleMac(), stream: stream, identities: PairedMemoryIdentityStore(),
                                     clock: FixedClock(ms: 5), sleep: waits.sleep)
        let host = try await host(network)
        _ = try await host.dispatch(.foregrounded(at: 1))
        #expect(await becomes { await waits.asked == [1000] }, "the Mac was out of reach: a 1 s wait")
        _ = try await host.dispatch(.networkChanged(online: true, at: 2))
        #expect(await becomes { await stream.opened.count == 2 }, "the network changed: tried now")
        #expect(await becomes { await linkOpen(host) })
        _ = try await host.dispatch(.backgrounded(at: 3))
    }
}
