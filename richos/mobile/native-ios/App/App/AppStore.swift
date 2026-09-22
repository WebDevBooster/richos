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
    /// Writes run in the order their actions happened; each waits for the one before. The network
    /// and platform effects run beside them, so a slow Mac never delays saving a draft.
    @ObservationIgnored private var lastWrite: Task<Void, Never>?

    #if DEBUG
    /// Development only: a fixture is a still frame. After the bridge's `fixture` or `reset`, the
    /// network and platform effects and the clock's ticks stop, so a screenshot shows the design and
    /// a scenario runs exactly as it does headless. A relaunch resumes normal operation.
    @ObservationIgnored var effectsSuspended = false
    #endif

    /// Whether the app's clock should drive `tick`.
    var ticking: Bool {
        #if DEBUG
        return !effectsSuspended
        #else
        return true
        #endif
    }

    init(state: AppState, runner: EffectRunner) {
        self.state = state
        self.runner = runner
    }

    /// The store for this launch: the saved state, or a new install. `effects` is the platform and
    /// network adapter (stream I3 supplies the platform half); without it, non-storage effects are
    /// recorded and skipped.
    static func launch(storage: any Storage, effects: (any EffectHandler)? = nil) async -> AppStore {
        let runner = EffectRunner(storage: storage, handler: effects)
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

    /// What long-running sources (the live connection) report. In a Debug fixture it is dropped: a
    /// fixture is a still frame, and a connection opened before it must not rewrite it.
    func receive(_ action: Action) {
        #if DEBUG
        if effectsSuspended { return }
        #endif
        apply(action)
    }

    @discardableResult
    func apply(_ action: Action) -> Task<Void, Never> {
        let (next, effects) = Reducer.reduce(state, action)
        // Only a real change is published, so a tick with nothing to do redraws nothing.
        if next != state { state = next }
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

    /// Whether writes reach storage: false when the stored state was unreadable (nothing is written
    /// over it) or the last write failed. Work handed over by another process (a share) is released
    /// by its sender only while this holds.
    var savesWrites: Bool { !storageIsReadOnly && persistenceProblem == nil }

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
        let runner = self.runner
        // An unreadable stored state is never written over; every other effect still runs.
        let writes = storageIsReadOnly ? [] : effects.filter { $0 == .persist }
        var others = effects.filter { $0 != .persist }
        #if DEBUG
        if effectsSuspended { others = [] }
        #endif
        let work = Task { [weak self] in
            // An effect's answer ("the microphone is allowed", "the Mac accepted it") is an action
            // like any other: it goes through the reducer.
            guard !others.isEmpty, let followUps = try? await runner.run(others, state: snapshot) else { return }
            for action in followUps { self?.apply(action) }
        }
        guard !writes.isEmpty else {
            return Task { await previous?.value; await work.value }
        }
        let write = Task { [weak self] in
            await previous?.value
            do {
                try await runner.run(writes, state: snapshot)
            } catch {
                self?.persistenceProblem = "This iPhone could not save your latest changes."
            }
        }
        lastWrite = write
        return Task { await write.value; await work.value }
    }
}
