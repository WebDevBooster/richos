using RichOSCompanionCore;
using Xunit;

namespace RichOSCompanionCore.Tests
{
    /// <summary>
    /// The mic-vs-loopback failover (§6.4): a stalled source must never freeze the whole recording —
    /// write the live side, silence-fill the dead side, alarm. Peer of the macOS companion's
    /// <c>MixDecisionTests.swift</c>.
    /// </summary>
    public class MixDecisionTests
    {
        [Fact]
        public void BothLiveTakesCommonMinimum()
        {
            var d = MixDecision.Decide(micAvail: 100, systemAvail: 60, micSilentMs: 0, systemSilentMs: 0, starveThresholdMs: 15000);
            Assert.Equal(60, d.Frames);
            Assert.True(d.UseMic);
            Assert.True(d.UseSystem);
            Assert.False(d.MicStarved);
            Assert.False(d.SystemStarved);
        }

        [Fact]
        public void MicStarvedWritesSystemAndSilenceFillsLeft()
        {
            var d = MixDecision.Decide(micAvail: 0, systemAvail: 480, micSilentMs: 20000, systemSilentMs: 0, starveThresholdMs: 15000);
            Assert.Equal(480, d.Frames);
            Assert.False(d.UseMic);
            Assert.True(d.UseSystem);
            Assert.True(d.MicStarved);
            Assert.False(d.SystemStarved);
        }

        [Fact]
        public void SystemStarvedWritesMicAndSilenceFillsRight()
        {
            var d = MixDecision.Decide(micAvail: 480, systemAvail: 0, micSilentMs: 0, systemSilentMs: 20000, starveThresholdMs: 15000);
            Assert.Equal(480, d.Frames);
            Assert.True(d.UseMic);
            Assert.False(d.UseSystem);
            Assert.False(d.MicStarved);
            Assert.True(d.SystemStarved);
        }

        [Fact]
        public void BothStarvedWritesNothingButBothAlarm()
        {
            var d = MixDecision.Decide(micAvail: 0, systemAvail: 0, micSilentMs: 20000, systemSilentMs: 20000, starveThresholdMs: 15000);
            Assert.Equal(0, d.Frames);
            Assert.True(d.MicStarved);
            Assert.True(d.SystemStarved);
        }
    }
}
