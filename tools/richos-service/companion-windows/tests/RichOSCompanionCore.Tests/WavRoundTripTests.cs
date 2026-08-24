using System;
using System.IO;
using RichOSCompanionCore;
using Xunit;

namespace RichOSCompanionCore.Tests
{
    /// <summary>
    /// The single self-contained 2-channel WAV is the companion's audio part (architecture §3.1). Prove the
    /// writer produces a valid, decodable RIFF/WAVE that the reader round-trips — including the L/R
    /// channel assignment surviving to disk.
    /// </summary>
    public class WavRoundTripTests
    {
        [Fact]
        public void WritesAndReadsBackTwoChannelPcm()
        {
            string path = Path.Combine(Path.GetTempPath(), "richos-wav-" + Guid.NewGuid().ToString("N") + ".wav");
            try
            {
                var w = new WavWriter(path, sampleRate: 48000, channels: 2, bitsPerSample: 16);
                // frame 0: LEFT=+1.0, RIGHT=-1.0 ; frame 1: LEFT=0, RIGHT=0
                var interleaved = ChannelMixer.InterleaveToInt16(new[] { 1.0f, 0f }, new[] { -1.0f, 0f });
                w.Append(ChannelMixer.Int16LeBytes(interleaved));
                w.Close();

                var pcm = WavReader.Read(path);
                Assert.Equal(48000, pcm.SampleRate);
                Assert.Equal(2, pcm.Channels);
                Assert.Equal(2, pcm.ChannelsData[0].Length);
                Assert.True(pcm.ChannelsData[0][0] > 0.99f);   // LEFT/mic ~ +1.0
                Assert.True(pcm.ChannelsData[1][0] < -0.99f);  // RIGHT/system ~ -1.0
            }
            finally
            {
                if (File.Exists(path)) File.Delete(path);
            }
        }

        [Fact]
        public void HeaderSizesReflectDataAfterFlush()
        {
            string path = Path.Combine(Path.GetTempPath(), "richos-wav-" + Guid.NewGuid().ToString("N") + ".wav");
            try
            {
                var w = new WavWriter(path, sampleRate: 16000, channels: 2, bitsPerSample: 16);
                w.Append(new byte[] { 0, 0, 0, 0 }); // one stereo frame
                w.Flush(); // header must now describe a decodable prefix
                Assert.Equal(44 + 4, w.TotalBytesOnDisk);
                w.Close();

                byte[] file = File.ReadAllBytes(path);
                Assert.Equal((byte)'R', file[0]);
                // data chunk size @ offset 40 == 4
                int dataLen = file[40] | (file[41] << 8) | (file[42] << 16) | (file[43] << 24);
                Assert.Equal(4, dataLen);
            }
            finally
            {
                if (File.Exists(path)) File.Delete(path);
            }
        }
    }
}
