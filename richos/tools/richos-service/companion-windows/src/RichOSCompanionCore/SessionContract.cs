using System;
using System.Collections.Generic;
using System.Globalization;

namespace RichOSCompanionCore
{
    /// <summary>
    /// Builds the frozen capture-&gt;pipeline contract (schemaVersion 2) that P1's pipeline consumes.
    ///
    /// The single most load-bearing interface in the system (architecture §3 / P1 README "The frozen
    /// capture-&gt;pipeline contract"). The Windows companion is "just another producer" of the SAME
    /// session directory the extension and the macOS companion write — so the pipeline (§4) and the
    /// reliability model (§6) are surface-independent. Every field name/shape below is matched to what
    /// <c>lib/contract.js</c>, <c>lib/pipeline.js</c>, <c>lib/reconcile.js</c> and
    /// <c>merge.js#renderMarkdown</c> read, and to the macOS companion's <c>SessionContract.swift</c>.
    /// </summary>
    public static class SessionContract
    {
        /// <summary>
        /// The frozen <c>capture.source</c> enum value for this surface (P1
        /// <c>CAPTURE_SOURCE.windows</c> in <c>lib/contract.js</c> = <c>desktop-companion-windows</c>).
        /// </summary>
        public const string CaptureSource = "desktop-companion-windows";

        /// <summary>Default method for all-system loopback (architecture §3.2 enum <c>wasapi-loopback+mic</c>).</summary>
        public const string MethodSystemLoopback = "wasapi-loopback+mic";

        /// <summary>Method when scoped to a target process tree (architecture §5.3 process loopback).</summary>
        public const string MethodProcessLoopback = "wasapi-process-loopback+mic";

        /// <summary>
        /// Portable, <c>:</c>-free, tz-unambiguous timestamp — byte-identical to the extension's
        /// <c>session.js#stampFor</c> and the macOS companion's <c>stampFor</c>:
        /// <c>new Date(ms).toISOString().replace(/\.\d+Z$/, 'Z').replace(/:/g, '-')</c>.
        /// </summary>
        public static string StampFor(long epochMs)
        {
            var dt = DateTimeOffset.FromUnixTimeMilliseconds(epochMs).UtcDateTime;
            return string.Format(
                CultureInfo.InvariantCulture,
                "{0:D4}-{1:D2}-{2:D2}T{3:D2}-{4:D2}-{5:D2}Z",
                dt.Year, dt.Month, dt.Day, dt.Hour, dt.Minute, dt.Second);
        }

        /// <summary><c>${stamp}--${platformId}--${slug}</c> — matches <c>session.js#sessionDirName</c>.</summary>
        public static string SessionDirName(long startedAt, string platformId, string slug)
            => $"{StampFor(startedAt)}--{platformId}--{slug}";

        public static string AudioPartFile(int part)
            => string.Format(CultureInfo.InvariantCulture, "audio-part-{0:D2}.wav", part);

        /// <summary>A finished audio part's accounting, as in <c>session.json.audio.parts[]</c>.</summary>
        public readonly struct AudioPart
        {
            public readonly int Part;
            public readonly int Bytes;
            public readonly long? FirstChunkAt;
            public readonly long? LastChunkAt;
            public AudioPart(int part, int bytes, long? firstChunkAt, long? lastChunkAt)
            {
                Part = part; Bytes = bytes; FirstChunkAt = firstChunkAt; LastChunkAt = lastChunkAt;
            }
        }

        /// <summary>Rolled-up health accounting for <c>session.json.health</c> (mirrors <c>session.js#accrueHealth</c>).</summary>
        public sealed class HealthSummary
        {
            public int Heartbeats;
            public int GreenSeconds;
            public int AmberSeconds;
            public int RedSeconds;
            public string WorstLevel = "green";
            public int RecordsWritten;
        }

        public sealed class Params
        {
            public string SessionId;
            public long StartedAt;
            public int SampleRate;
            public int ChunkMs;
            public bool MicEnabled;
            public string CaptureTarget;
            public string Method;
            public string PlatformId;
            public string PlatformLabel;
            public string PlatformSlug;
            public string CompanionVersion;
            public string? ProcessHint;
            /// <summary>Set when this session PROMOTES over a dead browser call (§5.4 failover).</summary>
            public string? Supersedes;

