using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using RichOSCompanionCore;

namespace RichOSCompanion
{
    /// <summary>
    /// RichOS Windows capture companion (P3) — CLI entry point. Peer of the macOS companion's
    /// <c>main.swift</c>: <c>doctor</c> / <c>ingest</c> (headless, no permission) / <c>capture</c>
    /// (live WASAPI). Feeds P1's frozen capture-&gt;pipeline contract (schemaVersion 2).
    /// </summary>
    internal static class Program
    {
        public const string Version = "0.1.0-p3";

        public static long NowMs() => DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();

        // MARK: - Arg parsing helpers

        private static string? Flag(string name, string[] args)
        {
            int i = Array.IndexOf(args, name);
            return (i >= 0 && i + 1 < args.Length) ? args[i + 1] : null;
        }

        private static bool Has(string name, string[] args) => Array.IndexOf(args, name) >= 0;

        /// <summary>
        /// Resolve the loro drop zone the pipeline watches (mirrors <c>config.js#dropZone</c> and the
        /// macOS companion): explicit, then <c>$RICHOS_DROP_ZONE</c>, then walk up to a checkout
        /// containing <c>wiki/</c>, else <c>./wiki/raw/meetings</c>.
        /// </summary>
        private static string ResolveZone(string? explicitZone)
        {
            if (explicitZone != null) return Environment.ExpandEnvironmentVariables(explicitZone);
            string? env = Environment.GetEnvironmentVariable("RICHOS_DROP_ZONE");
            if (!string.IsNullOrEmpty(env)) return env;

            string dir = AppContext.BaseDirectory;
            for (int i = 0; i < 12; i++)
            {
                if (Directory.Exists(Path.Combine(dir, "wiki")))
                    return Path.Combine(dir, "wiki", "raw", "meetings");
                var parent = Directory.GetParent(dir);
                if (parent == null) break;
                dir = parent.FullName;
            }
            return Path.Combine(Directory.GetCurrentDirectory(), "wiki", "raw", "meetings");
        }

        public static SessionContract.Params MakeParams(
            long startedAt, int sampleRate, string method, string captureTarget, string? processHint, string? supersedes)
        {
            string sessionId = SessionContract.SessionDirName(startedAt, "system", "call");
            return new SessionContract.Params(
                sessionId: sessionId, startedAt: startedAt, sampleRate: sampleRate, chunkMs: 3000,
                micEnabled: true, captureTarget: captureTarget, method: method, platformId: "system",
                platformLabel: "Desktop call", platformSlug: "call", companionVersion: Version,
                processHint: processHint, supersedes: supersedes);
        }

        // MARK: - Subcommands

        private static void CmdDoctor()
        {
            var os = Environment.OSVersion.Version;
            Console.WriteLine($"RichOS Windows capture companion {Version}");
            Console.WriteLine($"Windows: {os.Major}.{os.Minor} build {os.Build}");
            bool procLoopback = os.Build >= 20348;
            Console.WriteLine($"WASAPI system loopback (all Windows 10/11): AVAILABLE");
            Console.WriteLine($"WASAPI process loopback (>= build 20348): {(procLoopback ? "AVAILABLE" : "UNAVAILABLE — needs Windows 10 build 20348 / 21H2+; system loopback still works")}");
            Console.WriteLine($"Drop zone: {ResolveZone(null)}");
            foreach (var bin in new[] { "node", "ffmpeg", "whisper-cli" })
            {
                string found = Which(bin);
                Console.WriteLine($"pipeline dep {bin}: {(string.IsNullOrEmpty(found) ? "not found (P1 pipeline needs it)" : found)}");
            }
            string? cli = CompanionCoordinator.ResolveCli();
            Console.WriteLine($"shared coordination CLI: {(cli ?? "not found (coordination degrades to proceed)")}");
            Console.WriteLine();
            Console.WriteLine("PERMISSION MODEL: Windows does NOT prompt for system-audio loopback. The MICROPHONE");
            Console.WriteLine("requires the Windows microphone privacy permission (Settings > Privacy & security >");
            Console.WriteLine("Microphone). If the mic is denied, capture continues SYSTEM-only and silence-fills the");
            Console.WriteLine("LEFT channel with a loud health alarm — the far side of the call is never lost.");
        }

