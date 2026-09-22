import RichOSCore
import UIKit

/// The iPhone's half of the core's effects (`EffectHandler`, stream I1's seam at 5f27785a): the
/// microphone, the recorder, playback of your own recordings, the lock haptic, iPhone Settings, and
/// Apple's notification permission. Network effects (pairing, delivery, history, reply audio) are
/// passed to `network`, the core's own handler, unchanged.
///
/// Two kinds of answer. Actions RETURNED from `handle` answer the effect that was asked (the OS's
/// microphone answer). Actions that happen later on their own — a level every 100 ms, an
/// interruption, playback ending — go through `dispatch`, which the app points at its store.
final class PlatformEffects: EffectHandler, @unchecked Sendable {
    private let network: (any EffectHandler)?
    private let clock: any Clock
    @MainActor let recorder: VoiceRecorder
    /// Where actions that were not asked for go (the store's `send`). Set once the store exists.
    @MainActor var dispatch: ((Action) -> Void)?

    @MainActor
    init(network: (any EffectHandler)? = nil, clock: any Clock = SystemClock(), recorder: VoiceRecorder = VoiceRecorder()) {
        self.network = network
        self.clock = clock
        self.recorder = recorder
        recorder.onLevel = { [weak self] level in self?.dispatch?(.voiceLevel(level)) }
        recorder.onInterrupted = { [weak self] in
            guard let self else { return }
            self.dispatch?(.voiceInterrupted(at: self.clock.nowMs()))
        }
        recorder.onPlaybackEnded = { [weak self] in self?.dispatch?(.playbackEnded) }
    }

    /// The courier's source of voice-message bytes (the same files the recorder writes).
    var recordings: any RecordingStore { FileRecordingStore(directory: VoiceRecorder.defaultDirectory()) }

    /// What the app sends on launch and every time it becomes active, so the core's microphone state
    /// is always the OS's (PRD §3: no parallel permission state). Wired in `App/App` (stream I1).
    static func permissionMirror() -> [Action] {
        [.microphonePermission(MicrophonePermission.current())]
    }

    func handle(_ effect: Effect, state: AppState) async -> [Action] {
        switch effect {
        case .requestMicrophone:
            return [.microphonePermission(await MicrophonePermission.request())]

        case .startRecording(let id):
            let started: Bool = await MainActor.run {
                do {
                    try recorder.start(id: id)
                    return true
                } catch {
                    return false
                }
            }
            // The recorder could not start (the audio session was refused, the disk is full): the
            // gesture ends as if the system took the touch away, and nothing is kept, because
            // nothing was recorded. A denied permission is reported as the permission it is.
            guard started else {
                if MicrophonePermission.current() != .granted { return [.microphonePermission(MicrophonePermission.current())] }
                return [.voiceTouchCanceled(at: clock.nowMs())]
            }
            return []

        case .stopRecording(_, let keep):
            await MainActor.run { recorder.stop(keep: keep) }
            return []

        case .deleteRecording(let id):
            await MainActor.run { recorder.delete(id: id) }
            return []

        case .playRecording(let id):
            await MainActor.run { recorder.play(id: id) }
            return []

        case .stopAudio:
            await MainActor.run { recorder.stopPlayback() }
            // Rich's reply audio is the network handler's; it hears the stop too.
            return await network?.handle(effect, state: state) ?? []

        case .hapticTick:
            await MainActor.run { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
            return []

        case .openSystemSettings:
            await MainActor.run {
                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
            }
            return []

        case .requestNotifications:
            // Apple's question first; registering with the Mac is the network handler's, once there
            // is a token (`NotificationPlatform.onToken`).
            let status = await NotificationPlatform.shared.authorize()
            guard status == .turningOn else { return [.notificationsResult(status)] }
            return await network?.handle(effect, state: state) ?? [.notificationsResult(status)]

        case .openAppStore, .openSupport:
            // No App Store id or support URL exists yet (release-config.json: appId and supportURL
            // are null until the CEO's App Store Connect record); nothing to open, nothing guessed.
            return []

        case .persist, .pair, .confirmFingerprint, .forgetIdentity, .deliver, .loadOlder, .fetchReplyAudio, .connect, .disconnect,
             .unregisterNotifications:
            return await network?.handle(effect, state: state) ?? []
        }
    }
}
