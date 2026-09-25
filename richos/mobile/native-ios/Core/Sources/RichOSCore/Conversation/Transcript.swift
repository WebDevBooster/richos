import Foundation

extension Message {
    /// The line's identity on screen. One of your messages keeps its client id from Send, through
    /// the Mac's acceptance, to the Mac's row for it (`ConversationReducer.reconcile` records the
    /// client id on that row), so it is one row that changes state in place, never one row replaced
    /// by another. The Android rule: `Line.key` in `Transcript.kt`.
    public var lineID: String { author == .me ? (clientID ?? id) : id }
}

/// The conversation as the person sees it (PRD J4: one row per sent message from the tap to the
/// Mac's acknowledgement). The Android rule: `Transcript.of` and `Echoes.provisional`.
public enum Transcript {
    /// `AppState.messages`, with each of your messages drawn once. The Mac's row for a message can
    /// beat the HTTP acceptance; the Mac holding the words is then already true, so that row takes
    /// the place of the phone's own bubble at once and keeps the bubble's identity. Display only:
    /// the outbox keeps the item until the acceptance arrives (or its retry is answered as a
    /// duplicate), so delivery stays exactly-once. A message the Mac refused keeps its own line.
    public static func visible(_ s: AppState) -> [Message] {
        let early = ConversationReducer.provisionalEchoes(s)
        guard !early.isEmpty else { return s.messages }
        let hidden = Set(early.values.map(\.id))
        return s.messages.compactMap { message in
            guard !hidden.contains(message.id) else { return nil }
            guard let local = early[message.id] else { return message }
            var row = message
            row.clientID = local.id
            // The phone's own references (its file ids and names) outlive the bubble they replace.
            if let files = local.attachments { row.attachments = files }
            return row
        }
    }
}

extension ConversationReducer {
    /// Whether the Mac's `row` is the echo of the phone's own message `local`. The Mac's rows carry
    /// `client_id: null` (`phone/rows.rs`), so: a row of yours not already claimed by another
    /// message; newer than what was on screen when Send was pressed (the newest row then is the
    /// boundary, by its id, since a replay may renumber cursors, else by its cursor); never the
    /// Mac's stand-in for a desk message (`intake_<n>`, `phone/stream.rs` `announce_his_words`);
    /// voice by the transcript's SHA-256 from the receipt; otherwise the same words, kind and
    /// number of files.
    static func isEcho(_ row: Message, of local: Message, in messages: [Message]) -> Bool {
        guard row.author == .me, row.id != local.id, row.clientID != row.id, !row.id.hasPrefix("intake_") else { return false }
        if let clientID = row.clientID { return clientID == local.id }
        let boundary = local.echoAfterMessageID.flatMap { id in messages.first(where: { $0.id == id })?.cursor }
        if let floor = boundary ?? local.echoAfterCursor, (row.cursor ?? 0) <= floor { return false }
        if local.kind == .voice {
            guard let hash = local.transcriptSHA256 else { return false }
            return notificationReference(row.text) == hash
        }
        return row.text == local.text && row.kind == local.kind
            && (row.attachments?.count ?? 0) == (local.attachments?.count ?? 0)
    }

    /// The Mac's rows that already echo a message still in the outbox, by row id, each to the
    /// phone's bubble for it: the oldest matching row, messages in the order they were sent. A
    /// blocked item is excluded, so Try again and Discard stay reachable on its own line.
    static func provisionalEchoes(_ s: AppState) -> [String: Message] {
        var out: [String: Message] = [:]
        for item in s.outbox where item.state != .blocked {
            guard let local = s.messages.first(where: { $0.id == item.clientID && $0.clientID == $0.id && $0.cursor == nil })
            else { continue }
            let row = s.messages
                .filter { out[$0.id] == nil && isEcho($0, of: local, in: s.messages) }
                .min { ($0.cursor ?? 0) < ($1.cursor ?? 0) }
            if let row { out[row.id] = local }
        }
        return out
    }
}
