import Foundation
import RichOSCore

/// The app's side of "Share to Rich": it tells the Share extension what it needs to know (paired
/// or not, which Mac, which conversation, the appearance), and it takes shares the extension saved
/// into the app's own outbox.
///
/// Both halves are called from the store's wiring in `App/App` (stream I1; the exact lines are in
/// the I3 handoff). Nothing here writes the app's state file.
enum SharePlatform {
    /// What the extension reads, derived from the app's state. Pure, so the headless tests can
    /// check it against fixtures.
    static func context(for state: AppState, macAcceptsAttachments: Bool) -> ShareContext {
        let paired = state.pairing == .paired && state.consentGiven
        return ShareContext(paired: paired,
                            macName: paired ? state.mac?.name : nil,
                            threadID: paired ? state.mac?.threadID : nil,
                            macAcceptsAttachments: paired && macAcceptsAttachments,
                            appearance: state.appearance.rawValue)
    }

    /// Writes the context when it changed. Called after every state change; cheap when nothing did.
    static func mirror(_ state: AppState, macAcceptsAttachments: Bool, inbox: ShareInbox? = .shared) {
        guard let inbox else { return }
        let next = context(for: state, macAcceptsAttachments: macAcceptsAttachments)
        guard ShareContext.read(container: inbox.container) != next else { return }
        try? next.write(container: inbox.container)
    }

    /// Shares waiting for the app, oldest first, after removing any the extension died writing.
    /// The core takes each into its outbox with the envelope's own identifiers and commit bytes
    /// (so a share the Mac already accepted comes back `duplicate`, never twice), then the app
    /// calls `taken(_:)`.
    static func waiting(nowMs: Int64, inbox: ShareInbox? = .shared) -> [ShareEnvelope] {
        guard let inbox else { return [] }
        inbox.sweepIncomplete(nowMs: nowMs)
        return inbox.loadAll()
    }

    /// The core has the share in its outbox (with copies of the files it needs): remove it here.
    static func taken(_ envelope: ShareEnvelope, inbox: ShareInbox? = .shared) {
        try? inbox?.remove(id: envelope.id)
    }
}
