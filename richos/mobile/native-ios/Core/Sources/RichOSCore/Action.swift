import Foundation

/// Everything a person — or the platform, or the CLI standing in for either — can do.
///
/// The screens dispatch these and nothing else; `bin/rios headless action '<json>'` dispatches the
/// same values, which is what lets the command line prove a change without a simulator. The JSON
/// spelling is `{"type": "<kebab-case>", …fields}`, the preserved mobile CLI's action envelope
/// (`richos/mobile/cli/mobile.mjs`). Cases arrive with the reducer logic that gives them meaning.
public enum Action: Equatable, Sendable {
    // composer
    case compose(text: String)
    case setAppearance(Appearance)
    // pairing (round-12 group 1)
    case openScanner
    case closeScanner
    /// The QR scanner read this text. It is only ever parsed, never followed.
    case scanned(text: String)
    /// Pasted into the pairing-link sheet.
    case submitPairingLink(text: String)
    /// The OS reports the camera permission (a mirror; nothing parallel is stored).
    case cameraPermission(Permission)
    /// The Mac answered the pairing request (from the transport, or a fixture).
    case pairingAnswered(PairAnswer)
    /// The Mac refused the pairing code (404 after the one retry, contract §2.3).
    case pairingRefused
    /// "They match" on the six-word check.
    case confirmWords
    /// "They do not match": the Mac forgets this phone and the phone discards its key (§2.5).
    case rejectWords
    /// Continue on the consent screen (`pair-consent`).
    case acceptConsent
    case dismissPairingProblem
    // sheets
    case openSheet(Sheet)
    case closeSheet
    // conversation and outbox (groups 2, 3)
    /// Send the draft. `clientID` and `at` are stamped by the caller (`Action.sendDraftNow()` in the
    /// app, fixed values in a scenario), so the reducer stays pure and a trace replays exactly.
    case sendDraft(clientID: String, at: Int64)
    /// The Mac accepted this message (200, including `duplicate: true`).
    case deliveryAccepted(clientID: String, at: Int64)
    case deliveryFailed(clientID: String, failure: DeliveryFailure, at: Int64)
    /// Time passed (the outbox's retry clock); cheap and never persisted by itself.
    case tick(at: Int64)
    /// "Try now" on the waiting card (`conv-retry`).
    case retryNow(at: Int64)
    /// Remove one of your unsent messages (never one in flight).
    case discardMessage(id: String)
    /// Rows from the live stream or a refresh, merged by id.
    case messagesArrived([Message])
    case replyStarted
    /// The reply's text so far.
    case replyDelta(text: String)
    case replyFinished(Message)
    /// Scrolled to the top: fetch older messages (chunked; never pagination).
    case loadOlder
    case olderLoaded([Message], reachedBeginning: Bool)
    case setFollowing(Bool)
    case setComposerFocus(Bool)
    case openedFromNotification(messageID: String)
    case clearFocus
    /// "Hear it" on one of Rich's replies.
    case hearReply(id: String)
    case playbackStarted(id: String)
    case playbackProgress(id: String, progress: Double)
    case playbackEnded
    case stopPlayback
    case dismissToast
    // connection (group 7)
    /// The phone's own network came or went (a path monitor in the app).
    case networkChanged(online: Bool, at: Int64)
    /// The live stream or a request to the Mac failed at the transport level.
    case connectionLost(at: Int64)
    /// The Mac answered again (a stream opened, or a request succeeded).
    case connected(at: Int64)
    /// The transport's probe says why the Mac cannot be reached (evidence-based only).
    case connectionDiagnosed(ConnectionNotice)
    /// What the Mac says it accepts (capability negotiation, contract §12).
    case macCapabilities(text: Bool, voice: Bool)
    // voice (groups 4, 5, 6)
    /// Touch-down on the microphone. `id` names the recording (`Action.voicePressNow` in the app).
    case voicePress(id: String, width: Double, at: Int64)
    /// VoiceOver's "record hands-free": start a recording already locked.
    case voiceStartLocked(id: String, width: Double, at: Int64)
    /// The OS answered or reports the microphone permission (a mirror; nothing parallel is stored).
    case microphonePermission(Permission)
    /// The finger moved: offsets from the touch-down point, in points (negative = left / up).
    case voiceMove(dx: Double, dy: Double, at: Int64)
    case voiceRelease(at: Int64)
    /// Tap on the send circle while locked.
    case voiceLockedSend(at: Int64)
    /// Tap on Cancel while locked.
    case voiceLockedCancel(at: Int64)
    /// The system took the touch away (an alert over the app).
    case voiceTouchCanceled(at: Int64)
    /// The app left the screen or the OS took the audio: the recording is kept, never sent.
    case voiceInterrupted(at: Int64)
    /// The recording's level, 0 to 1, sampled every 100 ms, for the bubble it becomes.
    case voiceLevel(Double)
    /// The end animation finished.
    case voiceSettled
    case sendKept(id: String, at: Int64)
    case discardKept(id: String)
    /// Play one of your own recordings (a kept one or a sent voice bubble).
    case playRecording(id: String)
    // notifications and settings (groups 8, 9)
    case turnOnNotifications
    /// What the OS and the Mac said to a registration (or its absence).
    case notificationsResult(Notifications.Status)
    case turnOffNotifications
    /// "Not now" on the offer card: it is asked once.
    case dismissNotificationOffer
    case setPreviews(Bool)
    /// "Forget this phone" in Settings: opens the confirmation, or the refusal while work is unsent.
    case forgetPairing
    /// The filled, destructive button in the confirmation.
    case confirmForget
    case openSystemSettings
    // update notices (group 10)
    /// The hosted policy's verdict for this app version (contract §5.10).
    case updatePolicy(UpdateNotice?, voicePaused: Bool)
    case dismissUpdate
    case openAppStore
    case openSupport
}

