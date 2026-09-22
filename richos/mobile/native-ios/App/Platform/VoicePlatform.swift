import AVFoundation
import RichOSCore
import UIKit

/// The microphone as the core needs it: the OS permission (a mirror, never a stored copy — PRD §3),
/// the recorder behind `.startRecording` / `.stopRecording`, playback of your own recordings, and the
/// files the courier uploads (`RecordingStore`).
///
/// The recording format is the one the Mac accepts and the preserved app records
/// (`richos/mobile/ios/Sources/NativeServices.swift`, read, not modified): WAV, linear PCM, 16 kHz,
/// mono, 16-bit little-endian (contract §5.3). Files live in Application Support/RichOS/Recordings,
/// protected until first unlock and excluded from backup.
///
/// What is left out of the preserved app's recorder, and why: its free-space check before recording
/// (a required-reason API, disk space) — a full disk makes the recorder fail to start, which is
/// reported the same way as any other start failure, and the privacy manifest stays empty.
enum MicrophonePermission {
    /// The OS's answer now: `.unknown` until the person has been asked.
    static func current() -> Permission {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: return .granted
        case .denied: return .denied
        default: return .unknown
        }
    }

    /// The system question. Asked only on a deliberate press (the core decides when).
    static func request() async -> Permission {
        await AVAudioApplication.requestRecordPermission() ? .granted : .denied
    }
}

@MainActor
final class VoiceRecorder: NSObject, AVAudioRecorderDelegate, AVAudioPlayerDelegate {
    /// The level every 100 ms while recording (the core's `voiceLevel` cadence).
    var onLevel: ((Double) -> Void)?
    /// The OS took the audio (a call, Siri, the route went away): the core keeps the recording.
    var onInterrupted: (() -> Void)?
    /// Playback of one of your own recordings ended.
    var onPlaybackEnded: (() -> Void)?

    let directory: URL
    private var recorder: AVAudioRecorder?
    private var recordingID: String?
    private var meter: Timer?
    private var player: AVAudioPlayer?

    static let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16_000,
                                          AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16,
                                          AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false]
    /// The Mac's ceiling is 30 minutes (contract §5.3); the core stops at 30:00 itself.
    static let maxSeconds: TimeInterval = 30 * 60

    init(directory: URL = VoiceRecorder.defaultDirectory()) {
        self.directory = directory
        super.init()
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(sessionInterrupted(_:)), name: AVAudioSession.interruptionNotification, object: nil)
        center.addObserver(self, selector: #selector(routeChanged(_:)), name: AVAudioSession.routeChangeNotification, object: nil)
    }

    nonisolated static func defaultDirectory() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("RichOS/Recordings", isDirectory: true)
    }

    func url(for id: String) -> URL { directory.appendingPathComponent("\(Self.safe(id)).wav") }

    func start(id: String) throws {
        stopPlayback()
        if recorder != nil { stop(keep: true) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetooth])
        try session.setActive(true)
        let url = url(for: id)
        do {
            let recorder = try AVAudioRecorder(url: url, settings: Self.settings)
            recorder.delegate = self
            recorder.isMeteringEnabled = true
            guard recorder.prepareToRecord(), recorder.record(forDuration: Self.maxSeconds) else {
                throw CocoaError(.fileWriteUnknown)
            }
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)
            var file = url
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try file.setResourceValues(values)
            self.recorder = recorder
            recordingID = id
            UIApplication.shared.isIdleTimerDisabled = true
            meter = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.sample() }
            }
        } catch {
            try? FileManager.default.removeItem(at: url)
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            throw error
        }
    }

    /// Stops capturing; `keep` retains the file (sent or kept), otherwise it is removed.
    func stop(keep: Bool) {
        meter?.invalidate()
        meter = nil
        guard let recorder else { return }
        let url = recorder.url
        self.recorder = nil
        recordingID = nil
        recorder.stop()
        UIApplication.shared.isIdleTimerDisabled = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        if !keep { try? FileManager.default.removeItem(at: url) }
    }

    func delete(id: String) {
        if recordingID == id { stop(keep: false) }
        try? FileManager.default.removeItem(at: url(for: id))
    }

    func play(id: String) {
        stopPlayback()
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback)
            try AVAudioSession.sharedInstance().setActive(true)
            let player = try AVAudioPlayer(contentsOf: url(for: id))
            player.delegate = self
            guard player.play() else { throw CocoaError(.fileReadUnknown) }
            self.player = player
        } catch {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            onPlaybackEnded?()
        }
    }

    func stopPlayback() {
        guard let player else { return }
        player.stop()
        self.player = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func sample() {
        guard let recorder else { return }
        recorder.updateMeters()
        onLevel?(VoiceLevel.level(averagePowerDB: recorder.averagePower(forChannel: 0)))
    }

    // The session's notifications arrive on whatever thread posted them: read what matters there,
    // then act on the main actor.
    @objc nonisolated private func sessionInterrupted(_ note: Notification) {
        guard note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt == AVAudioSession.InterruptionType.began.rawValue else { return }
        Task { @MainActor in if self.recorder != nil { self.onInterrupted?() } }
    }

    @objc nonisolated private func routeChanged(_ note: Notification) {
        guard note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue else { return }
        Task { @MainActor in if self.recorder != nil { self.onInterrupted?() } }
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            self.player = nil
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            self.onPlaybackEnded?()
        }
    }

    /// The recorder stopped on its own (the 30-minute ceiling or an encoding error): the core is
    /// told it was interrupted, which keeps the recording rather than losing it.
    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        Task { @MainActor in if self.recorder === recorder { self.onInterrupted?() } }
    }

    nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        Task { @MainActor in if self.recorder === recorder { self.onInterrupted?() } }
    }

    /// A recording id becomes a file name only if it is one path component of safe characters.
    nonisolated static func safe(_ id: String) -> String {
        let cleaned = String(id.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_" }.map(Character.init))
        return cleaned.isEmpty ? "recording" : cleaned
    }
}

/// The WAV bytes the courier uploads for a voice message (Core's `RecordingStore`).
struct FileRecordingStore: RecordingStore {
    let directory: URL
    func wavBytes(id: String) async throws -> Data {
        try Data(contentsOf: directory.appendingPathComponent("\(VoiceRecorder.safe(id)).wav"))
    }
}
