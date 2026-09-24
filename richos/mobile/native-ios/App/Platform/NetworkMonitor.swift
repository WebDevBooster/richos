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
            Task { @MainActor in
                guard let self, self.generation == mine, self.monitor != nil else { return }
                store?.receive(.networkChanged(online: online, at: SystemClock().nowMs()))
            }
        }
        path.start(queue: DispatchQueue(label: "dev.richos.network-path", qos: .utility))
    }
    func stop() {
        generation += 1
        monitor?.cancel()
        monitor = nil
    }
}
