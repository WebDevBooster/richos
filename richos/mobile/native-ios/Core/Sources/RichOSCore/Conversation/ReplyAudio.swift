import Foundation

/// Which of Rich's replies show "Hear it" (round 12.1 `.rich-audio`), and where its audio comes from.
///
/// The Mac's contract (`web/web-app/CONTRACT-STUB.md` §2(b) and (c)): a reply can be heard when its
/// row says `has_audio: true`, or when the Mac offers `audio`, because such a Mac synthesizes any
/// finished reply on request at `GET /api/audio/<message_id>` (`phone/routes.rs` `audio`). A real
/// Mac sends `has_audio: false` on every row and offers `audio` whenever its voice is available
/// (`phone/rows.rs`, `routes.rs` `capabilities`), so both halves are needed. The reference client
/// draws the same rule (`web/web-app/app.js`: `row.has_audio || api.offers('audio')`).
public enum ReplyAudio {
    /// A finished reply of Rich's, in words, that the Mac can read aloud. Not a question card, not a
    /// file, and not the preview a notification put in place before the reply itself arrived (its id
    /// is the phone's, not the Mac's).
    public static func hearable(_ message: Message, macOffersAudio: Bool) -> Bool {
        guard message.author == .rich, message.kind == .text, message.question == nil,
              message.attachments?.isEmpty ?? true,
              !message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !message.id.hasPrefix(ConversationReducer.provisionalPrefix) else { return false }
        return message.hasAudio == true || macOffersAudio
    }

    /// The signed request for one reply's audio: the message id is one path segment, the thread is the
    /// conversation the reply is in (the Mac synthesizes from that thread's text).
    public static func path(messageID: String, threadID: String?) -> String {
        // RFC 3986 unreserved characters, ASCII only: `turn_9:text:0` is sent as `turn_9%3Atext%3A0`.
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.~")
        let segment = messageID.addingPercentEncoding(withAllowedCharacters: allowed) ?? messageID
        var path = "/api/audio/\(segment)"
        if let threadID { path += "?thread_id=\(Delivery.formEncode(threadID))" }
        return path
    }

    /// The Mac's reply ceiling (`phone/voice.rs` `MAX_REPLY`); anything larger is not played.
    public static let maxBytes = 6_000_000
}
