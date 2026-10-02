import Foundation
import Testing
@testable import RichOSCore
@testable import RichOSPerfSeed

/// The start-time measurement's fixed conversation on iOS is Android's, row for row: the fixture
/// bytes come from `perf/condition.py` itself (never a copy that could drift), and what the core
/// writes is what the core loads back.
@Suite struct PerfSeedTests {
    static let perf = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("../../../../perf").standardizedFileURL

    /// condition.py writes FILE_FIXTURE with `rows` into a new directory; returns it and the
    /// manifest SHA-256 perf.py records as the condition's `conversation.sha256`.
    static func androidFixture(rows: Int) throws -> (URL, String) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("perfseed-fixture-\(UUID().uuidString)")
        let script = """
        import sys; sys.path.insert(0, sys.argv[1]); import condition
        condition.write_fixture(int(sys.argv[2]), sys.argv[3])
        print(condition.for_files(int(sys.argv[2]), "release", "test")["conversation"]["sha256"])
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", "-c", script, perf.path, String(rows), dir.path]
        process.environment = ProcessInfo.processInfo.environment.merging(["PYTHONDONTWRITEBYTECODE": "1"]) { $1 }
        let out = Pipe()
        process.standardOutput = out
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0, "condition.py did not write the fixture")
        return (dir, String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    static func emptyDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("perfseed-out-\(UUID().uuidString)")
    }

    @Test func writesExactlyAndroidsFixtureAsTheAppsSavedState() async throws {
        let (fixture, manifest) = try Self.androidFixture(rows: 100)
        let out = Self.emptyDirectory()
        defer { try? FileManager.default.removeItem(at: fixture); try? FileManager.default.removeItem(at: out) }
        let report = try await PerfSeed.write(fixtureDirectory: fixture, expectedSHA256: manifest, into: out)
        // The bytes andy-opus-coldstart1's genstate.py produced (mobile-perf.test.py C2 pins the same).
        #expect(report.fixtureFiles == ["session.json": "02d1ed15a951637d5e4732a27af47f9ba7dd86a763c6672827899a0dcf72529f",
                                        "history.json": "b17f4c2b62260ecd699a3e639c8f0b4b908e34dc18ba62bc87635b19a269fa0b"])
        #expect(report.fixtureSha256 == manifest && report.fixture == "synthetic-conversation/1")
        #expect(report.rows == 100 && report.newestID == "row-00099" && report.deviceID == nil)
        #expect(report.origin == "https://coldstart-perf.invalid" && report.threadID == "perf-thread")
        #expect(Set(report.written.keys) == [EffectRunner.stateKey, EffectRunner.historyKey])
        for (name, sha) in report.written {
            #expect(PerfSeed.sha256(try Data(contentsOf: out.appendingPathComponent(name))) == sha)
        }
        // What the app will load: every fixture row, in order, as the app's own messages.
        let loaded = try #require(try await EffectRunner(storage: FileStorage(directory: out)).load())
        let rows = try JSONSerialization.jsonObject(with: Data(contentsOf: fixture.appendingPathComponent("history.json")))
        let fixtureRows = try #require(((rows as? [String: Any])?["rows"] as? [String: [[String: Any]]])?["perf-thread"])
        #expect(loaded.messages.map(\.id) == fixtureRows.map { $0["id"] as? String })
        #expect(loaded.messages.map(\.text) == fixtureRows.map { $0["text"] as? String })
        #expect(loaded.messages.map(\.author) == fixtureRows.map { ($0["role"] as? String) == "ceo" ? .me : .rich })
        #expect(loaded.messages.map(\.cursor) == fixtureRows.map { $0["cursor"] as? Int })
        #expect(loaded.screen == .conversation && loaded.pairing == .paired && loaded.outbox.isEmpty && loaded.draft.isEmpty)
        #expect(loaded.mac?.deviceID == nil && loaded.history.cached)
        // The newest CEO row, the one perf.py looks for on screen (condition.file_fixture_marker(100)).
        #expect(loaded.messages.last(where: { $0.author == .me })?.text == "Perf probe 50: what is on my plate this afternoon?")
    }

    @Test func refusesBytesThatAreNotTheFixtureAndWritesNothing() async throws {
        let (fixture, manifest) = try Self.androidFixture(rows: 100)
        let out = Self.emptyDirectory()
        defer { try? FileManager.default.removeItem(at: fixture); try? FileManager.default.removeItem(at: out) }
        let history = fixture.appendingPathComponent("history.json")
        var bytes = try Data(contentsOf: history)
        let at = try #require(bytes.firstRange(of: Data("Perf probe 50".utf8)))
        bytes.replaceSubrange(at, with: Data("Perf probe 51".utf8))
        try bytes.write(to: history)
        await #expect(throws: PerfSeed.Refusal.self) {
            try await PerfSeed.write(fixtureDirectory: fixture, expectedSHA256: manifest, into: out)
        }
        #expect(!FileManager.default.fileExists(atPath: out.path))
    }

    @Test func refusesAConversationTheAppWouldNotKeepWhole() async throws {
        // The app's saved history holds 100 messages: 120 rows would not all reach the screen.
        let (fixture, manifest) = try Self.androidFixture(rows: 120)
        let out = Self.emptyDirectory()
        defer { try? FileManager.default.removeItem(at: fixture); try? FileManager.default.removeItem(at: out) }
        let refusal = await #expect(throws: PerfSeed.Refusal.self) {
            try await PerfSeed.write(fixtureDirectory: fixture, expectedSHA256: manifest, into: out)
        }
        #expect(refusal?.description.contains("of the fixture's 120 rows") == true)
    }

    @Test func theMarkerNamesOnlyThisTarget() {
        #expect(PerfSeed.marker == "rios-perf-seed-fixture-writer")
    }
}
