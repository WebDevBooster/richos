import Foundation

// The core never touches the wall clock, the file system, the network or a device API directly.
// It reaches them through these ports, so the headless CLI and the tests substitute every one
// (build plan §3.2 "State"). Ports are added with the features that need them — signer, transport,
// event stream, recorder, player, network monitor, notifier — never ahead of their protocol.

/// Time, in milliseconds since 1970.
public protocol Clock: Sendable {
    func nowMs() -> Int64
}

/// Durable bytes by key, written atomically. `read` returns `nil` when nothing is stored.
public protocol Storage: Sendable {
    func read(_ key: String) async throws -> Data?
    func write(_ key: String, _ data: Data) async throws
}

public struct SystemClock: Clock {
    public init() {}
    public func nowMs() -> Int64 { Int64((Date().timeIntervalSince1970 * 1000).rounded()) }
}

/// One file per key under `directory`, replaced atomically. On iOS the directory is the app's
/// Application Support; for the headless CLI it is a session directory in the external cache.
public struct FileStorage: Storage {
    public let directory: URL

    public init(directory: URL) { self.directory = directory }

    public func read(_ key: String) async throws -> Data? {
        let url = try fileURL(key)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try Data(contentsOf: url)
    }

    public func write(_ key: String, _ data: Data) async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: try fileURL(key), options: .atomic)
    }

    private func fileURL(_ key: String) throws -> URL {
        guard !key.isEmpty, key.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "." }),
              !key.hasPrefix(".") else {
            throw CoreError("storage key '\(key)' must be letters, digits, '-', '_' or '.', and not start with '.'")
        }
        return directory.appendingPathComponent(key)
    }
}

public struct CoreError: Error, Equatable, CustomStringConvertible, Sendable {
    public var description: String
    public init(_ description: String) { self.description = description }
}

/// One encoder configuration for everything that stores or prints state, so two runs of the same
/// scenario produce byte-identical JSON and can be compared as text.
public enum CoreJSON {
    public static func encode<T: Encodable>(_ value: T, pretty: Bool = false) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = pretty ? [.sortedKeys, .withoutEscapingSlashes, .prettyPrinted]
                                          : [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try JSONDecoder().decode(type, from: data)
    }
}

/// Performs everything that is not a state change: the network, the microphone, notifications,
/// opening Settings. The app supplies one (the platform adapter, stream I3, plus the network
/// courier); tests and the headless CLI supply fakes or none. Each effect may answer with actions —
/// "the OS said the microphone is allowed", "the Mac accepted the message" — which the store
/// dispatches like any other, so an answer can never bypass the reducer.
public protocol EffectHandler: Sendable {
    /// Whether this handler takes `effect` (a composite routes by it).
    func handles(_ effect: Effect) -> Bool
    func handle(_ effect: Effect, state: AppState) async -> [Action]
}

extension EffectHandler {
    public func handles(_ effect: Effect) -> Bool { true }
}

/// Performs the effects a reducer asked for, through the ports. An actor, not main-actor-bound: the
/// UI thread never waits on storage or the network (the Avelor iOS lesson, build plan §3.2).
///
/// `.persist` is handled here; every other effect goes to the `EffectHandler`. With none wired (the
/// headless CLI, a test), those effects are recorded in `skipped` — never guessed at — and a fixture
/// or the CLI supplies the answer instead (for example `pairing-answered`).
public actor EffectRunner {
    public static let stateKey = "state.json"

    private let storage: any Storage
    private let handler: (any EffectHandler)?
    public private(set) var skipped: [Effect] = []

    public init(storage: any Storage, handler: (any EffectHandler)? = nil) {
        self.storage = storage
        self.handler = handler
    }

    /// Runs the effects in order and returns the actions their answers produced, in order.
    @discardableResult
    public func run(_ effects: [Effect], state: AppState) async throws -> [Action] {
        var followUps: [Action] = []
        for effect in effects {
            if effect == .persist {
                try await storage.write(Self.stateKey, try CoreJSON.encode(state.persisted))
            } else if let handler {
                followUps += await handler.handle(effect, state: state)
            } else {
                skipped.append(effect)
            }
        }
        return followUps
    }

    /// The stored state, or `nil` for a new install. A stored file that cannot be read THROWS — it
    /// is never replaced by a fresh state, because it may hold unsent work. A file from a newer app
    /// throws `StoredSchemaError` with `newer == true`, which the app shows as `pair-stale`.
    public func load() async throws -> AppState? {
        guard let data = try await storage.read(Self.stateKey) else { return nil }
        // The schema is read first, on its own, so a newer file is recognized as newer even when
        // its other fields no longer decode here.
        struct Probe: Decodable { var schema: Int }
        let schema = try CoreJSON.decode(Probe.self, from: data).schema
        guard schema == AppState.schemaVersion else { throw StoredSchemaError(found: schema) }
        return try AppState(restoring: CoreJSON.decode(AppState.Persisted.self, from: data))
    }
}