/// How a delivery attempt ended when it did not succeed (contract §4.2, the reference classification).
public enum DeliveryFailure: Codable, Equatable, Sendable {
    /// No Mac, a fault, or 429: the same bytes again after `afterMs` (the outbox's own clock when nil).
    case retryable(reason: String?, afterMs: Int64? = nil)
    /// A final answer for this item (409, 413, 422, 503 with `retry:false`): it needs the person; the
    /// rest of the queue carries on.
    case refused(reason: String?)
    /// A final answer about the phone, not the message (a final 404, a 403 that is not a revocation):
    /// this item is blocked and the queue stops.
    case refusedStopQueue(reason: String?)
    /// 403 `{"revoked":true}`: this phone was removed from the Mac.
    case revoked
}

extension Action {
    /// The app's touch-down on the microphone: a fresh recording id and the current time.
    public static func voicePressNow(width: Double, clock: any Clock = SystemClock()) -> Action {
        .voicePress(id: UUID().uuidString.lowercased(), width: width, at: clock.nowMs())
    }

    /// The app's way to send the draft: a fresh idempotency key and the current time.
    public static func sendDraftNow(clock: any Clock = SystemClock()) -> Action {
        .sendDraft(clientID: UUID().uuidString.lowercased(), at: clock.nowMs())
    }
}

/// What `POST /api/pair` answers with (contract §2.3), in the core's terms.
public struct PairAnswer: Codable, Equatable, Sendable {
    public var deviceID: String
    /// The Mac's root certificate SHA-256, as the Mac sends it (uppercase hex pairs joined by `:`).
    public var fingerprintHex: String
    public var threadID: String?
    public var macName: String?
    public init(deviceID: String, fingerprintHex: String, threadID: String? = nil, macName: String? = nil) {
        self.deviceID = deviceID; self.fingerprintHex = fingerprintHex; self.threadID = threadID; self.macName = macName
    }
}

extension Action: Codable {
    /// The flat wire form: a `type` and whichever fields that type carries.
    private struct Wire: Codable {
        var type: String
        var text: String?
        var appearance: Appearance?
        var permission: Permission?
        var sheet: Sheet?
        var answer: PairAnswer?
        var clientID: String?
        var id: String?
        var at: Int64?
        var failure: DeliveryFailure?
        var messages: [Message]?
        var message: Message?
        var reachedBeginning: Bool?
        var value: Bool?
        var progress: Double?
        var notice: ConnectionNotice?
        var acceptsText: Bool?
        var acceptsVoice: Bool?
        var width: Double?
        var dx: Double?
        var dy: Double?
        var level: Double?
        var status: Notifications.Status?
        var update: UpdateNotice?
    }

