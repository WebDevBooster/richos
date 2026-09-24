import AVFoundation
import CryptoKit
import PhotosUI
import RichOSCore
import UIKit
import UniformTypeIdentifiers

/// The + menu's three rows, on the iPhone (round 12.1 group 12): Apple's photo picker, which needs no
/// photo-library permission; Apple's camera, photo only; and Apple's document browser. What the person
/// chooses is staged into the app's attachment store and handed to the core as `attachmentsPicked`,
/// which checks it against the Mac's limits and puts it in the tray (`AttachmentPicking.swift`).
///
/// The Android twin's `Stager` (native-android `platform/Attachments.kt`) is the spec for staging: a
/// photo is sent as a JPEG no longer than 2,576 px on its long edge (a HEIC is converted, a camera
/// shot is encoded that way), every other file as it is; a file over the Mac's per-file limit is
/// refused before it is copied, so a huge file is never read into the app.
@MainActor
final class AttachmentPicker: NSObject {
    /// `<attachments>/pending/<id>-<name>`: the courier reads these paths, relative to the store.
    static let pendingFolder = "pending"

    private let directory: URL
    private let dispatch: (Action) -> Void
    private var limits = AttachmentLimits.macDefault
    /// The picker on screen retains this object only weakly; keep the delegate alive until it answers.
    private var presented: UIViewController?

    init(directory: URL, dispatch: @escaping (Action) -> Void) {
        self.directory = directory
        self.dispatch = dispatch
    }

    func present(_ source: AttachSource, maxCount: Int, limits: AttachmentLimits?) {
        self.limits = limits ?? .macDefault
        switch source {
        case .photos: presentPhotos(maxCount: maxCount)
        case .camera: presentCamera()
        case .files: presentFiles(multiple: maxCount > 1)
        }
    }

    // MARK: Photos (PHPicker: no library permission, numbered selection up to the room left)

    private func presentPhotos(maxCount: Int) {
        var configuration = PHPickerConfiguration()
        configuration.filter = .images
        configuration.selectionLimit = max(1, maxCount)
        configuration.selection = .ordered
        configuration.preferredAssetRepresentationMode = .current
        let picker = PHPickerViewController(configuration: configuration)
        picker.delegate = self
        show(picker)
    }

    // MARK: Camera (photo only; the permission is asked once, and a refusal becomes its card)

    private func presentCamera() {
        guard UIImagePickerController.isSourceTypeAvailable(.camera) else {
            dispatch(.attachPermissionDenied(.camera))
            return
        }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            openCamera()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                Task { @MainActor in
                    if granted { self.openCamera() } else { self.dispatch(.attachPermissionDenied(.camera)) }
                }
            }
        default:
            dispatch(.attachPermissionDenied(.camera))
        }
    }

    private func openCamera() {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.mediaTypes = [UTType.image.identifier]
        picker.cameraCaptureMode = .photo
        picker.delegate = self
        show(picker)
    }

    // MARK: Files (Apple's browser; the Mac's types are checked when staged, so a refusal has a name)

    private func presentFiles(multiple: Bool) {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: true)
        picker.allowsMultipleSelection = multiple
        picker.delegate = self
        show(picker)
    }

    private func show(_ controller: UIViewController) {
        guard let top = Self.topController() else { return }
        presented = controller
        top.present(controller, animated: true)
    }

    private static func topController() -> UIViewController? {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first { $0.activationState == .foregroundActive }
            ?? UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        var top = scene?.windows.first { $0.isKeyWindow }?.rootViewController ?? scene?.windows.first?.rootViewController
        while let next = top?.presentedViewController { top = next }
        return top
    }

    // MARK: Staging

    /// A picked item on disk (a provider's or the browser's temporary copy) with what is known about it.
    struct Picked: Sendable {
        var url: URL
        var name: String?
        var typeIdentifier: String?
    }

    /// Stages every item off the main thread, in the order chosen, then reports the staged files and
    /// each refusal. A refused item leaves nothing behind.
    nonisolated static func stage(_ items: [Picked], into directory: URL, limits: AttachmentLimits,
                                  newID: () -> String = { UUID().uuidString.lowercased() }) -> [Action] {
        var staged: [OutboxFile] = []
        var actions: [Action] = []
        let folder = directory.appendingPathComponent(pendingFolder, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for item in items {
            let fallback = "file"
            let proposed = ShareInbox.safeFileName(item.name ?? item.url.lastPathComponent, fallback: fallback)
            let identifier = item.typeIdentifier ?? UTType(filenameExtension: item.url.pathExtension)?.identifier ?? ""
            guard let mediaType = AttachmentRules.mediaType(forTypeIdentifier: identifier, accepting: limits.mediaTypes.isEmpty ? nil : limits.mediaTypes) else {
                actions.append(.attachmentRefused(name: proposed, bytes: nil, tooLarge: false))
                continue
            }
            // Over the limit before any copy: nothing is read. (A HEIC is checked again after it
            // becomes a JPEG, which is smaller.)
            let size = (try? item.url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            if !AttachmentRules.isPhoto(mediaType), size > limits.maxFileBytes {
                actions.append(.attachmentRefused(name: proposed, bytes: size, tooLarge: true))
                continue
            }
            do {
                let file = try stageOne(item.url, name: proposed, mediaType: mediaType, folder: folder, newID: newID())
                if file.byteCount > limits.maxFileBytes {
                    try? FileManager.default.removeItem(at: directory.appendingPathComponent(file.path))
                    actions.append(.attachmentRefused(name: file.name, bytes: file.byteCount, tooLarge: true))
                } else {
                    staged.append(file)
                }
            } catch {
                actions.append(.attachmentRefused(name: proposed, bytes: nil, tooLarge: false))
            }
        }
        if !staged.isEmpty { actions.insert(.attachmentsPicked(staged), at: 0) }
        return actions
    }

    /// One file into `pending/<id>-<name>`: a HEIC or HEIF photo becomes a JPEG (`PhotoNormalizer`,
    /// shared with the Share extension); everything else is copied as it is. Hashed as stored.
    nonisolated private static func stageOne(_ url: URL, name: String, mediaType: String, folder: URL, newID: String) throws -> OutboxFile {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("richos-stage-\(newID)", isDirectory: true)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }
        let normalized = try PhotoNormalizer.normalize(url, mediaType: mediaType, suggestedName: name, directory: work)
        let finalName = ShareInbox.safeFileName(normalized.suggestedName, fallback: name)
        let data = try Data(contentsOf: normalized.url)
        let relative = "\(pendingFolder)/\(newID)-\(finalName)"
        try data.write(to: folder.deletingLastPathComponent().appendingPathComponent(relative), options: .atomic)
        return OutboxFile(id: newID, name: finalName, mediaType: normalized.mediaType, byteCount: data.count,
                          sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(), path: relative)
    }

    /// A camera shot: JPEG at no more than 2,576 px on its long edge, orientation applied (Android
    /// `ImageScale`: never upscaled, aspect kept, quality 0.85).
    nonisolated static func jpeg(_ image: UIImage, maxLongEdge: CGFloat = CGFloat(AttachmentRules.photoLongEdge)) -> Data? {
        let size = image.size
        let long = max(size.width, size.height)
        let scale = long > maxLongEdge ? maxLongEdge / long : 1
        let target = CGSize(width: max(1, (size.width * scale).rounded()), height: max(1, (size.height * scale).rounded()))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let drawn = UIGraphicsImageRenderer(size: target, format: format).image { _ in image.draw(in: CGRect(origin: .zero, size: target)) }
        return drawn.jpegData(compressionQuality: PhotoNormalizer.jpegQuality)
    }

    private func finish(_ items: [Picked], cleanup: [URL] = []) {
        let directory = self.directory, limits = self.limits, dispatch = self.dispatch
        Task.detached(priority: .userInitiated) {
            let actions = Self.stage(items, into: directory, limits: limits)
            for url in cleanup { try? FileManager.default.removeItem(at: url) }
            await MainActor.run { actions.forEach(dispatch) }
        }
    }
}

