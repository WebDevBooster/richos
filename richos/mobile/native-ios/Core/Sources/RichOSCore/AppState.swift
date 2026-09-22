import Foundation

/// Everything the iPhone app shows, as data — independent of how it is drawn.
///
/// The SwiftUI screens render it; `bin/rios headless state` prints it; the Debug app's development
/// bridge reports it. Because all three read this one value, a headless run and a simulator run of
/// the same scenario can be compared for exact equality (`rios sim verify`).
///
/// Named `AppState`, not `State`, so a SwiftUI file importing this module does not make `@State`
/// ambiguous.
public struct AppState: Codable, Equatable, Sendable {
    /// Bumped whenever a stored field changes meaning. An unknown schema is refused on load and the
    /// file is left untouched (it may hold unsent work) — the preserved client's rule
    /// (`richos/mobile/DEVELOPMENT.md`, "Session schema 2").
    public static let schemaVersion = 1

    public var schema: Int
    public var pairing: Pairing
    /// The six fingerprint words while `pairing == .confirming`; empty otherwise.
    public var fingerprintWords: [String]
    /// The conversation, oldest first.
    public var messages: [Message]
    public var draft: String
    /// `nil` while healthy. Routine recovery stays invisible; a notice exists only for a persistent
    /// interruption (PRD §5, the CEO experience gate).
    public var connectionNotice: ConnectionNotice?
    public var appearance: Appearance

    public init(pairing: Pairing = .unpaired, fingerprintWords: [String] = [], messages: [Message] = [],
                draft: String = "", connectionNotice: ConnectionNotice? = nil, appearance: Appearance = .dark) {
        self.schema = Self.schemaVersion
        self.pairing = pairing
        self.fingerprintWords = fingerprintWords
        self.messages = messages
        self.draft = draft
        self.connectionNotice = connectionNotice
        self.appearance = appearance
    }

    /// A new install: not paired, dark (ceo-decisions §15: dark is what a new install opens in).
    public static let initial = AppState()

    /// The round-12 screen this state is. Derived, never stored, so it cannot disagree with the
    /// fields it is derived from. Printed with the state so a CLI reader sees it directly.
    public var screen: Screen {
        switch pairing {
        case .unpaired: return .pairIntro
        case .confirming: return .pairWords
        case .revoked: return .connectionRevoked
        case .paired: return messages.isEmpty ? .conversationEmpty : .conversation
        }
    }

    private enum CodingKeys: String, CodingKey {
        case schema, pairing, fingerprintWords, messages, draft, connectionNotice, appearance, screen
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let schema = try c.decode(Int.self, forKey: .schema)
        guard schema == Self.schemaVersion else {
            throw DecodingError.dataCorruptedError(
                forKey: .schema, in: c,
                debugDescription: "stored state has schema \(schema); this build reads \(Self.schemaVersion)")
        }
        self.schema = schema
        pairing = try c.decode(Pairing.self, forKey: .pairing)
        fingerprintWords = try c.decode([String].self, forKey: .fingerprintWords)
        messages = try c.decode([Message].self, forKey: .messages)
        draft = try c.decode(String.self, forKey: .draft)
        connectionNotice = try c.decodeIfPresent(ConnectionNotice.self, forKey: .connectionNotice)
        appearance = try c.decode(Appearance.self, forKey: .appearance)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(schema, forKey: .schema)
        try c.encode(pairing, forKey: .pairing)
        try c.encode(fingerprintWords, forKey: .fingerprintWords)
        try c.encode(messages, forKey: .messages)
        try c.encode(draft, forKey: .draft)
        try c.encode(connectionNotice, forKey: .connectionNotice)
        try c.encode(appearance, forKey: .appearance)
        try c.encode(screen, forKey: .screen)
    }
}

public enum Pairing: String, Codable, Sendable {
    case unpaired
    /// The six-word check is on screen (round-12 `pair-words`).
    case confirming
    case paired
    /// The Mac removed this phone; terminal until paired again (round-12 `conn-revoked`).
    case revoked
}

/// The two ruled palettes. Raw values are the CLI's and launch arguments' spelling.
public enum Appearance: String, Codable, CaseIterable, Sendable {
    /// "Sovereign", ceo-decisions §14 — the default.
    case dark
    /// "Daybreak", ceo-decisions §15 — switchable, never the default.
    case light
}

/// Persistent interruptions only (round-12 §7 "Connection"). Never "connected": healthy operation is
/// not announced.
public enum ConnectionNotice: String, Codable, Sendable {
    case reconnecting
    case phoneOffline = "phone-offline"
    case serviceUnavailable = "service-unavailable"
    case macUnreachable = "mac-unreachable"
    case incompatible
}

/// Round-12 screen identifiers, spelled exactly as `design/mockups/rounds/round-12/shared/screens.js`
/// spells them, so `fixture <name>` and a screenshot file can name the design they match. A case is
/// added when the state that produces it exists.
public enum Screen: String, Codable, Sendable {
    case pairIntro = "pair-intro"
    case pairWords = "pair-words"
    case conversationEmpty = "conv-empty"
    case conversation = "conv-populated"
    case connectionRevoked = "conn-revoked"
}

public struct Message: Codable, Equatable, Identifiable, Sendable {
    public enum Author: String, Codable, Sendable { case rich, me }
    public enum Kind: String, Codable, Sendable { case text, voice }
    /// Your own message's delivery, in place of read receipts (round-12 `conv-pending`: "three
    /// honest states"). `nil` for Rich's messages and for yours once the Mac has accepted them.
    public enum Delivery: String, Codable, Sendable {
        case sending
        case waiting
        case needsAttention = "needs-attention"
    }

    public var id: String
    public var author: Author
    public var kind: Kind
    /// The text, or the transcription of a voice message once the Mac has one.
    public var text: String
    /// Milliseconds since 1970, from the `Clock` port — never read from the wall inside the core.
    public var sentAt: Int64
    public var delivery: Delivery?
    /// Voice only.
    public var durationMs: Int?

    public init(id: String, author: Author, kind: Kind = .text, text: String, sentAt: Int64,
                delivery: Delivery? = nil, durationMs: Int? = nil) {
        self.id = id
        self.author = author
        self.kind = kind
        self.text = text
        self.sentAt = sentAt
        self.delivery = delivery
        self.durationMs = durationMs
    }
}