    public static let knownTypes = [
        "compose", "set-appearance", "open-scanner", "close-scanner", "scanned", "submit-pairing-link",
        "camera-permission", "pairing-answered", "pairing-refused", "confirm-words", "reject-words",
        "accept-consent", "dismiss-pairing-problem", "open-sheet", "close-sheet",
        "send-draft", "delivery-accepted", "delivery-failed", "tick", "retry-now", "discard-message",
        "messages-arrived", "reply-started", "reply-delta", "reply-finished", "load-older", "older-loaded",
        "set-following", "set-composer-focus", "opened-from-notification", "clear-focus", "hear-reply",
        "playback-started", "playback-progress", "playback-ended", "stop-playback", "dismiss-toast",
        "network-changed", "connection-lost", "connected", "connection-diagnosed", "mac-capabilities",
        "voice-press", "voice-start-locked", "microphone-permission", "voice-move", "voice-release", "voice-locked-send",
        "voice-locked-cancel", "voice-touch-canceled", "voice-interrupted", "voice-level", "voice-settled",
        "send-kept", "discard-kept", "play-recording",
        "turn-on-notifications", "notifications-result", "turn-off-notifications", "dismiss-notification-offer",
        "set-previews", "forget-pairing", "confirm-forget", "open-system-settings",
        "update-policy", "dismiss-update", "open-app-store", "open-support",
    ]

