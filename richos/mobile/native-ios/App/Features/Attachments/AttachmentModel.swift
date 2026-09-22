import Foundation

// Photos and files to Rich (ceo-decisions §75: "Photos and files to Rich, including sharing into Rich
// from other apps: yes, in the first version"), as the screens draw them (round-12
// `attachments-NOTES.md`). The core owns the outbox, upload and limits (stream I1, with the Mac's
// intake from stream M); these are the shapes the views read.

extension ScreenModel {
    struct Attach: Equatable, Sendable {
        /// The + menu is open (`att-menu`).
        var menuOpen = false
        /// Waiting in the composer's tray, in the order chosen (`att-pending-*`).
        var pending: [PendingItem] = []
        /// A photo or file opened full screen (`att-viewer`, `att-viewer-file`).
        var viewer: Viewer?
        /// A system picker the menu handed off to (`att-pick-photos`, `att-pick-files`, `att-pick-camera`).
        var picker: Picker?
        /// Round 12's proposals, to be replaced by what the Mac's intake enforces (NOTES "Gaps" A1, A2).
        static let itemLimit = 10
        static let bytesLimit = 100 * 1_000_000
    }

    enum Picker: Equatable, Sendable { case photos, camera, files }

    struct AttachPhoto: Equatable, Identifiable, Sendable {
        enum Source: Equatable, Sendable {
            /// A drawn Debug scene (`PhotoScene`).
            case scene(String)
            /// A staged image file on this phone.
            case file(URL)
        }
        var id: String
        var source: Source
        /// Width over height, for the album layout (clamped 3:4 … 4:3 for a single photo).
        var aspect: Double = 4.0 / 3.0
        var label: String = "Photo"
    }

    struct AttachFile: Equatable, Identifiable, Sendable {
        var id: String
        var name: String
        /// Upper-case extension, "PDF".
        var ext: String
        var bytes: Int
        var pages: Int?

        /// "PDF · 2.4 MB · 14 pages".
        var summary: String {
            var parts = [ext, AttachFile.size(bytes)]
            if let pages { parts.append(pages == 1 ? "1 page" : "\(pages) pages") }
            return parts.joined(separator: " · ")
        }

        static func size(_ bytes: Int) -> String {
            let mb = Double(bytes) / 1_000_000
            if mb >= 10 { return "\(Int(mb.rounded())) MB" }
            if mb >= 1 { return String(format: "%.1f MB", mb) }
            return "\(max(1, Int((Double(bytes) / 1000).rounded()))) KB"
        }
    }

    enum PendingItem: Equatable, Identifiable, Sendable {
        case photo(AttachPhoto)
        case file(AttachFile)
        var id: String {
            switch self {
            case .photo(let p): return p.id
            case .file(let f): return f.id
            }
        }
    }

    /// What Rich's answer quotes: the message it is about.
    struct Reference: Equatable, Sendable {
        enum Kind: Equatable, Sendable {
            case photos([AttachPhoto])
            case file(AttachFile)
        }
        var messageID: String
        var kind: Kind
        var sentAt: Int64
    }

    struct Viewer: Equatable, Sendable {
        var messageID: String
        var index: Int
    }
}