            public Params(
                string sessionId, long startedAt, int sampleRate, int chunkMs, bool micEnabled,
                string captureTarget, string method, string platformId, string platformLabel,
                string platformSlug, string companionVersion, string? processHint, string? supersedes = null)
            {
                SessionId = sessionId;
                StartedAt = startedAt;
                SampleRate = sampleRate;
                ChunkMs = chunkMs;
                MicEnabled = micEnabled;
                CaptureTarget = captureTarget;
                Method = method;
                PlatformId = platformId;
                PlatformLabel = platformLabel;
                PlatformSlug = platformSlug;
                CompanionVersion = companionVersion;
                ProcessHint = processHint;
                Supersedes = supersedes;
            }
        }

        /// <summary>
        /// The full v2 <c>session.json</c> object. <c>status</c>/<c>endedAt</c>/<c>audio</c>/<c>health</c>
        /// change between the call-START write (<c>open</c>, empty audio) and the call-CLOSE write
        /// (<c>closed</c>, populated) — the never-silent inversion (§6.1): the record is on disk from
        /// second zero, so a call that captured nothing is a loud <c>open</c>/empty anomaly, never an
        /// absence.
        /// </summary>
        public static Json SessionJson(
            Params p, string status, long? endedAt, IReadOnlyList<AudioPart> audioParts, HealthSummary health)
        {
            int bytesTotal = 0;
            var partsJson = new List<Json>(audioParts.Count);
            foreach (var part in audioParts)
            {
                bytesTotal += part.Bytes;
                partsJson.Add(Json.Obj(
                    ("part", Json.Int(part.Part)),
                    ("file", Json.Str(AudioPartFile(part.Part))),
                    ("bytes", Json.Int(part.Bytes)),
                    ("firstChunkAt", part.FirstChunkAt.HasValue ? Json.Int(part.FirstChunkAt.Value) : Json.Null),
                    ("lastChunkAt", part.LastChunkAt.HasValue ? Json.Int(part.LastChunkAt.Value) : Json.Null),
                    ("written", Json.Bool(true))));
            }

            return Json.Obj(
                ("schemaVersion", Json.Int(2)),
                ("sessionId", Json.Str(p.SessionId)),
                ("dir", Json.Str(p.SessionId)),
                ("status", Json.Str(status)),
                ("producer", Json.Obj(
                    ("product", Json.Str("RichOS Windows companion")),
                    ("module", Json.Str("call-capture")),
                    ("companionVersion", Json.Str(p.CompanionVersion)))),
                ("platform", Json.Obj(
                    ("id", Json.Str(p.PlatformId)),
                    ("label", Json.Str(p.PlatformLabel)),
                    ("slug", Json.Str(p.PlatformSlug)))),
                ("startedAt", Json.Int(p.StartedAt)),
                ("endedAt", endedAt.HasValue ? Json.Int(endedAt.Value) : Json.Null),
                ("capture", Json.Obj(
                    ("source", Json.Str(CaptureSource)),
                    ("method", Json.Str(p.Method)),
                    ("channels", Json.Obj(
                        ("left", Json.Str("microphone (me)")),
                        // Descriptive only — the pipeline maps by channel POSITION (L->me, R->others via
                        // ffmpeg channelsplit), never by this string. Honest about the Windows mechanism.
                        ("right", Json.Str("system/loopback (everyone else)")))),
                    ("captureTarget", Json.Str(p.CaptureTarget)),
                    ("sampleRate", Json.Int(p.SampleRate)),
                    ("container", Json.Str("audio/wav;codecs=pcm_s16le")),
                    ("micEnabled", Json.Bool(p.MicEnabled)),
                    ("chunkMs", Json.Int(p.ChunkMs)))),
                ("audio", Json.Obj(
                    ("parts", Json.Arr(partsJson)),
                    ("bytesTotal", Json.Int(bytesTotal)),
                    ("chunkCount", Json.Int(audioParts.Count)))),
                ("health", Json.Obj(
                    ("heartbeats", Json.Int(health.Heartbeats)),
                    ("greenSeconds", Json.Int(health.GreenSeconds)),
                    ("amberSeconds", Json.Int(health.AmberSeconds)),
                    ("redSeconds", Json.Int(health.RedSeconds)),
                    ("worstLevel", Json.Str(health.WorstLevel)),
                    ("recordsWritten", Json.Int(health.RecordsWritten)))),
                ("alerts", Json.Arr()),
                ("recovery", Json.Arr()),
                // §3.4: a desktop-app companion has NO platform captions. Present-from-birth, empty.
                ("captions", Json.Obj(
                    ("available", Json.Bool(false)),
                    ("adapter", Json.Null),
                    ("adapterVersion", Json.Null),
                    ("count", Json.Int(0)),
                    ("speakers", Json.Arr()),
                    ("degraded", Json.Bool(false)))),
                ("mode", Json.Str("full")),
                ("notes", Json.Arr()),
                // §5.4 dedup handshake block — a lone companion session owns itself; `supersedes` is
                // set when this session PROMOTES over a dead browser-owned call (failover).
                ("ownership", Json.Obj(
                    ("ownerSurface", Json.Str(CaptureSource)),
                    ("supersedes", Json.StrOrNull(p.Supersedes)),
                    ("processHint", Json.StrOrNull(p.ProcessHint)))),
                // Written by the pipeline; born `pending` so a never-run pipeline is visible on disk.
                ("pipeline", Json.Obj(
                    ("status", Json.Str("pending")),
                    ("model", Json.Null),
                    ("modelRuns", Json.Arr()),
                    ("ffmpegVersion", Json.Null),
                    ("whisperVersion", Json.Null),
                    ("loroCorrection", Json.Obj(
                        ("applied", Json.Bool(false)),
                        ("entitiesVersion", Json.Null),
                        ("corrections", Json.Int(0)))))));
        }

