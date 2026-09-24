import Foundation
import Observation

/// The one observable store. It lives on the main actor because SwiftUI reads it; everything it
/// wraps — the reducer, the effect runner, the ports — is off the main actor (build plan §3.2).
///
/// Screens read `state` and call `send(_:)`. The Debug development bridge drives the same store
/// with the same actions, so what the command line proves is what a tap does.
@MainActor
@Observable
public final class AppStore {
    public private(set) var state: AppState
    /// A storage failure the person should know about, in plain words. `nil` while healthy.
    public private(set) var persistenceProblem: String?

    @ObservationIgnored public let runner: EffectRunner
    /// When the stored state could not be read, nothing is written over it: it may hold unsent
    /// work (the preserved client's rule, `richos/mobile/DEVELOPMENT.md` "Session schema 2").
    @ObservationIgnored private var storageIsReadOnly = false
    /// Writes run in the order their actions happened; each waits for the one before. The network
    /// and platform effects run beside them, so a slow Mac never delays saving a draft.
    @ObservationIgnored private var lastWrite: Task<Void, Never>?
    @ObservationIgnored private var transaction: Task<Void, Never>?
    @ObservationIgnored private var deferred: [Action] = []
    @ObservationIgnored private var foreground = true
    public private(set) var savingSend = false

    #if DEBUG
    /// Development only: a fixture is a still frame. After the bridge's `fixture` or `reset`, the
    /// network and platform effects and the clock's ticks stop, so a screenshot shows the design and
    /// a scenario runs exactly as it does headless. A relaunch resumes normal operation.
    @ObservationIgnored public var effectsSuspended = false
    #endif

    /// Whether the app's clock should drive `tick`.
    public var ticking: Bool {
        guard persistenceProblem == nil, !savingSend else { return false }
        #if DEBUG
        return !effectsSuspended
        #else
        return true
        #endif
    }

    public init(state: AppState, runner: EffectRunner) {
        self.state = state
        self.runner = runner
    }

