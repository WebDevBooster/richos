import Darwin
import Network
import RichOSCore

/// Observe route changes only while the interface is active. The OS supplies events; no probes,
/// polling, reachability endpoint or requirement for public-internet validation.
@MainActor
final class NetworkMonitor {
    private var monitor: NWPathMonitor?
    private var generation = 0
    func start(store: AppStore) {
        guard monitor == nil else { return }
        generation += 1
        let mine = generation
        let path = NWPathMonitor()
        monitor = path
        path.pathUpdateHandler = { [weak self, weak store] update in
            let online = update.status == .satisfied
            // D05: whether this phone is on Tailscale, read once per path change (Tailscale coming up
            // or going down changes the path), never on a timer.
            let tailscale = TailscaleTunnel.isUp(Self.interfaces())
            Task { @MainActor in
                guard let self, self.generation == mine, self.monitor != nil else { return }
                store?.receive(.networkChanged(online: online, at: SystemClock().nowMs()))
                if let store, store.state.tunnelUp != tailscale { store.receive(.tunnelChanged(up: tailscale)) }
            }
        }
        path.start(queue: DispatchQueue(label: "dev.richos.network-path", qos: .utility))
    }
    /// The phone's interfaces with their numeric addresses (`getifaddrs`): one read, no network traffic.
    nonisolated static func interfaces() -> [TailscaleTunnel.Interface] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }
        var found: [TailscaleTunnel.Interface] = []
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            guard let address = entry.ifa_addr else { continue }
            let family = Int32(address.pointee.sa_family)
            guard family == AF_INET || family == AF_INET6 else { continue }
            let length = socklen_t(family == AF_INET ? MemoryLayout<sockaddr_in>.size : MemoryLayout<sockaddr_in6>.size)
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, length, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let up = (entry.ifa_flags & UInt32(IFF_UP)) != 0 && (entry.ifa_flags & UInt32(IFF_RUNNING)) != 0
            found.append(TailscaleTunnel.Interface(name: String(cString: entry.ifa_name), up: up, address: String(cString: host)))
        }
        return found
    }

    func stop() {
        generation += 1
        monitor?.cancel()
        monitor = nil
    }
}
