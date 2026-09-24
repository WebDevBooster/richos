import AVFoundation
import RichOSCore
import XCTest

/// The iPhone's effect handler, the notification platform and the recorder's file side, on a
/// simulator. The suite grants the microphone to the host app first
/// (`simctl privacy <device> grant microphone dev.richos.connect`), as I2's UI tests do.
///
/// Deliberately NOT exercised here: starting a recording (a simulator records from the Mac's own
/// microphone) and playing audio aloud (the Mac's speakers; ceo-decisions §53). Those are proven by
/// I2's UI tests on the voice gesture and on a phone.
@MainActor
final class PlatformEffectsTests: XCTestCase {
    func testTheMicrophoneQuestionIsAnsweredWithTheOSState() async {
        let effects = PlatformEffects()
        let answer = await effects.handle(.requestMicrophone, state: AppState())
        XCTAssertEqual(answer, [.microphonePermission(MicrophonePermission.current())])
        XCTAssertNotEqual(MicrophonePermission.current(), .unknown, "the suite granted the microphone before the run")
    }

    func testThePermissionMirrorIsTheOSState() {
        XCTAssertEqual(PlatformEffects.permissionMirror(), [.microphonePermission(MicrophonePermission.current())])
    }

    func testNetworkEffectsGoToTheCoresHandlerUnchanged() async {
        let network = RecordingHandler(answer: [.deliveryAccepted(clientID: "c1", at: 1)])
        let effects = PlatformEffects(network: network)
        let answer = await effects.handle(.deliver(clientID: "c1"), state: AppState())
        XCTAssertEqual(answer, [.deliveryAccepted(clientID: "c1", at: 1)])
        XCTAssertEqual(network.seen, [.deliver(clientID: "c1")])
    }

    func testWithNoNetworkHandlerNetworkEffectsAnswerNothing() async {
        let answer = await PlatformEffects().handle(.loadOlder(before: nil), state: AppState())
        XCTAssertEqual(answer, [])
    }

    func testNothingIsOpenedForAStoreOrSupportPageThatDoesNotExistYet() async {
        let effects = PlatformEffects()
        let store = await effects.handle(.openAppStore, state: AppState())
        let support = await effects.handle(.openSupport, state: AppState())
        XCTAssertEqual(store + support, [])
    }

    func testTheLockHapticIsHandled() async {
        let answer = await PlatformEffects().handle(.hapticTick, state: AppState())
        XCTAssertEqual(answer, [])
    }

    func testTheLevelGoesToTheStore() {
        let effects = PlatformEffects()
        var sent: [Action] = []
        effects.dispatch = { sent.append($0) }
        effects.recorder.onLevel?(0.4)
        XCTAssertEqual(sent, [.voiceLevel(0.4)])
    }

    func testPlayingAMissingRecordingEndsPlaybackWithoutSound() async {
        let effects = PlatformEffects()
        var sent: [Action] = []
        effects.dispatch = { sent.append($0) }
        _ = await effects.handle(.playRecording(id: "no-such-recording"), state: AppState())
        XCTAssertEqual(sent, [.playbackEnded])
    }

    func testRecordingFilesAreOneSafeComponentAndTheCourierReadsThem() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("recordings-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let recorder = VoiceRecorder(directory: directory)
        XCTAssertEqual(recorder.url(for: "../../etc/passwd").lastPathComponent, "etcpasswd.wav")
        XCTAssertEqual(recorder.url(for: "a1b2-c3").lastPathComponent, "a1b2-c3.wav")
        try Data("RIFF".utf8).write(to: recorder.url(for: "voice-1"))
        let bytes = try await FileRecordingStore(directory: directory).wavBytes(id: "voice-1")
        XCTAssertEqual(bytes, Data("RIFF".utf8))
        recorder.delete(id: "voice-1")
        XCTAssertFalse(FileManager.default.fileExists(atPath: recorder.url(for: "voice-1").path))
    }

    func testTheRecordingFormatIsTheMacs() {
        XCTAssertEqual(VoiceRecorder.settings[AVFormatIDKey] as? AudioFormatID, kAudioFormatLinearPCM)
        XCTAssertEqual(VoiceRecorder.settings[AVSampleRateKey] as? Int, 16_000)
        XCTAssertEqual(VoiceRecorder.settings[AVNumberOfChannelsKey] as? Int, 1)
        XCTAssertEqual(VoiceRecorder.settings[AVLinearPCMBitDepthKey] as? Int, 16)
    }

