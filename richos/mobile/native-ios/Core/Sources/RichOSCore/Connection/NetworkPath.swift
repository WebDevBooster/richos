import Foundation

/// **WHICH OF THE PHONE'S NETWORK PATH REPORTS ARE NEWS FOR THE CORE.** The app's path monitor
/// (`App/Platform/NetworkMonitor.swift`, `NWPathMonitor`, only while the app is on screen) hears every
/// path update; the core is told `networkChanged(online:)` only when something it acts on changed.
/// Online after online is a ROUTE change (`ConnectionReducer`: the live connection is replaced at
/// once), so a report that changed nothing must never reach it, or every update would cost a reopen.
///
/// The OS's own events, compared with the one before: no probe, no timer, no polling.
public enum NetworkPath {
    public struct Report: Equatable, Sendable {
        /// The path can carry traffic (`NWPath.Status.satisfied`).
        public var online: Bool
        /// What the traffic would leave by: the usable interfaces in the OS's order of preference and
        /// the default routers, written as one string. A different Wi-Fi, cellular taking over, or
        /// Tailscale coming or going changes it; a change of cost or a DNS update does not.
        public var route: String

        public init(online: Bool, route: String) { self.online = online; self.route = route }
    }

    /// Whether `report` is news, given the last report this monitor saw (`nil`: the first since the
    /// app came on screen) and whether the screen is saying "no network".
    ///
    /// - The first report after a return is news only when it says offline, or when it clears an
    ///   offline that is on screen: the return itself already connects (`foregrounded`), and a first
    ///   online report taken as a route change would throw away the open the return just started.
    /// - After that: going offline or coming back is news, and so is a new route while online.
    public static func isNews(_ report: Report, after previous: Report?, offlineShown: Bool) -> Bool {
        guard let previous else { return !report.online || offlineShown }
        if report.online != previous.online { return true }
        return report.online && report.route != previous.route
    }
}
