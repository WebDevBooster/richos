import Foundation
import RichOSCompanionCore
#if canImport(CoreAudio)
import CoreAudio
import AVFoundation
import AudioToolbox

/// The irreducibly-native macOS capture engine (architecture §5.2): a **Core Audio process tap** on all
/// system output (Granola parity, §10-Q2 "all-output first"), plus the **default mic**, mixed into
/// the frozen 2-channel contract (LEFT=mic, RIGHT=system).
///
/// - System audio: `CATapDescription(stereoGlobalTapButExcludeProcesses:)` -> `AudioHardwareCreateProcessTap`
///   added to a private **aggregate device**, read via `AudioDeviceCreateIOProcIDWithBlock`. Audio
///   keeps playing to the user (the tap reads a COPY of the render stream, pre-output-device — so it
///   works on headphones exactly as on speakers). Uses the narrow **"System Audio Recording"** TCC
///   permission, not Screen Recording.
/// - Microphone: `AVAudioEngine.inputNode`, resampled to the tap's sample rate so the two async
///   sources stay frame-aligned in `SessionWriter`.
///
/// PERMISSION GATE (honest): the first `AudioDeviceStart` on an aggregate containing a tap triggers
/// the macOS "System Audio Recording" prompt — a HUMAN GUI grant with no non-interactive path and no
/// API to query current status (architecture §5.2). Until granted, the tap delivers no frames; the watchdog
/// treats sudden all-silence on the system side as a possible revocation and alarms (§6.4).
@available(macOS 14.4, *)
final class CoreAudioCapture {
    private let writer: SessionWriter
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private let ioQueue = DispatchQueue(label: "com.richos.companion.tap-io")
    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private var tapSampleRate: Double = 48_000
    private(set) var tapRunning = false
    private(set) var micRunning = false

    // Cheap level metering accumulated in the audio callbacks; snapshot+reset once per health tick.
    private let levelLock = NSLock()
    private var micPeak = 0.0, micSumSq = 0.0, micN = 0
    private var sysPeak = 0.0, sysSumSq = 0.0, sysN = 0

    init(writer: SessionWriter) { self.writer = writer }

    /// (micPeak, micRms, sysPeak, sysRms) since the last snapshot; resets accumulators.
    func snapshotLevels() -> (Double, Double, Double, Double) {
        levelLock.lock(); defer { levelLock.unlock() }
        let mRms = micN > 0 ? (micSumSq / Double(micN)).squareRoot() : 0
        let sRms = sysN > 0 ? (sysSumSq / Double(sysN)).squareRoot() : 0
        let out = (micPeak, mRms, sysPeak, sRms)
        micPeak = 0; micSumSq = 0; micN = 0; sysPeak = 0; sysSumSq = 0; sysN = 0
        return out
    }

    private func meter(_ block: [Float], mic: Bool) {
        var peak = 0.0, sumSq = 0.0
        for x in block { let a = Double(abs(x)); if a > peak { peak = a }; sumSq += Double(x) * Double(x) }
        levelLock.lock()
        if mic { if peak > micPeak { micPeak = peak }; micSumSq += sumSq; micN += block.count }
        else { if peak > sysPeak { sysPeak = peak }; sysSumSq += sumSq; sysN += block.count }
        levelLock.unlock()
    }

    /// Bring up the tap + aggregate + mic. Throws with an actionable message on Core Audio failure.
    func start() throws {
        try startSystemTap()
        try startMic()
    }

    // MARK: - System tap

    private func startSystemTap() throws {
        // Capture ALL system output (empty exclude list) — one code path, Granola parity.
        let desc = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        desc.name = "RichOS System Capture"
        desc.isPrivate = true
        desc.muteBehavior = .unmuted // keep audio audible to the user while we tap a copy

        var status = AudioHardwareCreateProcessTap(desc, &tapID)
        guard status == noErr, tapID != kAudioObjectUnknown else {
            throw err("AudioHardwareCreateProcessTap failed", status)
        }

        // The tap's output stream format (so we downmix/interleave correctly).
        if let asbd = tapFormat() { tapSampleRate = asbd.mSampleRate > 0 ? asbd.mSampleRate : 48_000 }

        // A private aggregate device holding just the tap. Audio still flows to the real output.
        let aggUID = "com.richos.companion.aggregate.\(UUID().uuidString)"
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey as String: "RichOS Capture",
            kAudioAggregateDeviceUIDKey as String: aggUID,
            kAudioAggregateDeviceIsPrivateKey as String: true,
            kAudioAggregateDeviceIsStackedKey as String: false,
            kAudioAggregateDeviceTapAutoStartKey as String: true,
            kAudioAggregateDeviceTapListKey as String: [
                [kAudioSubTapUIDKey as String: desc.uuid.uuidString]
            ],
        ]
        status = AudioHardwareCreateAggregateDevice(description as CFDictionary, &aggregateID)
        guard status == noErr, aggregateID != kAudioObjectUnknown else {
            throw err("AudioHardwareCreateAggregateDevice failed", status)
        }

