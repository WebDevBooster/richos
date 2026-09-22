import Foundation

/// Everything a person — or the CLI standing in for one — can do.
///
/// The composer's text field dispatches `.compose`, and so does
/// `bin/rios headless action '{"type":"compose","text":"…"}'`: one code path, which is what lets
/// the command line prove a change without a simulator. The JSON spelling (`type` plus fields)
/// is the preserved mobile CLI's action envelope (`richos/mobile/cli/mobile.mjs`, build plan §3.1
/// "Grammar"). Cases are added with the features that need them; an unknown `type` is a structured
/// error that lists the known ones.
public enum Action: Equatable, Sendable {
    case compose(text: String)
    case setAppearance(Appearance)
}

extension Action: Codable {
    private enum CodingKeys: String, CodingKey { case type, text, appearance }

    /// The wire names, in one place.
    public enum Kind: String, CaseIterable, Sendable {
        case compose
        case setAppearance = "set-appearance"
    }

    public var kind: Kind {
        switch self {
        case .compose: return .compose
        case .setAppearance: return .setAppearance
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let raw = try c.decode(String.self, forKey: .type)
        guard let kind = Kind(rawValue: raw) else {
            throw DecodingError.dataCorruptedError(
                forKey: .type, in: c,
                debugDescription: "unknown action '\(raw)'; known: \(Kind.allCases.map(\.rawValue).joined(separator: ", "))")
        }
        switch kind {
        case .compose: self = .compose(text: try c.decode(String.self, forKey: .text))
        case .setAppearance: self = .setAppearance(try c.decode(Appearance.self, forKey: .appearance))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(kind.rawValue, forKey: .type)
        switch self {
        case .compose(let text): try c.encode(text, forKey: .text)
        case .setAppearance(let appearance): try c.encode(appearance, forKey: .appearance)
        }
    }
}

/// Work a reducer asks for and does not do itself. The reducer stays pure; `EffectRunner` performs
/// effects through the ports, so a test can substitute every one of them.
public enum Effect: Equatable, Sendable {
    /// Write the current state to durable storage (draft, appearance, cached conversation).
    case persist
}

/// The one place state changes. Pure: the same state and action always give the same result, so a
/// scenario replays exactly on this Mac and in the simulator.
public enum Reducer {
    public static func reduce(_ state: AppState, _ action: Action) -> (state: AppState, effects: [Effect]) {
        var next = state
        switch action {
        case .compose(let text):
            next.draft = text
        case .setAppearance(let appearance):
            next.appearance = appearance
        }
        return (next, next == state ? [] : [.persist])
    }
}