    /// The store for this launch: the saved state, or a new install. `effects` is the platform and
    /// network adapter (stream I3 supplies the platform half); without it, non-storage effects are
    /// recorded and skipped.
    public static func launch(storage: any Storage, effects: (any EffectHandler)? = nil) async -> AppStore {
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

    /// The UI's path: reduce now, persist in order behind the scenes.
    public func send(_ action: Action) {
        apply(action)
    }

    /// What long-running sources (the live connection) report. In a Debug fixture it is dropped: a
    /// fixture is a still frame, and a connection opened before it must not rewrite it.
    public func receive(_ action: Action) {
        #if DEBUG
        if effectsSuspended { return }
        #endif
        apply(action)
    }

    /// The app came to the front (launch, or back from the background). An OS report like the live
    /// connection's, so it goes through `receive`: in a Debug fixture it is dropped. Before, the
    /// launch's `foregrounded` reached a fixture, pumped its waiting message into "Sending…" and, with
    /// effects stopped, left it there (Urban's audit G11: `conv-retry` drew no "Waiting to send" card).
    public func becameActive(at: Int64) {
        receive(.foregrounded(at: at))
    }

    /// The phone's own light or dark setting (the CEO, 2026-09-24, Urban's audit G9: "Follow the
    /// phone"; round 12.1 has no appearance control). A mirror, never a choice: the core's
    /// `appearance` is what the phone says, sent at launch, on every return to the front and when
    /// the phone changes it. In a Debug fixture it is dropped, so a fixture keeps the theme it was
    /// photographed in (`-rios-appearance`).
    public func followPhone(_ appearance: Appearance) {
        guard state.appearance != appearance else { return }
        receive(.setAppearance(appearance))
    }

    /// The app left the screen: no stream in the background.
    public func wentToBackground(at: Int64) {
        receive(.backgrounded(at: at))
    }

    @discardableResult
    public func apply(_ action: Action) -> Task<Void, Never> {
        switch action {
        case .backgrounded: foreground = false
        case .foregrounded: foreground = true
        default: break
        }
        if let transaction {
            // Repeated presses while the same composer is being committed are one intent.
            if case .sendDraft = action {
                // A new composition followed by Send is a second intent, even on a slow disk.
                let lastCompose = deferred.lastIndex { if case .compose = $0 { return true }; return false }
                let lastSend = deferred.lastIndex { if case .sendDraft = $0 { return true }; return false }
                if lastCompose == nil || (lastSend != nil && lastSend! > lastCompose!) { return transaction }
            }
            deferred.append(action)
            if case .backgrounded = action {
                let (_, effects) = Reducer.reduce(state, action)
                let cleanup = effects.filter(Self.isCleanup)
                Task { _ = try? await runner.run(cleanup, state: state) }
            }
            return transaction
        }
        let (next, effects) = Reducer.reduce(state, action)
        let known = Set(state.outbox.map(\.clientID))
        if next.outbox.contains(where: { !known.contains($0.clientID) }) {
            return commitSend(next, effects: effects)
        }
        if next != state { state = next }
        return perform(effects, snapshot: next)
    }

    /// Keep the recoverable composer/recording visible until the new outbox entry is durable.
    private func commitSend(_ next: AppState, effects: [Effect]) -> Task<Void, Never> {
        savingSend = true
        let previous = lastWrite
        var cleanup = effects.filter(Self.isCleanup)
        #if DEBUG
        if effectsSuspended { cleanup = [] }
        #endif
        let task = Task { [self] in
            // Stopping capture must not wait for disk I/O, including when the disk fails.
            _ = try? await runner.run(cleanup, state: next)
            await previous?.value
            var saved = false
            do {
                guard !storageIsReadOnly else { throw CoreError("Saved data is read-only") }
                try await runner.run([.persist], state: next)
                state = next
                persistenceProblem = nil
                saved = true
            } catch {
                persistenceProblem = "This iPhone could not save your message. Your work has been kept; free storage and try again."
            }
            transaction = nil
            savingSend = false
            let waiting = deferred
            deferred.removeAll()
            if !saved, !cleanup.isEmpty, state.voice != nil {
                apply(.voiceInterrupted(at: SystemClock().nowMs()))
            }
            for action in waiting { apply(action) }
            if saved {
                await perform(effects.filter { $0 != .persist && !Self.isCleanup($0) }, snapshot: next).value
            }
        }
        transaction = task
        return task
    }

    private static func isCleanup(_ effect: Effect) -> Bool {
        switch effect {
        case .disconnect, .stopAudio, .stopRecording: return true
        default: return false
        }
    }

    /// Replaces the whole state (used by fixtures in Debug) and persists it.
    @discardableResult
    public func replace(_ newState: AppState) -> Task<Void, Never> {
        state = newState
        return perform([.persist], snapshot: newState)
    }

    #if DEBUG
    /// Development only (the Debug bridge's `fixture` and `reset`): an explicit replacement is the
    /// one thing allowed to write over a stored state this build could not read.
    @discardableResult
    public func replaceOverwritingUnreadable(_ newState: AppState) -> Task<Void, Never> {
        storageIsReadOnly = false
        persistenceProblem = nil
        return replace(newState)
    }
    #endif

    /// Whether writes reach storage: false when the stored state was unreadable (nothing is written
    /// over it) or the last write failed. Work handed over by another process (a share) is released
    /// by its sender only while this holds.
    public var savesWrites: Bool { !storageIsReadOnly && persistenceProblem == nil }

    /// Waits until every write issued so far has finished.
    public func settle() async {
        while let transaction { await transaction.value }
        await lastWrite?.value
    }

    /// Rebuilds the in-memory state from storage, as a relaunch would, without writing anything.
    public func reloadFromStorage() async throws {
        await settle()
        state = try await runner.load() ?? .initial
    }

    private func perform(_ effects: [Effect], snapshot: AppState) -> Task<Void, Never> {
        let previous = lastWrite
        let needsWrite = effects.contains(.persist)
        var others = effects.filter { $0 != .persist }
        #if DEBUG
        if effectsSuspended { others = [] }
        #endif
        let write = Task { [self] in
            await previous?.value
            guard needsWrite else { return true }
            guard !storageIsReadOnly else { return false }
            do {
                try await runner.run([.persist], state: snapshot)
                persistenceProblem = nil
                return true
            } catch {
                persistenceProblem = "This iPhone could not save your latest changes. Free storage to keep your work safely."
                return false
            }
        }
        if needsWrite { lastWrite = Task { _ = await write.value } }
        return Task { [self] in
            let cleanup = others.filter(Self.isCleanup)
            _ = try? await runner.run(cleanup, state: snapshot)
            guard await write.value else { return }
            var eligible = others.filter { !Self.isCleanup($0) }
            eligible.removeAll { effect in
                if case .deliver(let id) = effect {
                    return state.mac != snapshot.mac || !state.outbox.contains { $0.clientID == id && $0.state == .sending }
                }
                return false
            }
            if !foreground {
                for effect in eligible {
                    if case .deliver(let id) = effect {
                        apply(.deliveryFailed(clientID: id, failure: .retryable(reason: "background", afterMs: 0), at: SystemClock().nowMs()))
                    }
                }
                eligible.removeAll {
                    switch $0 { case .deliver, .connect, .loadOlder: return true; default: return false }
                }
            }
            guard let followUps = try? await runner.run(eligible, state: snapshot) else { return }
            for action in followUps { apply(action) }
        }
    }
}
