using RichOSCompanionCore;
using Xunit;

namespace RichOSCompanionCore.Tests
{
    /// <summary>
    /// The frozen audio invariant is load-bearing: LEFT = me (mic), RIGHT = others (system). A swapped
    /// L/R here would silently mis-attribute every speaker in every transcript — so it is tested to
    /// death, exactly like the macOS companion's <c>ChannelMixerTests.swift</c>.
    /// </summary>
    public class ChannelMixerTests
    {
        [Fact]
        public void FloatToInt16ScalesAndClamps()
        {
            Assert.Equal(0, ChannelMixer.FloatToInt16(0f));
            Assert.Equal((short)32767, ChannelMixer.FloatToInt16(1.0f));
            Assert.Equal((short)-32767, ChannelMixer.FloatToInt16(-1.0f));
            Assert.Equal((short)32767, ChannelMixer.FloatToInt16(2.0f));   // clamp high
            Assert.Equal((short)-32767, ChannelMixer.FloatToInt16(-2.0f)); // clamp low
        }

        [Fact]
        public void InterleavePutsMicOnLeftSystemOnRight()
        {
            var samples = ChannelMixer.InterleaveToInt16(new[] { 1.0f, 0f }, new[] { -1.0f, 0f });
            // frame 0: LEFT=mic(+1)->32767, RIGHT=system(-1)->-32767
            Assert.Equal((short)32767, samples[0]);
            Assert.Equal((short)-32767, samples[1]);
            Assert.Equal((short)0, samples[2]);
            Assert.Equal((short)0, samples[3]);
        }

        [Fact]
        public void Int16LeBytesAreLittleEndian()
        {
            var bytes = ChannelMixer.Int16LeBytes(new short[] { 0x0102, unchecked((short)0xFFFE) });
            Assert.Equal(new byte[] { 0x02, 0x01, 0xFE, 0xFF }, bytes);
        }

        [Fact]
        public void DownmixAveragesChannels()
        {
            // stereo interleaved: frame0 (1.0, 0.0), frame1 (0.0, 1.0) -> mono 0.5, 0.5
            var mono = ChannelMixer.DownmixToMono(new[] { 1.0f, 0.0f, 0.0f, 1.0f }, 2);
            Assert.Equal(2, mono.Length);
            Assert.Equal(0.5f, mono[0], 5);
            Assert.Equal(0.5f, mono[1], 5);
        }

        [Fact]
        public void PeakAndRms()
        {
            Assert.Equal(0.8, ChannelMixer.Peak(new[] { -0.8f, 0.2f }), 5);
            Assert.Equal(0.5, ChannelMixer.Rms(new[] { 0.5f, -0.5f }), 5);
        }
    }
}
