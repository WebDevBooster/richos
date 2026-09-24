import Foundation
import RichOSCore

/// Everything a screen draws, as one value. Views render only this and report only `Intent`s; they
/// hold no protocol code and make no decisions about delivery, pairing or connection.
///
/// It is DERIVED from `AppState` by `init(state:)` — one pure function, so a CLI `state` and a
/// screenshot can never disagree about what is on screen, and a headless check proves every round-12
/// fixture draws its own screen (`native-ios-ui.test.sh`, part 1). Foundation-only: it compiles on this
/// Mac with no simulator.
struct ScreenModel: Equatable, Sendable {
    var appearance: Appearance = .dark
    /// A full-screen takeover (pairing, consent, removed, update required). Nothing else is interactive.
    var takeover: Takeover?
    var scanner: Scanner?
    var dialog: Dialog?
    var sheet: Sheet?
    var banner: UpdateBanner?
    var thread = Transcript()
    /// The nameplate's second line: only for a persistent interruption (PRD §5 CEO experience gate).
    var connection: ConnectionLine?
    /// Cards above the composer, top to bottom.
    var cards: [Card] = []
    var toast: Toast?
    var composer = Composer()
    /// The recording gesture, exactly as the core holds it.
    var voice: VoiceSession?
    /// Photos and files (round-12 `attachments.html`): the menu, the tray, the viewer. Empty until the
    /// core carries attachments (`native-ios/docs/CORE-REQUESTS.md` §1).
    var attach = Attach()

    // MARK: Parts

    enum Takeover: Equatable, Sendable {
        case pairIntro(problem: PairProblem?)
        case pairProgress
        case pairWords([String])
        case pairStale
        case consent
        case removedFromMac
        case updateRequired(version: String, message: String)
    }

    enum PairProblem: Equatable, Sendable { case refused, invalidLink(String) }

    enum Scanner: Equatable, Sendable { case looking, found }

    enum Dialog: Equatable, Sendable {
        case cameraDenied
        /// `removed`: the Mac removed this phone, so the waiting messages can never be sent (Urban G2).
        case pairBlocked(waiting: Int, removed: Bool)
        case forget
        case forgetBlocked(waiting: Int)
        case update(version: String, message: String)
    }

    enum Sheet: Equatable, Sendable {
        case settings(Settings)
        case whereMessagesGo
        case pairingLink(problem: String?)
    }

    struct Settings: Equatable, Sendable {
        var notifications: NotificationStatus = .on
        var previews = true
        var update: UpdateCheck = .upToDate
        var macName = "your Mac"
    }

    enum NotificationStatus: String, Equatable, Sendable {
        case notAsked, on, off, turningOn, denied, unsupported, appleUnavailable, serviceUnavailable
    }

    enum UpdateCheck: Equatable, Sendable { case upToDate, available(String), couldNotCheck }

    struct UpdateBanner: Equatable, Sendable {
        var version: String
        var message: String
    }

    struct Transcript: Equatable, Sendable {
        var rows: [Row] = []
        var loadingOlder = false
        var reachedBeginning = false
        /// Showing history kept on this phone while the Mac is out of reach (`conn-cached`).
        var cached = false
        /// `false` while the reader has scrolled up to older messages.
        var following = true
        /// The reply a notification opened; it glows once.
        var focusedID: String?
        var isEmpty: Bool { rows.isEmpty }
    }

    struct Row: Equatable, Identifiable, Sendable {
        enum Author: Equatable, Sendable { case rich, me }
        enum Body: Equatable, Sendable {
            case text(String)
            case voice(durationMs: Int, levels: [Double])
            /// Rich is writing: three breathing dots, no sentence (`conv-replying`).
            case replying
            /// Words landing as they come, with a gold caret (`conv-streaming`).
            case streaming(String)
            /// Your photos, one album with an optional caption (`att-conv-album`).
            case album([AttachPhoto], caption: String?)
            /// A file, with an optional caption (`att-conv-file`).
            case file(AttachFile, caption: String?)
        }
        enum Delivery: Equatable, Sendable { case sent, sending, waiting, needsAttention }
        enum Audio: Equatable, Sendable { case ready, preparing, playing(progress: Double) }

        var id: String
        var author: Author
        var body: Body
        var sentAt: Int64
        /// `nil` for Rich; your messages carry their honest delivery state.
        var delivery: Delivery?
        /// Rich's reply read aloud (`conv-playing-reply`).
        var audio: Audio?
        /// "Now" instead of a clock time, for a message that has not reached the Mac yet.
        var isRecent = false
        /// Rich's answer quoting what you sent (`att-ref`): tapping it goes back to it.
        var reference: Reference? = nil
        /// "Shared from Photos" (`share-landed`).
        var sharedFrom: String? = nil
        /// Upload progress, 0…1, while an attachment is sending.
        var progress: Double? = nil
    }

