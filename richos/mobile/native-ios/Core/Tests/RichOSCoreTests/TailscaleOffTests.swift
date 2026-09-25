import Foundation
import Testing
@testable import RichOSCore
@testable import RichOSFixtures

/// D05 on iOS (the Android record: native acceptance r1, D05). On the Tailscale route, with this
/// phone's own Tailscale off, the app said "Reconnecting…" for as long as it was left, which it cannot
/// do by itself, and never named the fix. Android's rule (`Connections.cause`, `Header.kt`
/// `TAILSCALE_OFF`), ported: once the trouble has lasted the usual quiet 3 s, the one line names the
/// fix, once, and nothing more — no timer, no repeat, the draft and the queue kept.
@Suite struct TailscaleOffTests {
    static let t0: Int64 = 1_790_000_000_000

    /// Paired over Tailscale, a message waiting, the stream not open.
    static func queued() throws -> AppState {
        var s = try Fixture.named("conv-retry").state
        #expect(s.mac?.route == .tailnet)
        s.connectionNotice = nil
        s.troubleSinceMs = nil
        s.linkOpen = false
        return s
    }

    @Test func tailscaleOffOnTheTailscaleRouteNamesTheFixOnceTheTroublePersistsAndNothingNags() throws {
        var s = try Self.queued()
        let queued = s.outbox.map(\.clientID)
        s = Reducer.reduce(s, .compose(text: "Still here")).state
        s = Reducer.reduce(s, .tunnelChanged(up: false)).state
        s = Reducer.reduce(s, .connectionLost(at: Self.t0)).state
        #expect(s.connectionNotice == nil, "quiet at first, like any trouble")
        #expect(TickSchedule.nextTick(s) == Self.t0 + ConnectionReducer.quietMs)
        s = Reducer.reduce(s, .tick(at: Self.t0 + ConnectionReducer.quietMs)).state
        #expect(s.connectionNotice == .tailscaleOff, "the persistent trouble names the fix")
        #expect(TickSchedule.nextTick(s) == nil, "shown once: no timer after it")
        // More failed attempts change nothing: the same line, no new timer, nothing lost.
        for i in 1...5 {
            s = Reducer.reduce(s, .connectionLost(at: Self.t0 + 10_000 * Int64(i))).state
            s = Reducer.reduce(s, .tick(at: Self.t0 + 10_000 * Int64(i))).state
            #expect(s.connectionNotice == .tailscaleOff)
            #expect(TickSchedule.nextTick(s) == nil)
        }
        #expect(s.draft == "Still here")
        #expect(s.outbox.map(\.clientID) == queued && s.messages.last?.delivery == .waiting)
        // The phone's own offline state still comes first.
        s = Reducer.reduce(s, .networkChanged(online: false, at: Self.t0 + 70_000)).state
        #expect(s.connectionNotice == .phoneOffline)
        s = Reducer.reduce(s, .networkChanged(online: true, at: Self.t0 + 71_000)).state
        s = Reducer.reduce(s, .tick(at: Self.t0 + 74_000)).state
        #expect(s.connectionNotice == .tailscaleOff, "still not on Tailscale once the network is back")
        // Tailscale back on: the fix is done, so the line says what is true now, the owner tries at once,
        // and the line goes when the Mac answers.
        let (on, effects) = Reducer.reduce(s, .tunnelChanged(up: true))
        s = on
        #expect(s.connectionNotice == .reconnecting)
        #expect(effects.contains(.connect), "a tunnel that came up is worth an attempt now")
        s = Reducer.reduce(s, .connected(at: Self.t0 + 80_000)).state
        #expect(s.connectionNotice == nil && s.messages.last?.delivery == .sending, "the message goes")
    }

