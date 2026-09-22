import Foundation

/// The conversation and the outbox, round-12 groups 2 and 3.
///
/// The outbox rules are the reference queue's (`richos/web/web-app/lib/queue.js`, phone protocol
/// contract §6.4), each one a test: persisted before the bubble shows; strict first-in first-out,
/// one in flight, and the flush STOPS at the first retryable failure; a final refusal blocks that
/// item only and the queue continues; retries wait 1 s doubling to 16 s; the exact body bytes are
/// fixed at send and resent unchanged; nothing is attempted while the phone is offline.
public enum ConversationReducer {
    public static let firstRetryMs: Int64 = 1000
    public static let maxRetryMs: Int64 = 16000
    /// The reference client's cap (`richos/mobile/core/client.js`).
    public static let outboxLimit = 100

    public static func retryDelayMs(attempt: Int) -> Int64 {
        min(firstRetryMs << Int64(max(0, attempt - 1)), maxRetryMs)
    }

    static func reduce(_ s: inout AppState, _ action: Action, _ effects: inout [Effect]) {
        switch action {
        case .sendDraft(let clientID, let at):
            send(&s, clientID: clientID, at: at, &effects)
        case .deliveryAccepted(let clientID, let at):
            guard let i = s.outbox.firstIndex(where: { $0.clientID == clientID }) else { return }
            s.outbox.remove(at: i)
            setDelivery(&s, clientID, nil)
            pump(&s, at: at, &effects)
        case .deliveryFailed(let clientID, let failure, let at):
            guard let i = s.outbox.firstIndex(where: { $0.clientID == clientID }) else { return }
            switch failure {
            case .retryable(let reason, let afterMs):
                s.outbox[i].attempts += 1
                s.outbox[i].state = .waiting
                s.outbox[i].notBefore = at + (afterMs ?? retryDelayMs(attempt: s.outbox[i].attempts))
                s.outbox[i].lastReason = reason
                setDelivery(&s, clientID, .waiting)
            case .refused(let reason):
                s.outbox[i].state = .blocked
                s.outbox[i].lastReason = reason
                setDelivery(&s, clientID, .needsAttention)
                pump(&s, at: at, &effects)
            case .refusedStopQueue(let reason):
                s.outbox[i].state = .blocked
                s.outbox[i].lastReason = reason
                setDelivery(&s, clientID, .needsAttention)
            case .revoked:
                // Final for the pairing, not for his words: they stay on the phone ("Nothing here
                // was lost", round-12 `conn-revoked`).
                s.outbox[i].state = .waiting
                setDelivery(&s, clientID, .waiting)
                s.pairing = .revoked
            }
        case .tick(let at):
            pump(&s, at: at, &effects)
        case .retryNow(let at):
            for i in s.outbox.indices where s.outbox[i].state == .waiting { s.outbox[i].notBefore = 0 }
            pump(&s, at: at, &effects)
        case .discardMessage(let id):
            guard let i = s.outbox.firstIndex(where: { $0.clientID == id }), s.outbox[i].state != .sending else { return }
            s.outbox.remove(at: i)
            s.messages.removeAll { $0.id == id }
            if case .blockedByUnsentWork = s.pairingProblem {
                s.pairingProblem = s.outbox.isEmpty ? nil : .blockedByUnsentWork(count: s.outbox.count)
            }
            if s.sheet == .forgetBlocked, s.outbox.isEmpty { s.sheet = .forget }
        case .messagesArrived(let arrived):
            merge(&s, arrived)
        case .replyStarted:
            s.reply = .thinking
        case .replyDelta(let text):
            s.reply = .streaming(text: text)
        case .replyFinished(let message):
            s.reply = nil
            merge(&s, [message])
        case .loadOlder:
            guard !s.history.loadingOlder, !s.history.reachedBeginning else { return }
            s.history.loadingOlder = true
            effects.append(.loadOlder(before: s.messages.first?.id))
        case .olderLoaded(let older, let reachedBeginning):
            s.history.loadingOlder = false
            s.history.reachedBeginning = reachedBeginning
            merge(&s, older)
        case .setFollowing(let following):
            s.following = following
        case .setComposerFocus(let focused):
            s.composerFocused = focused
        case .openedFromNotification(let messageID):
            s.focusedMessageID = messageID
            s.following = true
        case .clearFocus:
            s.focusedMessageID = nil
        case .hearReply(let id):
            guard s.messages.contains(where: { $0.id == id && $0.author == .rich }) else { return }
            if s.playback != nil { effects.append(.stopAudio) }
            s.playback = Playback(messageID: id, phase: .preparing)
            effects.append(.fetchReplyAudio(messageID: id))
        case .playbackStarted(let id):
            // Audio that arrives for a reply no longer asked for never starts (the preserved rule).
            guard s.playback?.messageID == id else { effects.append(.stopAudio); return }
            s.playback = Playback(messageID: id, phase: .playing)
        case .playbackProgress(let id, let progress):
            guard s.playback?.messageID == id, s.playback?.phase == .playing else { return }
            s.playback?.progress = min(1, max(0, progress))
        case .playbackEnded, .stopPlayback:
            if action == .stopPlayback, s.playback != nil { effects.append(.stopAudio) }
            s.playback = nil
        case .dismissToast:
            s.toast = nil
        default:
            break
        }
    }

