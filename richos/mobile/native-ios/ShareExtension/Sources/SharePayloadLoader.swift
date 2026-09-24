import Foundation
import RichOSCore
import UniformTypeIdentifiers

/// Reads what the host app shared into files this extension owns.
///
/// A provider's file URL is valid only inside its callback, so each file is copied into the
/// extension's own temporary directory there. The Mac's limits hold while reading (`stage`): the size
/// of the opened file, never a size the provider reports, so a file the Mac would refuse (over
/// 25 MiB) is reported by name and size without being copied, and no more than the Mac's count of
/// files (10) is ever read.
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
    /// What the paired Mac advertised (or its published defaults).
    let limits: AttachmentLimits

    func load(_ providers: [NSItemProvider]) async -> Loaded {
        var loaded = Loaded()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for provider in providers {
            guard let (identifier, mediaType) = Self.acceptedType(of: provider, limits: limits) else {
                loaded.unsupported += 1
                continue
            }
            guard loaded.files.count + loaded.tooLarge.count < limits.maxFilesPerMessage else {
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
    static func acceptedType(of provider: NSItemProvider, limits: AttachmentLimits) -> (String, String)? {
        for identifier in provider.registeredTypeIdentifiers {
            if let mediaType = AttachmentRules.mediaType(forTypeIdentifier: identifier, accepting: limits.mediaTypes) { return (identifier, mediaType) }
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
        let maxFileBytes = limits.maxFileBytes
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
                let target = directory.appendingPathComponent("\(UUID().uuidString.lowercased())-\(url.lastPathComponent)")
                switch Self.stage(url, to: target, maxBytes: maxFileBytes) {
                case .copied: continuation.resume(returning: .copied(target, name))
                case .tooLarge(let bytes): continuation.resume(returning: .tooLarge(name, bytes))
                case .refused: continuation.resume(returning: .failed)
                }
            }
        }
    }

    enum Staged: Equatable {
        case copied
        /// Over `maxBytes`: the size of the file that was opened, or the bytes read before the read
        /// passed the limit. Nothing is kept.
        case tooLarge(Int)
        /// Not a regular file (a folder, a link, a pipe), or it could not be read. Nothing is kept.
        case refused
    }

    /// Copies `source` to `target` only if it is a regular file of at most `maxBytes`, enforcing the
    /// limit on what is opened and read, never on a size the provider reports (security review I-3:
    /// a provider that reports no size used to count as zero bytes, and was copied whole). A link is
    /// not followed and a folder is not copied. The size comes from the open file itself, and the copy
    /// stops as soon as more than `maxBytes` have been read, so a file that grows while it is read is
    /// refused too. At most one 1 MiB buffer is held: a Share extension's memory is small.
    static func stage(_ source: URL, to target: URL, maxBytes: Int) -> Staged {
        // A regular file only: not a folder, a link or a pipe (a link is not followed).
        guard (try? source.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { return .refused }
        // Non-blocking, so a pipe swapped in cannot hold the extension open; O_NOFOLLOW refuses a
        // link swapped in after the check above.
        let descriptor = open(source.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { return .refused }
        let input = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        // The size of the open file, by seeking to its end (not stat/fstat: those are file-timestamp
        // required-reason APIs, and the privacy manifest declares none; Release/check-release.sh R6).
        let end = lseek(descriptor, 0, SEEK_END)
        guard end >= 0, lseek(descriptor, 0, SEEK_SET) == 0 else { return .refused }
        let size = Int(end)
        guard size <= maxBytes else { return .tooLarge(size) }
        guard FileManager.default.createFile(atPath: target.path, contents: nil),
              let output = try? FileHandle(forWritingTo: target) else { return .refused }
        var read = 0
        let outcome: Staged
        do {
            while true {
                guard let chunk = try input.read(upToCount: 1 << 20), !chunk.isEmpty else {
                    outcome = .copied
                    break
                }
                read += chunk.count
                if read > maxBytes {
                    outcome = .tooLarge(read)
                    break
                }
                try output.write(contentsOf: chunk)
            }
        } catch {
            outcome = .refused
        }
        try? output.close()
        if outcome != .copied { try? FileManager.default.removeItem(at: target) }
        return outcome
    }
}
