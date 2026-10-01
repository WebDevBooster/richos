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

    // MARK: guards: only real changes, only on screen, back-off kept

    /// Only a report that changed something reaches the core: a route change costs a reopen.
    @Test func onlyAPathReportThatChangedSomethingIsNews() {
        let wifi = NetworkPath.Report(online: true, route: "en0|192.168.1.1")
        let cellular = NetworkPath.Report(online: true, route: "pdp_ip0|")
        let none = NetworkPath.Report(online: false, route: "|")
        // The first report after a return: the return already connects.
        #expect(!NetworkPath.isNews(wifi, after: nil, offlineShown: false), "a first online report would throw away the return's open")
        #expect(NetworkPath.isNews(wifi, after: nil, offlineShown: true), "but it clears a 'no network' still on screen")
        #expect(NetworkPath.isNews(none, after: nil, offlineShown: false))
        // After that.
        #expect(!NetworkPath.isNews(wifi, after: wifi, offlineShown: false), "the same path again is not news")
        #expect(NetworkPath.isNews(cellular, after: wifi, offlineShown: false), "Wi-Fi to cellular is")
        #expect(NetworkPath.isNews(none, after: wifi, offlineShown: false))
        #expect(!NetworkPath.isNews(none, after: none, offlineShown: true))
        #expect(NetworkPath.isNews(wifi, after: none, offlineShown: true))
    }

    @Test func aRouteChangeAsksForAReconnectOnlyWhenOneCanHelp() throws {
        let s = try Fixture.named("conv-empty").state
        #expect(Reducer.reduce(s, .networkChanged(online: true, at: 1)).effects == [.reconnect])
        var incompatible = s
        incompatible.connectionNotice = .incompatible
        #expect(Reducer.reduce(incompatible, .networkChanged(online: true, at: 1)).effects.isEmpty, "a Mac that cannot talk to this phone is not asked again")
        var unpaired = AppState.initial
        unpaired.linkOpen = false
        #expect(Reducer.reduce(unpaired, .networkChanged(online: true, at: 1)).effects.isEmpty)
        var offline = s
        offline = Reducer.reduce(offline, .networkChanged(online: false, at: 1)).state
        #expect(Reducer.reduce(offline, .networkChanged(online: true, at: 2)).effects.contains(.connect), "back online: the connect it was, unchanged")
    }

    /// The battery guard: a route change never opens a stream off screen. Off screen there is no owner,
    /// and `reconnect` starts nothing without one.
    @Test func aRouteChangeOffScreenOpensNothing() async throws {
        let stream = RouteStream([.open, .open])
        let network = NetworkEffects(transport: LifecycleMac(), stream: stream, identities: PairedMemoryIdentityStore(),
                                     clock: FixedClock(ms: 5), sleep: Waits(instant: true).sleep)
        await network.setSink { _ in }
        let s = try Fixture.named("conv-empty").state
        _ = await network.handle(.connect, state: s)
        #expect(await becomes { await stream.opened.count == 1 })
        _ = await network.handle(.disconnect, state: s)
        #expect(await becomes { await stream.closed == 1 })
        _ = await network.handle(.reconnect, state: s)
        #expect(await holds { await stream.opened.count == 1 }, "no owner, no stream")
    }

    /// Back-off still applies while on screen and failing: a route change tries at once, and if the Mac
    /// is still out of reach, the next wait is the next one in the sequence, never 1 s again.
    @Test func aRouteChangeDoesNotResetTheBackOff() async throws {
        let stream = RouteStream([.unreachable, .unreachable, .unreachable])
        let waits = Waits()
        let network = NetworkEffects(transport: LifecycleMac(), stream: stream, identities: PairedMemoryIdentityStore(),
                                     clock: FixedClock(ms: 5), sleep: waits.sleep)
        let host = try await host(network)
        _ = try await host.dispatch(.foregrounded(at: 1))
        #expect(await becomes { await waits.asked == [1000] })
        _ = try await host.dispatch(.networkChanged(online: true, at: 2))
        #expect(await becomes { await stream.opened.count == 2 })
        #expect(await becomes { await waits.asked == [1000, 2000] }, "the back-off went on from where it was, not back to 1 s")
        _ = try await host.dispatch(.backgrounded(at: 3))
        #expect(await becomes { await waits.canceled >= 2 })
    }
}
