import CryptoKit
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
        case .deliveryAccepted(let clientID, let at, let transcriptHash):
            guard let i = s.outbox.firstIndex(where: { $0.clientID == clientID }) else { return }
            if s.outbox[i].kind == .voice, let transcriptHash,
               transcriptHash.utf8.count == 64, transcriptHash.allSatisfy({ $0.isHexDigit && $0.isASCII }),
               let local = s.messages.firstIndex(where: { $0.id == clientID }) {
                s.messages[local].transcriptSHA256 = transcriptHash.lowercased()
            }
            releaseFiles(of: s.outbox.remove(at: i), &effects)
            setDelivery(&s, clientID, nil)
            reconcile(&s)
            pump(&s, at: at, &effects)
        case .deliveryFailed(let clientID, let failure, let at):
            guard let i = s.outbox.firstIndex(where: { $0.clientID == clientID }) else { return }
            switch failure {
            case .retryable(let reason, let afterMs):
                // Lifecycle/storage deferral is not a failed network attempt. Do not make the
                // next real transient failure wait longer merely because the user switched apps.
                if !["background", "background-budget", "local-storage"].contains(reason) {
                    s.outbox[i].attempts += 1
                }
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
            // "Send it first" in `pair-blocked` is this action: the choice is made, the dialog goes.
            if case .blockedByUnsentWork = s.pairingProblem { s.pairingProblem = nil }
            pump(&s, at: at, &effects)
        case .discardMessage(let id):
            guard let i = s.outbox.firstIndex(where: { $0.clientID == id }), s.outbox[i].state != .sending else { return }
            releaseFiles(of: s.outbox.remove(at: i), &effects)
            s.messages.removeAll { $0.id == id }
            if case .blockedByUnsentWork = s.pairingProblem {
                s.pairingProblem = s.outbox.isEmpty ? nil : .blockedByUnsentWork(count: s.outbox.count)
            }
            if s.sheet == .forgetBlocked, s.outbox.isEmpty { s.sheet = .forget }
        case .messagesArrived(let arrived):
            merge(&s, arrived)
            seekNotified(&s, &effects, progressed: true)
        case .replyStarted:
            s.reply = .thinking
        case .replyDelta(let text):
            s.reply = .streaming(text: text)
        case .replyFinished(let message):
            s.reply = nil
            merge(&s, [message])
            seekNotified(&s, &effects, progressed: true)
        case .loadOlder:
            guard !s.history.loadingOlder, !s.history.reachedBeginning else { return }
            s.history.loadingOlder = true
            effects.append(.loadOlder(before: s.messages.first?.id))
        case .olderLoaded(let older, let reachedBeginning):
            s.history.loadingOlder = false
            s.history.reachedBeginning = reachedBeginning
            let known = Set(s.messages.map(\.id))
            merge(&s, older)
            // A page that brought nothing new ends this search (a failed or stale page must not loop);
            // the next messages from the Mac start it again.
            seekNotified(&s, &effects, progressed: older.contains { !known.contains($0.id) })
        case .rememberReading(let anchor):
            s.readingAnchor = anchor
            s.following = false
        case .setFollowing(let following):
            s.following = following
            if following { s.readingAnchor = nil }
        case .setComposerFocus(let focused):
            s.composerFocused = focused
        case .openedFromNotification(let messageID):
            s.notifiedReply = nil
            s.focusedMessageID = messageID
            s.following = true
        case .openedFromNotificationReference(let reference):
            s.notifiedReply = reference
            seekNotified(&s, &effects, progressed: true)
        case .takeShare(let intake, let at):
            take(intake, &s, at: at, &effects)
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
        case .backgrounded:
            if s.playback != nil { effects.append(.stopAudio) }
            s.playback = nil
            s.history.loadingOlder = false
            // The stream carrying the reply closes with the app. The next one re-announces a reply
            // still being written and sends a finished one as history, never as "finished", so a
            // reply kept from here would stay "thinking" under its own answer (and animate).
            s.reply = nil
        default:
            break
        }
    }

    private static func send(_ s: inout AppState, clientID: String, at: Int64, _ effects: inout [Effect]) {
        let text = s.draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard s.pairing == .paired, s.consentGiven, !text.isEmpty || !s.pendingAttachments.isEmpty,
              s.connectionNotice != .incompatible else { return }
        guard s.draft.count <= Limits.messageCharacters else {
            s.toast = .tooLong(limit: Limits.messageCharacters)
            return
        }
        // Photos or files in the tray: they and the draft's words go together (Android `send`).
        if sendAttachments(&s, clientID: clientID, text: text, at: at, &effects) { return }
        guard s.outbox.count < outboxLimit else {
            s.toast = .outboxFull(limit: outboxLimit)
            return
        }
        guard !s.outbox.contains(where: { $0.clientID == clientID }) else { return }
        s.outbox.append(OutboxItem(clientID: clientID, kind: .text,
                                   body: textBody(clientID: clientID, threadID: s.mac?.threadID, text: text, sentAt: at),
                                   queuedAt: at))
        s.messages.append(Message(id: clientID, author: .me, text: text, sentAt: at, delivery: .waiting, clientID: clientID, echoAfterCursor: s.messages.compactMap(\.cursor).max() ?? 0,
                                      echoAfterMessageID: s.messages.last(where: { $0.cursor != nil })?.id))
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

    /// SHA-256 (lowercase hex) of a message id: how a notification names its reply (contract §7.3).
    public static func notificationReference(_ id: String) -> String {
        SHA256.hash(data: Data(id.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Focuses the notified reply once it is loaded; otherwise asks for the next older page, while the
    /// last step made progress and the beginning has not been reached (`web/lib/notification-target.js`).
    static func seekNotified(_ s: inout AppState, _ effects: inout [Effect], progressed: Bool) {
        guard let reference = s.notifiedReply else { return }
        if let found = s.messages.last(where: { notificationReference($0.id) == reference }) {
            s.notifiedReply = nil
            s.focusedMessageID = found.id
            s.following = true
            return
        }
        guard progressed, s.pairing == .paired, !s.history.loadingOlder, !s.history.reachedBeginning else { return }
        s.history.loadingOlder = true
        effects.append(.loadOlder(before: s.messages.first?.id))
    }

    private static func setDelivery(_ s: inout AppState, _ id: String, _ delivery: Message.Delivery?) {
        if let i = s.messages.firstIndex(where: { $0.id == id }) { s.messages[i].delivery = delivery }
    }

    /// Reconcile accepted local messages one-to-one, regardless of whether the HTTP receipt or
    /// stream echo arrived first. Remember the association on the server row so a replay cannot
    /// consume another Send with identical words. The outbox remains authoritative until accepted.
    private static func reconcile(_ s: inout AppState) {
        let locals = s.messages.filter { local in local.author == .me && local.clientID == local.id && local.cursor == nil
            && local.delivery == nil && !s.outbox.contains(where: { $0.clientID == local.id }) }
        for local in locals {
            let candidates = s.messages.indices.filter { isEcho(s.messages[$0], of: local, in: s.messages) }
            guard let index = candidates.min(by: { (s.messages[$0].cursor ?? 0) < (s.messages[$1].cursor ?? 0) }) else { continue }
            s.messages[index].clientID = local.id
            if local.kind == .voice {
                s.messages[index].kind = .voice
                s.messages[index].durationMs = local.durationMs
                s.messages[index].levels = local.levels
            }
            if let files = local.attachments { s.messages[index].attachments = files }
            s.messages.removeAll { $0.id == local.id }
        }
    }

    private static func merge(_ s: inout AppState, _ arrived: [Message]) {
        for var message in arrived {
            if let i = s.messages.firstIndex(where: { $0.id == message.id }) {
                // The wire may omit the client ID and use server file references on a replay.
                if let clientID = s.messages[i].clientID, clientID != message.id {
                    message.clientID = clientID
                    if s.messages[i].kind == .voice {
                        message.kind = .voice
                        message.durationMs = message.durationMs ?? s.messages[i].durationMs
                        message.levels = s.messages[i].levels
                    }
                    if let files = s.messages[i].attachments { message.attachments = files }
                }
                s.messages[i] = message
            } else {
                s.messages.append(message)
            }
        }
        reconcile(&s)
        s.messages = ordered(s.messages)
    }

    /// The Mac's rows in history-cursor order; the phone's own bubbles (no cursor yet) after them in
    /// the order they were sent. Also the order a relaunch restores, so the screen does not rearrange
    /// when the next frame arrives.
    static func ordered(_ messages: [Message]) -> [Message] {
        messages.enumerated().sorted { a, b in
            switch (a.element.cursor, b.element.cursor) {
            case let (x?, y?) where x != y: return x < y
            case (_?, nil): return true
            case (nil, _?): return false
            default:
                return a.element.sentAt != b.element.sentAt ? a.element.sentAt < b.element.sentAt : a.offset < b.offset
            }
        }.map(\.element)
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
