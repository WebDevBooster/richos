// Development only: compiled out of Release builds, so fixture data and the command envelope never
// ship (`richos/mobile/AGENTS.md`: "Keep fixtures and external development commands out of Release
// builds"). `bin/rios sim check-release` proves the app binary carries none of it.
#if DEBUG
import Foundation
import RichOSCore

/// The request envelope shared by `bin/rios headless …` and the Debug app's development bridge,
/// in the preserved CLI's grammar (`richos/mobile/cli/mobile.mjs` `payload()`): the same JSON
/// reaches the same runner in both places, so their results compare byte for byte.
public struct Command: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable {
        case state, reset, restart, fixture, action, scenario
    }
    public var command: Kind
    public var name: String?
    public var action: Action?

    public init(_ command: Kind, name: String? = nil, action: Action? = nil) {
        self.command = command
        self.name = name
        self.action = action
    }
}

/// The preserved runtime's result shapes (`richos/mobile/dev/runtime.js` `execute`): `{state}` for
/// a command, `{name, trace, state}` for a scenario.
public struct CommandResult: Codable, Equatable, Sendable {
    public var state: AppState
    public var name: String?
    public var trace: [TraceStep]?
}

public struct TraceStep: Codable, Equatable, Sendable {
    public var request: Command
    public var state: AppState
}

/// The reply envelope written by the Debug bridge and read by the CLI. `ok` is false exactly when
/// `error` is present.
public struct CommandResponse: Codable, Equatable, Sendable {
    public var ok: Bool
    public var result: CommandResult?
    public var error: String?

    public init(ok: Bool, result: CommandResult?, error: String?) {
        self.ok = ok
        self.result = result
        self.error = error
    }
}

/// Where commands land: the headless session on this Mac, or the live store inside the Debug app.
/// Both implement these four operations with the same reducer and effect runner.
public protocol CommandHost: AnyObject, Sendable {
    func currentState() async -> AppState
    /// Reduce, run the effects, return the new state.
    func dispatch(_ action: Action) async throws -> AppState
    /// Replace the whole state (fixture, reset) and persist it.
    func replace(with state: AppState) async throws -> AppState
    /// Rebuild the in-memory state from durable storage, as a relaunch would.
    func restart() async throws -> AppState
}

public enum CommandRunner {
    public static func execute(_ command: Command, on host: any CommandHost) async throws -> CommandResult {
        switch command.command {
        case .state:
            return CommandResult(state: await host.currentState())
        case .reset:
            return CommandResult(state: try await host.replace(with: .initial))
        case .restart:
            return CommandResult(state: try await host.restart())
        case .fixture:
            return CommandResult(state: try await host.replace(with: try Fixture.named(command.name).state))
        case .action:
            guard let action = command.action else { throw CoreError("action needs an 'action' object") }
            return CommandResult(state: try await host.dispatch(action))
        case .scenario:
            let scenario = try Scenario.named(command.name)
            var trace: [TraceStep] = []
            for step in scenario.steps {
                let result = try await execute(step, on: host)
                trace.append(TraceStep(request: step, state: result.state))
            }
            try scenario.check(trace.map(\.state))
            return CommandResult(state: await host.currentState(), name: scenario.name, trace: trace)
        }
    }

    /// Decodes one request, runs it, encodes the reply. A malformed request becomes `ok: false`,
    /// never a crash, so a bad CLI invocation cannot take the Debug app down.
    public static func respond(to request: Data, on host: any CommandHost) async -> Data {
        let response: CommandResponse
        do {
            let command = try CoreJSON.decode(Command.self, from: request)
            response = CommandResponse(ok: true, result: try await execute(command, on: host), error: nil)
        } catch let error as CoreError {
            response = CommandResponse(ok: false, result: nil, error: error.description)
        } catch let DecodingError.dataCorrupted(context) {
            response = CommandResponse(ok: false, result: nil, error: "invalid request: \(context.debugDescription)")
        } catch {
            response = CommandResponse(ok: false, result: nil, error: "invalid request: \(error)")
        }
        return (try? CoreJSON.encode(response)) ?? Data(#"{"ok":false,"error":"unencodable response"}"#.utf8)
    }
}

/// The headless host: a session on this Mac, persisted through the same `EffectRunner` the app uses.
public actor HeadlessHost: CommandHost {
    private var state: AppState
    private let runner: EffectRunner

    /// Loads the stored session, or starts a new install.
    public init(storage: any Storage) async throws {
        runner = EffectRunner(storage: storage)
        state = try await runner.load() ?? .initial
    }

    public func currentState() -> AppState { state }

    public func dispatch(_ action: Action) async throws -> AppState {
        let (next, effects) = Reducer.reduce(state, action)
        state = next
        try await runner.run(effects, state: next)
        return next
    }

    public func replace(with newState: AppState) async throws -> AppState {
        state = newState
        try await runner.run([.persist], state: newState)
        return newState
    }

    public func restart() async throws -> AppState {
        state = try await runner.load() ?? .initial
        return state
    }
}

/// Bytes kept in memory, for tests and one-shot scenarios.
public actor MemoryStorage: Storage {
    private var files: [String: Data] = [:]
    public init() {}
    public func read(_ key: String) -> Data? { files[key] }
    public func write(_ key: String, _ data: Data) { files[key] = data }
}
#endif
