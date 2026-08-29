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
        XCTAssertEqual(z.path, "/Users/tester/RichOS/corpus/person/unfiled/evidence/meetings")
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
        XCTAssertEqual(z.path, "/Users/tester/other-corpus/person/unfiled/evidence/meetings")
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
        XCTAssertEqual(z.path, "/Users/tester/RichOS/corpus/person/unfiled/evidence/meetings")
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

    /// `..` must not walk back in unnoticed — the check is lexical, so it has to normalise first.
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
}