        /// <summary>
        /// One <c>health.ndjson</c> row (§3.3 absolute-<c>t</c> keyed; §6.2 second-by-second signals).
        /// Field names are IDENTICAL to the macOS companion's <c>HealthSample</c> so <c>health.ndjson</c>
        /// is a uniform cross-surface schema; on Windows <c>tapRunning</c> means "the WASAPI loopback
        /// capture client is delivering" and <c>sysRms</c> is the loopback (RIGHT) channel level.
        /// </summary>
        public sealed class HealthSample
        {
            public string SessionId = "";
            public long T;
            public double MicRms;
            public double SysRms;
            public double MicRmsMean;
            public double SysRmsMean;
            public int BytesTotal;
            public int BytesDelta;
            public int Part;
            public bool TapRunning;
            public bool MicRunning;
            public string Level = "green";
            public IReadOnlyList<string> Problems = Array.Empty<string>();

            public Json ToJson()
            {
                var probs = new List<Json>(Problems.Count);
                foreach (var s in Problems) probs.Add(Json.Str(s));
                return Json.Obj(
                    ("sessionId", Json.Str(SessionId)),
                    ("t", Json.Int(T)),
                    ("micRms", Json.Dbl(Round6(MicRms))),
                    ("sysRms", Json.Dbl(Round6(SysRms))),
                    ("micRmsMean", Json.Dbl(Round6(MicRmsMean))),
                    ("sysRmsMean", Json.Dbl(Round6(SysRmsMean))),
                    ("bytesTotal", Json.Int(BytesTotal)),
                    ("bytesDelta", Json.Int(BytesDelta)),
                    ("part", Json.Int(Part)),
                    ("tapRunning", Json.Bool(TapRunning)),
                    ("micRunning", Json.Bool(MicRunning)),
                    ("level", Json.Str(Level)),
                    ("problems", Json.Arr(probs)));
            }

            private static double Round6(double x) => Math.Round(x * 1_000_000.0) / 1_000_000.0;
        }
    }
}
