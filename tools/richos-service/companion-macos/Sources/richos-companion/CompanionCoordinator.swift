import Foundation
import RichOSCompanionCore

/// Thin invoker that lets the macOS companion consult the SHARED coordination authority (the Node
/// service's `claim` / `failover-scan` CLI). No decision logic here — it runs the CLI and hands the
/// output to `Coordination` (the pure parser in the core). Best-effort by design: if node or the CLI
/// is unavailable the companion PROCEEDS (capture is never blocked by a missing service — the same
/// graceful-degrade rule the extension follows).
enum CompanionCoordinator {

    /// Resolve the shared service CLI: env override, else walk up from the executable to the checkout's
    /// `tools/richos-service/bin/richos-service.js`.
    static func resolveCLI() -> String? {
        if let p = ProcessInfo.processInfo.environment["RICHOS_SERVICE_CLI"], FileManager.default.fileExists(atPath: p) {
            return p
        }
        var dir = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().deletingLastPathComponent()
        for _ in 0..<12 {
            let candidate = dir.appendingPathComponent("tools/richos-service/bin/richos-service.js")
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate.path }
            dir.deleteLastPathComponent()
        }
        return nil
    }

    /// Run `node <cli> <args>` and return stdout (or nil on any failure — coordination is best-effort).
    private static func run(_ args: [String]) -> Data? {
        guard let cli = resolveCLI() else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["node", cli] + args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
        } catch {
            return nil
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return data.isEmpty ? nil : data
    }

    /// Ask the authority whether this companion may own a call now (or must stand down). nil = the
    /// service is absent, so proceed (best-effort).
    static func consultClaim(zone: String, captureKind: String, processHint: String?, sessionId: String) -> Coordination.ClaimDecision? {
        var args = ["claim", "--surface", Coordination.surface, "--kind", captureKind, "--session-id", sessionId, "--zone", zone]
        if let hint = processHint { args += ["--process-hint", hint] }
        guard let data = run(args) else { return nil }
        return try? Coordination.parseClaimResult(data)
    }

    /// Poll the authority for browser-owned calls that went dark and can be taken over.
    static func scanFailover(zone: String) -> [Coordination.FailoverCandidate] {
        guard let data = run(["failover-scan", "--zone", zone]) else { return [] }
        return (try? Coordination.parseFailoverCandidates(data)) ?? []
    }

    /// Close the failover loop: tell the authority a dead session has been superseded by this one.
    @discardableResult
    static func markSuperseded(zone: String, dead: String, by: String) -> Bool {
        run(["mark-superseded", "--dead", dead, "--by", by, "--zone", zone]) != nil
    }
}
