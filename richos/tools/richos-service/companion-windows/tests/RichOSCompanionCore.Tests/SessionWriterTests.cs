using System;
using System.IO;
using System.Text.Json;
using RichOSCompanionCore;
using Xunit;

namespace RichOSCompanionCore.Tests
{
    /// <summary>
    /// End-to-end (no audio hardware) proof that <see cref="SessionWriter"/> produces the frozen
    /// contract directory the P1 pipeline consumes: session.json at START (never-silent), a decodable
    /// 2-channel WAV with the correct L/R mapping, health.ndjson, and a populated closed record. Peer
    /// of the macOS companion's <c>SessionWriterTests.swift</c>.
    /// </summary>
    public class SessionWriterTests
    {
        private static SessionContract.Params Params(long startedAt) => new SessionContract.Params(
            sessionId: SessionContract.SessionDirName(startedAt, "system", "call"), startedAt: startedAt,
            sampleRate: 48_000, chunkMs: 3000, micEnabled: true, captureTarget: "system",
            method: SessionContract.MethodSystemLoopback, platformId: "system", platformLabel: "Desktop call",
            platformSlug: "call", companionVersion: "0.1.0-p3", processHint: null);

        [Fact]
        public void StartWritesOpenSessionJsonBeforeAnyAudio()
        {
            string zone = NewZone();
            try
            {
                long t = 1_700_000_000_000;
                // `using`: an open-but-never-closed session must still release its WAV + health handles,
                // otherwise Windows refuses the temp-dir delete (POSIX unlink-open masked this leak).
                using var w = new SessionWriter(zone, Params(t), () => t);
                w.Start();
                string sj = Path.Combine(w.Dir, "session.json");
                Assert.True(File.Exists(sj)); // never-silent: on disk from second zero
                var o = JsonDocument.Parse(File.ReadAllText(sj)).RootElement;
                Assert.Equal("open", o.GetProperty("status").GetString());
                Assert.Equal(0, o.GetProperty("audio").GetProperty("parts").GetArrayLength());
            }
            finally { Directory.Delete(zone, true); }
        }

        [Fact]
        public void FullSessionWritesContractDirWithCorrectChannels()
        {
            string zone = NewZone();
            try
            {
                long virtualNow = 1_700_000_000_000;
                var p = Params(virtualNow);
                using var w = new SessionWriter(zone, p, () => virtualNow);
                w.Start();

                // 1 second of mic=+0.5 (LEFT) and system=-0.5 (RIGHT).
                var mic = Fill(48_000, 0.5f);
                var sys = Fill(48_000, -0.5f);
                w.PushMic(mic);
                w.PushSystem(sys);
                w.Pump();
                w.WriteHealthTick(0.5, 0.5, 0.5, 0.5, tapRunning: true, micRunning: true);
                virtualNow += 1000;
                w.Close();

                // session.json closed + populated
                var o = JsonDocument.Parse(File.ReadAllText(Path.Combine(w.Dir, "session.json"))).RootElement;
                Assert.Equal("closed", o.GetProperty("status").GetString());
                Assert.True(o.GetProperty("audio").GetProperty("bytesTotal").GetInt32() > 0);

                // health.ndjson present with at least one row
                string[] health = File.ReadAllLines(Path.Combine(w.Dir, "health.ndjson"));
                Assert.True(health.Length >= 1);

                // the WAV decodes and preserves LEFT=mic(+0.5), RIGHT=system(-0.5)
                var pcm = WavReader.Read(Path.Combine(w.Dir, "audio-part-00.wav"));
                Assert.Equal(2, pcm.Channels);
                Assert.True(pcm.ChannelsData[0][0] > 0.49f && pcm.ChannelsData[0][0] < 0.51f);   // LEFT/mic
                Assert.True(pcm.ChannelsData[1][0] < -0.49f && pcm.ChannelsData[1][0] > -0.51f); // RIGHT/system
            }
            finally { Directory.Delete(zone, true); }
        }

        private static float[] Fill(int n, float v)
        {
            var a = new float[n];
            for (int i = 0; i < n; i++) a[i] = v;
            return a;
        }

        private static string NewZone()
        {
            string zone = Path.Combine(Path.GetTempPath(), "richos-zone-" + Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(zone);
            return zone;
        }
    }
}
