import RichOSCore
import UIKit
import XCTest

/// Staging what Apple's pickers hand back (the + menu, App Store blocker 5): into
/// `pending/<id>-<name>`, hashed as stored, a refusal for a type or size the Mac will not take, and
/// nothing left behind for a refused item.
@MainActor
final class AttachmentPickerTests: XCTestCase {
    private var root: URL!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("picker-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func write(_ name: String, bytes: Int) throws -> URL {
        let url = root.appendingPathComponent("in-\(name)")
        try Data(repeating: 0x25, count: bytes).write(to: url)
        return url
    }

    func testAPDFIsStagedWithItsHashAndPath() throws {
        let store = root.appendingPathComponent("store", isDirectory: true)
        let pdf = try write("Brief.pdf", bytes: 1_234)
        let actions = AttachmentPicker.stage([.init(url: pdf, name: "Brief.pdf", typeIdentifier: "com.adobe.pdf")],
                                             into: store, limits: .macDefault, newID: { "abc" })
        guard case .attachmentsPicked(let files)? = actions.first, let file = files.first else { return XCTFail("\(actions)") }
        XCTAssertEqual(file.path, "pending/abc-Brief.pdf")
        XCTAssertEqual(file.mediaType, "application/pdf")
        XCTAssertEqual(file.byteCount, 1_234)
        XCTAssertEqual(file.sha256.count, 64)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.appendingPathComponent(file.path).path))
    }

    func testAZipIsRefusedByNameAndNothingIsStaged() throws {
        let store = root.appendingPathComponent("store", isDirectory: true)
        let zip = try write("Archive.zip", bytes: 10)
        let actions = AttachmentPicker.stage([.init(url: zip, name: "Archive.zip", typeIdentifier: "public.zip-archive")],
                                             into: store, limits: .macDefault)
        XCTAssertEqual(actions, [.attachmentRefused(name: "Archive.zip", bytes: nil, tooLarge: false)])
        XCTAssertEqual((try? FileManager.default.contentsOfDirectory(atPath: store.appendingPathComponent("pending").path)) ?? [], [])
    }

    func testAFileOverTheMacsLimitIsRefusedBeforeItIsCopied() throws {
        let store = root.appendingPathComponent("store", isDirectory: true)
        let big = try write("Lease.pdf", bytes: AttachmentLimits.macDefault.maxFileBytes + 1)
        let actions = AttachmentPicker.stage([.init(url: big, name: "Lease.pdf", typeIdentifier: "com.adobe.pdf")],
                                             into: store, limits: .macDefault)
        XCTAssertEqual(actions, [.attachmentRefused(name: "Lease.pdf", bytes: AttachmentLimits.macDefault.maxFileBytes + 1, tooLarge: true)])
        XCTAssertEqual((try? FileManager.default.contentsOfDirectory(atPath: store.appendingPathComponent("pending").path)) ?? [], [])
    }

    func testACameraShotIsAJPEGNoLongerThan2576Pixels() throws {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 4032, height: 3024)).image { context in
            UIColor.systemTeal.setFill(); context.fill(CGRect(x: 0, y: 0, width: 4032, height: 3024))
        }
        let data = try XCTUnwrap(AttachmentPicker.jpeg(image))
        let decoded = try XCTUnwrap(UIImage(data: data))
        XCTAssertEqual(max(decoded.size.width * decoded.scale, decoded.size.height * decoded.scale), 2576, accuracy: 1)
        XCTAssertEqual(data.prefix(2), Data([0xFF, 0xD8]), "a JPEG")
    }

    func testThePhotoNameIsAReadableDateNotACameraRollName() {
        let date = Date(timeIntervalSince1970: 1_790_000_000)
        XCTAssertTrue(AttachmentPicker.photoName(date).hasPrefix("Photo 20"))
        XCTAssertTrue(AttachmentPicker.photoName(date).hasSuffix(".jpg"))
    }
}
