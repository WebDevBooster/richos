import Foundation
import ImageIO
import Network
import Observation
import RichOSCore
import UIKit

/// The Share sheet's state (round-12 group 16/17 `share-*`), on the main actor because SwiftUI reads
/// it. Every decision that is not drawing lives in the shared, tested code: the inbox, the Mac's
/// limits and the 3-second rule (`App/Platform/Shared/`).
@MainActor
@Observable
final class ShareModel {
    enum Phase: Equatable {
        /// Reading what was shared (milliseconds; nothing is announced).
        case loading
        /// `share-compose`, `share-compose-many`, `share-compose-file`, `share-too-large`.
        case compose
        /// The Send pill is a spinner.
        case sending
        /// `share-sent` or `share-saved`; the sheet leaves after the hold.
        case done(ShareOutcome)
        /// `share-unpaired`.
        case unpaired
        /// Nothing the Mac can take was shared, or it could not be kept: the reason, plainly.
        case failed(String)
    }

    struct Preview: Identifiable {
        var id = UUID()
        var name: String
        var mediaType: String
        var bytes: Int
        /// A small decoded image for photos (never the full photo).
        var thumbnail: UIImage?
        var isPhoto: Bool { AttachmentRules.isPhoto(mediaType) }
    }

    private(set) var phase: Phase = .loading
    private(set) var previews: [Preview] = []
    /// The first file over the Mac's limit, for `share-too-large`.
    private(set) var tooLarge: (name: String, bytes: Int)?
    var caption = ""
    let context: ShareContext

    @ObservationIgnored private var staged: [StagedShareFile] = []
    @ObservationIgnored private let inbox: ShareInbox?
    @ObservationIgnored private let transport: (any MacRequests)?
    @ObservationIgnored private let stagingDirectory: URL
    @ObservationIgnored private let finish: @MainActor () -> Void

    var photoCount: Int { previews.filter(\.isPhoto).count }
    var canSend: Bool { phase == .compose && tooLarge == nil && !staged.isEmpty }

    /// `transport` is the core's signed connection when this build has one; `nil` means every share
    /// is saved for the app to send (and the sheet says so, `ShareOutcome.SavedReason.cannotSendHere`).
    init(inbox: ShareInbox?, transport: (any MacRequests)?, finish: @escaping @MainActor () -> Void) {
        self.inbox = inbox
        self.transport = transport
        self.finish = finish
        context = inbox.map { ShareContext.read(container: $0.container) } ?? .unpaired
        stagingDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("share-\(UUID().uuidString.lowercased())", isDirectory: true)
    }

    func load(_ providers: [NSItemProvider]) async {
        guard inbox != nil else {
            phase = .failed("RichOS could not open its shared storage on this iPhone. Open RichOS once, then share again.")
            return
        }
        guard context.paired, context.threadID != nil else {
            phase = .unpaired
            return
        }
        // The providers belong to this request; the loader is their only user from here on.
        nonisolated(unsafe) let providers = providers
        let loaded = await SharePayloadLoader(directory: stagingDirectory, limits: context.limits).load(providers)
        staged = loaded.files
        previews = loaded.files.map { file in
            Preview(name: file.suggestedName ?? file.url.lastPathComponent, mediaType: file.mediaType,
                    bytes: (try? file.url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0,
                    thumbnail: AttachmentRules.isPhoto(file.mediaType) ? Self.thumbnail(file.url) : nil)
        }
        if let first = loaded.tooLarge.first {
            tooLarge = first
            previews.append(Preview(name: first.name, mediaType: "application/octet-stream", bytes: first.bytes))
        }
        if staged.isEmpty && tooLarge == nil {
            phase = .failed("RichOS can send photos, PDFs, Word, Excel and PowerPoint files, and text files. Nothing shared here is one of those.")
            return
        }
        phase = .compose
    }

    func cancel() {
        cleanUp()
        finish()
    }

    /// Send: keep it on the phone first, then try the Mac for up to 3 s.
    func send() {
        guard canSend, let inbox, let threadID = context.threadID else { return }
        phase = .sending
        let files = staged
        let caption = caption
        Task {
            let now = Int64((Date().timeIntervalSince1970 * 1000).rounded())
            let envelope: ShareEnvelope
            do {
                envelope = try inbox.write(caption: caption, files: files, threadID: threadID, nowMs: now, limits: context.limits)
            } catch {
                phase = .failed("RichOS could not keep this on your iPhone, so nothing was sent. Try sharing it again.")
                return
            }
            let online = await Self.isOnline()
            var outcome = await ShareAttempt.run(envelope, inbox: inbox, transport: transport, online: online)
            if outcome == .sent {
                let sentAt = Int64((Date().timeIntervalSince1970 * 1000).rounded())
                // The Mac has it; if recording that fails, the app sends again and the Mac answers
                // "duplicate", so the sheet may still say Sent.
                _ = try? inbox.markSent(envelope, atMs: sentAt)
            } else if case .saved(.notConfirmed) = outcome, !online {
                outcome = .saved(.offline)
            }
            phase = .done(outcome)
            cleanUp()
            // round 12: the confirmation holds 1.7 s, then the sheet leaves.
            try? await Task.sleep(nanoseconds: 1_700_000_000)
            finish()
        }
    }

    private func cleanUp() {
        try? FileManager.default.removeItem(at: stagingDirectory)
    }

    /// The current path, answered once (the extension lives seconds; nothing is monitored).
    private static func isOnline() async -> Bool {
        await withCheckedContinuation { continuation in
            let monitor = NWPathMonitor()
            let once = OnceFlag()
            monitor.pathUpdateHandler = { path in
                guard once.take() else { return }
                monitor.cancel()
                continuation.resume(returning: path.status == .satisfied)
            }
            monitor.start(queue: DispatchQueue(label: "richos.share.path"))
        }
    }

    private static func thumbnail(_ url: URL) -> UIImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                        kCGImageSourceCreateThumbnailWithTransform: true,
                                        kCGImageSourceThumbnailMaxPixelSize: 720]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary).map { UIImage(cgImage: $0) }
    }
}

private final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var used = false
    func take() -> Bool {
        lock.lock(); defer { lock.unlock() }
        defer { used = true }
        return !used
    }
}
