import Foundation
import RichOSCore
import Testing
@testable import RichOSNative

/// D05: the phone's word on Tailscale comes from its own interface list, read by `NetworkMonitor`
/// once per network-path change. The read is real here (`getifaddrs` on the simulator): what matters
/// is that it returns each interface's name, whether it is up and its NUMERIC address, which is what
/// `TailscaleTunnel.isUp` compares against Tailscale's ranges.
@Suite("Network monitor interface read")
struct NetworkMonitorTests {
    @Test func theReadGivesEachInterfaceItsNameStateAndNumericAddress() {
        let interfaces = NetworkMonitor.interfaces()
        #expect(interfaces.contains { $0.name == "lo0" && $0.address == "127.0.0.1" && $0.up }, "loopback, numeric and up: \(interfaces)")
        #expect(interfaces.contains { $0.name == "lo0" && $0.address == "::1" }, "IPv6 addresses are read too")
        #expect(!TailscaleTunnel.isUp(interfaces.filter { $0.name == "lo0" }), "loopback is never Tailscale")
    }
}
