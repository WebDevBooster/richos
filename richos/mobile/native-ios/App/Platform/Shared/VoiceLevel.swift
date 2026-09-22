import Foundation

// Compiled into the app and the macOS platform tests. Foundation only.

/// The level the bubble's waveform and the recording halo read, 0…1, from the recorder's average
/// power in dBFS: silence (−50 dB and below) is 0, full scale is 1, linear in dB between — the
/// scale a voice actually moves across. Pure, so the platform tests pin it.
enum VoiceLevel {
    static let floorDB: Float = -50
    static func level(averagePowerDB db: Float) -> Double {
        guard db.isFinite else { return 0 }
        return Double(min(1, max(0, (db - floorDB) / -floorDB)))
    }
}