        private static string Which(string bin)
        {
            try
            {
                var psi = new ProcessStartInfo
                {
                    FileName = "where",
                    Arguments = bin,
                    UseShellExecute = false,
                    CreateNoWindow = true,
                    RedirectStandardOutput = true,
                    RedirectStandardError = true,
                };
                var p = Process.Start(psi);
                if (p == null) return "";
                string outp = p.StandardOutput.ReadToEnd();
                p.WaitForExit();
                var first = outp.Split('\n');
                return first.Length > 0 ? first[0].Trim() : "";
            }
            catch { return ""; }
        }

        /// <summary>
        /// Headless proof path: push a pre-made sample through the SAME SessionWriter/ChannelMixer/
        /// WavWriter the live capture uses, producing a valid contract dir WITHOUT any permission.
        /// <c>--stereo</c> routes a stereo WAV's L-&gt;mic, R-&gt;system; <c>--mic</c>/<c>--system</c>
        /// take two mono WAVs (proves the L/R mapping). Mirrors the macOS companion's <c>ingest</c>.
        /// </summary>
        private static int CmdIngest(string[] args)
        {
            string zone = ResolveZone(Flag("--zone", args));
            long startedAt = long.TryParse(Flag("--started-at", args), out var s) ? s : NowMs();

            float[] micCh;
            float[] sysCh;
            int rate = 48_000;

            string? stereo = Flag("--stereo", args);
            string? micPath = Flag("--mic", args);
            string? sysPath = Flag("--system", args);
            if (stereo != null)
            {
                var pcm = WavReader.Read(stereo);
                rate = pcm.SampleRate;
                micCh = pcm.ChannelsData.Length > 0 ? pcm.ChannelsData[0] : Array.Empty<float>();
                sysCh = pcm.ChannelsData.Length > 1 ? pcm.ChannelsData[1] : new float[micCh.Length];
            }
            else if (micPath != null && sysPath != null)
            {
                var m = WavReader.Read(micPath);
                var sy = WavReader.Read(sysPath);
                rate = m.SampleRate;
                micCh = m.ChannelsData.Length > 0 ? m.ChannelsData[0] : Array.Empty<float>();
                sysCh = sy.ChannelsData.Length > 0 ? sy.ChannelsData[0] : Array.Empty<float>();
            }
            else
            {
                Console.Error.WriteLine("ingest requires --stereo <wav> OR --mic <wav> --system <wav>");
                return 2;
            }

            var p = MakeParams(startedAt, rate, SessionContract.MethodSystemLoopback, "system", null, null);
            long virtualNow = startedAt;
            using var writer = new SessionWriter(zone, p, () => virtualNow);
            writer.Start();
            Console.WriteLine($"session (open) written: {writer.Dir}");

            int block = rate;
            int offset = 0;
            int total = Math.Max(micCh.Length, sysCh.Length);
            while (offset < total)
            {
                int end = Math.Min(offset + block, total);
                var micSlice = Slice(micCh, offset, end);
                var sysSlice = Slice(sysCh, offset, end);
                writer.PushMic(micSlice);
                writer.PushSystem(sysSlice);
                writer.Pump();
                writer.WriteHealthTick(
                    ChannelMixer.Peak(micSlice), ChannelMixer.Rms(micSlice),
                    ChannelMixer.Peak(sysSlice), ChannelMixer.Rms(sysSlice),
                    tapRunning: true, micRunning: true);
                virtualNow += 1000;
                offset = end;
            }
            writer.Close();
            Console.WriteLine($"session (closed) written: {writer.Dir}");
            Console.WriteLine($"run the P1 pipeline over it:  node ../../bin/richos-service.js run \"{writer.Dir}\"");
            return 0;
        }