    private static func send(_ s: inout AppState, clientID: String, at: Int64, _ effects: inout [Effect]) {
        let text = s.draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard s.pairing == .paired, s.consentGiven, !text.isEmpty, s.connectionNotice != .incompatible else { return }
        guard s.draft.count <= Limits.messageCharacters else {
            s.toast = .tooLong(limit: Limits.messageCharacters)
            return
        }
        guard s.outbox.count < outboxLimit else {
            s.toast = .outboxFull(limit: outboxLimit)
            return
        }
        guard !s.outbox.contains(where: { $0.clientID == clientID }) else { return }
        s.outbox.append(OutboxItem(clientID: clientID, kind: .text,
                                   body: textBody(clientID: clientID, threadID: s.mac?.threadID, text: text, sentAt: at),
                                   queuedAt: at))
        s.messages.append(Message(id: clientID, author: .me, text: text, sentAt: at, delivery: .waiting, clientID: clientID))
        s.draft = ""
        s.toast = nil
        // Both send gestures resume following immediately (PRD §5).
        s.following = true
        pump(&s, at: at, &effects)
    }

    /// Starts the next delivery if the queue may move: one in flight, first in first out, nothing
    /// while offline, revoked or incompatible, and nothing before the head's retry time.
    static func pump(_ s: inout AppState, at: Int64, _ effects: inout [Effect]) {
        guard s.pairing == .paired, !s.outbox.contains(where: { $0.state == .sending }) else { return }
        switch s.connectionNotice {
        case .phoneOffline?, .incompatible?: return
        default: break
        }
        guard let head = s.outbox.firstIndex(where: { $0.state == .waiting }), s.outbox[head].notBefore <= at else { return }
        s.outbox[head].state = .sending
        setDelivery(&s, s.outbox[head].clientID, .sending)
        effects.append(.deliver(clientID: s.outbox[head].clientID))
    }

    private static func setDelivery(_ s: inout AppState, _ id: String, _ delivery: Message.Delivery?) {
        if let i = s.messages.firstIndex(where: { $0.id == id }) { s.messages[i].delivery = delivery }
    }

    /// Adds or replaces by id, keeping the conversation ordered by time (stable for equal times). The
    /// Mac's row for one of your messages retires the phone's own bubble for it: by `clientID` when
    /// the row carries it, else by the same text on a bubble the Mac has already accepted (the
    /// reference thread model's rule).
    private static func merge(_ s: inout AppState, _ incoming: [Message]) {
        for message in incoming where message.author == .me {
            s.messages.removeAll { local in
                guard local.id != message.id, local.author == .me, local.delivery == nil,
                      !s.outbox.contains(where: { $0.clientID == local.id }) else { return false }
                if let clientID = message.clientID { return local.id == clientID }
                return local.clientID == local.id && local.text == message.text
            }
        }
        for message in incoming {
            if let i = s.messages.firstIndex(where: { $0.id == message.id }) {
                s.messages[i] = message
            } else {
                s.messages.append(message)
            }
        }
        s.messages = s.messages.enumerated()
            .sorted { $0.element.sentAt != $1.element.sentAt ? $0.element.sentAt < $1.element.sentAt : $0.offset < $1.offset }
            .map(\.element)
    }

    /// The text request body (contract §5.2), in the reference's field order, serialized once.
    public static func textBody(clientID: String, threadID: String?, text: String, sentAt: Int64) -> String {
        func quoted(_ value: String) -> String {
            let encoder = JSONEncoder()
            encoder.outputFormatting = .withoutEscapingSlashes
            return String(decoding: (try? encoder.encode(value)) ?? Data("\"\"".utf8), as: UTF8.self)
        }
        var fields = ["\"client_id\":\(quoted(clientID))"]
        if let threadID { fields.append("\"thread_id\":\(quoted(threadID))") }
        fields += ["\"kind\":\"text\"", "\"text\":\(quoted(text))", "\"sent_at\":\(quoted(isoMillis(sentAt)))"]
        return "{" + fields.joined(separator: ",") + "}"
    }

    /// `2026-09-22T13:00:00.000Z`, as JavaScript's `toISOString` writes it.
    public static func isoMillis(_ ms: Int64) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: Date(timeIntervalSince1970: Double(ms) / 1000))
    }
}
