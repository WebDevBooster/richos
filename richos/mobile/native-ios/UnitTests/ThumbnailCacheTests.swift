import Foundation
import Testing
import UIKit
@testable import RichOSNative

@MainActor struct ThumbnailCacheTests {
    @Test func downsampleAndInvalidateDeletedFile() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let bytes = UIGraphicsImageRenderer(size: CGSize(width: 2_048, height: 1_024), format: format).pngData { context in
            UIColor.red.setFill(); context.fill(CGRect(x: 0, y: 0, width: 2_048, height: 1_024))
        }
        try bytes.write(to: url)
        let cache = ThumbnailCache()
        let image = try #require(await cache.image(for: url))
        #expect(image.size.width <= 1_024 && image.size.height <= 1_024)
        try FileManager.default.removeItem(at: url)
        #expect(await cache.image(for: url) == nil)
    }
}