    struct ConnectionLine: Equatable, Sendable {
        enum Kind: Equatable, Sendable {
            case reconnecting, phoneOffline, serviceUnavailable, macUnreachable, incompatible
            case voiceUnsupported, voicePaused, attachmentsUnsupported
        }
        var kind: Kind
    }

    enum Card: Equatable, Identifiable, Sendable {
        case waitingToSend(count: Int)
        case notificationOffer
        case microphoneDenied
        case keptRecording(KeptRecording)
        case attachRefused(name: String, detail: String, tooLarge: Bool)
        case attachCameraDenied
        case attachPhotosDenied
        case attachMacUnsupported
        var id: String {
            switch self {
            case .waitingToSend: return "waiting"
            case .notificationOffer: return "notification-offer"
            case .microphoneDenied: return "mic-denied"
            case .keptRecording(let r): return "kept-\(r.id)"
            case .attachRefused: return "attach-refused"
            case .attachCameraDenied: return "attach-camera-denied"
            case .attachPhotosDenied: return "attach-photos-denied"
            case .attachMacUnsupported: return "attach-mac-unsupported"
            }
        }
    }

    struct KeptRecording: Equatable, Sendable {
        enum Reason: Equatable, Sendable { case unsent, interrupted, ceiling }
        var id: String
        var durationMs: Int
        var levels: [Double]
        var reason: Reason
    }

    enum Toast: Equatable, Sendable {
        case tooShort
        case ceilingWarning
        case tooLong(limit: Int)
        case outboxFull(limit: Int)
        case attachLimit
        var text: String {
            switch self {
            case .tooShort: return "Hold the button while you speak. Release to send."
            case .ceilingWarning: return "One minute left on this voice message."
            case .tooLong(let limit):
                return "That’s over the \(limit.formatted(.number.locale(Locale(identifier: "en_US"))))-character limit. Trim it, or send it as a voice message."
            case .outboxFull(let limit):
                return "\(limit) messages are already waiting on this phone. Send or discard some first."
            case .attachLimit: return "Up to 10 at a time. Send these, then add more."
            }
        }
    }

