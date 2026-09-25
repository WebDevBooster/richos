import Foundation
import Testing
@testable import RichOSCore
@testable import RichOSFixtures

/// D03 on iPhone (native acceptance r1; Android's fix is `af962783`/`9e207984`): the microphone-off
/// card (round 12 `rec-mic-denied`) answers a press while the microphone is off, and nothing else
/// raises it. "Not now" takes it down, a grant takes it down, and forgetting the pairing takes it
/// down. It is never saved: after a relaunch only a new press raises it.
///
/// iOS never shows its microphone question twice, so unlike Android there is no "Allow microphone"
/// here: the card's only way back on is iPhone Settings.
@Suite struct MicrophoneCardTests {
    let t: Int64 = 1_000_000
    let width = 386.0

    func denied() throws -> AppState {
        var s = try Fixture.named("comp-idle").state
        s.microphone = .denied
        return s
    }

    @Test func theOSReportingADenialRaisesNoCard() throws {
        // The launch and every return to the front mirror the OS's answer (RichOSNativeApp.swift).
        let s = Reducer.reduce(try Fixture.named("comp-idle").state, .microphonePermission(.denied)).state
        #expect(s.microphone == .denied)
        #expect(!s.microphoneCard, "a denial alone, before any press, raises nothing")
    }

    @Test func aPressWhileDeniedRaisesTheCardAndNeverRecords() throws {
        let (s, effects) = Reducer.reduce(try denied(), .voicePress(id: "v", width: width, at: t))
        #expect(s.microphoneCard)
        #expect(s.voice == nil && s.sheet == nil, "the press never records and never asks again")
        #expect(!effects.contains(.requestMicrophone) && !effects.contains(.startRecording(id: "v")))
        #expect(!effects.contains(.persist), "the card is not saved")
    }

    @Test func recordHandsFreeWhileDeniedRaisesTheSameCard() throws {
        let (s, effects) = Reducer.reduce(try denied(), .voiceStartLocked(id: "v", width: width, at: t))
        #expect(s.microphoneCard && s.voice == nil)
        #expect(effects.isEmpty)
    }

    @Test func notNowTakesTheCardDownUntilTheNextPress() throws {
        let raised = Reducer.reduce(try denied(), .voicePress(id: "v", width: width, at: t)).state
        let dismissed = Reducer.reduce(raised, .dismissMicrophoneCard).state
        #expect(!dismissed.microphoneCard && dismissed.microphone == .denied)
        // Coming back to the front with the microphone still off does not bring it back.
        #expect(!Reducer.reduce(dismissed, .microphonePermission(.denied)).state.microphoneCard)
        // The next press does.
        #expect(Reducer.reduce(dismissed, .voicePress(id: "v2", width: width, at: t + 5_000)).state.microphoneCard)
    }

    @Test func aGrantTakesTheCardDownAndTheNextPressRecords() throws {
        let raised = Reducer.reduce(try denied(), .voicePress(id: "v", width: width, at: t)).state
        let stillOff = Reducer.reduce(raised, .microphonePermission(.denied)).state
        #expect(stillOff.microphoneCard, "back from Settings with the microphone still off, the card stays")
        let granted = Reducer.reduce(raised, .microphonePermission(.granted)).state
        #expect(!granted.microphoneCard && granted.microphone == .granted)
        #expect(Reducer.reduce(granted, .voicePress(id: "v2", width: width, at: t + 5_000)).state.voice?.phase == .pressed)
    }

    @Test func nothingElseRaisesTheCard() throws {
        // The first press asks the system; it is not a denial yet.
        var unknown = try Fixture.named("comp-idle").state
        unknown.microphone = .unknown
        #expect(!Reducer.reduce(unknown, .voicePress(id: "v", width: width, at: t)).state.microphoneCard)
        // A Mac that cannot take voice answers the press with its own line, not this card.
        var unsupported = try denied()
        unsupported.voiceAvailability = .unsupportedByMac
        #expect(!Reducer.reduce(unsupported, .voicePress(id: "v", width: width, at: t)).state.microphoneCard)
        #expect(!Reducer.reduce(unsupported, .voiceStartLocked(id: "v", width: width, at: t)).state.microphoneCard)
    }

    @Test func forgettingThePairingTakesTheCardDown() throws {
        var s = Reducer.reduce(try denied(), .voicePress(id: "v", width: width, at: t)).state
        s = Reducer.reduce(s, .forgetPairing).state
        s = Reducer.reduce(s, .confirmForget).state
        #expect(!s.microphoneCard)
    }

    @Test func theCardIsNeverSavedAndIsPrintedOnlyWhileUp() throws {
        let raised = Reducer.reduce(try denied(), .voicePress(id: "v", width: width, at: t)).state
        let restored = try AppState(restoring: raised.persisted)
        #expect(!restored.microphoneCard, "after a relaunch only a new press raises it")
        let printed = try #require(try JSONSerialization.jsonObject(with: CoreJSON.encode(raised)) as? [String: Any])
        #expect(printed["microphoneCard"] as? Bool == true)
        let quiet = try #require(try JSONSerialization.jsonObject(with: CoreJSON.encode(try denied())) as? [String: Any])
        #expect(quiet["microphoneCard"] == nil, "the printed state omits it until set, as Android's does")
        #expect(try CoreJSON.decode(AppState.self, from: CoreJSON.encode(raised)) == raised)
    }

    @Test func notNowIsAnActionTheCommandLineUnderstands() throws {
        let action = try CoreJSON.decode(Action.self, from: Data(#"{"type":"dismiss-microphone-card"}"#.utf8))
        #expect(action == .dismissMicrophoneCard)
        #expect(Action.knownTypes.contains("dismiss-microphone-card"))
    }

    @Test func theScenarioWalksTheCardEndToEnd() async throws {
        // The scenario carries its own checks; a failed check throws.
        let host = try await HeadlessHost(storage: MemoryStorage())
        let result = try await CommandRunner.execute(Command(.scenario, name: "voice-mic-denied"), on: host)
        #expect(result.trace?.count == (try Scenario.named("voice-mic-denied")).steps.count)
    }
}
