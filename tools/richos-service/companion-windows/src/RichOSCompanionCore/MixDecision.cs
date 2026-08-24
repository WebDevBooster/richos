using System;

namespace RichOSCompanionCore
{
    /// <summary>
    /// The pure decision of how to combine the two ring buffers on one writer pump, INCLUDING the
    /// mic-vs-loopback failover from the reliability model (§6.4): if one source stalls while the
    /// other is still delivering, we do NOT freeze the whole recording — we write the live side and
    /// silence-fill the dead side, and raise an alarm. Never lose the live half of the call; never go
    /// silent. Extracted pure so the failover is deterministically unit-tested without any audio
    /// hardware — the exact peer of the macOS companion's <c>MixDecision.swift</c>.
    /// </summary>
    public readonly struct MixDecision : IEquatable<MixDecision>
    {
        /// <summary>Number of frames to emit this pump (0 = nothing ready yet).</summary>
        public readonly int Frames;
        /// <summary>Emit real mic samples (true) or silence for the mic/LEFT side (false).</summary>
        public readonly bool UseMic;
        /// <summary>Emit real system samples (true) or silence for the system/RIGHT side (false).</summary>
        public readonly bool UseSystem;
        /// <summary>A source is starved while the other is live — surfaces as a red health alarm.</summary>
        public readonly bool MicStarved;
        public readonly bool SystemStarved;

        public MixDecision(int frames, bool useMic, bool useSystem, bool micStarved, bool systemStarved)
        {
            Frames = frames;
            UseMic = useMic;
            UseSystem = useSystem;
            MicStarved = micStarved;
            SystemStarved = systemStarved;
        }

        /// <param name="micAvail">frames currently buffered for the mic source.</param>
        /// <param name="systemAvail">frames currently buffered for the loopback source.</param>
        /// <param name="micSilentMs">how long since the mic last delivered ANY samples.</param>
        /// <param name="systemSilentMs">how long since the loopback last delivered ANY samples.</param>
        /// <param name="starveThresholdMs">age past which a lagging source is declared starved.</param>
        public static MixDecision Decide(
            int micAvail, int systemAvail, long micSilentMs, long systemSilentMs, long starveThresholdMs)
        {
            bool micStarved = micSilentMs >= starveThresholdMs;
            bool sysStarved = systemSilentMs >= starveThresholdMs;

            // Normal path: both delivering — stay perfectly aligned by taking the common minimum.
            if (!micStarved && !sysStarved)
            {
                int n = Math.Min(micAvail, systemAvail);
                return new MixDecision(n, useMic: true, useSystem: true, micStarved: false, systemStarved: false);
            }

            // Failover: mic starved, system live -> write system on RIGHT, silence on LEFT, alarm.
            if (micStarved && !sysStarved)
                return new MixDecision(systemAvail, useMic: false, useSystem: true, micStarved: true, systemStarved: false);

            // Failover: system starved, mic live -> write mic on LEFT, silence on RIGHT, alarm.
            if (sysStarved && !micStarved)
                return new MixDecision(micAvail, useMic: true, useSystem: false, micStarved: false, systemStarved: true);

            // Both starved: nothing to write, but both alarms are raised (watchdog escalates, §6.3).
            return new MixDecision(0, useMic: false, useSystem: false, micStarved: true, systemStarved: true);
        }

        public bool Equals(MixDecision other)
            => Frames == other.Frames && UseMic == other.UseMic && UseSystem == other.UseSystem
               && MicStarved == other.MicStarved && SystemStarved == other.SystemStarved;

        public override bool Equals(object? obj) => obj is MixDecision d && Equals(d);

        public override int GetHashCode()
            => HashCode.Combine(Frames, UseMic, UseSystem, MicStarved, SystemStarved);
    }
}