    @Test func theLineIsOnlyForTheTailscaleRouteOnlyOnTheOSsWordAndOnlyWhileAway() throws {
        func noticeAfterTrouble(_ edit: (inout AppState) -> Void, tunnel: Bool?) throws -> ConnectionNotice? {
            var s = try Self.queued()
            edit(&s)
            if let tunnel { s = Reducer.reduce(s, .tunnelChanged(up: tunnel)).state }
            s = Reducer.reduce(s, .connectionLost(at: Self.t0)).state
            return Reducer.reduce(s, .tick(at: Self.t0 + ConnectionReducer.quietMs)).state.connectionNotice
        }
        #expect(try noticeAfterTrouble({ _ in }, tunnel: nil) == .reconnecting, "no report from the OS yet: never guessed")
        #expect(try noticeAfterTrouble({ _ in }, tunnel: true) == .reconnecting, "Tailscale is up: reconnecting is the truth")
        #expect(try noticeAfterTrouble({ $0.mac?.route = .connect }, tunnel: false) == .reconnecting,
                "RichOS Connect needs no Tailscale: never about Tailscale")
        #expect(try noticeAfterTrouble({ $0.mac?.route = .other }, tunnel: false) == .reconnecting)
        // Connected: nothing to say, whatever the tunnel.
        var s = try Self.queued()
        s = Reducer.reduce(s, .tunnelChanged(up: false)).state
        s = Reducer.reduce(s, .connected(at: Self.t0)).state
        #expect(s.connectionNotice == nil)
        // The Mac's own evidence for "unreachable" is refined the same way; the service's is not.
        s = Reducer.reduce(try Self.queued(), .tunnelChanged(up: false)).state
        #expect(Reducer.reduce(s, .connectionDiagnosed(.macUnreachable)).state.connectionNotice == .tailscaleOff)
        #expect(Reducer.reduce(s, .connectionDiagnosed(.serviceUnavailable)).state.connectionNotice == .serviceUnavailable)
        // Tailscale going off while Reconnecting… is already said: the line names the fix at once.
        var r = try Self.queued()
        r = Reducer.reduce(r, .connectionLost(at: Self.t0)).state
        r = Reducer.reduce(r, .tick(at: Self.t0 + ConnectionReducer.quietMs)).state
        #expect(r.connectionNotice == .reconnecting)
        let (off, offEffects) = Reducer.reduce(r, .tunnelChanged(up: false))
        #expect(off.connectionNotice == .tailscaleOff && !offEffects.contains(.connect), "a tunnel that went down is no reason to try")
    }

    @Test func theReportTravelsOnAndroidsGrammar() throws {
        let decoded = try CoreJSON.decode(Action.self, from: Data(#"{"type":"health","vpn":false}"#.utf8))
        #expect(decoded == .tunnelChanged(up: false))
        let encoded = String(decoding: try CoreJSON.encode(Action.tunnelChanged(up: true)), as: UTF8.self)
        #expect(encoded == #"{"type":"health","vpn":true}"#)
        #expect(String(decoding: try CoreJSON.encode(ConnectionNotice.tailscaleOff), as: UTF8.self) == #""tailscale-off""#)
    }

    /// The iPhone's word for "this phone is on Tailscale": Tailscale's own tunnel interface is up, with
    /// one of the addresses Tailscale gives a device (100.64.0.0/10, fd7a:115c:a1e0::/48). An address in
    /// that range on the cellular interface (carrier-grade NAT) is not Tailscale; nor is another VPN's tunnel.
    @Test func tailscaleIsReadFromItsTunnelsAddress() {
        typealias I = TailscaleTunnel.Interface
        #expect(TailscaleTunnel.isUp([I(name: "utun4", up: true, address: "100.101.102.103")]))
        #expect(TailscaleTunnel.isUp([I(name: "utun6", up: true, address: "fd7a:115c:a1e0:ab12:4843:cd96:6265:9a12")]))
        #expect(TailscaleTunnel.isUp([I(name: "utun4", up: true, address: "100.127.255.254")]))
        #expect(!TailscaleTunnel.isUp([I(name: "utun4", up: false, address: "100.101.102.103")]), "a tunnel that is down")
        #expect(!TailscaleTunnel.isUp([I(name: "pdp_ip0", up: true, address: "100.72.4.9")]), "carrier-grade NAT on cellular")
        #expect(!TailscaleTunnel.isUp([I(name: "utun2", up: true, address: "10.8.0.2")]), "another VPN")
        #expect(!TailscaleTunnel.isUp([I(name: "utun4", up: true, address: "100.128.0.1")]), "just outside 100.64.0.0/10")
        #expect(!TailscaleTunnel.isUp([I(name: "utun0", up: true, address: "fe80::1")]), "the system's own tunnels")
        #expect(!TailscaleTunnel.isUp([]))
    }
}
