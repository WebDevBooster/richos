import Foundation

/// Pairing, round-12 group 1: intro → scanner (or a pasted link) → progress → six words → consent.
/// Rules from the phone protocol contract §2 and the preserved client (`richos/mobile/core/client.js`).
enum PairingReducer {
    static func reduce(_ s: inout AppState, _ action: Action, _ effects: inout [Effect]) {
        switch action {
        case .openScanner:
            // "Pair again" after the Mac removed this phone opens the scanner too (on main it did
            // nothing). Unsent messages were written for the Mac that removed the phone, so they
            // cannot go to the next one: the removed-state `pair-blocked` asks first (Urban G2).
            guard s.pairing == .unpaired || s.pairing == .revoked else { return }
            if s.pairing == .revoked, s.unsentCount > 0 {
                s.pairingProblem = .blockedByUnsentWork(count: s.unsentCount)
                return
            }
            s.pairingProblem = nil
            openCamera(&s)
        case .closeScanner:
            s.scanner = nil
        case .cameraPermission(let permission):
            s.camera = permission
            if permission == .denied, s.scanner == .looking {
                s.scanner = nil
                s.sheet = .cameraDenied
            }
        case .scanned(let text):
            // A code that does not parse keeps the camera looking: it is a normal thing to point at.
            guard s.pairing == .unpaired || s.pairing == .revoked, s.scanner == .looking else { return }
            start(&s, text, fromScanner: true, &effects)
        case .submitPairingLink(let text):
            guard s.pairing == .unpaired || s.pairing == .revoked || s.pairing == .paired else { return }
            start(&s, text, fromScanner: false, &effects)
        case .pairingAnswered(let answer):
            guard s.pairing == .connecting, var mac = s.mac else { return }
            do {
                s.fingerprintWords = try Fingerprint.words(fromHex: answer.fingerprintHex)
            } catch {
                // A Mac that cannot state its fingerprint cannot be checked, so it is not trusted.
                refuse(&s)
                effects.append(.forgetIdentity(origin: mac.origin))
                return
            }
            mac.deviceID = answer.deviceID
            mac.threadID = answer.threadID
            mac.name = answer.macName
            s.mac = mac
            s.pairing = .confirming
            s.scanner = nil
        case .pairingRefused:
            guard s.pairing == .connecting else { return }
            refuse(&s)
        case .pairingUnreachable:
            guard s.pairing == .connecting else { return }
            refuse(&s)
            s.pairingProblem = .macUnreachable
        case .confirmWords:
            guard s.pairing == .confirming else { return }
            s.pairing = .paired
            s.fingerprintWords = []
            effects.append(.confirmFingerprint(matches: true))
            effects.append(.connect)
        case .rejectWords:
            // The Mac forgets the phone synchronously and the phone discards its key on the same
            // press (contract §2.5). Nothing about this pairing is kept.
            guard s.pairing == .confirming else { return }
            s.pairing = .unpaired
            s.fingerprintWords = []
            effects.append(.confirmFingerprint(matches: false))
            if let origin = s.mac?.origin { effects.append(.forgetIdentity(origin: origin)) }
            s.mac = nil
        case .acceptConsent:
            s.consentGiven = true
        case .dismissPairingProblem:
            s.pairingProblem = nil
        case .discardUnsentAndPair:
            guard case .blockedByUnsentWork = s.pairingProblem else { return }
            // Everything not already on its way is discarded, files and all.
            let discarded = s.outbox.filter { $0.state != .sending }
            for item in discarded { ConversationReducer.releaseFiles(of: item, &effects) }
            let gone = Set(discarded.map(\.clientID))
            s.outbox.removeAll { gone.contains($0.clientID) }
            s.messages.removeAll { gone.contains($0.id) || ($0.clientID.map(gone.contains) ?? false) }
            guard s.outbox.isEmpty else {
                s.pairingProblem = .blockedByUnsentWork(count: s.outbox.count)
                return
            }
            s.pairingProblem = nil
            // Back to the way the person was pairing: the scanner (removed, or not paired), or the
            // pairing-link sheet (a paired phone reaches another Mac only through a link).
            if s.pairing == .paired { s.sheet = .pairingLink } else { openCamera(&s) }
        default:
            break
        }
    }

    private static func start(_ s: inout AppState, _ text: String, fromScanner: Bool, _ effects: inout [Effect]) {
        let link: PairLink
        do {
            link = try PairLink.parse(text)
        } catch let refusal as PairLink.Refusal {
            if !fromScanner { s.pairingProblem = .invalidLink(refusal.description) }
            return
        } catch {
            return
        }
        // Unsent messages were written for the Mac this phone is paired with now; pairing another
        // Mac would strand them (round-12 `pair-blocked`; the preserved app refuses the same way).
        if s.unsentCount > 0, s.mac?.origin != link.origin {
            s.scanner = nil
            s.sheet = nil
            s.pairingProblem = .blockedByUnsentWork(count: s.unsentCount)
            return
        }
        s.pairingProblem = nil
        s.sheet = nil
        s.scanner = fromScanner ? .found : nil
        s.pairing = .connecting
        s.mac = MacLink(origin: link.origin, route: link.route)
        s.fingerprintWords = []
        effects.append(.pair(link))
    }

    private static func openCamera(_ s: inout AppState) {
        if s.camera == .denied {
            s.sheet = .cameraDenied
        } else {
            s.scanner = .looking
        }
    }

    private static func refuse(_ s: inout AppState) {
        s.pairing = .unpaired
        s.mac = nil
        s.scanner = nil
        s.fingerprintWords = []
        s.pairingProblem = .refused
    }
}
