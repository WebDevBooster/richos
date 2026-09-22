import Foundation
import RichOSCore

/// Everything a person can do on a screen, as the views report it. `action` translates an intent into
/// the core's `Action` — the ONLY way a screen changes the app's state. An intent the core has no
/// action for yet returns `nil` and changes nothing: a screen never pretends something happened.
enum Intent: Equatable, Sendable {
    // Composer
    case compose(String)
    case sendText
    case setComposerFocus(Bool)
    // Voice: the finger and the frame clock, reported; the core's gesture decides (build plan §3.2).
    case voicePress(atMs: Int64)
    case voiceMove(dx: Double, dy: Double, atMs: Int64)
    case voiceRelease(atMs: Int64)
    case voiceLockedSend(atMs: Int64)
    case voiceLockedCancel(atMs: Int64)
    case voiceInterrupted(atMs: Int64)
    case voiceTick(atMs: Int64)
    case voiceSettled
    /// VoiceOver's "Record hands-free": start a recording already locked.
    case voiceRecordHandsFree(atMs: Int64)
    case sendKept(id: String)
    case discardKept(id: String)
    case playVoice(id: String)
    // Conversation
    case setFollowing(Bool)
    case loadOlder
    case hearReply(id: String)
    case stopReply
    case discard(id: String)
    case retryNow
    case dismissToast
    case dismissCard(id: String)
    case clearFocus
    // Pairing
    case scan
    case scanned(String)
    case cameraDenied
    case closeScanner
    case usePairingLink
    case submitPairingLink(String)
    case confirmWords
    case rejectWords
    case acceptConsent
    case learnMore
    case pairAgain
    case sendWaitingFirst
    case discardAndPair
    case keepPairing
    // Settings
    case openSettings
    case closeSheet
    case openWhereMessagesGo
    case setNotifications(Bool)
    case setPreviews(Bool)
    case openSystemSettings
    case checkForUpdates
    case openSupport
    case forget
    case confirmForget
    case showWaiting
    case closeDialog
    case setAppearance(Appearance)
    // Notifications
    case turnOnNotifications
    case notificationsNotNow
    // Updates
    case openAppStore
    case updateLater
    case checkAgain
    // Attachments (round-12 attachments; the core's attachment domain is pending)
    case openAttachMenu
    case closeAttachMenu
    case openPicker(ScreenModel.Picker)
    case removePending(id: String)
    case jumpTo(id: String)
    case openViewer(messageID: String, index: Int)
    case viewerShow(index: Int)
    case closeViewer

    /// The core action for this intent, where the core has one. `now` stamps time-bearing actions.
    func action(now: Int64 = VoiceClock.nowMs()) -> Action? {
        switch self {
        case .compose(let text): return .compose(text: text)
        case .sendText: return .sendDraftNow()
        case .setComposerFocus(let focused): return .setComposerFocus(focused)
        case .setFollowing(let following): return .setFollowing(following)
        case .loadOlder: return .loadOlder
        case .hearReply(let id): return .hearReply(id: id)
        case .stopReply: return .stopPlayback
        case .discard(let id): return .discardMessage(id: id)
        case .retryNow: return .retryNow(at: now)
        case .dismissToast: return .dismissToast
        case .clearFocus: return .clearFocus
        case .scan, .pairAgain: return .openScanner
        case .scanned(let text): return .scanned(text: text)
        case .cameraDenied: return .cameraPermission(.denied)
        case .closeScanner: return .closeScanner
        case .usePairingLink: return .openSheet(.pairingLink)
        case .submitPairingLink(let text): return .submitPairingLink(text: text)
        case .confirmWords: return .confirmWords
        case .rejectWords: return .rejectWords
        case .acceptConsent: return .acceptConsent
        case .keepPairing: return .dismissPairingProblem
        case .openSettings: return .openSheet(.settings)
        case .closeSheet, .closeDialog: return .closeSheet
        case .openWhereMessagesGo, .learnMore: return .openSheet(.whereMessagesGo)
        case .forget: return .openSheet(.forget)
        case .setAppearance(let appearance): return .setAppearance(appearance)
        default: return nil
        }
    }
}