    public init(from decoder: Decoder) throws {
        let w = try Wire(from: decoder)
        func need<T>(_ value: T?, _ field: String) throws -> T {
            guard let value else {
                throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "action '\(w.type)' needs '\(field)'"))
            }
            return value
        }
        switch w.type {
        case "compose": self = .compose(text: try need(w.text, "text"))
        case "set-appearance": self = .setAppearance(try need(w.appearance, "appearance"))
        case "open-scanner": self = .openScanner
        case "close-scanner": self = .closeScanner
        case "scanned": self = .scanned(text: try need(w.text, "text"))
        case "submit-pairing-link": self = .submitPairingLink(text: try need(w.text, "text"))
        case "camera-permission": self = .cameraPermission(try need(w.permission, "permission"))
        case "pairing-answered": self = .pairingAnswered(try need(w.answer, "answer"))
        case "pairing-refused": self = .pairingRefused
        case "confirm-words": self = .confirmWords
        case "reject-words": self = .rejectWords
        case "accept-consent": self = .acceptConsent
        case "dismiss-pairing-problem": self = .dismissPairingProblem
        case "open-sheet": self = .openSheet(try need(w.sheet, "sheet"))
        case "close-sheet": self = .closeSheet
        case "send-draft": self = .sendDraft(clientID: try need(w.clientID, "clientID"), at: try need(w.at, "at"))
        case "delivery-accepted": self = .deliveryAccepted(clientID: try need(w.clientID, "clientID"), at: try need(w.at, "at"))
        case "delivery-failed":
            self = .deliveryFailed(clientID: try need(w.clientID, "clientID"), failure: try need(w.failure, "failure"), at: try need(w.at, "at"))
        case "tick": self = .tick(at: try need(w.at, "at"))
        case "retry-now": self = .retryNow(at: try need(w.at, "at"))
        case "discard-message": self = .discardMessage(id: try need(w.id, "id"))
        case "messages-arrived": self = .messagesArrived(try need(w.messages, "messages"))
        case "reply-started": self = .replyStarted
        case "reply-delta": self = .replyDelta(text: try need(w.text, "text"))
        case "reply-finished": self = .replyFinished(try need(w.message, "message"))
        case "load-older": self = .loadOlder
        case "older-loaded": self = .olderLoaded(try need(w.messages, "messages"), reachedBeginning: try need(w.reachedBeginning, "reachedBeginning"))
        case "set-following": self = .setFollowing(try need(w.value, "value"))
        case "set-composer-focus": self = .setComposerFocus(try need(w.value, "value"))
        case "opened-from-notification": self = .openedFromNotification(messageID: try need(w.id, "id"))
        case "clear-focus": self = .clearFocus
        case "hear-reply": self = .hearReply(id: try need(w.id, "id"))
        case "playback-started": self = .playbackStarted(id: try need(w.id, "id"))
        case "playback-progress": self = .playbackProgress(id: try need(w.id, "id"), progress: try need(w.progress, "progress"))
        case "playback-ended": self = .playbackEnded
        case "stop-playback": self = .stopPlayback
        case "dismiss-toast": self = .dismissToast
        case "network-changed": self = .networkChanged(online: try need(w.value, "value"), at: try need(w.at, "at"))
        case "connection-lost": self = .connectionLost(at: try need(w.at, "at"))
        case "connected": self = .connected(at: try need(w.at, "at"))
        case "connection-diagnosed": self = .connectionDiagnosed(try need(w.notice, "notice"))
        case "mac-capabilities":
            self = .macCapabilities(text: try need(w.acceptsText, "acceptsText"), voice: try need(w.acceptsVoice, "acceptsVoice"))
        case "voice-press": self = .voicePress(id: try need(w.id, "id"), width: try need(w.width, "width"), at: try need(w.at, "at"))
        case "voice-start-locked": self = .voiceStartLocked(id: try need(w.id, "id"), width: try need(w.width, "width"), at: try need(w.at, "at"))
        case "microphone-permission": self = .microphonePermission(try need(w.permission, "permission"))
        case "voice-move": self = .voiceMove(dx: try need(w.dx, "dx"), dy: try need(w.dy, "dy"), at: try need(w.at, "at"))
        case "voice-release": self = .voiceRelease(at: try need(w.at, "at"))
        case "voice-locked-send": self = .voiceLockedSend(at: try need(w.at, "at"))
        case "voice-locked-cancel": self = .voiceLockedCancel(at: try need(w.at, "at"))
        case "voice-touch-canceled": self = .voiceTouchCanceled(at: try need(w.at, "at"))
        case "voice-interrupted": self = .voiceInterrupted(at: try need(w.at, "at"))
        case "voice-level": self = .voiceLevel(try need(w.level, "level"))
        case "voice-settled": self = .voiceSettled
        case "send-kept": self = .sendKept(id: try need(w.id, "id"), at: try need(w.at, "at"))
        case "discard-kept": self = .discardKept(id: try need(w.id, "id"))
        case "play-recording": self = .playRecording(id: try need(w.id, "id"))
        case "turn-on-notifications": self = .turnOnNotifications
        case "notifications-result": self = .notificationsResult(try need(w.status, "status"))
        case "turn-off-notifications": self = .turnOffNotifications
        case "dismiss-notification-offer": self = .dismissNotificationOffer
        case "set-previews": self = .setPreviews(try need(w.value, "value"))
        case "forget-pairing": self = .forgetPairing
        case "confirm-forget": self = .confirmForget
        case "open-system-settings": self = .openSystemSettings
        case "update-policy": self = .updatePolicy(w.update, voicePaused: try need(w.value, "value"))
        case "dismiss-update": self = .dismissUpdate
        case "open-app-store": self = .openAppStore
        case "open-support": self = .openSupport
        default:
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription:
                "unknown action '\(w.type)'; known: \(Self.knownTypes.joined(separator: ", "))"))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var w = Wire(type: "")
        switch self {
        case .compose(let text): w.type = "compose"; w.text = text
        case .setAppearance(let a): w.type = "set-appearance"; w.appearance = a
        case .openScanner: w.type = "open-scanner"
        case .closeScanner: w.type = "close-scanner"
        case .scanned(let text): w.type = "scanned"; w.text = text
        case .submitPairingLink(let text): w.type = "submit-pairing-link"; w.text = text
        case .cameraPermission(let p): w.type = "camera-permission"; w.permission = p
        case .pairingAnswered(let a): w.type = "pairing-answered"; w.answer = a
        case .pairingRefused: w.type = "pairing-refused"
        case .confirmWords: w.type = "confirm-words"
        case .rejectWords: w.type = "reject-words"
        case .acceptConsent: w.type = "accept-consent"
        case .dismissPairingProblem: w.type = "dismiss-pairing-problem"
        case .openSheet(let s): w.type = "open-sheet"; w.sheet = s
        case .closeSheet: w.type = "close-sheet"
        case .sendDraft(let c, let at): w.type = "send-draft"; w.clientID = c; w.at = at
        case .deliveryAccepted(let c, let at): w.type = "delivery-accepted"; w.clientID = c; w.at = at
        case .deliveryFailed(let c, let f, let at): w.type = "delivery-failed"; w.clientID = c; w.failure = f; w.at = at
        case .tick(let at): w.type = "tick"; w.at = at
        case .retryNow(let at): w.type = "retry-now"; w.at = at
        case .discardMessage(let id): w.type = "discard-message"; w.id = id
        case .messagesArrived(let m): w.type = "messages-arrived"; w.messages = m
        case .replyStarted: w.type = "reply-started"
        case .replyDelta(let text): w.type = "reply-delta"; w.text = text
        case .replyFinished(let m): w.type = "reply-finished"; w.message = m
        case .loadOlder: w.type = "load-older"
        case .olderLoaded(let m, let r): w.type = "older-loaded"; w.messages = m; w.reachedBeginning = r
        case .setFollowing(let v): w.type = "set-following"; w.value = v
        case .setComposerFocus(let v): w.type = "set-composer-focus"; w.value = v
        case .openedFromNotification(let id): w.type = "opened-from-notification"; w.id = id
        case .clearFocus: w.type = "clear-focus"
        case .hearReply(let id): w.type = "hear-reply"; w.id = id
        case .playbackStarted(let id): w.type = "playback-started"; w.id = id
        case .playbackProgress(let id, let p): w.type = "playback-progress"; w.id = id; w.progress = p
        case .playbackEnded: w.type = "playback-ended"
        case .stopPlayback: w.type = "stop-playback"
        case .dismissToast: w.type = "dismiss-toast"
        case .networkChanged(let online, let at): w.type = "network-changed"; w.value = online; w.at = at
        case .connectionLost(let at): w.type = "connection-lost"; w.at = at
        case .connected(let at): w.type = "connected"; w.at = at
        case .connectionDiagnosed(let n): w.type = "connection-diagnosed"; w.notice = n
        case .macCapabilities(let t, let v): w.type = "mac-capabilities"; w.acceptsText = t; w.acceptsVoice = v
        case .voicePress(let id, let width, let at): w.type = "voice-press"; w.id = id; w.width = width; w.at = at
        case .voiceStartLocked(let id, let width, let at): w.type = "voice-start-locked"; w.id = id; w.width = width; w.at = at
        case .microphonePermission(let p): w.type = "microphone-permission"; w.permission = p
        case .voiceMove(let dx, let dy, let at): w.type = "voice-move"; w.dx = dx; w.dy = dy; w.at = at
        case .voiceRelease(let at): w.type = "voice-release"; w.at = at
        case .voiceLockedSend(let at): w.type = "voice-locked-send"; w.at = at
        case .voiceLockedCancel(let at): w.type = "voice-locked-cancel"; w.at = at
        case .voiceTouchCanceled(let at): w.type = "voice-touch-canceled"; w.at = at
        case .voiceInterrupted(let at): w.type = "voice-interrupted"; w.at = at
        case .voiceLevel(let l): w.type = "voice-level"; w.level = l
        case .voiceSettled: w.type = "voice-settled"
        case .sendKept(let id, let at): w.type = "send-kept"; w.id = id; w.at = at
        case .discardKept(let id): w.type = "discard-kept"; w.id = id
        case .playRecording(let id): w.type = "play-recording"; w.id = id
        case .turnOnNotifications: w.type = "turn-on-notifications"
        case .notificationsResult(let st): w.type = "notifications-result"; w.status = st
        case .turnOffNotifications: w.type = "turn-off-notifications"
        case .dismissNotificationOffer: w.type = "dismiss-notification-offer"
        case .setPreviews(let v): w.type = "set-previews"; w.value = v
        case .forgetPairing: w.type = "forget-pairing"
        case .confirmForget: w.type = "confirm-forget"
        case .openSystemSettings: w.type = "open-system-settings"
        case .updatePolicy(let n, let paused): w.type = "update-policy"; w.update = n; w.value = paused
        case .dismissUpdate: w.type = "dismiss-update"
        case .openAppStore: w.type = "open-app-store"
        case .openSupport: w.type = "open-support"
        }
        try w.encode(to: encoder)
    }
}

