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

/// Which delivered notifications a read conversation takes out of Notification Center (D04; Android's
/// `Replies.withdrawRead`). Foundation and the core only, so the platform tests run it on this Mac.
enum NotificationWithdrawal {
    /// The identifiers of `delivered` notifications about a reply in `read`: from the Mac this phone is
    /// registered with, about the conversation on screen, and a reply the person has read. Anything
    /// else, including a notification that is not RichOS's, stays. No host id yet: nothing is withdrawn.
    static func identifiers(of delivered: [(identifier: String, userInfo: [AnyHashable: Any])], read: ReadReplies.Read,
                            hostID: String?) -> [String] {
        let ours = delivered.compactMap { item -> (String, NotificationTarget)? in
            guard let target = NotificationTarget(userInfo: item.userInfo),
                  target.belongs(toHost: hostID, thread: read.threadID) else { return nil }
            return (item.identifier, target)
        }
        guard !ours.isEmpty else { return [] }
        // Hashed only once something from this conversation is actually delivered.
        let readEvents = Set(read.replyIDs.map(NotificationTarget.reference))
        return ours.filter { readEvents.contains($0.1.event) }.map(\.0)
    }
}
