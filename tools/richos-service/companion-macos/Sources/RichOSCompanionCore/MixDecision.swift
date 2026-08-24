import Foundation

/// The pure decision of how to combine the two ring buffers on one writer pump, INCLUDING the
/// mic-vs-tap failover from the reliability model (§6.4): if one source stalls while the other is
/// still delivering, we do NOT freeze the whole recording — we write the live side and silence-fill
/// the dead side, and raise an alarm. Never lose the live half of the call; never go silent.
///
/// Extracted pure so the failover is deterministically unit-tested without any audio hardware.
public struct MixDecision: Equatable {
    /// Number of frames to emit this pump (0 = nothing ready yet).
    public let frames: Int
    /// Emit real mic samples (true) or silence for the mic/LEFT side (false).
    public let useMic: Bool
    /// Emit real system samples (true) or silence for the system/RIGHT side (false).
    public let useSystem: Bool
    /// A source is starved while the other is live — surfaces as a red health alarm.
    public let micStarved: Bool
    public let systemStarved: Bool

    public init(frames: Int, useMic: Bool, useSystem: Bool, micStarved: Bool, systemStarved: Bool) {
        self.frames = frames
        self.useMic = useMic
        self.useSystem = useSystem
        self.micStarved = micStarved
        self.systemStarved = systemStarved
    }

    /// - Parameters:
    ///   - micAvail/systemAvail: frames currently buffered per source.
    ///   - micSilentMs/systemSilentMs: how long since each source last delivered ANY samples.
    ///   - starveThresholdMs: age past which a lagging source is declared starved (failover trips).
    public static func decide(
        micAvail: Int,
        systemAvail: Int,
        micSilentMs: Int64,
        systemSilentMs: Int64,
        starveThresholdMs: Int64
    ) -> MixDecision {
        let micStarved = micSilentMs >= starveThresholdMs
        let sysStarved = systemSilentMs >= starveThresholdMs

        // Normal path: both delivering — stay perfectly aligned by taking the common minimum.
        if !micStarved && !sysStarved {
            let n = min(micAvail, systemAvail)
            return MixDecision(frames: n, useMic: true, useSystem: true,
                               micStarved: false, systemStarved: false)
        }

        // Failover: mic starved, system live -> write system on RIGHT, silence on LEFT, alarm.
        if micStarved && !sysStarved {
            return MixDecision(frames: systemAvail, useMic: false, useSystem: true,
                               micStarved: true, systemStarved: false)
        }
        // Failover: system starved, mic live -> write mic on LEFT, silence on RIGHT, alarm.
        if sysStarved && !micStarved {
            return MixDecision(frames: micAvail, useMic: true, useSystem: false,
                               micStarved: false, systemStarved: true)
        }

        // Both starved: nothing to write, but both alarms are raised (watchdog escalates, §6.3).
        return MixDecision(frames: 0, useMic: false, useSystem: false,
                           micStarved: true, systemStarved: true)
    }
}