    // MARK: notifications

    func testTheDeviceTokenBecomesLowercaseHexOnce() {
        let platform = NotificationPlatform()
        var tokens: [String] = []
        platform.onToken = { tokens.append($0) }
        platform.registered(deviceToken: Data([0xAB, 0x01]))
        platform.registered(deviceToken: Data([0xAB, 0x01]))
        XCTAssertEqual(tokens, ["ab01"], "an unchanged token does not re-register")
    }

    func testAColdLaunchTapIsDeliveredOnceTheStoreListens() throws {
        let platform = NotificationPlatform()
        let target = try XCTUnwrap(NotificationTarget(userInfo: ["richos": ["host": String(repeating: "a", count: 32),
                                                                             "thread": String(repeating: "b", count: 64),
                                                                             "event": String(repeating: "c", count: 64)]]))
        NotificationRouteMailbox.shared.put(target)
        var opened: [NotificationTarget] = []
        platform.onOpen = { opened.append($0) }
        platform.deliverPending()
        platform.deliverPending()
        XCTAssertEqual(opened, [target])
    }

    func testThePreviewKeyAndChoiceReachTheExtensionsKeychainItem() throws {
        let store = PreviewKeyStore.shared
        try store.erase()
        defer { try? store.erase() }
        let first = try NotificationPlatform.shared.configurePreviews(origin: "https://c-x.richos.ceo", previews: true)
        XCTAssertEqual(first.key?.count, 32)
        XCTAssertEqual(try store.load(), first)
        let off = try NotificationPlatform.shared.configurePreviews(origin: "https://c-x.richos.ceo", previews: false)
        XCTAssertEqual(off.key, first.key, "the same Mac keeps its key")
        XCTAssertFalse(try store.load().previews, "the extension reads the choice")
        let other = try NotificationPlatform.shared.configurePreviews(origin: "https://c-y.richos.ceo", previews: false)
        XCTAssertNotEqual(other.key, first.key, "a different Mac gets a new key")
    }

    /// Security review I-1: "Forget this phone" takes the preview key with the pairing, on the phone,
    /// whether or not the Mac ever hears the unregistration (it is sent best effort, and only when a
    /// connection exists). Here the Mac hears nothing: the network handler answers nothing at all.
    func testForgetErasesThePreviewKeyEvenWhenTheMacNeverHearsIt() async throws {
        let store = PreviewKeyStore.shared
        try store.erase()
        defer { try? store.erase() }
        let origin = "https://c-x.richos.ceo"
        XCTAssertEqual(try store.configure(origin: origin).key?.count, 32)
        var state = AppState()
        state.pairing = .paired
        state.mac = MacLink(origin: origin, route: .connect, deviceID: "dev_1", threadID: "thr_5c1e", name: "Alex’s Mac")
        state.notifications.status = .on
        state.sheet = .forget
        let (forgotten, effects) = Reducer.reduce(state, .confirmForget)
        XCTAssertTrue(effects.contains(.forgetIdentity(origin: origin)), "the core asks for the identity to go")
        let network = RecordingHandler(answer: [])
        let platform = PlatformEffects(network: network)
        for effect in effects { _ = await platform.handle(effect, state: forgotten) }
        XCTAssertTrue(network.seen.contains(.forgetIdentity(origin: origin)), "the signing key is still the core's to remove")
        XCTAssertNil(try store.load().key, "no sealed preview opens on a phone that forgot its Mac")
    }
}

final class RecordingHandler: EffectHandler, @unchecked Sendable {
    private let lock = NSLock()
    private var effects: [Effect] = []
    let answer: [Action]
    init(answer: [Action]) { self.answer = answer }
    var seen: [Effect] { lock.lock(); defer { lock.unlock() }; return effects }
    func handle(_ effect: Effect, state: AppState) async -> [Action] {
        record(effect)
        return answer
    }
    private func record(_ effect: Effect) {
        lock.lock(); defer { lock.unlock() }
        effects.append(effect)
    }
}
