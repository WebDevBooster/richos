import Foundation
import ImageIO
import UniformTypeIdentifiers

// Compiled into the app, the Share extension, and the macOS platform tests.

/// Makes a shared photo something Rich can read. The Mac stores HEIC as HEIC, and the model behind
/// Rich reads JPEG, PNG, GIF and WebP only (Echo, `cc/echo-opus-m1` 22e59ed8: "phones should send
/// JPEG at <= 2576 px long edge"). So a HEIC or HEIF photo becomes a JPEG no longer than
/// `AttachmentRules.photoLongEdge` on its long edge; every other accepted type is sent as it is.
///
/// This overrules round 12's gap A7 ("HEIC sent as the picker hands it"; "the engineers may
/// overrule this"), because a photo Rich cannot see is a photo that was not sent.
enum PhotoNormalizer {
    /// JPEG quality: the camera's own default neighborhood; a document photo stays legible.
    static let jpegQuality = 0.85

    /// The file to send and its media type. The input is not modified; a converted photo is written
    /// beside it in `directory`.
    static func normalize(_ url: URL, mediaType: String, suggestedName: String?, directory: URL) throws -> StagedShareFile {
        guard mediaType == "image/heic" || mediaType == "image/heif" else {
            return StagedShareFile(url: url, suggestedName: suggestedName, mediaType: mediaType)
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { throw ShareInboxError.unsupported(fileName: suggestedName ?? "photo") }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,   // apply the camera's orientation
            kCGImageSourceThumbnailMaxPixelSize: AttachmentRules.photoLongEdge,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw ShareInboxError.unsupported(fileName: suggestedName ?? "photo")
        }
        let base = URL(fileURLWithPath: suggestedName ?? "photo").deletingPathExtension().lastPathComponent
        let output = directory.appendingPathComponent("\(UUID().uuidString.lowercased())-\(base).jpg")
        guard let destination = CGImageDestinationCreateWithURL(output as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw ShareInboxError.unsupported(fileName: suggestedName ?? "photo")
        }
        // No location or other metadata is copied: only the pixels go to the Mac.
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: jpegQuality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw ShareInboxError.unsupported(fileName: suggestedName ?? "photo") }
        return StagedShareFile(url: output, suggestedName: "\(base).jpg", mediaType: "image/jpeg")
    }
}