/// Work a reducer asks for and does not do itself. The reducer stays pure; the effect runner
/// performs these through the ports, so every one can be substituted in a test. An effect with no
/// port wired yet is recorded and skipped, never guessed at.
public enum Effect: Equatable, Sendable {
    /// Write `AppState.persisted` to durable storage.
    case persist
    /// Generate (or reuse) this origin's device key and send `POST /api/pair` with the code.
    case pair(PairLink)
    /// Send the signed six-word answer (contract §2.5).
    case confirmFingerprint(matches: Bool)
    /// Discard this phone's key and pairing for the current origin.
    case forgetIdentity
    /// Open this app's page in iPhone Settings (camera or microphone turned off).
    case openSystemSettings
    /// POST the outbox item's exact bytes (contract §5.2).
    case deliver(clientID: String)
    /// Fetch older history before this message (contract §5.5).
    case loadOlder(before: String?)
    /// Fetch and play the reply's audio (contract §5.6).
    case fetchReplyAudio(messageID: String)
    case stopAudio
    /// Ask the OS for the microphone (once, on the first deliberate press).
    case requestMicrophone
    case startRecording(id: String)
    /// Stop capturing; `keep` retains the file (sent or kept), otherwise it is removed.
    case stopRecording(id: String, keep: Bool)
    case deleteRecording(id: String)
    /// The light tick when the lock engages (`UIImpactFeedbackGenerator(.light)`).
    case hapticTick
    case playRecording(id: String)
    /// Ask the OS for notification permission and register with the Mac (native push, contract §7.2).
    case requestNotifications(previews: Bool)
    case unregisterNotifications
    case openAppStore
    case openSupport
}

