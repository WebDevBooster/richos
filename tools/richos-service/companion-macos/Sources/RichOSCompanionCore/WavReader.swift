import Foundation

/// A minimal 16-bit PCM WAV reader — just enough to drive the headless `ingest` proof path, where a
/// pre-made sample is pushed through the SAME SessionWriter/ChannelMixer/WavWriter code the live
/// capture uses. This proves the contract + P1 handoff end-to-end WITHOUT the TCC permission grant.
public enum WavReader {
    public struct PCM {
        public let sampleRate: Int
        public let channels: Int
        /// Deinterleaved mono float channels: `channels[0]` = LEFT, `channels[1]` = RIGHT, ...
        public let channelsData: [[Float]]
    }

    public static func read(path: String) throws -> PCM {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        func u32(_ o: Int) -> Int { Int(data[o]) | Int(data[o+1])<<8 | Int(data[o+2])<<16 | Int(data[o+3])<<24 }
        func u16(_ o: Int) -> Int { Int(data[o]) | Int(data[o+1])<<8 }
        guard data.count > 44,
              String(decoding: data[0..<4], as: UTF8.self) == "RIFF",
              String(decoding: data[8..<12], as: UTF8.self) == "WAVE" else {
            throw NSError(domain: "WavReader", code: 1, userInfo: [NSLocalizedDescriptionKey: "not a RIFF/WAVE file"])
        }
        // Walk chunks to locate fmt + data (WAVs are not always header-at-44).
        var o = 12
        var sampleRate = 0, channels = 0, bits = 0
        var dataOffset = -1, dataLen = 0
        while o + 8 <= data.count {
            let id = String(decoding: data[o..<o+4], as: UTF8.self)
            let sz = u32(o + 4)
            let body = o + 8
            if id == "fmt " {
                channels = u16(body + 2)
                sampleRate = u32(body + 4)
                bits = u16(body + 14)
            } else if id == "data" {
                dataOffset = body
                dataLen = min(sz, data.count - body)
            }
            o = body + sz + (sz % 2) // chunks are word-aligned
        }
        guard bits == 16, dataOffset >= 0, channels > 0 else {
            throw NSError(domain: "WavReader", code: 2, userInfo: [NSLocalizedDescriptionKey: "only 16-bit PCM WAV supported"])
        }
        let frames = dataLen / (channels * 2)
        var out = [[Float]](repeating: [Float](repeating: 0, count: frames), count: channels)
        for f in 0..<frames {
            for c in 0..<channels {
                let idx = dataOffset + (f * channels + c) * 2
                let s = Int16(bitPattern: UInt16(data[idx]) | (UInt16(data[idx+1]) << 8))
                out[c][f] = Float(s) / 32767.0
            }
        }
        return PCM(sampleRate: sampleRate, channels: channels, channelsData: out)
    }
}
