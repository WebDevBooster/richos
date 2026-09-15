using System;
using System.Collections.Generic;
using System.IO;
using System.Text;

namespace RichOSCompanionCore
{
    /// <summary>
    /// Orchestrates one capture session's on-disk contract directory (architecture §6.1 never-silent). The
    /// exact peer of the macOS companion's <c>SessionWriter.swift</c>.
    ///
    /// Lifecycle:
    ///   1. <see cref="Start"/> — create the dir, write <c>session.json</c> (status "open", empty
    ///      audio) IMMEDIATELY, open the WAV. A call that captures nothing therefore leaves a loud
    ///      open/empty session on disk — an anomaly the pipeline's reconcile guard flags — never an
    ///      absence nobody notices.
    ///   2. <see cref="PushMic"/> / <see cref="PushSystem"/> — real-time callbacks feed mono float frames.
    ///   3. <see cref="Pump"/> — mix aligned frames (with failover), append to WAV, accrue byte growth.
    ///   4. <see cref="WriteHealthTick"/> — one <c>health.ndjson</c> row per second.
    ///   5. <see cref="Close"/> — flush WAV, rewrite <c>session.json</c> (status "closed", populated).
    ///      The closed status is what triggers P1's pipeline.
    /// </summary>
    public sealed class SessionWriter : IDisposable
    {
        public string Dir { get; }
        public SessionContract.Params Params { get; }
        private readonly Func<long> _clock;

        private WavWriter? _wav;
        private readonly RingBuffer _micRing = new RingBuffer();
        private readonly RingBuffer _sysRing = new RingBuffer();

        private long? _firstAudioMs;
        private long? _lastAudioMs;
        private int _lastBytesTotal;
        private readonly SessionContract.HealthSummary _health = new SessionContract.HealthSummary();
        private FileStream? _healthHandle;

        /// <summary>Failover threshold: a source silent this long while the other is live trips silence-fill+alarm.</summary>
        public long StarveThresholdMs { get; set; } = 15_000;

        public bool Closed { get; private set; }
        public MixDecision? LastDecision { get; private set; }

        public SessionWriter(string rootZone, SessionContract.Params p, Func<long> clock)
        {
            Dir = System.IO.Path.Combine(rootZone, p.SessionId);
            Params = p;
            _clock = clock;
        }

        /// <summary>Write <c>session.json</c> (open) + open the WAV part. Call once.</summary>
        public void Start()
        {
            Directory.CreateDirectory(Dir);
            WriteSessionJson("open", null, Array.Empty<SessionContract.AudioPart>());
            string wavPath = System.IO.Path.Combine(Dir, SessionContract.AudioPartFile(0));
            _wav = new WavWriter(wavPath, Params.SampleRate, channels: 2, bitsPerSample: 16);
            string healthPath = System.IO.Path.Combine(Dir, "health.ndjson");
            _healthHandle = new FileStream(healthPath, FileMode.Create, FileAccess.Write, FileShare.Read);
        }

        /// <summary>
        /// Rewrite <c>session.json</c> in the OPEN state after mutating <see cref="Params"/> — used by
        /// the live path to correct <c>capture.method</c>/<c>captureTarget</c> once the WASAPI engine
        /// has resolved whether it got process loopback or fell back to system loopback. Never touches
        /// the WAV, so the never-silent open record simply gets more accurate.
        /// </summary>
        public void RewriteOpenSessionJson()
        {
            if (Closed) return;
            WriteSessionJson("open", null, Array.Empty<SessionContract.AudioPart>());
        }

        public void PushMic(IReadOnlyList<float> mono) => _micRing.Append(mono, _clock());
        public void PushSystem(IReadOnlyList<float> mono) => _sysRing.Append(mono, _clock());

        /// <summary>Mix one block of aligned frames to the WAV. Returns bytes written this pump.</summary>
        public int Pump()
        {
            if (_wav == null || Closed) return 0;
            long now = _clock();
            long micSilent = _micRing.LastAppend() == 0 ? 0 : now - _micRing.LastAppend();
            long sysSilent = _sysRing.LastAppend() == 0 ? 0 : now - _sysRing.LastAppend();
            var decision = MixDecision.Decide(
                _micRing.Count, _sysRing.Count, micSilent, sysSilent, StarveThresholdMs);
            LastDecision = decision;
            if (decision.Frames <= 0) return 0;

            float[] mic = decision.UseMic ? _micRing.Take(decision.Frames) : new float[decision.Frames];
            float[] sys = decision.UseSystem ? _sysRing.Take(decision.Frames) : new float[decision.Frames];
            // Guard alignment even under failover silence-fill.
            int n = Math.Min(mic.Length, sys.Length);
            if (n < mic.Length) Array.Resize(ref mic, n);
            if (n < sys.Length) Array.Resize(ref sys, n);
            short[] interleaved = ChannelMixer.InterleaveToInt16(mic, sys);
            byte[] bytes = ChannelMixer.Int16LeBytes(interleaved);
            _wav.Append(bytes);
            if (_firstAudioMs == null) _firstAudioMs = now;
            _lastAudioMs = now;
            return bytes.Length;
        }