        let channels = Int(tapFormat()?.mChannelsPerFrame ?? 2)
        status = AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, ioQueue) {
            [weak self] (_, inInputData, _, _, _) in
            self?.handleTapInput(inInputData, channels: channels)
        }
        guard status == noErr, ioProcID != nil else {
            throw err("AudioDeviceCreateIOProcIDWithBlock failed", status)
        }

        // This is the call that triggers the "System Audio Recording" TCC prompt on first run.
        status = AudioDeviceStart(aggregateID, ioProcID)
        guard status == noErr else { throw err("AudioDeviceStart failed", status) }
        tapRunning = true
    }

    private func handleTapInput(_ list: UnsafePointer<AudioBufferList>, channels: Int) {
        let abl = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: list))
        guard let first = abl.first, let raw = first.mData else { return }
        let ch = max(1, Int(first.mNumberChannels))
        let frameCount = Int(first.mDataByteSize) / (MemoryLayout<Float>.size * ch)
        guard frameCount > 0 else { return }
        let ptr = raw.assumingMemoryBound(to: Float.self)
        let interleaved = Array(UnsafeBufferPointer(start: ptr, count: frameCount * ch))
        let mono = ChannelMixer.downmixToMono(interleaved: interleaved, channelCount: ch)
        meter(mono, mic: false)
        writer.pushSystem(mono)
    }

    private func tapFormat() -> AudioStreamBasicDescription? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let status = AudioObjectGetPropertyData(tapID, &addr, 0, nil, &size, &asbd)
        return status == noErr ? asbd : nil
    }

    // MARK: - Microphone (resampled to the tap rate so both sources stay frame-aligned)

    private func startMic() throws {
        let input = engine.inputNode
        let inFormat = input.outputFormat(forBus: 0)
        guard let outFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: tapSampleRate, channels: 1, interleaved: false
        ) else { throw err("could not build mic output format", -1) }
        converter = AVAudioConverter(from: inFormat, to: outFormat)

        input.installTap(onBus: 0, bufferSize: 4096, format: inFormat) { [weak self] buffer, _ in
            guard let self = self, let converter = self.converter else { return }
            let ratio = outFormat.sampleRate / inFormat.sampleRate
            let cap = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 16)
            guard let out = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: cap) else { return }
            var fed = false
            var e: NSError?
            converter.convert(to: out, error: &e) { _, status in
                if fed { status.pointee = .noDataNow; return nil }
                fed = true; status.pointee = .haveData; return buffer
            }
            if let ch = out.floatChannelData, out.frameLength > 0 {
                let mono = Array(UnsafeBufferPointer(start: ch[0], count: Int(out.frameLength)))
                self.meter(mono, mic: true)
                self.writer.pushMic(mono)
            }
        }
        engine.prepare()
        try engine.start()
        micRunning = true
    }

    func stop() {
        if let ioProcID = ioProcID, aggregateID != kAudioObjectUnknown {
            AudioDeviceStop(aggregateID, ioProcID)
            AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
        }
        if aggregateID != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(aggregateID) }
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        engine.inputNode.removeTap(onBus: 0)
        if engine.isRunning { engine.stop() }
        tapRunning = false
        micRunning = false
    }

    var sampleRate: Int { Int(tapSampleRate) }

    private func err(_ msg: String, _ status: OSStatus) -> NSError {
        NSError(domain: "CoreAudioCapture", code: Int(status),
                userInfo: [NSLocalizedDescriptionKey: "\(msg) (OSStatus \(status))"])
    }
}
#endif