    struct Composer: Equatable, Sendable {
        var draft = ""
        /// Why sending is off, in one line, or `nil` (`comp-disabled`).
        var disabledReason: String?
        /// The keyboard is up and the field has focus (`comp-keyboard`).
        var focused = false
        /// Voice paused by policy or unsupported: the microphone dims and does nothing.
        var voiceAvailable = true
        /// Round 12's limit (`comp-too-long`), from the core.
        static let characterLimit = Limits.messageCharacters
        var isTooLong: Bool { draft.count > Self.characterLimit }
        var hasDraft: Bool { !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
}

extension ScreenModel {
    /// The one derivation from the core's state. Total: every `AppState` draws.
    init(state s: AppState) {
        self.init()
        appearance = s.appearance

        // The full-screen surface; the core decides which (`AppState.screen`).
        switch s.screen {
        case .pairIntro:
            switch s.pairingProblem {
            case .refused?: takeover = .pairIntro(problem: .refused)
            case .invalidLink(let why)? where s.sheet != .pairingLink: takeover = .pairIntro(problem: .invalidLink(why))
            default: takeover = .pairIntro(problem: nil)
            }
        case .pairScanner:
            takeover = .pairIntro(problem: nil)
            scanner = s.scanner == .found ? .found : .looking
        case .pairProgress: takeover = .pairProgress
        case .pairWords: takeover = .pairWords(s.fingerprintWords)
        case .pairConsent: takeover = .consent
        case .pairStale: takeover = .pairStale
        case .connectionRevoked: takeover = .removedFromMac
        case .updateRequired:
            takeover = .updateRequired(version: s.update?.version ?? "", message: s.update?.message ?? "")
        case .conversation, .conversationEmpty:
            break
        }

        // The conversation.
        thread.rows = s.messages.map { Row(message: $0) }
        if let playback = s.playback, let i = thread.rows.firstIndex(where: { $0.id == playback.messageID }) {
            thread.rows[i].audio = playback.phase == .preparing ? .preparing : .playing(progress: playback.progress)
        }
        let replyAt = s.messages.last?.sentAt ?? 0
        switch s.reply {
        case .thinking?:
            thread.rows.append(Row(id: "~reply", author: .rich, body: .replying, sentAt: replyAt, isRecent: true))
        case .streaming(let text)?:
            thread.rows.append(Row(id: "~reply", author: .rich, body: .streaming(text), sentAt: replyAt, isRecent: true))
        case nil:
            break
        }
        thread.loadingOlder = s.history.loadingOlder
        thread.reachedBeginning = s.history.reachedBeginning
        thread.cached = s.history.cached
        thread.following = s.following
        thread.focusedID = s.focusedMessageID

        // The nameplate's line: a persistent interruption first, then what voice cannot do now.
        if let notice = s.connectionNotice {
            switch notice {
            case .reconnecting: connection = ConnectionLine(kind: .reconnecting)
            case .phoneOffline: connection = ConnectionLine(kind: .phoneOffline)
            case .serviceUnavailable: connection = ConnectionLine(kind: .serviceUnavailable)
            case .macUnreachable: connection = ConnectionLine(kind: .macUnreachable)
            case .incompatible: connection = ConnectionLine(kind: .incompatible)
            }
        } else if s.voiceAvailability == .unsupportedByMac {
            connection = ConnectionLine(kind: .voiceUnsupported)
        } else if s.voiceAvailability == .pausedByPolicy {
            connection = ConnectionLine(kind: .voicePaused)
        }

        // Dialogs and sheets.
        switch s.sheet {
        case .settings?:
            sheet = .settings(Settings(notifications: Self.status(s.notifications.status), previews: s.notifications.previews,
                                       update: s.update.map { .available($0.version) } ?? .upToDate,
                                       macName: s.mac?.name ?? "your Mac"))
        case .whereMessagesGo?:
            sheet = .whereMessagesGo
        case .pairingLink?:
            if case .invalidLink(let why)? = s.pairingProblem { sheet = .pairingLink(problem: why) } else { sheet = .pairingLink(problem: nil) }
        case .forget?:
            dialog = .forget
        case .forgetBlocked?:
            dialog = .forgetBlocked(waiting: max(1, s.unsentCount))
        case .cameraDenied?:
            dialog = .cameraDenied
        case .microphonePrompt?, nil:
            break  // the microphone question is the system's own alert, not ours to draw
        }
        if case .blockedByUnsentWork(let count)? = s.pairingProblem {
            dialog = .pairBlocked(waiting: count, removed: s.pairing == .revoked)
        }
        if let update = s.update {
            switch update.prominence {
            case .banner: banner = UpdateBanner(version: update.version, message: update.message)
            case .dialog: if dialog == nil { dialog = .update(version: update.version, message: update.message) }
            case .required: break  // the takeover above
            }
        }

        // Cards above the composer, in round 12's order.
        let waiting = s.messages.filter { $0.delivery == .waiting }.count
        if waiting > 0, let notice = s.connectionNotice, notice != .incompatible {
            cards.append(.waitingToSend(count: waiting))
        }
        for r in s.keptRecordings {
            let reason: KeptRecording.Reason
            switch r.reason {
            case .interrupted: reason = .interrupted
            case .ceiling: reason = .ceiling
            case .unsent: reason = .unsent
            }
            cards.append(.keptRecording(KeptRecording(id: r.id, durationMs: r.durationMs, levels: r.levels, reason: reason)))
        }
        if s.microphone == .denied { cards.append(.microphoneDenied) }
        if s.pairing == .paired, s.notifications.status == .notAsked, !s.notifications.offerDismissed {
            cards.append(.notificationOffer)
        }

        switch s.toast {
        case .tooShort?: toast = .tooShort
        case .ceilingWarning?: toast = .ceilingWarning
        case .tooLong(let limit)?: toast = .tooLong(limit: limit)
        case .outboxFull(let limit)?: toast = .outboxFull(limit: limit)
        case nil: break
        }

        composer.draft = s.draft
        composer.focused = s.composerFocused
        composer.voiceAvailable = s.voiceAvailability == .available
        if s.connectionNotice == .incompatible { composer.disabledReason = "Sending is off until your Mac updates" }
        voice = s.voice
    }

    static func status(_ s: Notifications.Status) -> NotificationStatus {
        switch s {
        case .notAsked: return .notAsked
        case .turningOn: return .turningOn
        case .on: return .on
        case .off: return .off
        case .denied: return .denied
        case .unsupported: return .unsupported
        case .appleUnavailable: return .appleUnavailable
        case .serviceUnavailable: return .serviceUnavailable
        }
    }
}

extension ScreenModel.Row {
    init(message m: Message) {
        let author: Author = m.author == .rich ? .rich : .me
        let body: Body
        switch m.kind {
        case .text: body = .text(m.text)
        case .voice: body = .voice(durationMs: m.durationMs ?? 0, levels: m.levels ?? [])
        }
        let delivery: Delivery?
        if author == .rich {
            delivery = nil
        } else {
            switch m.delivery {
            case .none: delivery = .sent
            case .sending: delivery = .sending
            case .waiting: delivery = .waiting
            case .needsAttention: delivery = .needsAttention
            }
        }
        self.init(id: m.id, author: author, body: body, sentAt: m.sentAt, delivery: delivery,
                  isRecent: delivery == .sending || delivery == .waiting)
    }
}
