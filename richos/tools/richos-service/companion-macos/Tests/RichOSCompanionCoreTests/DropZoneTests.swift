import XCTest
@testable import RichOSCompanionCore

/// The drop zone is where a recording the CEO cannot make again gets written. Every one of these
/// tests is named after the thing that goes wrong when it fails.
final class DropZoneTests: XCTestCase {

    private let home = "/Users/tester"
    private let repo = "/checkout/richos"

    // MARK: - The default must be the pipeline's default, not a second opinion

    func testUnconfiguredDefaultMatchesThePipelinesUnconfiguredDefault() throws {
        let z = try DropZone.resolve(explicit: nil, env: [:], home: home, productRepo: repo)
        XCTAssertEqual(z.path, "/Users/tester/RichOS/corpus/ceo/unfiled/evidence/meetings")
        XCTAssertEqual(z.source, .corpus)
        XCTAssertNil(z.company)
    }

    func testActiveCompanyPartitionsTheCorpusTheSameWayEvidenceRootDoes() throws {
        let z = try DropZone.resolve(
            explicit: nil, env: ["RICHOS_ACTIVE_COMPANY": "acme"], home: home, productRepo: repo)
        XCTAssertEqual(z.path, "/Users/tester/RichOS/corpus/companies/acme/evidence/meetings")
        XCTAssertEqual(z.company, "acme")
    }

    func testLoroCorpusMovesTheWholeTreeIncludingTilde() throws {
        let z = try DropZone.resolve(
            explicit: nil, env: ["LORO_CORPUS": "~/other-corpus"], home: home, productRepo: repo)
        XCTAssertEqual(z.path, "/Users/tester/other-corpus/ceo/unfiled/evidence/meetings")
    }

    // MARK: - Overrides, and which one wins

    func testExplicitZoneFlagBeatsTheEnvironment() throws {
        let z = try DropZone.resolve(
            explicit: "/tmp/explicit", env: ["RICHOS_DROP_ZONE": "/tmp/from-env"],
            home: home, productRepo: repo)
        XCTAssertEqual(z.path, "/tmp/explicit")
        XCTAssertEqual(z.source, .explicitFlag)
    }

    func testEnvironmentBeatsTheCorpusDefault() throws {
        let z = try DropZone.resolve(
            explicit: nil, env: ["RICHOS_DROP_ZONE": "~/zone"], home: home, productRepo: repo)
        XCTAssertEqual(z.path, "/Users/tester/zone")
        XCTAssertEqual(z.source, .environment)
    }

    /// An empty variable is a variable somebody meant to set and didn't. Treating "" as an override
    /// would resolve the zone to the current directory.
    func testEmptyOverridesAreIgnoredRatherThanObeyed() throws {
        let z = try DropZone.resolve(
            explicit: "", env: ["RICHOS_DROP_ZONE": "", "LORO_CORPUS": "  "],
            home: home, productRepo: repo)
        XCTAssertEqual(z.path, "/Users/tester/RichOS/corpus/ceo/unfiled/evidence/meetings")
    }

    // MARK: - The refusal. This is the one that stops a public leak.

    func testRefusesAZoneInsideTheProductRepo() {
        XCTAssertThrowsError(
            try DropZone.resolve(
                explicit: "/checkout/richos/wiki/raw/meetings", env: [:], home: home, productRepo: repo)
        ) { error in
            guard case DropZone.Failure.insideProductRepo = error else {
                return XCTFail("expected insideProductRepo, got \(error)")
            }
        }
    }

    func testRefusesTheRepoRootItself() {
        XCTAssertThrowsError(
            try DropZone.resolve(explicit: repo, env: [:], home: home, productRepo: repo))
    }

    /// `..` must not walk back in unnoticed — the check is lexical, so it has to normalize first.
    func testRefusesAZoneThatReachesBackIntoTheRepoViaDotDot() {
        XCTAssertThrowsError(
            try DropZone.resolve(
                explicit: "/checkout/richos/tools/../wiki/meetings", env: [:], home: home, productRepo: repo))
    }

