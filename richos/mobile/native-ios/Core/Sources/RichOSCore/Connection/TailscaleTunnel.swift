import Foundation

/// D05: whether this phone is on Tailscale, from the OS's own interface list. iOS has no public "the
/// default network runs through a VPN" (Android's `NetworkCapabilities.TRANSPORT_VPN`), so the app reads
/// what Tailscale itself puts there: its tunnel interface (`utun…`), up, holding one of the addresses
/// Tailscale gives a device — 100.64.0.0/10 or fd7a:115c:a1e0::/48 (Tailscale's documented ranges). The
/// same range on the cellular interface is a carrier's NAT, not Tailscale, and another VPN's tunnel is
/// not Tailscale either. Pure, so the headless tests prove it; the app supplies the interfaces
/// (`getifaddrs`) when the network path changes, never on a timer.
public enum TailscaleTunnel {
    public struct Interface: Equatable, Sendable {
        public var name: String
        public var up: Bool
        /// Numeric form, as `getnameinfo` writes it (`100.101.102.103`, `fd7a:115c:a1e0:…`).
        public var address: String
        public init(name: String, up: Bool, address: String) { self.name = name; self.up = up; self.address = address }
    }

    public static func isUp(_ interfaces: [Interface]) -> Bool {
        interfaces.contains { $0.up && $0.name.hasPrefix("utun") && isTailscaleAddress($0.address) }
    }

    static func isTailscaleAddress(_ address: String) -> Bool {
        let a = address.lowercased()
        if a.hasPrefix("fd7a:115c:a1e0:") { return true }
        let octets = a.split(separator: ".", omittingEmptySubsequences: false).compactMap { UInt8($0) }
        guard octets.count == 4 else { return false }
        return octets[0] == 100 && (64...127).contains(octets[1])
    }
}
