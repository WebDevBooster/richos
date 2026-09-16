import Foundation

/// Where a captured session directory is written — the ONE answer, mirroring the pipeline's
/// `lib/config.js#dropZone` because a producer that writes somewhere the consumer does not read is
/// a silent absence, and this project's whole reliability model is "never silent".
///
/// WHY THIS FILE EXISTS AT ALL, stated rather than discovered later.
///
/// The companion used to resolve its own zone with a private rule: `$RICHOS_DROP_ZONE`, else walk up
/// to a checkout containing `wiki/`, else `$PWD/wiki/raw/meetings`. That was written when the
/// pipeline's default WAS `<repo>/wiki/raw/meetings`, and it was labelled "mirrors
/// `config.js#dropZone`". The pipeline has since moved its default OUT of the repository and added
/// `assertEvidenceOutsideProductRepo`, a hard refusal. The companion did not move with it, so on
/// 2026-08-29 the two halves disagreed in the worst possible direction:
///
///   * `richos-companion doctor` on a clean checkout reported the drop zone as
///     `<checkout>/tools/richos-service/companion-macos/wiki/raw/meetings` — INSIDE a repository
///     that ships publicly.
///   * `node bin/richos-service.js` pointed at that same path REFUSES to run, with
///     "privacy invariant: refusing to write call recordings and transcripts inside the RichOS
///     product repo".
///
/// So an unconfigured `capture` would have put the CEO's recorded call inside the public tree, and
/// the pipeline that was supposed to pick it up would never have looked there. Two defects, one
/// stale copy of a rule.
///
/// The rule now lives in ONE place per language and is unit-tested here, with no hardware and no
/// permission. It is still two copies across two languages — Swift cannot import `config.js` — so
/// the mirror is stated explicitly in both directions: `config.js#dropZone` names this file, and
/// this file names it back. A third copy should not be created; a fourth surface should call one of
/// these two.
public enum DropZone {

    /// The recommended corpus location when none is configured — `config.js#DEFAULT_CORPUS_ROOT`.
    public static let defaultCorpusRoot = "~/RichOS/corpus"

    /// Which rule produced the path, so `doctor` can say it out loud instead of the operator
    /// guessing whether his environment took effect.
    public enum Source: String {
        case explicitFlag = "--zone"
        case environment = "RICHOS_DROP_ZONE"
        case corpus = "corpus default"
    }

    public struct Resolution {
        public let path: String
        public let source: Source
        /// The corpus partition, when `source == .corpus`; nil otherwise.
        public let company: String?
    }

    public enum Failure: Error, CustomStringConvertible {
        case insideProductRepo(zone: String, repo: String)
        case unresolvablePath(path: String, reason: String)

        public var description: String {
            switch self {
            case let .unresolvablePath(path, reason):
                return "privacy invariant: cannot verify recording path \(path): \(reason)"
            case let .insideProductRepo(zone, repo):
                return """
                privacy invariant: refusing to write call recordings inside the RichOS product repo \
                (\(zone), repo \(repo)). RichOS ships publicly and this is the CEO's own material. \
                Point it at the corpus (LORO_CORPUS) or an explicit path outside the checkout with \
                --zone / RICHOS_DROP_ZONE. This is the same refusal the pipeline's \
                lib/workspace/privacy.js makes; the companion makes it BEFORE recording rather than \
                after, so a call is never captured into a place the pipeline will not read.
                """
            }
        }
    }

    /// Resolve the zone, or refuse. `productRepo` nil means "could not be located", which is not an
    /// error — a companion binary copied somewhere else has no repo to be inside of.
    ///
    /// - Parameters:
    ///   - explicit: the `--zone` flag, if given.
    ///   - env: the process environment (injected, so this is testable).
    ///   - home: the user's home directory (injected for the same reason).
    ///   - productRepo: the RichOS checkout root, if the binary is running from inside one.
    public static func resolve(
        explicit: String?,
        env: [String: String],
        home: String,
        productRepo: String?
    ) throws -> Resolution {
        let resolution: Resolution
        if let explicit = explicit, !explicit.isEmpty {
            resolution = Resolution(path: absolute(explicit, home: home), source: .explicitFlag, company: nil)
        } else if let fromEnv = env["RICHOS_DROP_ZONE"], !fromEnv.isEmpty {
            resolution = Resolution(path: absolute(fromEnv, home: home), source: .environment, company: nil)
        } else {
            let corpus = absolute(nonEmpty(env["LORO_CORPUS"]) ?? defaultCorpusRoot, home: home)
            let company = nonEmpty(env["RICHOS_ACTIVE_COMPANY"])
            // `config.js#evidenceRoot`: companies/<c>/evidence, else ceo/unfiled/evidence.
            let evidence = company.map { (corpus as NSString).appendingPathComponent("companies/\($0)/evidence") }
                ?? (corpus as NSString).appendingPathComponent("ceo/unfiled/evidence")
            resolution = Resolution(
                path: (evidence as NSString).appendingPathComponent("meetings"),
                source: .corpus,
                company: company
            )
        }

        let physical = try physicalPath(resolution.path)
        if let repo = productRepo, contains(physical, try physicalPath(repo)) {
            throw Failure.insideProductRepo(zone: resolution.path, repo: repo)
        }
        return resolution
    }

