import RichOSCore
import SwiftUI
import UniformTypeIdentifiers
import XCTest

/// The Share to Rich sheet's model and view, on a simulator, with the extension's own sources
/// compiled into this bundle (Release/platform.yml, target RichOSPlatformTests). What the platform
/// tests on the Mac cannot reach: NSItemProvider loading, the model's phases, and the SwiftUI sheet
/// actually rendering. Each rendered state is written as a PNG when `RICHOS_SNAPSHOT_DIR` is set
/// (the suite sets it through `TEST_RUNNER_RICHOS_SNAPSHOT_DIR`).
@MainActor
final class ShareSheetTests: XCTestCase {
    private var container: URL!
    private var inbox: ShareInbox!

    override func setUp() async throws {
        container = FileManager.default.temporaryDirectory.appendingPathComponent("share-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        inbox = ShareInbox(container: container)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: container)
    }

    private func pair(appearance: String = "dark") throws {
        try ShareContext(paired: true, macName: "Alex’s Mac", threadID: "thr_5c1e", macAcceptsAttachments: true,
                         appearance: appearance).write(container: container)
    }

    private func file(_ name: String, bytes: Int, fill: UInt8 = 7) throws -> URL {
        let url = container.appendingPathComponent(name)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(bytes))   // sparse: a 26 MiB file costs nothing
        try handle.close()
        if bytes <= 4096 { try Data(repeating: fill, count: bytes).write(to: url) }
        return url
    }

