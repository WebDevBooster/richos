import Foundation

/// Inspect only a bounded WAV header. Recover a journaled PCM capture without trusting an
/// unfinished RIFF/data length or interpreting arbitrary files as recordings.
public enum WaveRecovery {
    public struct Plan: Sendable, Equatable {
        public let sizeOffset: Int
        public let dataOffset: Int
        public let byteCount: Int
        public var durationMs: Int { byteCount / 2 * 1_000 / 16_000 }
    }

    public static func inspect(header: Data, fileBytes: Int) throws -> Plan? {
        guard fileBytes <= 57_600_000 + 65_536 else { throw CoreError("The saved recording exceeds the capture limit") }
        let bytes = [UInt8](header.prefix(65_536))
        func word(_ offset: Int) -> Int {
            Int(bytes[offset]) | Int(bytes[offset + 1]) << 8 | Int(bytes[offset + 2]) << 16 | Int(bytes[offset + 3]) << 24
        }
        func tag(_ offset: Int) -> String { String(bytes: bytes[offset..<(offset + 4)], encoding: .ascii) ?? "" }
        guard bytes.count >= 12, tag(0) == "RIFF", tag(8) == "WAVE" else { throw CoreError("The saved recording header is incomplete") }
        var offset = 12
        var pcm = false
        while offset + 8 <= bytes.count {
            let size = word(offset + 4)
            let data = offset + 8
            if tag(offset) == "fmt " {
                guard size >= 16, data + 16 <= bytes.count else { throw CoreError("The saved recording format is incomplete") }
                pcm = bytes[data] == 1 && bytes[data + 1] == 0 && bytes[data + 2] == 1 && bytes[data + 3] == 0 &&
                    word(data + 4) == 16_000 && word(data + 8) == 32_000 &&
                    bytes[data + 12] == 2 && bytes[data + 13] == 0 && bytes[data + 14] == 16 && bytes[data + 15] == 0
            }
            if tag(offset) == "data" {
                guard pcm, fileBytes >= data else { throw CoreError("The saved recording format is not recognized") }
                let available = fileBytes - data
                let count = (size > 0 && size <= available ? size : available) / 2 * 2
                return count == 0 ? nil : Plan(sizeOffset: offset + 4, dataOffset: data, byteCount: count)
            }
            guard size <= 65_536 else { break }
            offset = data + size + size % 2
        }
        throw CoreError("The saved recording data header is missing")
    }
}
