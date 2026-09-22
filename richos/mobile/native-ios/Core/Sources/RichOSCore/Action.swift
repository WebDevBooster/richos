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
    /// The Mac answered 403 `{"revoked":true}`: this phone was removed (round-12 `conn-revoked`).
    case pairingRevoked
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
        case .networkChanged, .connectionLost, .connected, .connectionDiagnosed, .macCapabilities, .pairingRevoked:
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