    /// A sibling directory whose name merely starts with the repo path is NOT inside it.
    /// `/checkout/richos-notes` must not be refused because `/checkout/richos` is a prefix of it.
    func testASiblingSharingAPathPrefixIsNotInsideTheRepo() throws {
        let z = try DropZone.resolve(
            explicit: "/checkout/richos-notes/meetings", env: [:], home: home, productRepo: repo)
        XCTAssertEqual(z.path, "/checkout/richos-notes/meetings")
    }

    func testWithNoProductRepoThereIsNothingToBeInsideOf() throws {
        let z = try DropZone.resolve(
            explicit: "/checkout/richos/wiki/raw/meetings", env: [:], home: home, productRepo: nil)
        XCTAssertEqual(z.path, "/checkout/richos/wiki/raw/meetings")
    }

    // MARK: - Locating the repo

    func testSymlinkIntoProductIsRefusedBeforeCreatingAZone() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let product = root.appendingPathComponent("product")
        try FileManager.default.createDirectory(at: product.appendingPathComponent("docs"), withIntermediateDirectories: true)
        let alias = root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: product.appendingPathComponent("docs"))
        let target = alias.appendingPathComponent("new/recordings").path
        XCTAssertTrue(DropZone.isInside(target, product.path))
        XCTAssertThrowsError(try DropZone.resolve(explicit: target, env: [:], home: root.path, productRepo: product.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: product.appendingPathComponent("docs/new").path))
        // The protected root can itself be an alias.
        XCTAssertThrowsError(try DropZone.resolve(explicit: product.appendingPathComponent("docs/new/recordings").path,
                                                 env: [:], home: root.path, productRepo: alias.path))
    }

    func testSymlinkToExternalStorageRemainsUsable() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let outside = root.appendingPathComponent("private")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let alias = root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: outside)
        let target = alias.appendingPathComponent("new/recordings").path
        let result = try DropZone.resolve(explicit: target, env: [:], home: root.path,
                                          productRepo: root.appendingPathComponent("product").path)
        XCTAssertEqual(result.path, target)
    }

    func testUnresolvedLinksAreRefusedEvenWithoutAProductRoot() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let dangling = root.appendingPathComponent("dangling")
        let cycle = root.appendingPathComponent("cycle")
        try FileManager.default.createSymbolicLink(at: dangling, withDestinationURL: root.appendingPathComponent("missing"))
        try FileManager.default.createSymbolicLink(at: cycle, withDestinationURL: cycle)
        for alias in [dangling, cycle] {
            XCTAssertThrowsError(try DropZone.resolve(explicit: alias.appendingPathComponent("new/recordings").path,
                                                     env: [:], home: root.path, productRepo: nil))
        }
    }

    func testLocatesTheCheckoutByTheServiceCLIMarkerAndNotByADirectoryName() {
        let marker = "/checkout/richos/tools/richos-service/bin/richos-service.js"
        let found = DropZone.locateProductRepo(
            startingAt: "/checkout/richos/tools/richos-service/companion-macos/.build/debug"
        ) { $0 == marker }
        XCTAssertEqual(found, "/checkout/richos")
    }

    func testReturnsNilWhenTheBinaryLivesOutsideAnyCheckout() {
        let found = DropZone.locateProductRepo(startingAt: "/usr/local/bin") { _ in false }
        XCTAssertNil(found)
    }

    func testGroupedCheckoutProtectsTheOuterRepository() {
        let root = "/checkout/project"
        let marker = root + "/richos/tools/richos-service/bin/richos-service.js"
        for boundary in [".git", ".richos"] {
            for start in [root, root + "/docs", root + "/richos/tools/richos-service/companion-macos/.build/debug"] {
                let found = DropZone.locateProductRepo(startingAt: start) {
                    $0 == marker || $0 == root + "/" + boundary
                }
                XCTAssertEqual(found, root)
                for target in [root + "/docs/meetings", root + "/.richos/meetings", root + "/richos/tools/meetings"] {
                    XCTAssertThrowsError(try DropZone.resolve(
                        explicit: target, env: [:], home: home, productRepo: found))
                }
            }
        }
    }
}
