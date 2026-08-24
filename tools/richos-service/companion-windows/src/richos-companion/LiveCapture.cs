using System;
using System.Threading;
using RichOSCompanionCore;

namespace RichOSCompanion
{
    /// <summary>
    /// The live capture loop: wire the WASAPI engine to the <see cref="SessionWriter"/>, run a 10 Hz
    /// mix pump and a 1 Hz health tick + watchdog, and finalize cleanly on Ctrl-C. This is the
    /// outside-the-browser watchdog made real (§6.3) — it holds its own timer and alarms on stalls the
    /// capture can't hide. The peer of the macOS companion's <c>LiveCapture.swift</c>.
    /// </summary>
    internal static class LiveCapture
    {
        public static int Run(string zone, long startedAt, uint? pid, string? processName, string? processHint, string? supersedes)
        {
            // session.json is written at START (§6.1) — a call that captures nothing leaves a loud
            // open/empty session on disk, never an absence. Provisional method/target reflect intent and
            // are corrected once the engine resolves process-vs-system loopback.
            bool wantProcess = pid.HasValue;
            string method = wantProcess ? SessionContract.MethodProcessLoopback : SessionContract.MethodSystemLoopback;
            string target = wantProcess ? "process:" + (processName ?? pid!.Value.ToString()) : "system";

            var p = Program.MakeParams(startedAt, 48_000, method, target, processHint, supersedes);
            var writer = new SessionWriter(zone, p, Program.NowMs);
            try
            {
                writer.Start();
            }
            catch (Exception e)
            {
                Notifier.Alarm($"could not create the session directory: {e.Message}");
                return 1;
            }
            string dir = writer.Dir;
            Notifier.Info($"session (open) written: {dir}");

            var capture = new WasapiCapture(writer, pid, processName);
            try
            {
                capture.Start();
                Notifier.Info("capturing system audio + mic. Press Ctrl-C to stop.");
            }
            catch (Exception e)
            {
                // The open session.json stays on disk as the anomaly; we exit loud, not silent.
                Notifier.Alarm(
                    $"capture failed to start: {e.Message}. If the microphone is denied, allow it in " +
                    $"Settings > Privacy & security > Microphone, then retry. The open session at {dir} " +
                    "is the on-disk record that this call was NOT captured.");
                return 1;
            }

            // Correct the open session.json to the actually-resolved capture path (process vs system).
            if (capture.CaptureMethod != p.Method || capture.CaptureTarget != p.CaptureTarget)
            {
                p.Method = capture.CaptureMethod;
                p.CaptureTarget = capture.CaptureTarget;
                writer.RewriteOpenSessionJson();
            }

            var stop = new ManualResetEventSlim(false);
            int lastBytes = 0;
            int stalledSeconds = 0;

            // 10 Hz mix pump: keep the WAV growing and both sources frame-aligned.
            using var pump = new Timer(_ => { try { writer.Pump(); } catch { /* transient */ } }, null, 100, 100);

            // 1 Hz health tick + flush + watchdog escalation.
            using var health = new Timer(_ =>
            {
                var (mp, mr, sp, sr) = capture.SnapshotLevels();
                try
                {
                    writer.WriteHealthTick(mp, mr, sp, sr, capture.TapRunning, capture.MicRunning);
                    writer.Flush(); // durable to disk each second (§6.5)
                }
                catch { /* transient */ }

                // Watchdog: byte growth is the ground-truth liveness signal (§6.2 "no growth > 15 s").
                int bytes = writer.PumpedBytesTotal;
                if (bytes == lastBytes) stalledSeconds += 1; else stalledSeconds = 0;
                lastBytes = bytes;
                if (stalledSeconds == 15)
                {
                    Notifier.Alarm("no audio has been written for 15s — the capture has stalled (loopback "
                        + $"stopped, the render device changed, or the mic was revoked). Session: {dir}");
                }
            }, null, 1000, 1000);

            // Clean finalize on Ctrl-C: drain, flush, rewrite session.json as closed -> triggers P1.
            Console.CancelKeyPress += (_, e) => { e.Cancel = true; stop.Set(); };
            stop.Wait();

            pump.Dispose();
            health.Dispose();
            capture.Stop();
            try
            {
                writer.Close();
                Notifier.Info($"session (closed) written: {dir} — the P1 watcher will now transcribe it.");
            }
            catch (Exception e)
            {
                Notifier.Alarm($"failed to finalize session: {e.Message}");
            }
            return 0;
        }
    }
}
