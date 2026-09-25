import Foundation

/// D04 (native acceptance r1): a reply the person has read leaves Notification Center, the way
/// Telegram (the CEO's standard) clears a chat's notifications once it is read. A tap on a
/// notification removes that one notification; opened any other way (the Home Screen icon, the app
/// switcher, a link, a return from another app) nothing removed any, so read replies piled up.
/// Android's fix is `279bf32d` (`ReadReplies.kt`); this is the same rule, over the iOS core's state.
///
/// "Read" is what the screen shows, decided from the core's state alone, so a test reaches it with
/// no phone: the conversation is drawn (paired, consent given, nothing covering it), and the reply is
/// at or above where the person is reading. That is every loaded reply while the conversation follows
/// the newest. Otherwise it is the replies at or above the saved reading position, which on iPhone is
/// the TOPMOST row showing (`TranscriptView.visibleAnchor`), so everything counted has been scrolled
/// into view. A reply below that, in another conversation, or not yet on this phone is not read and
/// keeps its notification. With no known position nothing is assumed seen.
///
/// The app evaluates this only while it is on screen and acts only when the answer changes (CEO
/// ruling §81): no timer, no polling, nothing while the app is in the background.
public enum ReadReplies {
    /// The conversation on screen, and its replies at or above the reading position, oldest first.
    public struct Read: Equatable, Sendable {
        public var threadID: String
        public var replyIDs: [String]
        public init(threadID: String, replyIDs: [String]) { self.threadID = threadID; self.replyIDs = replyIDs }
    }

    /// What the person has read right now, or `nil` when no conversation is drawn or none of its
    /// replies is in view. Pure.
    public static func of(_ s: AppState) -> Read? {
        guard let threadID = s.mac?.threadID, drawn(s), let upTo = readingIndex(s) else { return nil }
        let replies = s.messages[...upTo].filter { $0.author == .rich }.map(\.id)
        return replies.isEmpty ? nil : Read(threadID: threadID, replyIDs: replies)
    }

    /// The conversation is what the screen draws and nothing covers it: no takeover (pairing, consent,
    /// removed from the Mac, a required update), no sheet or dialog (Settings, Forget, the system's
    /// microphone question, an update dialog, pair-blocked), no scanner.
    static func drawn(_ s: AppState) -> Bool {
        guard s.screen == .conversation, s.sheet == nil, s.scanner == nil else { return false }
        if case .blockedByUnsentWork? = s.pairingProblem { return false }
        return s.update?.prominence != .dialog
    }

    /// The index of the newest message the person has reached: the newest while following; else the
    /// saved reading position's row; `nil` when that position is not a loaded message.
    static func readingIndex(_ s: AppState) -> Int? {
        guard !s.messages.isEmpty else { return nil }
        if s.following { return s.messages.count - 1 }
        guard let id = s.readingAnchor?.messageID else { return nil }
        return s.messages.lastIndex { $0.id == id }
    }
}
