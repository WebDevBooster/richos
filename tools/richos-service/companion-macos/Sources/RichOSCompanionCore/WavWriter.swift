import Foundation

/// An appendable 2-channel 16-bit PCM WAV writer with crash-recoverable framing.
///
/// Why WAV single-part (architecture §3.1 explicitly sanctions "Opus-in-Ogg OR 16 kHz WAV"): the frozen
/// pipeline's multi-part concat (`normalize.js`) copies parts into a `.webm` container with
/// `-c copy`, which PCM cannot enter (`Only ... Opus audio ... supported for WebM`) — so multiple
/// WAV parts would break the pipeline, while a SINGLE self-contained WAV is used directly
/// (`parts.length === 1` path). Native Core Audio has no Opus encoder, so WAV is the correct
/// zero-dependency choice. Recoverability (§6.5 "continuous write + periodic fsync, worst case one
/// chunk") is met by rewriting the RIFF/data size headers on every flush + fsync: a crash loses at
/// most the samples since the last flush, and the on-disk header always describes a valid, decodable
/// prefix.
public final class WavWriter {
    private let handle: FileHandle
    public let path: String
    public let sampleRate: Int
    public let channels: Int
    public let bitsPerSample: Int
    private(set) public var dataBytes: Int = 0

    private static let headerSize = 44

    public init(path: String, sampleRate: Int, channels: Int = 2, bitsPerSample: Int = 16) throws {
        self.path = path
        self.sampleRate = sampleRate
        self.channels = channels
        self.bitsPerSample = bitsPerSample
        FileManager.default.createFile(atPath: path, contents: nil)
        guard let h = FileHandle(forWritingAtPath: path) else {
            throw NSError(domain: "WavWriter", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "cannot open \(path) for writing"])
        }
        self.handle = h
        try h.write(contentsOf: WavWriter.header(dataBytes: 0, sampleRate: sampleRate,
                                                 channels: channels, bitsPerSample: bitsPerSample))
    }

    /// Append interleaved Int16 PCM sample bytes (little-endian).
    public func append(_ bytes: [UInt8]) throws {
        try handle.write(contentsOf: Data(bytes))
        dataBytes += bytes.count
    }

    /// Rewrite the two size fields to describe everything written so far, then fsync. Called on the
    /// flush cadence so the on-disk file is always a valid WAV describing a decodable prefix.
    public func flush() throws {
        try handle.seek(toOffset: 4)
        try handle.write(contentsOf: WavWriter.u32le(WavWriter.headerSize - 8 + dataBytes))
        try handle.seek(toOffset: 40)
        try handle.write(contentsOf: WavWriter.u32le(dataBytes))
        try handle.seekToEnd()
        // Durable to disk — the ≤ one-flush-window crash guarantee (§6.5).
        fsync(handle.fileDescriptor)
    }

    public func close() throws {
        try flush()
        try handle.close()
    }

    public var totalBytesOnDisk: Int { WavWriter.headerSize + dataBytes }

    // MARK: - Header

    static func header(dataBytes: Int, sampleRate: Int, channels: Int, bitsPerSample: Int) -> Data {
        let byteRate = sampleRate * channels * (bitsPerSample / 8)
        let blockAlign = channels * (bitsPerSample / 8)
        var d = Data()
        d.append(contentsOf: Array("RIFF".utf8))
        d.append(u32le(headerSize - 8 + dataBytes)) // file size - 8
        d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8))
        d.append(u32le(16))            // PCM fmt chunk size
        d.append(u16le(1))             // audio format = PCM
        d.append(u16le(channels))
        d.append(u32le(sampleRate))
        d.append(u32le(byteRate))
        d.append(u16le(blockAlign))
        d.append(u16le(bitsPerSample))
        d.append(contentsOf: Array("data".utf8))
        d.append(u32le(dataBytes))
        return d
    }

    static func u32le(_ v: Int) -> Data {
        let u = UInt32(truncatingIfNeeded: v)
        return Data([UInt8(u & 0xff), UInt8((u >> 8) & 0xff), UInt8((u >> 16) & 0xff), UInt8((u >> 24) & 0xff)])
    }
    static func u16le(_ v: Int) -> Data {
        let u = UInt16(truncatingIfNeeded: v)
        return Data([UInt8(u & 0xff), UInt8((u >> 8) & 0xff)])
    }
}