    private func jpeg(_ name: String, width: Int = 1200, height: Int = 900) throws -> URL {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: {
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            return format
        }())
        let image = renderer.image { context in
            UIColor(red: 0.30, green: 0.45, blue: 0.62, alpha: 1).setFill()
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            UIColor(red: 0.85, green: 0.72, blue: 0.40, alpha: 1).setFill()
            context.fill(CGRect(x: width / 4, y: height / 3, width: width / 2, height: height / 3))
        }
        let url = container.appendingPathComponent(name)
        try XCTUnwrap(image.jpegData(compressionQuality: 0.9)).write(to: url)
        return url
    }

    private func provider(_ url: URL, type: UTType) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.registerFileRepresentation(forTypeIdentifier: type.identifier, fileOptions: [], visibility: .all) { completion in
            completion(url, false, nil)
            return nil
        }
        provider.suggestedName = url.deletingPathExtension().lastPathComponent
        return provider
    }

    private func model(transport: (any MacRequests)?, finished: XCTestExpectation? = nil) -> ShareModel {
        ShareModel(inbox: inbox, transport: transport) { finished?.fulfill() }
    }

    /// Renders the sheet as the extension shows it (402 × 874 pt, the round-12 phone) and writes it.
    private func snapshot(_ model: ShareModel, _ name: String, appearance: Appearance = .dark) throws {
        let view = ShareSheetView(model: model).palette(Palette.for(appearance)).frame(width: 402, height: 874)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 3
        let image = try XCTUnwrap(renderer.uiImage, "the sheet did not render")
        XCTAssertEqual(image.size, CGSize(width: 402, height: 874))
        guard let directory = ProcessInfo.processInfo.environment["RICHOS_SNAPSHOT_DIR"] else { return }
        let url = URL(fileURLWithPath: directory).appendingPathComponent("\(name)-\(appearance.rawValue).png")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try XCTUnwrap(image.pngData()).write(to: url)
    }

    func testUnpairedPhoneIsToldToPairFirst() async throws {
        let model = model(transport: nil)
        await model.load([provider(try jpeg("a.jpg"), type: .jpeg)])
        XCTAssertEqual(model.phase, .unpaired)
        try snapshot(model, "share-unpaired")
    }

    func testOnePhotoComposesWithTheMacNamed() async throws {
        try pair()
        let model = model(transport: nil)
        await model.load([provider(try jpeg("IMG_0042.jpg"), type: .jpeg)])
        XCTAssertEqual(model.phase, .compose)
        XCTAssertEqual(model.photoCount, 1)
        XCTAssertTrue(model.canSend)
        XCTAssertEqual(model.context.macName, "Alex’s Mac")
        try snapshot(model, "share-compose")
        try snapshot(model, "share-compose", appearance: .light)
    }

    func testThreePhotosFanWithACount() async throws {
        try pair()
        let model = model(transport: nil)
        await model.load(try (1...3).map { provider(try jpeg("IMG_\($0).jpg", width: $0 == 2 ? 900 : 1200, height: $0 == 2 ? 1200 : 900), type: .jpeg) })
        XCTAssertEqual(model.photoCount, 3)
        try snapshot(model, "share-compose-many")
    }

    func testAPDFShowsItsCard() async throws {
        try pair()
        let model = model(transport: nil)
        await model.load([provider(try file("Q3 plan.pdf", bytes: 2_400_000), type: .pdf)])
        XCTAssertEqual(model.phase, .compose)
        XCTAssertEqual(model.previews.first?.mediaType, "application/pdf")
        try snapshot(model, "share-compose-file")
    }

    func testAFileOverTheMacsLimitCannotBeSent() async throws {
        try pair()
        let model = model(transport: nil)
        await model.load([provider(try file("Board deck.pdf", bytes: AttachmentLimits.macDefault.maxFileBytes + 1), type: .pdf)])
        XCTAssertEqual(model.tooLarge?.name, "Board deck.pdf")
        XCTAssertFalse(model.canSend, "Send is off for share-too-large")
        let limit = AttachmentLimits.macDefault.maxFileBytes
        XCTAssertEqual(ShareSheetView.tooLargeReason(bytes: limit + 1, limit: limit),
                       "Rich can take files up to 25 MB each; this one is just over that. Send a smaller part of it, or share it from your Mac.",
                       "a file one byte over never reads as the same size as the limit")
        XCTAssertTrue(ShareSheetView.tooLargeReason(bytes: 40 * 1_048_576, limit: limit).contains("this one is 40 MB"))
        try snapshot(model, "share-too-large")
    }

    /// The sheet's staging directories (`share-<uuid>` under this process's temporary directory;
    /// the test's own container is `share-tests-<uuid>`).
    private func stagingDirectories() -> [URL] {
        let tmp = FileManager.default.temporaryDirectory
        let names = (try? FileManager.default.contentsOfDirectory(atPath: tmp.path)) ?? []
        return names.filter { $0.hasPrefix("share-") && !$0.hasPrefix("share-tests-") }.map { tmp.appendingPathComponent($0) }
    }

    /// Every entry the loader kept in its staging directories. Links are counted, never followed.
    private func stagedEntries() -> [String] {
        stagingDirectories().flatMap { directory in
            ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).map { "\(directory.lastPathComponent)/\($0)" }
        }
    }

    private func clearStaging() {
        stagingDirectories().forEach { try? FileManager.default.removeItem(at: $0) }
    }

    /// Security review I-3: a provider whose item reports no size (here a package directory posing
    /// as a PDF, which `NSItemProvider` hands over as it is, with no file size) is never counted as
    /// zero bytes and copied whole. It cannot be sent and nothing of it is kept.
    func testAnItemThatReportsNoSizeIsNotCopied() async throws {
        try pair()
        clearStaging()
        let package = container.appendingPathComponent("Board deck.pdf", isDirectory: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        let inner = try file("inner.bin", bytes: AttachmentLimits.macDefault.maxFileBytes + 1)
        try FileManager.default.moveItem(at: inner, to: package.appendingPathComponent("inner.bin"))
        XCTAssertNil(try package.resourceValues(forKeys: [.fileSizeKey]).fileSize, "the item reports no size")
        let model = model(transport: nil)
        await model.load([provider(package, type: .pdf)])
        XCTAssertFalse(model.canSend, "nothing that was not measured can be sent")
        XCTAssertEqual(stagedEntries(), [], "nothing was copied")
        clearStaging()
    }

    /// Security review I-3: the size a provider reports is not what gets read. A link reports its
    /// own few bytes and leads to a file over the Mac's limit; it is never followed, so it cannot be
    /// sent and nothing of it is kept.
    func testAReportedSizeThatIsNotWhatWouldBeReadIsNotTrusted() async throws {
        try pair()
        clearStaging()
        let limit = AttachmentLimits.macDefault.maxFileBytes
        let target = try file("target.bin", bytes: limit + 1)
        let link = container.appendingPathComponent("Board deck.pdf")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        XCTAssertLessThan(try XCTUnwrap(link.resourceValues(forKeys: [.fileSizeKey]).fileSize), limit, "the reported size is small")
        let model = model(transport: nil)
        await model.load([provider(link, type: .pdf)])
        XCTAssertFalse(model.canSend, "what was not measured cannot be sent")
        XCTAssertEqual(stagedEntries(), [], "nothing was kept")
        clearStaging()
    }

    /// The limit is the size of what is opened and read, and a file just under it still goes.
    func testAFileAtTheMacsLimitIsKept() async throws {
        try pair()
        clearStaging()
        let limit = AttachmentLimits.macDefault.maxFileBytes
        let model = model(transport: nil)
        await model.load([provider(try file("Exactly the limit.pdf", bytes: limit), type: .pdf)])
        XCTAssertTrue(model.canSend)
        XCTAssertNil(model.tooLarge)
        XCTAssertEqual(model.previews.first?.bytes, limit)
        clearStaging()
    }

    func testWithoutASignedConnectionTheShareIsSavedNeverSent() async throws {
        try pair()
        let finished = expectation(description: "the sheet leaves")
        let model = model(transport: nil, finished: finished)
        await model.load([provider(try jpeg("IMG_1.jpg"), type: .jpeg)])
        model.caption = "For the invite"
        model.send()
        try await waitForDone(model)
        XCTAssertEqual(model.phase, .done(.saved(.cannotSendHere)))
        try snapshot(model, "share-saved")
        let saved = try XCTUnwrap(inbox.loadAll().first)
        XCTAssertEqual(saved.delivery, .saved, "kept for the app to send")
        XCTAssertEqual(saved.caption, "For the invite")
        await fulfillment(of: [finished], timeout: 5)
    }

    func testTheMacsAcceptanceIsTheOnlySent() async throws {
        try pair()
        let mac = AcceptingMac()
        let model = model(transport: mac)
        await model.load([provider(try jpeg("IMG_1.jpg"), type: .jpeg)])
        model.send()
        try await waitForDone(model)
        XCTAssertEqual(model.phase, .done(.sent))
        XCTAssertEqual(mac.targets.count, 2, "one upload, one commit")
        XCTAssertEqual(mac.targets.last, "/api/messages")
        if case .sent = try XCTUnwrap(inbox.loadAll().first).delivery {} else { XCTFail("the inbox records the acceptance") }
        try snapshot(model, "share-sent")
    }

    private func waitForDone(_ model: ShareModel) async throws {
        for _ in 0..<100 {
            if case .done = model.phase { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTFail("the sheet never finished (phase \(model.phase))")
    }
}

/// A Mac that accepts every upload and every commit.
final class AcceptingMac: MacRequests, @unchecked Sendable {
    private let lock = NSLock()
    private var seen: [String] = []
    var targets: [String] { lock.lock(); defer { lock.unlock() }; return seen }
    func send(_ method: String, _ target: String, body: Data, contentType: String) async throws -> HTTPResponse {
        record(target)
        return HTTPResponse(status: 200, body: Data(#"{"duplicate":false}"#.utf8))
    }
    private func record(_ target: String) {
        lock.lock(); defer { lock.unlock() }
        seen.append(target)
    }
}
