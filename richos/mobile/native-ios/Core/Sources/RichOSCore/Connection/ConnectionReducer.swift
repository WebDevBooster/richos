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
                s.troubleSinceMs = s.troubleSinceMs ?? at
            } else if s.connectionNotice == .phoneOffline {
                // Back online: say nothing yet; the transport reconnects, and the quiet period
                // starts again from now.
                s.connectionNotice = nil
                s.troubleSinceMs = at
                ConversationReducer.pump(&s, at: at, &effects)
            }
        case .connectionLost(let at):
            s.troubleSinceMs = s.troubleSinceMs ?? at
        case .connected(let at):
            s.troubleSinceMs = nil
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
            effects.append(.disconnect)
        case .foregrounded(let at):
            guard s.pairing == .paired else { return }
            effects.append(.connect)
            ConversationReducer.pump(&s, at: at, &effects)
        case .backgrounded:
            // No stream in the background (build plan §3.2): APNs is for awareness, the foreground
            // reconciles. The quiet period restarts on return.
            s.troubleSinceMs = nil
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
