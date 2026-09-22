import Foundation
import RichOSCore

/// Where a tapped notification goes, in the core's terms (contract §7.3 "Deep-linking from a tap").
/// Foundation and the core only, so the platform tests run it on this Mac.
enum NotificationTapRouter {
    /// `.openedFromNotification` for the reply when it is loaded; `nil` when the notification is not
    /// from this Mac or this conversation, or the reply is not loaded yet (the core then needs to
    /// fetch older history until it appears — requested of stream I1).
    static func action(for target: NotificationTarget, state: AppState, hostID: String?) -> Action? {
        guard target.belongs(toHost: hostID, thread: state.mac?.threadID) else { return nil }
        return target.messageID(in: state.messages.filter { $0.author == .rich }.map(\.id))
            .map { Action.openedFromNotification(messageID: $0) }
    }
}
