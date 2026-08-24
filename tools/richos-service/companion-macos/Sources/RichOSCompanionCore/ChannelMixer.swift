import Foundation

/// The frozen audio invariant (P1 README / architecture §3.1), made mechanical and testable:
///
///   **Exactly two channels, LEFT = me (microphone), RIGHT = others (system tap). Never a pre-mix.**
///
/// This gives free "me vs them" separation with no diarization model and lets the pipeline
/// transcribe each channel independently. `ChannelMixer` is the ONE place that assignment is
/// encoded, so it is unit-tested to death — a swapped L/R here would silently mis-attribute every
/// speaker in every transcript.
public enum ChannelMixer {

    /// Clamp a Float sample in [-1, 1] to signed 16-bit PCM (round half away from zero).
    public static func floatToInt16(_ x: Float) -> Int16 {
        let clamped = max(-1.0, min(1.0, x))
        // 32767 (not 32768) so +1.0 maps to Int16.max without overflow.
        let scaled = (clamped * 32767.0).rounded()
        return Int16(scaled)
    }

    /// Downmix an interleaved multi-channel Float frame block to mono by averaging channels.
    /// Core Audio taps/mics often deliver stereo or N-channel; the contract's per-side channel is
    /// mono, so we average (not just take ch0) to avoid dropping a hard-panned talker.
    public static func downmixToMono(interleaved: [Float], channelCount: Int) -> [Float] {
        guard channelCount > 1 else { return interleaved }
        let frames = interleaved.count / channelCount
        var out = [Float](repeating: 0, count: frames)
        for f in 0..<frames {
            var sum: Float = 0
            for c in 0..<channelCount { sum += interleaved[f * channelCount + c] }
            out[f] = sum / Float(channelCount)
        }
        return out
    }

    /// Interleave two equal-length mono Float streams into 2-channel Int16 PCM: LEFT=mic, RIGHT=sys.
    /// The two inputs MUST be frame-aligned (same sample rate, same count) — the caller (SessionWriter)
    /// guarantees this by pulling `min(available)` from both ring buffers each pump.
    public static func interleaveToInt16(mic: [Float], system: [Float]) -> [Int16] {
        precondition(mic.count == system.count, "mic/system must be frame-aligned")
        var out = [Int16]()
        out.reserveCapacity(mic.count * 2)
        for i in 0..<mic.count {
            out.append(floatToInt16(mic[i]))       // LEFT  = me
            out.append(floatToInt16(system[i]))    // RIGHT = others
        }
        return out
    }

    /// Little-endian byte serialization of interleaved Int16 PCM (WAV sample data).
    public static func int16LEBytes(_ samples: [Int16]) -> [UInt8] {
        var bytes = [UInt8]()
        bytes.reserveCapacity(samples.count * 2)
        for s in samples {
            let u = UInt16(bitPattern: s)
            bytes.append(UInt8(u & 0xff))
            bytes.append(UInt8((u >> 8) & 0xff))
        }
        return bytes
    }

    /// Peak absolute amplitude of a Float block, for the health per-channel level.
    public static func peak(_ block: [Float]) -> Double {
        var m: Float = 0
        for x in block { let a = abs(x); if a > m { m = a } }
        return Double(m)
    }

    /// RMS of a Float block, for the health per-channel mean level.
    public static func rms(_ block: [Float]) -> Double {
        guard !block.isEmpty else { return 0 }
        var sum: Double = 0
        for x in block { sum += Double(x) * Double(x) }
        return (sum / Double(block.count)).squareRoot()
    }
}
