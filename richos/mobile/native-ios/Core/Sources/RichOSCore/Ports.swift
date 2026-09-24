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
    func recoverRecording(_ recording: KeptRecording) async throws -> KeptRecording?
    /// Whether this handler takes `effect` (a composite routes by it).
    func handles(_ effect: Effect) -> Bool
    func handle(_ effect: Effect, state: AppState) async -> [Action]
}

extension EffectHandler {
    public func handles(_ effect: Effect) -> Bool { true }
    public func recoverRecording(_ recording: KeptRecording) async throws -> KeptRecording? { nil }
}

/// Performs the effects a reducer asked for, through the ports. An actor, not main-actor-bound: the
/// UI thread never waits on storage or the network (the Avelor iOS lesson, build plan §3.2).
///
/// `.persist` is handled here; every other effect goes to the `EffectHandler`. With none wired (the
/// headless CLI, a test), those effects are recorded in `skipped` — never guessed at — and a fixture
/// or the CLI supplies the answer instead (for example `pairing-answered`).
public actor EffectRunner {
    public static let stateKey = "state.json"
    public static let historyKey = "history.json"
    public static let cachedMessages = 100
    public static let readingCachedMessages = 10_000
    private var lastUserWork: AppState.Persisted?
    private var lastHistory: CachedHistory?
    private var lastHistoryAt: Int64?
    private var historyFailed = false
    private var completionWrite: Task<Void, Never>?

    private struct CachedHistory: Codable, Equatable {
        var mac: MacLink?
        var messages: [Message]
    }

    private let storage: any Storage
    private let clock: any Clock
    private let handler: (any EffectHandler)?
    public private(set) var skipped: [Effect] = []

    public init(storage: any Storage, handler: (any EffectHandler)? = nil, clock: any Clock = SystemClock()) {
        self.clock = clock
        self.storage = storage
        self.handler = handler
    }

    /// Reservations survive process death. Foreground-only completion refunds its reservation.
    /// Six five-second leases/hour and 24/day, retained on clock rollback or interrupted writes.
    public func reserveCompletion() async -> Int64? {
        let previous = completionWrite
        let task = Task { await previous?.value; return await reserveCompletionSerially() }
        completionWrite = Task { _ = await task.value }
        return await task.value
    }

    private func reserveCompletionSerially() async -> Int64? {
        do {
            let data = try await storage.read("completion-budget.json")
            let saved = try data.map { try CoreJSON.decode([Int64].self, from: $0) } ?? []
            let now = clock.nowMs()
            let retained = saved.filter { now - $0 < 86_400_000 }
            guard retained.count < 24, retained.filter({ now - $0 < 3_600_000 }).count < 6 else { return nil }
            let token = max(now, (retained.max() ?? (now - 1)) + 1)
            try await storage.write("completion-budget.json", try CoreJSON.encode(retained + [token]))
            return token
        } catch { return nil } // Optional continuation cannot prevent ordinary foreground delivery.
    }

    public func refundCompletion(_ token: Int64) async {
        let previous = completionWrite
        let task = Task { await previous?.value; await refundCompletionSerially(token) }
        completionWrite = task
        await task.value
    }

    private func refundCompletionSerially(_ token: Int64) async {
        do {
            guard let data = try await storage.read("completion-budget.json") else { return }
            let saved = try CoreJSON.decode([Int64].self, from: data)
            try await storage.write("completion-budget.json", try CoreJSON.encode(saved.filter { $0 != token }))
        } catch { /* Conservatively keep the spent reservation. No timed disk retries. */ }
    }

    /// Runs the effects in order and returns the actions their answers produced, in order.
    @discardableResult
    public func run(_ effects: [Effect], state: AppState) async throws -> [Action] {
        var followUps: [Action] = []
        for effect in effects {
            if effect == .persist {
                try await persist(state)
            } else if let handler {
                followUps += await handler.handle(effect, state: state)
            } else {
                skipped.append(effect)
            }
        }
        return followUps
    }

    /// Never rewrite the transcript on a keystroke. Outbox-related bubbles stay with user work,
    /// so a missing/stale disposable cache cannot lose the visible representation of an unsent send.
    private func persist(_ state: AppState) async throws {
        var user = state.persisted
        let pending = Set(state.outbox.map(\.clientID))
        user.messages = pending.isEmpty ? [] : state.messages.filter { pending.contains($0.clientID ?? $0.id) }
        user.separateHistory = true
        let intentChanged = user.outbox != lastUserWork?.outbox
        let anchorChanged = user.readingAnchor != lastUserWork?.readingAnchor
        if user != lastUserWork {
            try await storage.write(Self.stateKey, try CoreJSON.encode(user))
            lastUserWork = user
        }
        var count = Self.cachedMessages
        if !state.following, let anchor = state.readingAnchor,
           let index = state.messages.firstIndex(where: { $0.lineID == anchor.messageID }) {
            count = min(Self.readingCachedMessages, max(count, state.messages.count - index + 20))
        }
        let history = CachedHistory(mac: state.mac, messages: Array(state.messages.suffix(count)))
        let now = clock.nowMs()
        if !historyFailed, history != lastHistory,
           anchorChanged || intentChanged || history.mac != lastHistory?.mac || history.messages.last?.id != lastHistory?.messages.last?.id ||
           lastHistoryAt == nil || now - lastHistoryAt! >= 250 {
            do {
                try await storage.write(Self.historyKey, try CoreJSON.encode(history))
                lastHistory = history
                lastHistoryAt = now
            } catch {
                // The durable transaction already succeeded. Cache failure cannot turn it into a
                // failed Send and invite a duplicate. Stop retries; history can be fetched again.
                historyFailed = true
            }
        }
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
        var saved = try CoreJSON.decode(AppState.Persisted.self, from: data)
        lastUserWork = saved
        if saved.separateHistory == true,
           let bytes = try? await storage.read(Self.historyKey),
           let cached = try? CoreJSON.decode(CachedHistory.self, from: bytes), cached.mac == saved.mac {
            lastHistory = cached
            let protected = Set(saved.messages.map(\.id))
            saved.messages = ConversationReducer.ordered(cached.messages.filter { !protected.contains($0.id) } + saved.messages)
        }
        if let interrupted = saved.activeRecording {
            let known = saved.keptRecordings.contains { $0.id == interrupted.id } || saved.outbox.contains { $0.clientID == interrupted.id }
            if !known, let recovered = try await handler?.recoverRecording(interrupted) { saved.keptRecordings.append(recovered) }
            saved.activeRecording = nil
            let restored = try AppState(restoring: saved)
            try await persist(restored)
            return restored
        }
        return try AppState(restoring: saved)
    }
}
