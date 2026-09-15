using System.Collections.Generic;
using System.Text.Json;
using RichOSCompanionCore;
using Xunit;

namespace RichOSCompanionCore.Tests
{
    /// <summary>
    /// Pins the on-disk contract to P1's frozen schemaVersion 2, and to the Windows surface's enum
    /// values. Every field the pipeline reads (<c>contract.js</c>, <c>pipeline.js</c>,
    /// <c>reconcile.js</c>, <c>merge.js#renderMarkdown</c>) is asserted here — the peer of the macOS
    /// companion's <c>SessionContractTests.swift</c>.
    /// </summary>
    public class SessionContractTests
    {
        // 1_700_000_000_000 -> 2023-11-14T22:13:20.000Z -> stamp "2023-11-14T22-13-20Z"
        [Fact]
        public void StampMatchesExtensionStampFor()
            => Assert.Equal("2023-11-14T22-13-20Z", SessionContract.StampFor(1_700_000_000_000));

        [Fact]
        public void SessionDirNameShape()
            => Assert.Equal("2023-11-14T22-13-20Z--system--call",
                SessionContract.SessionDirName(1_700_000_000_000, "system", "call"));

        [Fact]
        public void AudioPartFilenameIsPipelineMatchable()
        {
            Assert.Equal("audio-part-00.wav", SessionContract.AudioPartFile(0));
            // Must satisfy the pipeline's part regex /^audio-part-\d+\.[a-z0-9]+$/i
            Assert.Matches(@"^audio-part-\d+\.[a-z0-9]+$", SessionContract.AudioPartFile(0));
        }

        private static SessionContract.Params Params() => new SessionContract.Params(
            sessionId: "2023-11-14T22-13-20Z--system--call", startedAt: 1_700_000_000_000,
            sampleRate: 48_000, chunkMs: 3000, micEnabled: true, captureTarget: "system",
            method: SessionContract.MethodSystemLoopback, platformId: "system",
            platformLabel: "Desktop call", platformSlug: "call", companionVersion: "0.1.0-p3",
            processHint: null);

        private static JsonElement Parse(Json json)
            => JsonDocument.Parse(json.Serialized()).RootElement;

        [Fact]
        public void OpenSessionJsonHasFrozenV2Shape()
        {
            var o = Parse(SessionContract.SessionJson(Params(), "open", null,
                new List<SessionContract.AudioPart>(), new SessionContract.HealthSummary()));

            Assert.Equal(2, o.GetProperty("schemaVersion").GetInt32());
            Assert.Equal("open", o.GetProperty("status").GetString());
            Assert.Equal(JsonValueKind.Null, o.GetProperty("endedAt").ValueKind); // explicit null, not omitted

            var capture = o.GetProperty("capture");
            Assert.Equal("desktop-companion-windows", capture.GetProperty("source").GetString());
            Assert.Equal("wasapi-loopback+mic", capture.GetProperty("method").GetString());
            Assert.Equal("system", capture.GetProperty("captureTarget").GetString());
            Assert.Equal(48_000, capture.GetProperty("sampleRate").GetInt32());
            var channels = capture.GetProperty("channels");
            Assert.Equal("microphone (me)", channels.GetProperty("left").GetString());
            Assert.Equal("system/loopback (everyone else)", channels.GetProperty("right").GetString());
            Assert.Equal("audio/wav;codecs=pcm_s16le", capture.GetProperty("container").GetString());

            var audio = o.GetProperty("audio");
            Assert.Equal(0, audio.GetProperty("parts").GetArrayLength());
            Assert.Equal(0, audio.GetProperty("bytesTotal").GetInt32());

            var ownership = o.GetProperty("ownership");
            Assert.Equal("desktop-companion-windows", ownership.GetProperty("ownerSurface").GetString());
            Assert.Equal(JsonValueKind.Null, ownership.GetProperty("supersedes").ValueKind);

            var pipeline = o.GetProperty("pipeline");
            Assert.Equal("pending", pipeline.GetProperty("status").GetString());
            Assert.Equal(JsonValueKind.Null, pipeline.GetProperty("model").ValueKind);
            Assert.Equal(0, pipeline.GetProperty("modelRuns").GetArrayLength());
            var loro = pipeline.GetProperty("loroCorrection");
            Assert.False(loro.GetProperty("applied").GetBoolean());
            Assert.Equal(0, loro.GetProperty("corrections").GetInt32());

            // §3.4 — companion has no captions, present-from-birth empty.
            var captions = o.GetProperty("captions");
            Assert.False(captions.GetProperty("available").GetBoolean());
            Assert.Equal(0, captions.GetProperty("count").GetInt32());
        }