        /// <summary>Flush the WAV to disk — the &lt;= one-flush-window crash guarantee.</summary>
        public void Flush() => _wav?.Flush();

        /// <summary>Total bytes on disk for the audio part so far — the watchdog's ground-truth signal.</summary>
        public int PumpedBytesTotal => _wav?.TotalBytesOnDisk ?? 0;

        /// <summary>
        /// Emit one health row + accrue the rolled-up summary from precomputed per-channel levels
        /// (peak + RMS over the last second). Kept level-based (not block-based) so the live capture can
        /// meter cheaply in its audio callbacks without re-buffering a second of samples.
        /// </summary>
        public void WriteHealthTick(
            double micPeak, double micRms, double sysPeak, double sysRms, bool tapRunning, bool micRunning)
        {
            long now = _clock();
            int bytesTotal = _wav?.TotalBytesOnDisk ?? 0;
            int delta = bytesTotal - _lastBytesTotal;
            _lastBytesTotal = bytesTotal;

            var problems = new List<string>();
            string level = "green";
            // Never-silent signals (§6.2): stalled byte growth, and failover-tripped starvation.
            if (_health.Heartbeats > 20 && delta == 0)
            {
                problems.Add("no audio bytes written in the last second");
                level = "amber";
            }
            if (LastDecision.HasValue && LastDecision.Value.MicStarved)
            {
                problems.Add("microphone source stalled — silence-filling LEFT (loopback-only failover the other way)");
                level = "red";
            }
            if (LastDecision.HasValue && LastDecision.Value.SystemStarved)
            {
                problems.Add("system loopback stalled — silence-filling RIGHT (device change or render endpoint went idle)");
                level = "red";
            }
            if (!tapRunning) { problems.Add("system loopback capture client not running"); level = "red"; }
            if (!micRunning) { problems.Add("microphone capture client not running"); level = "red"; }

            var sample = new SessionContract.HealthSample
            {
                SessionId = Params.SessionId,
                T = now,
                MicRms = micPeak,
                SysRms = sysPeak,
                MicRmsMean = micRms,
                SysRmsMean = sysRms,
                BytesTotal = bytesTotal,
                BytesDelta = delta,
                Part = 0,
                TapRunning = tapRunning,
                MicRunning = micRunning,
                Level = level,
                Problems = problems,
            };
            if (_healthHandle != null)
            {
                byte[] line = Encoding.UTF8.GetBytes(sample.ToJson().Compact() + "\n");
                _healthHandle.Write(line, 0, line.Length);
                _healthHandle.Flush(flushToDisk: true);
            }

            _health.Heartbeats += 1;
            switch (level)
            {
                case "green": _health.GreenSeconds += 1; break;
                case "amber": _health.AmberSeconds += 1; break;
                default: _health.RedSeconds += 1; break;
            }
            int Rank(string l) => l == "red" ? 2 : l == "amber" ? 1 : 0;
            if (Rank(level) > Rank(_health.WorstLevel)) _health.WorstLevel = level;
            _health.RecordsWritten += 1;
        }

        /// <summary>Drain remaining buffered audio, flush, and rewrite <c>session.json</c> as closed+populated.</summary>
        public void Close()
        {
            if (Closed) return;
            // Drain whatever is left in both rings before finalizing.
            for (int i = 0; i < 64; i++) { if (Pump() == 0) break; }
            _wav?.Close();
            int bytes = _wav?.TotalBytesOnDisk ?? 0;
            var part = new SessionContract.AudioPart(0, bytes, _firstAudioMs, _lastAudioMs);
            var parts = bytes > 0
                ? new List<SessionContract.AudioPart> { part }
                : new List<SessionContract.AudioPart>();
            WriteSessionJson("closed", _clock(), parts);
            _healthHandle?.Dispose();
            _healthHandle = null;
            _wav = null; // stream already disposed by _wav.Close() above
            Closed = true;
        }

        /// <summary>
        /// Deterministically release the WAV + health OS file handles even when <see cref="Close"/> was
        /// never reached — an abandoned/errored/never-closed session (e.g. capture fails to start after
        /// <see cref="Start"/>, or a call that captures nothing). Idempotent and safe to call after
        /// <see cref="Close"/>. Crucially it does NOT rewrite <c>session.json</c>: an un-closed session
        /// stays in its loud "open" state — the never-silent anomaly the pipeline's reconcile guard flags
        /// — rather than being silently marked "closed". Without this, on Windows the leaked WAV handle
        /// leaves <c>audio-part-00.wav</c> locked (a crashed/killed companion could not be cleaned up or
        /// re-collected); POSIX masked the leak by allowing unlink of an open file.
        /// </summary>
        public void Dispose()
        {
            _wav?.Dispose();
            _wav = null;
            _healthHandle?.Dispose();
            _healthHandle = null;
        }

        private void WriteSessionJson(string status, long? endedAt, IReadOnlyList<SessionContract.AudioPart> parts)
        {
            var json = SessionContract.SessionJson(Params, status, endedAt, parts, _health);
            string path = System.IO.Path.Combine(Dir, "session.json");
            File.WriteAllBytes(path, json.Data());
        }
    }
}
