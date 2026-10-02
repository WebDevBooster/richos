// The start-time measurement's fixed condition on iOS: the made-up conversation Android's
// measurement seeds (`richos/mobile/perf/condition.py`, FILE_FIXTURE), written as the iPhone app's
// own saved state, through the app's own core, so a launch reads it exactly as it reads a real one.
//
// WHY A SEPARATE LIBRARY: nothing the app links can contain this. The app target links RichOSCore
// and RichOSFixtures only (`../project.yml`); this target is linked by the `rios-cli` executable on
// the Mac and by the core's tests, never by the app or its extensions. The files are written on the
// Mac and copied into the installed app's data container by `perf.py ios` (simctl on a simulator,
// devicectl on an iPhone), so the Release app the measurement launches is the stamped bundle,
// byte for byte, with no launch argument and no code path that knows a fixture exists.
// `bin/rios sim check-release` proves `marker` is absent from both app bundles and present in the
// CLI that writes them (a negative search needs its positive probe).
//
// Input: Android's fixture files exactly as `condition.file_fixture(rows)` produces them
// (session.json and history.json), checked by the same SHA-256 manifest perf.py records, so the
// iPhone and the Android phone are given the same conversation, row for row.
//
// The Mac is unreachable by construction, as on Android: the pairing names a host under `.invalid`,
// which never resolves (RFC 6761). One difference, stated in the report: the iOS pairing carries no
// device id. With one, the app looks up this phone's own key for that origin, which only a real
// pairing creates; finding none it treats the pairing as removed (security review I-2) and leaves
// the conversation. Without one, the app holds the pairing and opens no connection at all.
import Foundation
import CryptoKit
import RichOSCore

public enum PerfSeed {
    /// A string only this target contains: `rios sim check-release` requires it absent from the
    /// Debug and Release app bundles and present in `rios-cli`.
    public static let marker = "rios-perf-seed-fixture-writer"
    /// The fixture's own name (condition.py FILE_FIXTURE); a different input is refused.
    public static let fixtureName = "synthetic-conversation/1"
    public static let fixtureFiles = ["history.json", "session.json"]

    public struct Report: Codable, Equatable, Sendable {
        public var marker = PerfSeed.marker
        public var fixture: String
        /// condition.py `_manifest_sha256` of the fixture files: the condition's `conversation.sha256`.
        public var fixtureSha256: String
        public var fixtureFiles: [String: String]
        public var rows: Int
        /// What the app reads: each written file's SHA-256, read back after a load through the core.
        public var written: [String: String]
        public var origin: String
        public var threadID: String
        public var newestID: String
        public var deviceID: String?
        public var mac: String
    }

    public struct Refusal: Error, CustomStringConvertible, Sendable {
        public var description: String
        init(_ description: String) { self.description = description }
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// condition.py `_manifest_sha256`: the SHA-256 of a sha256sum-style manifest, names sorted.
    public static func manifestSHA256(_ files: [String: Data]) -> String {
        let lines = files.keys.sorted().map { "\(sha256(files[$0]!))  \($0)\n" }.joined()
        return sha256(Data(lines.utf8))
    }

    // MARK: - Android's fixture, as condition.py writes it

    struct AndroidSession: Decodable {
        struct Thread: Decodable { var id: String; var title: String? }
        struct Pairing: Decodable { var phase: String; var apiBase: String; var route: String; var deviceId: String? }
        struct Notices: Decodable { var status: String; var offerDismissed: Bool; var previews: Bool }
        var threads: [Thread]
        var selectedThreadId: String
        var draft: String
        var paired: Bool
        var theme: String
        var pairing: Pairing
        var notifications: Notices
    }

    struct AndroidHistory: Decodable {
        struct Row: Decodable {
            var id: String
            var thread_id: String
            var cursor: Int
            var role: String
            var kind: String
            var text: String
            var created_at: String
            var state: String
            var complete: Bool
        }
        var rows: [String: [Row]]
    }

