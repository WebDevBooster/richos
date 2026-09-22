import Foundation
import Observation
import RichOSCore

/// The one observable store. It lives on the main actor because SwiftUI reads it; everything it
/// wraps — the reducer, the effect runner, the ports — is off the main actor (build plan §3.2).
///
/// Screens read `state` and call `send(_:)`. The Debug development bridge drives the same store
/// with the same actions, so what the command line proves is what a tap does.
@MainActor
@Observable
final class AppStore {
    private(set) var state: AppState
    /// A storage failure the person should know about, in plain words. `nil` while healthy.
    private(set) var persistenceProblem: String?

    @ObservationIgnored let runner: EffectRunner
    /// When the stored state could not be read, nothing is written over it: it may hold unsent
    /// work (the preserved client's rule, `richos/mobile/DEVELOPMENT.md` "Session schema 2").
    @ObservationIgnored private var storageIsReadOnly = false
    /// Effects run in the order their actions happened; each write waits for the one before.
    @ObservationIgnored private var lastWrite: Task<Void, Never>?

    init(state: AppState, runner: EffectRunner) {
        self.state = state
        self.runner = runner
    }

    /// The store for this launch: the saved state, or a new install.
    static func launch(storage: any Storage) async -> AppStore {
        let runner = EffectRunner(storage: storage)
        do {
            return AppStore(state: try await runner.load() ?? .initial, runner: runner)
        } catch let error as StoredSchemaError where error.newer {
            // Saved by a newer app (round-12 `pair-stale`): say so, and write nothing over it.
            var state = AppState.initial
            state.pairingProblem = .sessionNeedsNewerApp
            let store = AppStore(state: state, runner: runner)
            store.storageIsReadOnly = true
            return store
        } catch {
            let store = AppStore(state: .initial, runner: runner)
            store.storageIsReadOnly = true
            store.persistenceProblem = "Saved data on this iPhone could not be read, so it was left untouched."
            return store
        }
    }

    /// Where the app keeps its state: Application Support, which is backed up and not user-visible.
    static func defaultStorage() -> FileStorage {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return FileStorage(directory: base.appendingPathComponent("RichOS", isDirectory: true))
    }

    /// The UI's path: reduce now, persist in order behind the scenes.
    func send(_ action: Action) {
        apply(action)
    }

    @discardableResult
    func apply(_ action: Action) -> Task<Void, Never> {
        let (next, effects) = Reducer.reduce(state, action)
        state = next
        return perform(effects, snapshot: next)
    }

    /// Replaces the whole state (used by fixtures in Debug) and persists it.
    @discardableResult
    func replace(_ newState: AppState) -> Task<Void, Never> {
        state = newState
        return perform([.persist], snapshot: newState)
    }

    #if DEBUG
    /// Development only (the Debug bridge's `fixture` and `reset`): an explicit replacement is the
    /// one thing allowed to write over a stored state this build could not read.
    @discardableResult
    func replaceOverwritingUnreadable(_ newState: AppState) -> Task<Void, Never> {
        storageIsReadOnly = false
        persistenceProblem = nil
        return replace(newState)
    }
    #endif

    /// Waits until every write issued so far has finished.
    func settle() async {
        await lastWrite?.value
    }

    /// Rebuilds the in-memory state from storage, as a relaunch would, without writing anything.
    func reloadFromStorage() async throws {
        await settle()
        state = try await runner.load() ?? .initial
    }

    private func perform(_ effects: [Effect], snapshot: AppState) -> Task<Void, Never> {
        let previous = lastWrite
        guard !effects.isEmpty, !storageIsReadOnly else {
            return Task { await previous?.value }
        }
        let runner = self.runner
        let task = Task { [weak self] in
            await previous?.value
            do {
                try await runner.run(effects, state: snapshot)
            } catch {
                self?.persistenceProblem = "This iPhone could not save your latest changes."
            }
        }
        lastWrite = task
        return task
    }
}
