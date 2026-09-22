#if DEBUG
import Foundation
import RichOSCore

/// A named starting state. Each name is the round-12 screen it produces
/// (`design/mockups/rounds/round-12/shared/screens.js`), so `rios sim fixture conv-empty` puts the
/// app straight onto that design with no navigation, and a screenshot can be compared to the
/// mockup of the same name. The conversation text is round 12's synthetic conversation — one
/// person and Rich, nothing real.
public struct Fixture: Sendable {
    public var name: String
    public var state: AppState

    public static let all: [Fixture] = [
        Fixture(name: "pair-intro", state: .initial),
        Fixture(name: "pair-words", state: AppState(
            pairing: .confirming,
            fingerprintWords: ["harbor", "velvet", "copper", "meadow", "lantern", "quartz"])),
        Fixture(name: "conv-empty", state: AppState(pairing: .paired)),
        Fixture(name: "conv-populated", state: AppState(pairing: .paired, messages: Conversation.round12)),
        Fixture(name: "conn-revoked", state: AppState(pairing: .revoked, messages: Conversation.round12)),
    ]

    public static func named(_ name: String?) throws -> Fixture {
        guard let name, let fixture = all.first(where: { $0.name == name }) else {
            throw CoreError("unknown fixture '\(name ?? "")'; known: \(all.map(\.name).joined(separator: ", "))")
        }
        return fixture
    }
}

/// Round 12's `CONVO` (`shared/app.js`), with times as fixed instants on 2026-09-22 (UTC) so every
/// run is identical.
enum Conversation {
    static let day: Int64 = 1_790_035_200_000  // 2026-09-22T00:00:00Z
    static func at(_ hour: Int64, _ minute: Int64) -> Int64 { day + (hour * 60 + minute) * 60_000 }

    static let round12: [Message] = [
        Message(id: "r1", author: .rich, text: "Morning. Three things moved overnight: the Henderson proposal came back signed, payroll cleared, and the offsite venue is confirmed for the 14th. Nothing needs you before ten.", sentAt: at(8, 2)),
        Message(id: "m1", author: .me, text: "Push my 10:30 with Dana to Thursday and tell her why.", sentAt: at(8, 14)),
        Message(id: "r2", author: .rich, text: "Done. Dana has Thursday at 2:00 PM and knows it’s board prep. I also moved your prep block to Wednesday afternoon so it isn’t the night before.", sentAt: at(8, 15)),
        Message(id: "m2", author: .me, kind: .voice, text: "", sentAt: at(8, 31), durationMs: 8000),
        Message(id: "r3", author: .rich, text: "Got it. I’ll draft the note to the Portland team tonight and have it in your inbox by seven tomorrow. Want me to copy Priya?", sentAt: at(8, 32)),
        Message(id: "m3", author: .me, text: "Yes. And keep it short.", sentAt: at(8, 33)),
        Message(id: "r4", author: .rich, text: "Short it is.", sentAt: at(8, 33)),
    ]
}

/// A deterministic sequence of commands with the checks that make it a test, in the preserved
/// runtime's shape (`richos/mobile/dev/runtime.js` `scenario`). The same steps run headless and
/// inside the Debug app; `rios sim verify` requires identical traces.
public struct Scenario: Sendable {
    public var name: String
    public var steps: [Command]
    public var check: @Sendable ([AppState]) throws -> Void

    public static let all: [Scenario] = [
        // The composer takes a draft and gives it back across a theme change and a restart: the
        // smallest round trip through every action and effect this foundation has.
        Scenario(
            name: "compose-draft",
            steps: [
                Command(.fixture, name: "conv-empty"),
                Command(.action, action: .compose(text: "Hello Rich")),
                Command(.action, action: .setAppearance(.light)),
                Command(.restart),
                Command(.action, action: .compose(text: "")),
                Command(.action, action: .setAppearance(.dark)),
            ],
            check: { states in
                func require(_ ok: Bool, _ why: String) throws { if !ok { throw CoreError("Scenario failed: \(why)") } }
                try require(states[0].screen == .conversationEmpty, "starts on conv-empty")
                try require(states[1].draft == "Hello Rich", "compose sets the draft")
                try require(states[2].appearance == .light && states[2].draft == "Hello Rich", "theme change keeps the draft")
                try require(states[3] == states[2], "restart restores the persisted draft and theme")
                try require(states[5] == states[0], "clearing the draft and theme returns to the fixture")
            }),
    ]

    public static func named(_ name: String?) throws -> Scenario {
        guard let name, let scenario = all.first(where: { $0.name == name }) else {
            throw CoreError("unknown scenario '\(name ?? "")'; known: \(all.map(\.name).joined(separator: ", "))")
        }
        return scenario
    }
}
#endif