    /// Physical containment, including missing final directories. Unresolvable
    /// paths conservatively count as inside; `resolve` reports the actual error.
    public static func isInside(_ path: String, _ root: String) -> Bool {
        guard !root.isEmpty else { return false }
        guard let a = try? physicalPath(path), let b = try? physicalPath(root) else { return true }
        return contains(a, b)
    }

    private static func contains(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        return a.hasPrefix(b.hasSuffix("/") ? b : b + "/")
    }

    /// `realpath` cannot resolve a directory that capture has not created yet.
    /// Walk to its nearest existing ancestor, refusing dangling links and other
    /// filesystem errors instead of treating them as absent directories.
    private static func physicalPath(_ path: String) throws -> String {
        var ancestor = (path as NSString).standardizingPath
        var missing: [String] = []
        while true {
            if let resolved = realpath(ancestor, nil) {
                defer { free(resolved) }
                return missing.reversed().reduce(String(cString: resolved)) {
                    ($0 as NSString).appendingPathComponent($1)
                }
            }
            let code = errno
            var metadata = stat()
            guard code == ENOENT, lstat(ancestor, &metadata) != 0, errno == ENOENT else {
                throw Failure.unresolvablePath(path: path, reason: String(cString: strerror(code)))
            }
            let parent = (ancestor as NSString).deletingLastPathComponent
            guard !parent.isEmpty, parent != ancestor else {
                throw Failure.unresolvablePath(path: path, reason: "no resolvable ancestor")
            }
            missing.append((ancestor as NSString).lastPathComponent)
            ancestor = parent
        }
    }

    /// Expand a leading `~` against `home`, then make absolute + lexically normal.
    /// Mirrors `config.js#expand`.
    public static func absolute(_ p: String, home: String) -> String {
        var s = p
        if s == "~" {
            s = home
        } else if s.hasPrefix("~/") {
            s = (home as NSString).appendingPathComponent(String(s.dropFirst(2)))
        }
        if !s.hasPrefix("/") {
            s = (FileManager.default.currentDirectoryPath as NSString).appendingPathComponent(s)
        }
        return (s as NSString).standardizingPath
    }

    /// The RichOS checkout `start` is inside, found by the marker the companion already trusts for
    /// this purpose (`CompanionCoordinator.resolveCLI`): `tools/richos-service/bin/richos-service.js`.
    /// Deliberately a FILE that only the real product tree has — a directory name like `tools/` would
    /// match half the filesystems on earth.
    public static func locateProductRepo(startingAt start: String, fileExists: (String) -> Bool) -> String? {
        var dir = (start as NSString).standardizingPath
        for _ in 0..<12 {
            let parent = (dir as NSString).deletingLastPathComponent
            let marker = (dir as NSString).appendingPathComponent("tools/richos-service/bin/richos-service.js")
            if fileExists(marker) {
                if (dir as NSString).lastPathComponent == "richos",
                   fileExists((parent as NSString).appendingPathComponent(".git"))
                    || fileExists((parent as NSString).appendingPathComponent(".richos")) {
                    return parent
                }
                return dir
            }
            let grouped = (dir as NSString).appendingPathComponent("richos/tools/richos-service/bin/richos-service.js")
            if fileExists(grouped) { return dir }
            if parent == dir || parent.isEmpty { break }
            dir = parent
        }
        return nil
    }

    private static func nonEmpty(_ s: String?) -> String? {
        guard let s = s else { return nil }
        let t = s.trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? nil : t
    }
}