extension AttachmentPicker: PHPickerViewControllerDelegate {
    nonisolated func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        Task { @MainActor in
            picker.dismiss(animated: true)
            self.presented = nil
            guard !results.isEmpty else { return }
            // A provider's file exists only inside its callback: copy each out first, in order.
            let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("richos-picked-\(UUID().uuidString)", isDirectory: true)
            try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
            var picked: [Picked?] = Array(repeating: nil, count: results.count)
            await withTaskGroup(of: (Int, Picked?).self) { group in
                for (index, result) in results.enumerated() {
                    let provider = result.itemProvider
                    let identifier = provider.registeredTypeIdentifiers.first { UTType($0)?.conforms(to: .image) == true } ?? UTType.image.identifier
                    group.addTask {
                        await withCheckedContinuation { continuation in
                            provider.loadFileRepresentation(forTypeIdentifier: identifier) { url, _ in
                                guard let url else { continuation.resume(returning: (index, nil)); return }
                                let copy = scratch.appendingPathComponent("\(index)-\(url.lastPathComponent)")
                                let ok = (try? FileManager.default.copyItem(at: url, to: copy)) != nil
                                continuation.resume(returning: (index, ok ? Picked(url: copy, name: provider.suggestedName.map { "\($0).\(url.pathExtension)" } ?? url.lastPathComponent, typeIdentifier: identifier) : nil))
                            }
                        }
                    }
                }
                for await (index, item) in group { picked[index] = item }
            }
            self.finish(picked.compactMap { $0 }, cleanup: [scratch])
        }
    }
}

extension AttachmentPicker: UIImagePickerControllerDelegate, UINavigationControllerDelegate {
    nonisolated func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
        let image = info[.originalImage] as? UIImage
        Task { @MainActor in
            picker.dismiss(animated: true)
            self.presented = nil
            guard let image, let data = Self.jpeg(image) else { return }
            let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("richos-camera-\(UUID().uuidString).jpg")
            guard (try? data.write(to: scratch, options: .atomic)) != nil else { return }
            let stamp = Self.photoName(Date())
            self.finish([Picked(url: scratch, name: stamp, typeIdentifier: UTType.jpeg.identifier)], cleanup: [scratch])
        }
    }

    nonisolated func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
        Task { @MainActor in
            picker.dismiss(animated: true)
            self.presented = nil
        }
    }

    /// "Photo 2026-09-24 08.41.jpg": readable on the Mac, no camera roll name to leak.
    nonisolated static func photoName(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm"
        return "Photo \(formatter.string(from: date)).jpg"
    }
}

extension AttachmentPicker: UIDocumentPickerDelegate {
    nonisolated func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        // `asCopy: true`: these are the app's own temporary copies, removed once staged.
        let items = urls.map { Picked(url: $0, name: $0.lastPathComponent, typeIdentifier: (try? $0.resourceValues(forKeys: [.contentTypeKey]))?.contentType?.identifier) }
        Task { @MainActor in
            self.presented = nil
            self.finish(items, cleanup: urls)
        }
    }

    nonisolated func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        Task { @MainActor in self.presented = nil }
    }
}