    /// The app state Android's fixture describes: paired with the `.invalid` Mac, the consent
    /// answered, the conversation's rows in order, no draft, nothing unsent.
    public static func state(session: Data, history: Data) throws -> AppState {
        let s: AndroidSession, h: AndroidHistory
        do {
            s = try JSONDecoder().decode(AndroidSession.self, from: session)
            h = try JSONDecoder().decode(AndroidHistory.self, from: history)
        } catch {
            throw Refusal("the fixture does not decode as condition.py's session.json and history.json: \(error)")
        }
        guard s.paired, s.pairing.phase == "paired" else { throw Refusal("the fixture's session is not paired") }
        guard let host = URL(string: s.pairing.apiBase)?.host, host.hasSuffix(".invalid") else {
            throw Refusal("the fixture's Mac \(s.pairing.apiBase) is not under .invalid, so it could be reachable")
        }
        guard let route = PairLink.Route(rawValue: s.pairing.route) else { throw Refusal("unknown route \(s.pairing.route)") }
        guard let appearance = Appearance(rawValue: s.theme) else { throw Refusal("unknown theme \(s.theme)") }
        guard let status = Notifications.Status(rawValue: s.notifications.status) else {
            throw Refusal("unknown notification status \(s.notifications.status)")
        }
        guard let rows = h.rows[s.selectedThreadId], !rows.isEmpty else {
            throw Refusal("the fixture's history has no rows for its thread \(s.selectedThreadId)")
        }
        let dates = ISO8601DateFormatter()
        dates.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var messages: [Message] = []
        for row in rows {
            guard row.thread_id == s.selectedThreadId, row.kind == "text", row.complete, row.state == "complete",
                  let author: Message.Author = row.role == "ceo" ? .me : row.role == "rich" ? .rich : nil,
                  let at = dates.date(from: row.created_at) else {
                throw Refusal("fixture row \(row.id) is not a complete text row of the thread")
            }
            messages.append(Message(id: row.id, author: author, kind: .text, text: row.text,
                                    sentAt: Int64((at.timeIntervalSince1970 * 1000).rounded()), cursor: row.cursor))
        }
        var state = AppState()
        state.pairing = .paired
        state.consentGiven = true
        state.mac = MacLink(origin: s.pairing.apiBase, route: route, deviceID: nil, threadID: s.selectedThreadId)
        state.messages = messages
        state.draft = s.draft
        state.notifications = Notifications(status: status, offerDismissed: s.notifications.offerDismissed,
                                            previews: s.notifications.previews)
        state.appearance = appearance
        return state
    }

    // MARK: - writing the app's saved state

    /// Reads Android's fixture from `fixtureDirectory`, refuses unless its manifest is
    /// `expectedSHA256`, writes the app's saved state into `output` through the core's own
    /// `.persist`, then loads it back through the core's own `load` and refuses unless every row
    /// came back as the fixture has it.
    public static func write(fixtureDirectory: URL, expectedSHA256: String, into output: URL) async throws -> Report {
        var files: [String: Data] = [:]
        for name in fixtureFiles {
            let url = fixtureDirectory.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: url) else { throw Refusal("no fixture file \(url.path)") }
            files[name] = data
        }
        let manifest = manifestSHA256(files)
        guard manifest == expectedSHA256.lowercased() else {
            throw Refusal("the fixture files' SHA-256 manifest is \(manifest), not the expected \(expectedSHA256)")
        }
        let seeded = try Self.state(session: files["session.json"]!, history: files["history.json"]!)
        let fm = FileManager.default
        var existing: [String] = []
        if fm.fileExists(atPath: output.path) { existing = try fm.contentsOfDirectory(atPath: output.path) }
        guard existing.isEmpty else {
            throw Refusal("\(output.path) is not empty; the saved state is written into an empty directory")
        }
        let storage = FileStorage(directory: output)
        try await EffectRunner(storage: storage).run([.persist], state: seeded)
        guard let loaded = try await EffectRunner(storage: storage).load() else {
            throw Refusal("the core loaded nothing from what it wrote")
        }
        func row(_ m: Message) -> [String] { [m.id, m.author.rawValue, m.text, String(m.sentAt), String(m.cursor ?? -1)] }
        guard loaded.pairing == .paired, loaded.consentGiven, loaded.mac == seeded.mac, loaded.outbox.isEmpty,
              loaded.messages.count == seeded.messages.count, loaded.messages.map(row) == seeded.messages.map(row) else {
            throw Refusal("the core loaded \(loaded.messages.count) of the fixture's \(seeded.messages.count) rows, or a "
                          + "different pairing (the app keeps at most \(EffectRunner.cachedMessages) messages in its saved history)")
        }
        guard loaded.screen == .conversation else { throw Refusal("the loaded state opens on \(loaded.screen.rawValue), not the conversation") }
        var written: [String: String] = [:]
        for name in try fm.contentsOfDirectory(atPath: output.path).sorted() {
            written[name] = sha256(try Data(contentsOf: output.appendingPathComponent(name)))
        }
        return Report(fixture: fixtureName, fixtureSha256: manifest,
                      fixtureFiles: files.mapValues { sha256($0) }, rows: loaded.messages.count, written: written,
                      origin: seeded.mac!.origin, threadID: seeded.mac!.threadID!, newestID: loaded.messages.last!.id,
                      deviceID: nil,
                      mac: "unreachable: the pairing names a host under .invalid and no device id, so the app reads no "
                           + "key and opens no connection")
    }
}
