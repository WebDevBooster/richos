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
            // What the last attempt said stays until a new code is read (`start`): backing out of
            // the scanner leaves the card where it was (Urban's review, question 1, check 1).
            if case .blockedByUnsentWork = s.pairingProblem { s.pairingProblem = nil }
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
            // The v2 words, over the origin this phone DIALED (the link's, never one the Mac
            // advertised), the Mac's pairing value byte for byte and this phone's own key. A Mac
            // that cannot state its value, or an answer without the phone's key, cannot be checked,
            // so it is not trusted — and a v2 phone never falls back to the old words.
            guard let point = answer.devicePoint,
                  let words = try? Fingerprint.words(origin: mac.origin, caFingerprintSHA256: answer.fingerprintHex, devicePoint: point) else {
                refuse(&s)
                effects.append(.forgetIdentity(origin: mac.origin))
                return
            }
            s.fingerprintWords = words
            mac.deviceID = answer.deviceID
            mac.threadID = answer.threadID
            mac.name = answer.macName
            s.mac = mac
            s.pairing = .confirming
            s.macWait = MacWait(boundMs: MacWait.boundMs(confirmWithinSeconds: answer.confirmWithinSeconds),
                                holds: answer.offersPairWait == true)
            s.scanner = nil
        case .pairingRefused:
            guard s.pairing == .connecting else { return }
            refuse(&s)
        case .pairingUnreachable:
            guard s.pairing == .connecting else { return }
            refuse(&s)
            s.pairingProblem = .macUnreachable
        case .pairingNeedsMacUpdate:
            // Refused, never fallen back to (review §3.5). The network effect has already signed the
            // one "They do not match" that makes that Mac forget the key; the phone forgets it now.
            guard s.pairing == .connecting, let origin = s.mac?.origin else { return }
            refuse(&s)
            s.pairingProblem = .macNeedsUpdate
            effects.append(.forgetIdentity(origin: origin))
        case .confirmWords:
            // Said on the phone; the Mac lets this phone in only after the same press ON THE MAC. The
            // words stay up. THE PRESS IS THE FIRST ASK (Sage's pair-v2 hypotheses review §1, point 1):
            // the phone's signed "They match", held by a Mac that offers `pair-wait` for as long as the
            // bound allows (at most 14 s), and its answer starts the bound (`macConfirmation`).
            guard s.pairing == .confirming else { return }
            s.pairing = .awaitingMac
            var wait = MacWait(boundMs: s.macWait?.boundMs ?? MacWait.windowMs, holds: s.macWait?.holds ?? false)
            wait.asking = true
            s.macWait = wait
            effects.append(.checkMacConfirmation(waitSeconds: MacWait.holdSeconds(holds: wait.holds, leftMs: wait.boundMs)))
        case .rejectWords:
            // The Mac forgets the phone synchronously and the phone discards its key on the same
            // press (contract §2.5). Nothing about this pairing is kept. Also the way out while the
            // phone waits for the press on the Mac.
            guard s.pairing == .confirming || s.pairing == .awaitingMac else { return }
            s.pairing = .unpaired
            s.fingerprintWords = []
            s.macWait = nil
            s.pairingProblem = .wordsRejected
            effects.append(.confirmFingerprint(matches: false))
            if let origin = s.mac?.origin { effects.append(.forgetIdentity(origin: origin)) }
            s.mac = nil
        case .macConfirmation(let answer, let at, let askedAt):
            // Only the answer to the ask in flight is taken: one that arrives after the app left the
            // screen is dropped, and the return to the screen asks again.
            guard s.pairing == .awaitingMac, var wait = s.macWait, wait.asking else { return }
            let started = askedAt ?? wait.lastAskAtMs ?? at
            // The first answer is the Mac's to the press on the phone: the bound counts from the press.
            if wait.deadlineMs == nil { wait.deadlineMs = started + wait.boundMs }
            let final = wait.finalAsk
            wait.asking = false
            wait.finalAsk = false
            wait.lastAskAtMs = started
            s.macWait = wait
            switch answer {
            case .confirmed:
                s.pairing = .paired
                s.fingerprintWords = []
                s.macWait = nil
                s.pairingProblem = nil
                effects.append(.connect)
            case .refused:
                end(&s, .notAcceptedByMac, &effects)
            case .awaiting where final:
                // The last ask, and the Mac still had not said yes (or could not be reached): the phone
                // stops, and says it did not hear back, which is true either way.
                end(&s, .macAnswerExpired, &effects)
            case .awaiting:
                schedule(&s, askedAt: started, answeredAt: at)
            }
        case .tick(let at):
            guard s.pairing == .awaitingMac, let wait = s.macWait, !wait.paused, !wait.asking,
                  let due = wait.nextAskAtMs, at >= due else { return }
            ask(&s, at: at, &effects)
        case .backgrounded(let at):
            // Off screen nothing is asked, scheduled or retried; an answer already on its way is
            // dropped (the app cancels the request). A canceled ask still counts as the latest one for
            // the 7 s spacing; the press carries no time of its own, so leaving stands in for it.
            guard s.pairing == .awaitingMac, var wait = s.macWait else { return }
            if wait.asking, wait.lastAskAtMs == nil { wait.lastAskAtMs = at }
            wait.paused = true
            wait.asking = false
            wait.finalAsk = false
            wait.nextAskAtMs = nil
            s.macWait = wait
        case .foregrounded(let at):
            // Back on screen (or a relaunch, which restores the wait paused): the phone asks again, at
            // once or, while the Mac holds, as soon as 7 s have passed since the previous ask. Past the
            // bound that ask is the last one. A relaunch before the Mac answered the press starts the
            // bound now. The app never left the screen (an alert or Control Center came and went): the
            // schedule, or the answer on its way, stands.
            guard s.pairing == .awaitingMac else { return }
            var wait = s.macWait ?? MacWait(paused: true)
            guard wait.paused else { return }
            wait.paused = false
            wait.asking = false
            if wait.deadlineMs == nil { wait.deadlineMs = at + wait.boundMs }
            s.macWait = wait
            if wait.holds, let last = wait.lastAskAtMs, at < last + MacWait.minAskSpacingMs {
                s.macWait?.nextAskAtMs = last + MacWait.minAskSpacingMs
            } else {
                ask(&s, at: at, &effects)
            }
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
        s.macWait = nil
        s.pairingProblem = .refused
    }

    // MARK: the wait for the press on the Mac (`MacWait`)

    /// After an answer that says "not yet": the next ask (`MacWait.nextAskAt`), never later than the
    /// deadline except that the last ask keeps 7 s from the previous one while the Mac holds; at the
    /// ceiling of `MacWait.maxRequests`, only the last ask. Off screen, nothing.
    private static func schedule(_ s: inout AppState, askedAt: Int64, answeredAt: Int64) {
        guard var wait = s.macWait, let deadline = wait.deadlineMs else { return }
        if wait.paused {
            wait.nextAskAtMs = nil
        } else if wait.requests >= MacWait.maxRequests {
            wait.nextAskAtMs = MacWait.lastAskAt(askedAt: askedAt, until: deadline, holds: wait.holds)
        } else {
            wait.nextAskAtMs = MacWait.nextAskAt(attempt: wait.requests, askedAt: askedAt, answeredAt: answeredAt,
                                                 until: deadline, holds: wait.holds)
        }
        s.macWait = wait
    }

    /// The moment an ask is owed (a tick at its time, or the return to the screen). At or past the
    /// deadline it is the last ask, with no hold; at the ceiling the phone only waits for that last
    /// ask; otherwise one ask goes, held by a Mac that offers it for as long as the deadline allows.
    private static func ask(_ s: inout AppState, at: Int64, _ effects: inout [Effect]) {
        guard var wait = s.macWait, let deadline = wait.deadlineMs else { return }
        if at >= deadline {
            wait.finalAsk = true
            wait.asking = true
            wait.nextAskAtMs = nil
            wait.lastAskAtMs = at
            effects.append(.checkMacConfirmation(waitSeconds: 0))
        } else if wait.requests >= MacWait.maxRequests {
            wait.nextAskAtMs = MacWait.lastAskAt(askedAt: wait.lastAskAtMs, until: deadline, holds: wait.holds)
        } else {
            wait.requests += 1
            wait.asking = true
            wait.nextAskAtMs = nil
            wait.lastAskAtMs = at
            effects.append(.checkMacConfirmation(waitSeconds: MacWait.holdSeconds(holds: wait.holds, leftMs: deadline - at)))
        }
        s.macWait = wait
    }

    /// The wait is over without a pairing: the Mac refused this phone, or its last ask went unanswered
    /// by a yes. The Mac has already forgotten the key (it refused it, or its own window closed); the
    /// phone forgets it too, and the person is told what happened and how to pair again.
    private static func end(_ s: inout AppState, _ problem: PairingProblem, _ effects: inout [Effect]) {
        if let origin = s.mac?.origin { effects.append(.forgetIdentity(origin: origin)) }
        s.pairing = .unpaired
        s.mac = nil
        s.scanner = nil
        s.fingerprintWords = []
        s.macWait = nil
        s.pairingProblem = problem
    }
}
