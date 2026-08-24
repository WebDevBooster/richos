using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Text;
using RichOSCompanionCore;

namespace RichOSCompanion
{
    /// <summary>
    /// Thin invoker that lets the Windows companion consult the SHARED coordination authority (the Node
    /// service's <c>claim</c> / <c>failover-scan</c> CLI). No decision logic here — it runs the CLI and
    /// hands the output to <see cref="Coordination"/> (the pure parser in the core). Best-effort by
    /// design: if node or the CLI is unavailable the companion PROCEEDS (capture is never blocked by a
    /// missing service — the same graceful-degrade rule the extension and the macOS companion follow).
    /// The peer of the macOS companion's <c>CompanionCoordinator.swift</c>.
    /// </summary>
    internal static class CompanionCoordinator
    {
        /// <summary>
        /// Resolve the shared service CLI: env override, else walk up from the executable to the
        /// checkout's <c>tools/richos-service/bin/richos-service.js</c>.
        /// </summary>
        public static string? ResolveCli()
        {
            string? env = Environment.GetEnvironmentVariable("RICHOS_SERVICE_CLI");
            if (!string.IsNullOrEmpty(env) && File.Exists(env)) return env;

            string dir = AppContext.BaseDirectory;
            for (int i = 0; i < 12; i++)
            {
                string candidate = Path.Combine(dir, "tools", "richos-service", "bin", "richos-service.js");
                if (File.Exists(candidate)) return candidate;
                var parent = Directory.GetParent(dir);
                if (parent == null) break;
                dir = parent.FullName;
            }
            return null;
        }

        /// <summary>Run <c>node &lt;cli&gt; &lt;args&gt;</c> and return stdout (or null on any failure).</summary>
        private static string? Run(IEnumerable<string> args)
        {
            string? cli = ResolveCli();
            if (cli == null) return null;
            try
            {
                var psi = new ProcessStartInfo
                {
                    FileName = "node",
                    UseShellExecute = false,
                    CreateNoWindow = true,
                    RedirectStandardOutput = true,
                    RedirectStandardError = true,
                };
                psi.ArgumentList.Add(cli);
                foreach (var a in args) psi.ArgumentList.Add(a);
                var p = Process.Start(psi);
                if (p == null) return null;
                string outp = p.StandardOutput.ReadToEnd();
                p.WaitForExit();
                return string.IsNullOrWhiteSpace(outp) ? null : outp;
            }
            catch
            {
                return null;
            }
        }

        /// <summary>
        /// Ask the authority whether this companion may own a call now (or must stand down). null = the
        /// service is absent, so proceed (best-effort).
        /// </summary>
        public static Coordination.ClaimDecision? ConsultClaim(string zone, string captureKind, string? processHint, string sessionId)
        {
            var args = new List<string> { "claim", "--surface", Coordination.Surface, "--kind", captureKind, "--session-id", sessionId, "--zone", zone };
            if (!string.IsNullOrEmpty(processHint)) { args.Add("--process-hint"); args.Add(processHint!); }
            string? data = Run(args);
            if (data == null) return null;
            try { return Coordination.ParseClaimResult(data); }
            catch { return null; }
        }

        /// <summary>Poll the authority for browser-owned calls that went dark and can be taken over.</summary>
        public static List<Coordination.FailoverCandidate> ScanFailover(string zone)
        {
            string? data = Run(new[] { "failover-scan", "--zone", zone });
            if (data == null) return new List<Coordination.FailoverCandidate>();
            try { return Coordination.ParseFailoverCandidates(data); }
            catch { return new List<Coordination.FailoverCandidate>(); }
        }

        /// <summary>Close the failover loop: tell the authority a dead session has been superseded by this one.</summary>
        public static bool MarkSuperseded(string zone, string dead, string by)
            => Run(new[] { "mark-superseded", "--dead", dead, "--by", by, "--zone", zone }) != null;
    }
}
