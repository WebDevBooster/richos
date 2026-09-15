using System;
using System.Collections.Generic;
using System.Text.Json;

namespace RichOSCompanionCore
{
    /// <summary>
    /// Windows-companion side of the cross-surface capture COORDINATION (architecture §5.4, P4). The exact
    /// peer of the macOS companion's <c>Coordination.swift</c>.
    ///
    /// The DECISION LOGIC is NOT duplicated here — it lives once in the shared Node service
    /// (<c>lib/coordination.js</c>), which the companion consults via the <c>richos-service claim</c> /
    /// <c>failover-scan</c> CLI. This file is only the PURE parser for that shared authority's answer,
    /// plus the constants + the promotion-ownership block the companion writes when it takes over a
    /// dead browser call. Keeping the brain in one place is what makes the system generic over
    /// companion type (macOS + Windows): both companions ask the same authority and parse the same
    /// JSON. Pure + BCL-only so it is unit-tested with no WASAPI, no COM, no child process.
    /// </summary>
    public static class Coordination
    {
        /// <summary>This companion's identity in the frozen contract (P1 <c>CAPTURE_SOURCE.windows</c>).</summary>
        public const string Surface = "desktop-companion-windows";

        /// <summary>Default capture scope: all system output (Granola-parity, §10-Q2 "all-output first").</summary>
        public const string DefaultCaptureKind = "system";

        public enum ClaimKind { Own, StandDown }

        public sealed class ClaimDecision : IEquatable<ClaimDecision>
        {
            public ClaimKind Decision;
            public string Reason = "";
            public string? ConflictSessionId;
            public string? ExcludeProcessHint;
            public IReadOnlyList<string> Supersede = Array.Empty<string>();

            public bool Equals(ClaimDecision? other)
                => other != null && Decision == other.Decision && Reason == other.Reason
                   && ConflictSessionId == other.ConflictSessionId
                   && ExcludeProcessHint == other.ExcludeProcessHint;

            public override bool Equals(object? obj) => Equals(obj as ClaimDecision);
            public override int GetHashCode() => HashCode.Combine(Decision, Reason, ConflictSessionId, ExcludeProcessHint);
        }

        public sealed class FailoverCandidate
        {
            public string SessionId = "";
            public string Surface = "unknown";
            public string CaptureKind = "unknown";
            public string? ProcessHint;
            public string Reason = "";
        }

        public sealed class CoordException : Exception
        {
            public CoordException(string message) : base(message) { }
        }

        private static string? Str(JsonElement e, string key)
            => e.TryGetProperty(key, out var v) && v.ValueKind == JsonValueKind.String ? v.GetString() : null;

        /// <summary>Parse the JSON <c>richos-service claim</c> prints (<c>{request, decision, reason, ...}</c>).</summary>
        public static ClaimDecision ParseClaimResult(string json)
        {
            JsonElement root;
            try { root = JsonDocument.Parse(json).RootElement; }
            catch { throw new CoordException("claim result is not JSON"); }
            if (root.ValueKind != JsonValueKind.Object)
                throw new CoordException("claim result is not a JSON object");

            string? raw = Str(root, "decision");
            ClaimKind kind;
            if (raw == "own") kind = ClaimKind.Own;
            else if (raw == "stand-down") kind = ClaimKind.StandDown;
            else throw new CoordException("claim result has no valid `decision`");

            var supersede = new List<string>();
            if (root.TryGetProperty("supersede", out var arr) && arr.ValueKind == JsonValueKind.Array)
                foreach (var item in arr.EnumerateArray())
                    if (item.ValueKind == JsonValueKind.String) supersede.Add(item.GetString()!);

            return new ClaimDecision
            {
                Decision = kind,
                Reason = Str(root, "reason") ?? "",
                ConflictSessionId = Str(root, "conflictSessionId"),
                ExcludeProcessHint = Str(root, "excludeProcessHint"),
                Supersede = supersede,
            };
        }

        /// <summary>Parse the JSON <c>richos-service failover-scan</c> prints (<c>{zone, candidates:[...]}</c>).</summary>
        public static List<FailoverCandidate> ParseFailoverCandidates(string json)
        {
            JsonElement root;
            try { root = JsonDocument.Parse(json).RootElement; }
            catch { throw new CoordException("failover-scan result is not JSON"); }
            if (root.ValueKind != JsonValueKind.Object ||
                !root.TryGetProperty("candidates", out var arr) || arr.ValueKind != JsonValueKind.Array)
                throw new CoordException("failover-scan result has no `candidates` array");

            var outList = new List<FailoverCandidate>();
            foreach (var c in arr.EnumerateArray())
            {
                if (c.ValueKind != JsonValueKind.Object) continue;
                string? id = Str(c, "sessionId");
                if (id == null) continue;
                outList.Add(new FailoverCandidate
                {
                    SessionId = id,
                    Surface = Str(c, "surface") ?? "unknown",
                    CaptureKind = Str(c, "captureKind") ?? "unknown",
                    ProcessHint = Str(c, "processHint"),
                    Reason = Str(c, "reason") ?? "",
                });
            }
            return outList;
        }

        /// <summary>
        /// The <c>ownership</c> block a companion writes when it PROMOTES to supersede a dead browser
        /// call (mirrors <c>coordination.js#buildPromotionOwnership</c> and the macOS companion's
        /// <c>promotionOwnership</c>). Fed into SessionContract's ownership.
        /// </summary>
        public static Json PromotionOwnership(string deadSessionId, string? processHint)
            => Json.Obj(
                ("ownerSurface", Json.Str(Surface)),
                ("supersedes", Json.Str(deadSessionId)),
                ("processHint", Json.StrOrNull(processHint)));
    }
}
