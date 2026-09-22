import Foundation
import UniformTypeIdentifiers

/// Reads what the host app shared into files this extension owns.
///
/// A provider's file URL is valid only inside its callback, so each file is copied into the
/// extension's own temporary directory there. Size is read from the provider's file before copying,
/// so a file the Mac would refuse (over 25 MiB) is reported by name and size without being copied.
struct SharePayloadLoader: Sendable {
    struct Loaded: Sendable {
        var files: [StagedShareFile] = []
        /// Accepted types that are too large: name and size, for `share-too-large`.
        var tooLarge: [(name: String, bytes: Int)] = []
        /// Items of a type the Mac does not take (the activation rule should keep these away).
        var unsupported = 0
        /// More than the Mac takes in one message.
        var overLimit = 0
    }

    /// Where staged files go; removed by the caller when the sheet closes.
    let directory: URL

    func load(_ providers: [NSItemProvider]) async -> Loaded {
        var loaded = Loaded()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for provider in providers {
            guard let (identifier, mediaType) = Self.acceptedType(of: provider) else {
                loaded.unsupported += 1
                continue
            }
            guard loaded.files.count + loaded.tooLarge.count < AttachmentRules.maxFilesPerMessage else {
                loaded.overLimit += 1
                continue
            }
            switch await copy(provider, identifier: identifier) {
            case .copied(let url, let name):
                do {
                    loaded.files.append(try PhotoNormalizer.normalize(url, mediaType: mediaType, suggestedName: name, directory: directory))
                } catch {
                    loaded.unsupported += 1
                }
            case .tooLarge(let name, let bytes):
                loaded.tooLarge.append((name, bytes))
            case .failed:
                loaded.unsupported += 1
            }
        }
        return loaded
    }

    /// The first type the provider offers that the Mac accepts, in the provider's own order (the
    /// original representation comes first: a camera photo's HEIC before a derived JPEG).
    static func acceptedType(of provider: NSItemProvider) -> (String, String)? {
        for identifier in provider.registeredTypeIdentifiers {
            if let mediaType = AttachmentRules.mediaType(forTypeIdentifier: identifier) { return (identifier, mediaType) }
        }
        return nil
    }

    private enum Copy: Sendable {
        case copied(URL, String?)
        case tooLarge(String, Int)
        case failed
    }

    private func copy(_ provider: NSItemProvider, identifier: String) async -> Copy {
        let suggested = provider.suggestedName
        let directory = self.directory
        return await withCheckedContinuation { continuation in
            _ = provider.loadFileRepresentation(forTypeIdentifier: identifier) { url, _ in
                guard let url else {
                    continuation.resume(returning: .failed)
                    return
                }
                let name = suggested.map { name -> String in
                    // Providers often suggest a name without the extension.
                    URL(fileURLWithPath: name).pathExtension.isEmpty && !url.pathExtension.isEmpty
                        ? "\(name).\(url.pathExtension)" : name
                } ?? url.lastPathComponent
                let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                guard bytes <= AttachmentRules.maxFileBytes else {
                    continuation.resume(returning: .tooLarge(name, bytes))
                    return
                }
                let target = directory.appendingPathComponent("\(UUID().uuidString.lowercased())-\(url.lastPathComponent)")
                do {
                    try FileManager.default.copyItem(at: url, to: target)
                    continuation.resume(returning: .copied(target, name))
                } catch {
                    continuation.resume(returning: .failed)
                }
            }
        }
    }
}
