import Foundation

// AVAudioRecorder can leave PCM bytes behind with an unfinished WAV header when
// iOS terminates the process. Repair only our fixed mono PCM format, never infer
// a format or alter an already valid recording.
func recoverInterruptedRecording(_ bytes: Data) -> Data? {
    guard bytes.count >= 44, bytes.count <= 60_000_000 else { return nil }
    func tag(_ offset: Int) -> String { String(data: bytes[offset..<offset+4], encoding: .ascii) ?? "" }
    func u16(_ offset: Int) -> Int { Int(bytes[offset]) | Int(bytes[offset+1]) << 8 }
    func u32(_ offset: Int) -> Int { u16(offset) | u16(offset+2) << 16 }
    guard tag(0) == "RIFF", tag(8) == "WAVE" else { return nil }
    var offset = 12, pcm = false
    while offset + 8 <= min(bytes.count, 65_536) {
        let kind = tag(offset), length = u32(offset+4), start = offset+8
        if kind == "fmt " {
            guard length >= 16, start+length <= bytes.count else { return nil }
            pcm = u16(start) == 1 && u16(start+2) == 1 && u32(start+4) == 16_000 && u16(start+12) == 2 && u16(start+14) == 16
        }
        if kind == "data" {
            let available = bytes.count-start
            guard pcm, available > 0, available % 2 == 0,
                  length == 0 || length > available else { return nil }
            var result = bytes
            func write(_ value: Int, at: Int) { for n in 0..<4 { result[at+n] = UInt8((value >> (8*n)) & 255) } }
            write(bytes.count-8, at:4); write(available, at:offset+4)
            return result
        }
        guard length <= bytes.count-start else { return nil }
        offset = start+length+(length % 2)
    }
    return nil
}
