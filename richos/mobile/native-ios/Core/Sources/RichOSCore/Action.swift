import Foundation

/// Everything a person — or the platform, or the CLI standing in for either — can do.
///
/// The screens dispatch these and nothing else; `bin/rios headless action '<json>'` dispatches the
/// same values, which is what lets the command line prove a change without a simulator. The JSON
/// spelling is `{"type": "<kebab-case>", …fields}`, the preserved mobile CLI's action envelope
/// (`richos/mobile/cli/mobile.mjs`). Cases arrive with the reducer logic that gives them meaning.
public enum Action: Equatable, Sendable {
    // composer
    case compose(text: String)
    case setAppearance(Appearance)
    // pairing (round-12 group 1)
    case openScanner
    case closeScanner
    /// The QR scanner read this text. It is only ever parsed, never followed.
    case scanned(text: String)
    /// Pasted into the pairing-link sheet.
    case submitPairingLink(text: String)
    /// The OS reports the camera permission (a mirror; nothing parallel is stored).
    case cameraPermission(Permission)
    /// The Mac answered the pairing request (from the transport, or a fixture).
    case pairingAnswered(PairAnswer)
    /// The Mac refused the pairing code (404 after the one retry, contract §2.3).
    case pairingRefused
    /// "They match" on the six-word check.
    case confirmWords
    /// "They do not match": the Mac forgets this phone and the phone discards its key (§2.5).
    case rejectWords
    /// Continue on the consent screen (`pair-consent`).
    case acceptConsent
    case dismissPairingProblem
    // sheets
    case openSheet(Sheet)
    case closeSheet
}

/// What `POST /api/pair` answers with (contract §2.3), in the core's terms.
public struct PairAnswer: Codable, Equatable, Sendable {
    public var deviceID: String
    /// The Mac's root certificate SHA-256, as the Mac sends it (uppercase hex pairs joined by `:`).
    public var fingerprintHex: String
    public var threadID: String?
    public var macName: String?
    public init(deviceID: String, fingerprintHex: String, threadID: String? = nil, macName: String? = nil) {
        self.deviceID = deviceID; self.fingerprintHex = fingerprintHex; self.threadID = threadID; self.macName = macName
    }
}

extension Action: Codable {
    /// The flat wire form: a `type` and whichever fields that type carries.
    private struct Wire: Codable {
        var type: String
        var text: String?
        var appearance: Appearance?
        var permission: Permission?
        var sheet: Sheet?
        var answer: PairAnswer?
    }

    public static let knownTypes = [
        "compose", "set-appearance", "open-scanner", "close-scanner", "scanned", "submit-pairing-link",
        "camera-permission", "pairing-answered", "pairing-refused", "confirm-words", "reject-words",
        "accept-consent", "dismiss-pairing-problem", "open-sheet", "close-sheet",
    ]

    public init(from decoder: Decoder) throws {
        let w = try Wire(from: decoder)
        func need<T>(_ value: T?, _ field: String) throws -> T {
            guard let value else {
                throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "action '\(w.type)' needs '\(field)'"))
            }
            return value
        }
        switch w.type {
        case "compose": self = .compose(text: try need(w.text, "text"))
        case "set-appearance": self = .setAppearance(try need(w.appearance, "appearance"))
        case "open-scanner": self = .openScanner
        case "close-scanner": self = .closeScanner
        case "scanned": self = .scanned(text: try need(w.text, "text"))
        case "submit-pairing-link": self = .submitPairingLink(text: try need(w.text, "text"))
        case "camera-permission": self = .cameraPermission(try need(w.permission, "permission"))
        case "pairing-answered": self = .pairingAnswered(try need(w.answer, "answer"))
        case "pairing-refused": self = .pairingRefused
        case "confirm-words": self = .confirmWords
        case "reject-words": self = .rejectWords
        case "accept-consent": self = .acceptConsent
        case "dismiss-pairing-problem": self = .dismissPairingProblem
        case "open-sheet": self = .openSheet(try need(w.sheet, "sheet"))
        case "close-sheet": self = .closeSheet
        default:
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription:
                "unknown action '\(w.type)'; known: \(Self.knownTypes.joined(separator: ", "))"))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var w = Wire(type: "")
        switch self {
        case .compose(let text): w.type = "compose"; w.text = text
        case .setAppearance(let a): w.type = "set-appearance"; w.appearance = a
        case .openScanner: w.type = "open-scanner"
        case .closeScanner: w.type = "close-scanner"
        case .scanned(let text): w.type = "scanned"; w.text = text
        case .submitPairingLink(let text): w.type = "submit-pairing-link"; w.text = text
        case .cameraPermission(let p): w.type = "camera-permission"; w.permission = p
        case .pairingAnswered(let a): w.type = "pairing-answered"; w.answer = a
        case .pairingRefused: w.type = "pairing-refused"
        case .confirmWords: w.type = "confirm-words"
        case .rejectWords: w.type = "reject-words"
        case .acceptConsent: w.type = "accept-consent"
        case .dismissPairingProblem: w.type = "dismiss-pairing-problem"
        case .openSheet(let s): w.type = "open-sheet"; w.sheet = s
        case .closeSheet: w.type = "close-sheet"
        }
        try w.encode(to: encoder)
    }
}

/// Work a reducer asks for and does not do itself. The reducer stays pure; the effect runner
/// performs these through the ports, so every one can be substituted in a test. An effect with no
/// port wired yet is recorded and skipped, never guessed at.
public enum Effect: Equatable, Sendable {
    /// Write `AppState.persisted` to durable storage.
    case persist
    /// Generate (or reuse) this origin's device key and send `POST /api/pair` with the code.
    case pair(PairLink)
    /// Send the signed six-word answer (contract §2.5).
    case confirmFingerprint(matches: Bool)
    /// Discard this phone's key and pairing for the current origin.
    case forgetIdentity
    /// Open this app's page in iPhone Settings (camera or microphone turned off).
    case openSystemSettings
}

/// The one place state changes. Pure: the same state and action always give the same result, so a
/// scenario replays exactly on this Mac and in the simulator.
public enum Reducer {
    public static func reduce(_ state: AppState, _ action: Action) -> (state: AppState, effects: [Effect]) {
        var next = state
        var effects: [Effect] = []
        switch action {
        case .compose(let text):
            next.draft = text
        case .setAppearance(let appearance):
            next.appearance = appearance
        case .openSheet(let sheet):
            next.sheet = sheet
        case .closeSheet:
            next.sheet = nil
        default:
            PairingReducer.reduce(&next, action, &effects)
        }
        // Persist only when something durable changed: a touch-rate action never writes a file.
        if next.persisted != state.persisted { effects.insert(.persist, at: 0) }
        return (next, effects)
    }
}
