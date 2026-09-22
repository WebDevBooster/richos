import Foundation

/// Pairing, round-12 group 1: intro → scanner (or a pasted link) → progress → six words → consent.
/// Rules from the phone protocol contract §2 and the preserved client (`richos/mobile/core/client.js`).
enum PairingReducer {
    static func reduce(_ s: inout AppState, _ action: Action, _ effects: inout [Effect]) {
        switch action {
        case .openScanner:
            guard s.pairing == .unpaired else { return }
            s.pairingProblem = nil
            if s.camera == .denied {
                s.sheet = .cameraDenied
            } else {
                s.scanner = .looking
            }
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
            guard s.pairing == .unpaired, s.scanner == .looking else { return }
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
                effects.append(.forgetIdentity)
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
        case .confirmWords:
            guard s.pairing == .confirming else { return }
            s.pairing = .paired
            s.fingerprintWords = []
            effects.append(.confirmFingerprint(matches: true))
        case .rejectWords:
            // The Mac forgets the phone synchronously and the phone discards its key on the same
            // press (contract §2.5). Nothing about this pairing is kept.
            guard s.pairing == .confirming else { return }
            s.pairing = .unpaired
            s.fingerprintWords = []
            effects.append(.confirmFingerprint(matches: false))
            effects.append(.forgetIdentity)
            s.mac = nil
        case .acceptConsent:
            s.consentGiven = true
        case .dismissPairingProblem:
            s.pairingProblem = nil
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

    private static func refuse(_ s: inout AppState) {
        s.pairing = .unpaired
        s.mac = nil
        s.scanner = nil
        s.fingerprintWords = []
        s.pairingProblem = .refused
    }
}