        [Fact]
        public void ProcessLoopbackTargetIsHonoured()
        {
            var p = new SessionContract.Params(
                sessionId: "id", startedAt: 1_700_000_000_000, sampleRate: 48_000, chunkMs: 3000,
                micEnabled: true, captureTarget: "process:Zoom", method: SessionContract.MethodProcessLoopback,
                platformId: "system", platformLabel: "Desktop call", platformSlug: "call",
                companionVersion: "0.1.0-p3", processHint: "Zoom");
            var o = Parse(SessionContract.SessionJson(p, "open", null,
                new List<SessionContract.AudioPart>(), new SessionContract.HealthSummary()));
            var capture = o.GetProperty("capture");
            Assert.Equal("wasapi-process-loopback+mic", capture.GetProperty("method").GetString());
            Assert.Equal("process:Zoom", capture.GetProperty("captureTarget").GetString());
            Assert.Equal("Zoom", o.GetProperty("ownership").GetProperty("processHint").GetString());
        }

        [Fact]
        public void PromotionSessionRecordsSupersedes()
        {
            var p = new SessionContract.Params(
                sessionId: "id", startedAt: 1_700_000_000_000, sampleRate: 48_000, chunkMs: 3000,
                micEnabled: true, captureTarget: "system", method: SessionContract.MethodSystemLoopback,
                platformId: "system", platformLabel: "Desktop call", platformSlug: "call",
                companionVersion: "0.1.0-p3", processHint: null, supersedes: "ext-dead");
            var o = Parse(SessionContract.SessionJson(p, "open", null,
                new List<SessionContract.AudioPart>(), new SessionContract.HealthSummary()));
            Assert.Equal("ext-dead", o.GetProperty("ownership").GetProperty("supersedes").GetString());
        }

        [Fact]
        public void ClosedSessionPopulatesAudioAndEndedAt()
        {
            var h = new SessionContract.HealthSummary
            { Heartbeats = 12, GreenSeconds = 12, WorstLevel = "green", RecordsWritten = 12 };
            var part = new SessionContract.AudioPart(0, 96_044, 1_700_000_000_000, 1_700_000_012_000);
            var o = Parse(SessionContract.SessionJson(Params(), "closed", 1_700_000_012_000,
                new List<SessionContract.AudioPart> { part }, h));

            Assert.Equal("closed", o.GetProperty("status").GetString());
            Assert.Equal(1_700_000_012_000, o.GetProperty("endedAt").GetInt64());
            var audio = o.GetProperty("audio");
            Assert.Equal(96_044, audio.GetProperty("bytesTotal").GetInt32());
            var first = audio.GetProperty("parts")[0];
            Assert.Equal("audio-part-00.wav", first.GetProperty("file").GetString());
            Assert.Equal(96_044, first.GetProperty("bytes").GetInt32());
        }

        [Fact]
        public void HealthSampleShape()
        {
            var sample = new SessionContract.HealthSample
            {
                SessionId = "s", T = 1_700_000_001_000, MicRms = 0.1234567, SysRms = 0.02,
                MicRmsMean = 0.05, SysRmsMean = 0.01, BytesTotal = 1000, BytesDelta = 100, Part = 0,
                TapRunning = true, MicRunning = true, Level = "green", Problems = new List<string>(),
            };
            var o = JsonDocument.Parse(sample.ToJson().Compact()).RootElement;
            Assert.Equal(1_700_000_001_000, o.GetProperty("t").GetInt64());
            Assert.Equal(0.123457, o.GetProperty("micRms").GetDouble(), 6); // rounded to 6dp
            Assert.Equal("green", o.GetProperty("level").GetString());
            Assert.True(o.GetProperty("tapRunning").GetBoolean());
        }
    }
}
