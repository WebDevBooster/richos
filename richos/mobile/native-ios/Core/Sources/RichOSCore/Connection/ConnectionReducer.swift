import Foundation

/// Connection states, round-12 group 7, under the CEO experience gate (PRD §5; `richos/mobile/AGENTS.md`):
/// healthy operation and routine recovery are invisible. A routine drop shows nothing for
/// `quietMs`; only a trouble that lasts gets the calm "Reconnecting…" line. States the phone KNOWS
/// — no network, the managed service down, the Mac unreachable on the evidence, an incompatible Mac —
/// are explicit at once. Revocation is the pairing's own state, not a notice.
public enum ConnectionReducer {
    /// Routine reconnects are presentation-silent for three seconds (preserved client, DEVELOPMENT.md).
    public static let quietMs: Int64 = 3000

    static func reduce(_ s: inout AppState, _ action: Action, _ effects: inout [Effect]) {
        switch action {
        case .networkChanged(let online, let at):
            if !online {
                s.connectionNotice = .phoneOffline
                s.linkOpen = false
                effects.append(.disconnect)
                s.troubleSinceMs = s.troubleSinceMs ?? at
            } else if s.connectionNotice == .phoneOffline {
                // Back online: say nothing yet; the transport reconnects, and the quiet period
                // starts again from now.
                s.connectionNotice = nil
                s.troubleSinceMs = at
                if s.pairing == .paired { effects.append(.connect) }
                ConversationReducer.pump(&s, at: at, &effects)
            }
        case .connectionLost(let at):
            s.troubleSinceMs = s.troubleSinceMs ?? at
            s.linkOpen = false
        case .connected(let at):
            s.troubleSinceMs = nil
            s.linkOpen = true
            if s.connectionNotice != .incompatible { s.connectionNotice = nil }
            // History on screen has now been reconciled with the Mac.
            s.history.cached = false
            ConversationReducer.pump(&s, at: at, &effects)
        case .connectionDiagnosed(let notice):
            // Evidence-based only (contract §6.3): the transport's probe says which.
            guard notice != .reconnecting, s.connectionNotice != .incompatible, s.connectionNotice != .phoneOffline else { return }
            s.connectionNotice = notice
        case .macCapabilities(let text, let voice):
            s.connectionNotice = text ? (s.connectionNotice == .incompatible ? nil : s.connectionNotice) : .incompatible
            if voice {
                if s.voiceAvailability == .unsupportedByMac { s.voiceAvailability = .available }
            } else {
                s.voiceAvailability = .unsupportedByMac
            }
        case .pairingRevoked:
            // Final for the pairing, not for his words: the conversation and anything unsent stay.
            s.pairing = .revoked
            s.troubleSinceMs = nil
            s.connectionNotice = nil
            s.linkOpen = false
            effects.append(.disconnect)
        case .macAttachmentLimits(let limits):
            s.attachmentLimits = limits
        case .pushRegistered(let hostID):
            s.notifications.status = .on
            s.notifications.hostID = hostID
            s.notifications.offerDismissed = true
        case .foregrounded(let at):
            guard s.pairing == .paired, s.connectionNotice != .phoneOffline else { return }
            effects.append(.connect)
            // Connecting is trouble until the Mac answers: a Mac that takes the connection and never
            // answers is explained after the same quiet 3 s as one that refuses it, not after the
            // stream's minute-long timeout (I06). The reference starts its 3 s at `opening`, Android
            // at `Link(OPENING)`. A healthy stream opens well inside the quiet period and clears it.
            if !s.linkOpen { s.troubleSinceMs = s.troubleSinceMs ?? at }
            ConversationReducer.pump(&s, at: at, &effects)
        case .backgrounded:
            // No stream in the background (build plan §3.2): APNs is for awareness, the foreground
            // reconciles. The quiet period restarts on return.
            s.troubleSinceMs = nil
            s.linkOpen = false
            if s.pairing == .paired { effects.append(.disconnect) }
        case .tick(let at):
            if let since = s.troubleSinceMs, s.connectionNotice == nil, at - since >= quietMs {
                s.connectionNotice = .reconnecting
            }
        default:
            break
        }
    }
}