        private static float[] Slice(float[] src, int start, int end)
        {
            if (start >= src.Length) return Array.Empty<float>();
            int e = Math.Min(end, src.Length);
            int n = e - start;
            if (n <= 0) return Array.Empty<float>();
            var outb = new float[n];
            Array.Copy(src, start, outb, 0, n);
            return outb;
        }

        private static int CmdCapture(string[] args)
        {
            string zone = ResolveZone(Flag("--zone", args));
            long startedAt = NowMs();

            uint? pid = null;
            string? pidStr = Flag("--pid", args);
            if (pidStr != null && uint.TryParse(pidStr, out var parsed)) pid = parsed;
            string? processName = Flag("--process-name", args);
            string? processHint = Flag("--process-hint", args);
            bool force = Has("--force", args);
            string kind = Flag("--kind", args) ?? Coordination.DefaultCaptureKind;

            // COORDINATION (§5.4): before an all-system capture, ask the SHARED authority whether the
            // extension already owns a browser call. If so, stand down (its capture is richer) unless
            // --force. Best-effort: if the service is absent the companion proceeds, exactly like the
            // extension's Downloads fallback and the macOS companion.
            string provisionalId = SessionContract.SessionDirName(startedAt, "system", "call");
            var decision = CompanionCoordinator.ConsultClaim(zone, kind, processHint, provisionalId);
            if (decision != null && decision.Decision == Coordination.ClaimKind.StandDown && !force)
            {
                Console.Error.WriteLine($"stand down: {decision.Reason}");
                if (!string.IsNullOrEmpty(decision.ExcludeProcessHint))
                    Console.Error.WriteLine($"  (the extension owns {decision.ExcludeProcessHint}; it will capture this call with captions/names)");
                Console.Error.WriteLine("  pass --force to capture anyway (double-capture; the pipeline dedup backstop keeps the richer one).");
                return 0;
            }

            return LiveCapture.Run(zone, startedAt, pid, processName, processHint, supersedes: null);
        }

        private static void Usage()
        {
            Console.WriteLine($@"RichOS Windows capture companion {Version}

USAGE:
  richos-companion doctor
      Report environment + the permission model.
  richos-companion capture [--zone DIR] [--pid N --process-name NAME] [--process-hint H] [--force]
      Live capture: WASAPI system loopback (or process loopback with --pid) + mic -> 2-channel
      contract dir. Ctrl-C finalizes the session (status ""closed"") -> the P1 watcher transcribes it.
  richos-companion ingest --stereo <wav> [--zone DIR] [--started-at MS]
  richos-companion ingest --mic <monoWav> --system <monoWav> [--zone DIR]
      Headless: push a sample through the real contract writer (no permission) -> a valid session
      dir the P1 pipeline transcribes. The on-Windows proof of the contract + handoff.

The drop zone defaults to $RICHOS_DROP_ZONE, else <checkout>/wiki/raw/meetings.");
        }

        private static int Main(string[] argv)
        {
            if (argv.Length == 0) { Usage(); return 2; }
            string cmd = argv[0];
            var rest = new string[argv.Length - 1];
            Array.Copy(argv, 1, rest, 0, rest.Length);
            try
            {
                switch (cmd)
                {
                    case "doctor": CmdDoctor(); return 0;
                    case "ingest": return CmdIngest(rest);
                    case "capture": return CmdCapture(rest);
                    case "-h":
                    case "--help":
                    case "help": Usage(); return 0;
                    default:
                        Console.Error.WriteLine($"unknown command: {cmd}");
                        Usage();
                        return 2;
                }
            }
            catch (Exception e)
            {
                Console.Error.WriteLine($"error: {e.Message}");
                return 1;
            }
        }
    }
}