/// The one place state changes. Pure: the same state and action always give the same result, so a
/// scenario replays exactly on this Mac and in the simulator.
public enum Reducer {
    public static func reduce(_ state: AppState, _ action: Action) -> (state: AppState, effects: [Effect]) {
        var next = state
        var effects: [Effect] = []
        switch action {
        case .compose(let text):
            next.draft = text
        case .setAppearance(let appearance):
            next.appearance = appearance
        case .openSheet(let sheet):
            next.sheet = sheet
        case .closeSheet:
            next.sheet = nil
        case .openScanner, .closeScanner, .scanned, .submitPairingLink, .cameraPermission, .pairingAnswered,
             .pairingRefused, .confirmWords, .rejectWords, .acceptConsent, .dismissPairingProblem:
            PairingReducer.reduce(&next, action, &effects)
        case .networkChanged, .connectionLost, .connected, .connectionDiagnosed, .macCapabilities:
            ConnectionReducer.reduce(&next, action, &effects)
        case .tick:
            ConnectionReducer.reduce(&next, action, &effects)
            ConversationReducer.reduce(&next, action, &effects)
            VoiceReducer.reduce(&next, action, &effects)
        case .voicePress, .voiceStartLocked, .microphonePermission, .voiceMove, .voiceRelease, .voiceLockedSend, .voiceLockedCancel,
             .voiceTouchCanceled, .voiceInterrupted, .voiceLevel, .voiceSettled, .sendKept, .discardKept, .playRecording:
            VoiceReducer.reduce(&next, action, &effects)
        case .turnOnNotifications, .notificationsResult, .turnOffNotifications, .dismissNotificationOffer, .setPreviews,
             .forgetPairing, .confirmForget, .openSystemSettings:
            SettingsReducer.reduce(&next, action, &effects)
        case .updatePolicy, .dismissUpdate, .openAppStore, .openSupport:
            UpdateReducer.reduce(&next, action, &effects)
        default:
            ConversationReducer.reduce(&next, action, &effects)
        }
        // Persist only when something durable changed: a touch-rate action never writes a file.
        if next.persisted != state.persisted { effects.insert(.persist, at: 0) }
        return (next, effects)
    }
}
