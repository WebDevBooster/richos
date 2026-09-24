import Foundation
import Testing
@testable import RichOSCore
@testable import RichOSFixtures

/// After the Mac removed this phone (Urban's UX audit G2, §4.1): "Pair again" works, and messages
/// written for the Mac that removed the phone are never sent to whichever Mac is paired next.
@Suite struct PairingRemovedTests {
    /// `pair-blocked`'s own state, then the Mac removes the phone: one message waiting, revoked.
    func removedWithWork() -> AppState {
        var s = try! Fixture.named("pair-blocked").state
        s.pairingProblem = nil
        s.pairing = .revoked
        return s
    }

    @Test func pairAgainWithNothingWaitingOpensTheScannerOverTheRemovedScreen() {
        var s = try! Fixture.named("conn-revoked").state
        s.camera = .granted
        let next = Reducer.reduce(s, .openScanner).state
        #expect(next.scanner == .looking)
        #expect(next.screen == .pairScanner)
        // Closing it comes back to the removed screen, not to a first-run intro.
        #expect(Reducer.reduce(next, .closeScanner).state.screen == .connectionRevoked)
    }

    @Test func pairAgainWithAMessageWaitingAsksFirstAndOpensNothing() {
        let next = Reducer.reduce(removedWithWork(), .openScanner).state
        #expect(next.pairingProblem == .blockedByUnsentWork(count: 1))
        #expect(next.scanner == nil)
        #expect(next.screen == .connectionRevoked)
    }

    @Test func notNowKeepsTheMessageAndTheRemovedScreen() {
        let asked = Reducer.reduce(removedWithWork(), .openScanner).state
        let kept = Reducer.reduce(asked, .dismissPairingProblem).state
        #expect(kept.pairingProblem == nil)
        #expect(kept.outbox.count == 1)
        #expect(kept.messages.contains { $0.id == "q1" })
        #expect(kept.screen == .connectionRevoked)
    }

    @Test func discardAndPairDiscardsTheMessageThenOpensTheScanner() {
        var s = removedWithWork()
        s.camera = .granted
        let asked = Reducer.reduce(s, .openScanner).state
        let (next, effects) = Reducer.reduce(asked, .discardUnsentAndPair)
        #expect(next.outbox.isEmpty)
        #expect(!next.messages.contains { $0.id == "q1" })
        #expect(next.pairingProblem == nil)
        #expect(next.scanner == .looking)
        // Nothing is sent: the Mac that removed this phone never gets it, and neither does the next.
        #expect(!effects.contains { if case .deliver = $0 { return true } else { return false } })
    }

    @Test func discardAndPairWithTheCameraOffShowsTheCameraDialog() {
        var s = removedWithWork()
        s.camera = .denied
        let asked = Reducer.reduce(s, .openScanner).state
        #expect(Reducer.reduce(asked, .discardUnsentAndPair).state.sheet == .cameraDenied)
    }

    @Test func aScannedCodeAfterRemovalStartsPairing() throws {
        var s = try Fixture.named("conn-revoked").state
        s.camera = .granted
        s = Reducer.reduce(s, .openScanner).state
        let (next, effects) = Reducer.reduce(s, .scanned(text: "https://mm2.tail1a2b3c.ts.net:8443/#pair=K7M2QX9H"))
        #expect(next.pairing == .connecting)
        #expect(effects.contains { if case .pair = $0 { return true } else { return false } })
    }

    @Test func discardAndPairDoesNothingWithoutTheQuestion() {
        let s = removedWithWork()
        #expect(Reducer.reduce(s, .discardUnsentAndPair).state == s)
    }

    @Test func sendItFirstInThePairedDialogSendsAndClosesIt() throws {
        let s = try Fixture.named("pair-blocked").state
        let next = Reducer.reduce(s, .retryNow(at: Fixture.now + 1)).state
        #expect(next.pairingProblem == nil)
    }
}
