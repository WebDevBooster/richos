import Foundation

/// Companion side of the cross-surface capture COORDINATION (architecture §5.4, P4).
///
/// The DECISION LOGIC is NOT duplicated here — it lives once in the shared Node service
/// (`lib/coordination.js`), which the companion consults via the `richos-service claim` /
/// `failover-scan` CLI. This file is only the PURE parser for that shared authority's answer, plus
/// the constants + the promotion-ownership block the companion writes when it takes over a dead
/// browser call. Keeping the brain in one place is what makes the system generic over companion type
/// (macOS today, Windows later): both companions ask the same authority and parse the same JSON.
///
/// Pure + Foundation-only so `swift test` exercises it with no Core Audio, no TCC, no child process.
public enum Coordination {

    /// This companion's identity + default capture scope in the frozen contract.
    public static let surface = "desktop-companion-macos"
    public static let defaultCaptureKind = "system" // all system output (Granola-parity)

    public struct ClaimDecision: Equatable {
        public enum Kind: String { case own, standDown = "stand-down" }
        public let decision: Kind
        public let reason: String
        public let conflictSessionId: String?
        public let excludeProcessHint: String?
        public let supersede: [String]

        public init(decision: Kind, reason: String, conflictSessionId: String?, excludeProcessHint: String?, supersede: [String]) {
            self.decision = decision
            self.reason = reason
            self.conflictSessionId = conflictSessionId
            self.excludeProcessHint = excludeProcessHint
            self.supersede = supersede
        }
    }

    public struct FailoverCandidate: Equatable {
        public let sessionId: String
        public let surface: String
        public let captureKind: String
        public let processHint: String?
        public let reason: String

        public init(sessionId: String, surface: String, captureKind: String, processHint: String?, reason: String) {
            self.sessionId = sessionId
            self.surface = surface
            self.captureKind = captureKind
            self.processHint = processHint
            self.reason = reason
        }
    }

    public enum CoordError: Error, Equatable { case malformed(String) }

    /// Parse the JSON `richos-service claim` prints (`{request, decision, reason, ...}`).
    public static func parseClaimResult(_ data: Data) throws -> ClaimDecision {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw CoordError.malformed("claim result is not a JSON object")
        }
        guard let raw = obj["decision"] as? String, let kind = ClaimDecision.Kind(rawValue: raw) else {
            throw CoordError.malformed("claim result has no valid `decision`")
        }
        return ClaimDecision(
            decision: kind,
            reason: obj["reason"] as? String ?? "",
            conflictSessionId: obj["conflictSessionId"] as? String,
            excludeProcessHint: obj["excludeProcessHint"] as? String,
            supersede: obj["supersede"] as? [String] ?? []
        )
    }

    /// Parse the JSON `richos-service failover-scan` prints (`{zone, candidates:[...]}`).
    public static func parseFailoverCandidates(_ data: Data) throws -> [FailoverCandidate] {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let arr = obj["candidates"] as? [[String: Any]] else {
            throw CoordError.malformed("failover-scan result has no `candidates` array")
        }
        return arr.compactMap { c in
            guard let id = c["sessionId"] as? String else { return nil }
            return FailoverCandidate(
                sessionId: id,
                surface: c["surface"] as? String ?? "unknown",
                captureKind: c["captureKind"] as? String ?? "unknown",
                processHint: c["processHint"] as? String,
                reason: c["reason"] as? String ?? ""
            )
        }
    }

    /// The `ownership` block a companion writes when it PROMOTES to supersede a dead browser call
    /// (mirrors `coordination.js#buildPromotionOwnership`). Fed into SessionContract's ownership.
    public static func promotionOwnership(deadSessionId: String, processHint: String?) -> JSON {
        .object([
            ("ownerSurface", .string(surface)),
            ("supersedes", .string(deadSessionId)),
            ("processHint", processHint.map { JSON.string($0) } ?? .null),
        ])
    }
}
