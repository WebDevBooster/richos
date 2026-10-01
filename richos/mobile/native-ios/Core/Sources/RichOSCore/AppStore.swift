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
    public private(set) var recordingProblem: String?

    @ObservationIgnored private let performance: @Sendable (String) -> Void
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
    @ObservationIgnored private var completionActive = false
    /// The durable lease for this batch, being written or written (`nil` inside: no lease left this
    /// hour or day). Started when the batch begins on screen and never awaited there, so a Home that
    /// arrives while it is written finds the batch begun (iPhone walk D3).
    @ObservationIgnored private var completionReservation: Task<Int64?, Never>?
    /// Counts batches, so a deadline that outlives its batch cannot expire the next one.
    @ObservationIgnored private var completionBatch = 0
    /// Messages whose Send is being saved right now: already sent on screen, not yet in `state`.
    @ObservationIgnored private var committing: Set<String> = []
    /// The OS's extra time after Home (`BackgroundContinuation`), held for the current batch.
    @ObservationIgnored public var backgroundContinuation: (any BackgroundContinuation)?
    /// One line per step of a send's life around Home (the batch, the request, its answer), for the
    /// phone's own log. Fixed words and counts only: never a message, an id or anything the Mac said.
    /// Without it a message that stayed on the phone left no account of why (iPhone re-walk D3).
    @ObservationIgnored public var sendLog: @Sendable (String) -> Void = { _ in }
    @ObservationIgnored private var continuationHeld = false
    @ObservationIgnored private var completionSpent = false
    @ObservationIgnored private var completionExpired = false
    @ObservationIgnored private var completionIDs: Set<String> = []
    @ObservationIgnored private var completionRequests = 0
    @ObservationIgnored private var completionBytes = 0
    @ObservationIgnored private var completionDeadline: Task<Void, Never>?
    /// When this batch's bound after Home runs out (ms since 1970); `nil` until it has started.
    @ObservationIgnored private var completionBoundEndsAt: Int64?
    @ObservationIgnored private var deliveryTask: Task<[Action], Never>?
    @ObservationIgnored private var hiddenCut: Task<Void, Never>?
    @ObservationIgnored private var hungCut = false
    @ObservationIgnored private var delivering: OutboxItem?
    /// The delivery given up because the stream to the Mac was lost (`connectionLost`).
    @ObservationIgnored private var linkLostDelivery: String?
    @ObservationIgnored private var historyTask: Task<[Action], Never>?
    @ObservationIgnored private var historyGeneration = 0
    /// Pairing v2's probe for the press on the Mac, while one is in flight. Leaving the screen
    /// cancels it, and its answer is then dropped: nothing about the wait runs off screen.
    @ObservationIgnored private var macWaitTask: Task<[Action], Never>?


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

    public init(state: AppState, runner: EffectRunner, performance: @escaping @Sendable (String) -> Void = { _ in }) {
        self.performance = performance
        self.state = state
        self.runner = runner
    }

    /// The store for this launch: the saved state, or a new install. `effects` is the platform and
    /// network adapter (stream I3 supplies the platform half); without it, non-storage effects are
    /// recorded and skipped.
    public static func launch(storage: any Storage, effects: (any EffectHandler)? = nil,
                              performance: @escaping @Sendable (String) -> Void = { _ in }) async -> AppStore {
        let runner = EffectRunner(storage: storage, handler: effects)
        do {
            return AppStore(state: try await runner.load() ?? .initial, runner: runner, performance: performance)
        } catch let error as StoredSchemaError where error.newer {
            // Saved by a newer app (round-12 `pair-stale`): say so, and write nothing over it.
            var state = AppState.initial
            state.pairingProblem = .sessionNeedsNewerApp
            let store = AppStore(state: state, runner: runner, performance: performance)
            store.storageIsReadOnly = true
            return store
        } catch {
            let store = AppStore(state: .initial, runner: runner, performance: performance)
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
        if case .replyDelta = action { performance("text-received") }
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
        if case .sendDraft = action { performance("send-requested") }
        switch action {
        case .voicePress, .voiceStartLocked: recordingProblem = nil
        case .backgrounded:
            foreground = false
            if state.outbox.contains(where: { $0.state == .sending && ($0.questionID != nil || $0.clientID.hasPrefix("seen-question:")) }) {
                deliveryTask?.cancel()
            }
            historyGeneration &+= 1
            historyTask?.cancel()
            historyTask = nil
            macWaitTask?.cancel()
            macWaitTask = nil
            sendLog("left the screen: batch \(completionActive ? "open" : "none"), request \(deliveryTask != nil ? "in flight" : "none"), saving \(committing.count), sending \(state.outbox.filter { $0.state == .sending }.count), waiting \(state.outbox.filter { $0.state == .waiting }.count)")
            startCompletionDeadline()
        case .foregrounded:
            foreground = true
            sendLog("back on screen: waiting \(state.outbox.filter { $0.state == .waiting }.count)")
        case .connected: sendLog("stream open")
        case .connectionLost:
            sendLog("stream lost")
            // The stream to the Mac is lost (dropped, or silent past `LiveConnection.silenceLimitMs`)
            // while a message is on its way: the request is given up and the message waits, saying
            // so, and goes again under the same id when the stream reopens (`connected` pumps; the
            // Mac keeps one copy per id, `app/src-tauri/src/phone/delivery.rs` `Duplicate`). Left to
            // run, a request to a Mac that stopped answering drew "Sending…" until its own 30 s
            // timeout (iPhone walk D5). Only on screen: in the background no stream is open, and the
            // bounded completion owns what is in flight.
            if foreground, let delivering, deliveryTask != nil {
                sendLog("stream lost on screen: request given up")
                linkLostDelivery = delivering.clientID
                deliveryTask?.cancel()
            }
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
        var startAllowed = true
        #if DEBUG
        startAllowed = !effectsSuspended
        #endif
        if startAllowed, effects.contains(where: { if case .startRecording = $0 { return true }; return false }) {
            return beginRecording(next, effects: effects)
        }
        let known = Set(state.outbox.map(\.clientID))
        if next.outbox.contains(where: { !known.contains($0.clientID) }) {
            return commitSend(next, effects: effects)
        }
        if next != state { state = next }
        return perform(effects, snapshot: next)
    }

    /// Journal before opening the microphone, then publish recording only after capture succeeds.
    private func beginRecording(_ next: AppState, effects: [Effect]) -> Task<Void, Never> {
        let previous = lastWrite
        let task = Task { [self] in
            await previous?.value
            var started = false
            var problem: String?
            do {
                guard !storageIsReadOnly else { throw CoreError("Saved data is read-only") }
                try await runner.run([.persist], state: next)
                if foreground {
                    let replies = try await runner.run(effects.filter { if case .startRecording = $0 { return true }; return false }, state: next)
                    started = !replies.contains { if case .voiceStartFailed = $0 { return true }; return false }
                    if started {
                        state = next
                        persistenceProblem = nil
                        if !foreground, let id = next.voice?.id {
                            _ = try await runner.run([.stopRecording(id: id, keep: true)], state: next)
                        }
                    } else {
                        state.voice = nil
                        for reply in replies { state = Reducer.reduce(state, reply).0 }
                        recordingProblem = "The microphone could not start. Check microphone access and try again."
                    }
                } else { state.voice = nil }
            } catch {
                state.voice = nil
                problem = "This iPhone could not prepare a recoverable recording. Free storage and try again."
            }
            if !started { await perform([.persist], snapshot: state).value }
            if let problem { persistenceProblem = problem }
            transaction = nil
            let waiting = deferred
            deferred.removeAll()
            for action in waiting { apply(action) }
        }
        transaction = task
        return task
    }

    /// Keep the recoverable composer/recording visible until the new outbox entry is durable.
    private func commitSend(_ next: AppState, effects: [Effect]) -> Task<Void, Never> {
        savingSend = true
        let previous = lastWrite
        var cleanup = effects.filter(Self.isCleanup)
        #if DEBUG
        if effectsSuspended { cleanup = [] }
        #endif
        // The Send is pressed now, on screen: its bounded completion begins now, not when its request
        // starts. Home commonly arrives while the Send is still being saved, and a batch begun only at
        // the request found the app already hidden and refused the message ("background-budget"); it
        // then stayed on the phone until the app was next opened (iPhone walk D3).
        let known = Set(state.outbox.map(\.clientID))
        let fresh = next.outbox.filter { !known.contains($0.clientID) }
        let freshIDs = Set(fresh.map(\.clientID))
        committing.formUnion(freshIDs)
        sendLog("send pressed: stream \(state.linkOpen ? "open" : "closed"), \(foreground ? "on screen" : "hidden")")
        var completes = fresh.contains { !Self.isQuestionOperation($0) }
        #if DEBUG
        if effectsSuspended { completes = false }
        #endif
        let persisted = Task<Bool, Never> { [self] in
            // Stopping capture must not wait for disk I/O, including when the disk fails.
            _ = try? await runner.run(cleanup, state: next)
            await previous?.value
            guard !storageIsReadOnly else { return false }
            do { try await runner.run([.persist], state: next) } catch { return false }
            return true
        }
        // The lease is written after the message: the Send is durable first.
        if completes { beginCompletion(after: persisted) }
        let task = Task { [self] in
            let saved = await persisted.value
            if saved {
                performance("durable-queued")
                state = next
                persistenceProblem = nil
            } else {
                persistenceProblem = "This iPhone could not save your message. Your work has been kept; free storage and try again."
            }
            committing.subtract(freshIDs)
            transaction = nil
            savingSend = false
            var waiting = deferred
            deferred.removeAll()
            if !saved, let edited = waiting.compactMap({ action -> String? in
                if case .compose(let text) = action { return text }; return nil
            }).last {
                // A failed first send must not be overwritten by typing that arrived behind it.
                // Keep both pieces of text for recovery and never automatically send a combined draft.
                let original = state.draft
                state.draft = original.isEmpty || edited.hasPrefix(original) ? edited : original + "\n\n" + edited
                waiting.removeAll { action in
                    switch action { case .compose, .sendDraft: return true; default: return false }
                }
            }
            if !saved, !cleanup.isEmpty, state.voice != nil {
                apply(.voiceInterrupted(at: SystemClock().nowMs()))
            }
            for action in waiting { apply(action) }
            if saved {
                await perform(effects.filter { $0 != .persist && !Self.isCleanup($0) }, snapshot: next).value
            } else {
                // Nothing was queued, so nothing will be sent: give the time back now.
                await finishCompletionIfIdle()
            }
        }
        transaction = task
        return task
    }

    private static func isQuestionOperation(_ item: OutboxItem) -> Bool {
        item.questionID != nil || item.clientID.hasPrefix("seen-question:")
    }

    private static func isRetryableFailure(_ action: Action) -> Bool {
        if case .deliveryFailed(_, .retryable, _) = action { return true }
        return false
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
                for effect in effects {
                    if case .deliver(let id) = effect,
                       state.outbox.contains(where: { $0.clientID == id && $0.state == .sending }) {
                        // The previous durable entry is still waiting. Do not leave an undelivered
                        // message stuck as in-flight after the save that authorized delivery failed.
                        state = Reducer.reduce(state, .deliveryFailed(clientID: id,
                            failure: .retryable(reason: "local-storage", afterMs: 0), at: 0)).state
                    }
                }
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
                eligible.removeAll { switch $0 { case .connect, .loadOlder, .checkMacConfirmation: return true; default: return false } }
            }
            for effect in eligible {
                let followUps: [Action]
                if case .deliver(let id) = effect {
                    followUps = await deliver(id, snapshot: snapshot)
                } else if case .checkMacConfirmation = effect {
                    let task = Task { [runner] in (try? await runner.run([effect], state: snapshot)) ?? [] }
                    macWaitTask = task
                    let actions = await task.value
                    if macWaitTask == task { macWaitTask = nil }
                    followUps = !task.isCancelled && foreground ? actions : []
                } else if case .loadOlder = effect {
                    historyGeneration &+= 1
                    let generation = historyGeneration
                    let task = Task { [runner] in (try? await runner.run([effect], state: snapshot)) ?? [] }
                    historyTask = task
                    let actions = await task.value
                    if generation == historyGeneration { historyTask = nil }
                    followUps = !task.isCancelled && foreground && generation == historyGeneration && state.mac == snapshot.mac ? actions : []
                } else {
                    followUps = (try? await runner.run([effect], state: snapshot)) ?? []
                }
                for action in followUps { apply(action) }
            }
            await finishCompletionIfIdle()
        }
    }
    private static func completionCost(_ item: OutboxItem) -> Int {
        item.kind == .text ? (item.body?.utf8.count ?? 256 * 1024) + 4096 : 256 * 1024 + 1
    }

    /// Begins a bounded completion batch for a send started on screen: the durable lease is asked for
    /// (after `save`, when a Send is being saved; never awaited here) and the OS is asked for time
    /// after Home. A no-op off screen or while a batch is open.
    private func beginCompletion(after save: Task<Bool, Never>? = nil) {
        guard !completionActive, foreground else { return }
        completionActive = true
        completionBatch &+= 1
        sendLog("batch began on screen")
        completionReservation = Task { [runner] in
            _ = await save?.value
            return await runner.reserveCompletion()
        }
        if !continuationHeld, let backgroundContinuation {
            continuationHeld = true
            backgroundContinuation.begin(expired: { [weak self] in self?.backgroundTimeExpired() })
        }
    }

    /// The OS took the time back (its adapter ends the task itself): the batch is over, and the request
    /// in flight is given up so the message waits on the phone.
    private func backgroundTimeExpired() {
        continuationHeld = false
        sendLog("iOS took the background time back: batch \(completionActive ? "open" : "none"), request \(deliveryTask != nil ? "in flight" : "none")")
        guard completionActive else { return }
        completionExpired = true
        if !foreground { deliveryTask?.cancel() }
    }

    private func endBackgroundTime() {
        guard continuationHeld else { return }
        continuationHeld = false
        backgroundContinuation?.end()
    }

    private func startCompletionDeadline() {
        guard completionActive else { return }
        if completionExpired { deliveryTask?.cancel(); return }
        guard completionDeadline == nil else { return }
        completionSpent = true
        // What was sent on screen: the queue, and a Send still being saved.
        completionIDs = Set(state.outbox.map(\.clientID)).union(committing)
        if let item = delivering {
            completionRequests += 1
            completionBytes += Self.completionCost(item)
        }
        if completionBytes > 256 * 1024 {
            completionExpired = true
            deliveryTask?.cancel()
            return
        }
        let batch = completionBatch
        let reservation = completionReservation
        completionDeadline = Task { [weak self] in
            // No lease left (six an hour, 24 a day): the batch ends now, as before.
            let leased = await reservation?.value != nil
            self?.sendLog(leased ? "hidden: 5 s bound started" : "hidden: no background lease left, bound ends now")
            if leased {
                if let self, self.completionBatch == batch {
                    self.completionBoundEndsAt = SystemClock().nowMs() + Self.completionBoundMs
                    // A request already in flight at Home gets its deadline from the bound's start.
                    if !self.foreground, let inFlight = self.deliveryTask { self.armHiddenCut(for: inFlight) }
                }
                guard (try? await Task.sleep(for: .milliseconds(Self.completionBoundMs))) != nil else { return }
            }
            guard let self, self.completionActive, self.completionBatch == batch, !Task.isCancelled else { return }
            self.completionExpired = true
            self.sendLog("hidden: bound ran out, request \(self.deliveryTask != nil ? "in flight, given up" : "none")")
            if !self.foreground { self.deliveryTask?.cancel() }
        }
    }

    /// Hidden, inside a started bound, one request may hang this long before it is cut and goes again.
    /// A network that drops under a request leaves the socket up and the transport's own timeout is
    /// 30 s, so such a request never faults inside the 5 s bound (the Honor's hung send; the same
    /// code here). Only when a full deadline fits before the bound ends: with less left the bound's
    /// own end cuts it, as before. A delay inside the bound already held, no new background work.
    static let hiddenAttemptMs: Int64 = 2000

    private func armHiddenCut(for task: Task<[Action], Never>) {
        guard let endsAt = completionBoundEndsAt, endsAt - SystemClock().nowMs() > Self.hiddenAttemptMs else { return }
        hiddenCut?.cancel()
        hiddenCut = Task { [weak self] in
            guard (try? await Task.sleep(for: .milliseconds(Self.hiddenAttemptMs))) != nil else { return }
            guard let self, !self.foreground, self.deliveryTask == task, !task.isCancelled else { return }
            self.hungCut = true
            task.cancel()
        }
    }

    /// The bound after Home: how long a batch begun on screen may keep going once the app is hidden.
    static let completionBoundMs: Int64 = 5000

    /// One delivery, and, while the app is hidden inside a started bound, the same message again
    /// after a transient failure (iPhone re-walk D3, on the phone, three of three tries: the request
    /// in flight at Home came back a fault 1.4 s into the bound, the batch ended there with the
    /// message unsent and gave the time back, and the message waited until the app was next opened).
    /// Off screen nothing else would try it: a waiting message is moved by the tick or by `connected`,
    /// and both need the Mac's stream, which is closed off screen. So the pause the outbox would wait
    /// on screen (1 s doubling, or the Mac's own Retry-After) is waited here, inside the bound and the
    /// batch's three requests, under the same id (the Mac keeps one copy per id). The pause is the
    /// request slot, so the bound running out or iOS taking the time back cancels it.
    private func deliver(_ id: String, snapshot: AppState) async -> [Action] {
        var actions = await deliverOnce(id, snapshot: snapshot)
        var again = 0
        while let pause = hiddenRetryPause(id, snapshot: snapshot, after: actions, again: again) {
            again += 1
            sendLog("hidden: going again in \(pause) ms")
            let wait = Task<[Action], Never> { _ = try? await Task.sleep(for: .milliseconds(pause)); return [] }
            deliveryTask = wait
            _ = await wait.value
            deliveryTask = nil
            if wait.isCancelled {
                sendLog("hidden: bound ran out before going again")
                return actions
            }
            actions = await deliverOnce(id, snapshot: snapshot)
        }
        return actions
    }

    /// The pause before the same message goes again while hidden, or `nil` when it does not: the
    /// answer was a transient failure at the Mac or the network (never the phone's own deferral), the
    /// batch's bound has started and still has room for the pause, and the batch has a request and the
    /// bytes left for it.
    private func hiddenRetryPause(_ id: String, snapshot: AppState, after actions: [Action], again: Int) -> Int64? {
        guard !foreground, completionActive, !completionExpired, let endsAt = completionBoundEndsAt,
              actions.count == 1, case .deliveryFailed(let failed, .retryable(let reason, let afterMs), _) = actions[0],
              failed == id, !ConversationReducer.deferralReasons.contains(reason ?? ""),
              let item = snapshot.outbox.first(where: { $0.clientID == id }), !Self.isQuestionOperation(item) else { return nil }
        guard completionRequests < 3, Self.completionCost(item) <= 256 * 1024 - completionBytes else {
            sendLog("hidden: not going again (requests \(completionRequests))")
            return nil
        }
        let pause = max(0, afterMs ?? ConversationReducer.retryDelayMs(attempt: item.attempts + again + 1))
        guard SystemClock().nowMs() + pause < endsAt else {
            sendLog("hidden: not going again (the bound ends first)")
            return nil
        }
        return pause
    }

    private func deliverOnce(_ id: String, snapshot: AppState) async -> [Action] {
        guard let item = snapshot.outbox.first(where: { $0.clientID == id }) else { return [] }
        let questionOperation = Self.isQuestionOperation(item)
        if questionOperation && !foreground {
            return [.deliveryFailed(clientID: id, failure: .retryable(reason: "background", afterMs: 0), at: SystemClock().nowMs())]
        }
        if !questionOperation { beginCompletion() }
        if !foreground {
            // The lease was asked for when the batch began on screen; its answer is awaited only here.
            // Awaiting it before the request (on screen) let a Home in the meantime refuse the message.
            let leased = await completionReservation?.value != nil
            guard leased, completionActive, !completionExpired, completionIDs.contains(id),
                  completionRequests < 3, Self.completionCost(item) <= 256 * 1024 - completionBytes else {
                sendLog("hidden: not sent (lease \(leased), batch \(completionActive), bound \(completionExpired ? "ran out" : "left"), sent on screen \(completionIDs.contains(id)), requests \(completionRequests))")
                return [.deliveryFailed(clientID: id, failure: .retryable(reason: "background-budget", afterMs: 0), at: SystemClock().nowMs())]
            }
            completionRequests += 1
            completionBytes += Self.completionCost(item)
        }
        delivering = item
        let startedAt = SystemClock().nowMs()
        sendLog("request started \(foreground ? "on screen" : "hidden")")
        let task = Task { [runner] in (try? await runner.run([.deliver(clientID: id)], state: snapshot)) ?? [] }
        deliveryTask = task
        hungCut = false
        if !foreground, completionBoundEndsAt != nil { armHiddenCut(for: task) }
        let actions = await task.value
        hiddenCut?.cancel()
        hiddenCut = nil
        deliveryTask = nil
        delivering = nil
        // Cut by its own deadline: the network hung under it, so it goes again (see `armHiddenCut`).
        if hungCut, task.isCancelled, actions.allSatisfy(Self.isRetryableFailure) {
            hungCut = false
            sendLog("hidden: request cut after \(Self.hiddenAttemptMs) ms")
            return [.deliveryFailed(clientID: id, failure: .retryable(reason: "timeout", afterMs: nil), at: SystemClock().nowMs())]
        }
        sendLog("answer: \(Self.answerWord(actions, canceled: task.isCancelled)) after \(SystemClock().nowMs() - startedAt) ms, \(foreground ? "on screen" : "hidden")")
        let lostLink = linkLostDelivery == id
        if lostLink { linkLostDelivery = nil }
        // Given up because the stream was lost: waiting, not a failed attempt, unless the Mac's
        // answer (an acceptance or a refusal) arrived before the cancel did.
        if task.isCancelled, lostLink, actions.allSatisfy(Self.isRetryableFailure) {
            return [.deliveryFailed(clientID: id, failure: .retryable(reason: "link-lost", afterMs: 0), at: SystemClock().nowMs())]
        }
        // A canceled adapter may have no result. Preserve the durable entry as waiting.
        if task.isCancelled, actions.isEmpty {
            return [.deliveryFailed(clientID: id, failure: .retryable(reason: "background-budget", afterMs: 0), at: SystemClock().nowMs())]
        }
        return actions
    }

    /// Ends the batch once nothing of it is left: no Send being saved, no request in flight, nothing
    /// marked sending.
    private func finishCompletionIfIdle() async {
        guard completionActive, committing.isEmpty, deliveryTask == nil,
              !state.outbox.contains(where: { $0.state == .sending }) else { return }
        await finishCompletion()
    }

    /// The kind of answer, in fixed words for the phone's log; a reason is named only when it is one
    /// of the phone's own (never text the Mac sent).
    static func answerWord(_ actions: [Action], canceled: Bool) -> String {
        let known: Set<String> = ["unreachable", "fault", "refused", "revoked", "background", "background-budget", "link-lost", "local-storage"]
        let kind: String
        switch actions.first {
        case .deliveryAccepted?, .questionAnswered?: kind = "accepted"
        case .deliveryFailed(_, .retryable(let reason, _), _)?: kind = "retryable (\(reason.map { known.contains($0) ? $0 : "other" } ?? "none"))"
        case .deliveryFailed(_, .refused, _)?: kind = "refused"
        case .deliveryFailed(_, .refusedStopQueue, _)?: kind = "refused, queue stopped"
        case .deliveryFailed(_, .revoked, _)?: kind = "revoked"
        case nil: kind = "none"
        default: kind = "other"
        }
        return canceled ? kind + ", canceled" : kind
    }

    private func finishCompletion() async {
        sendLog("batch ended: \(completionSpent ? "after leaving the screen" : "on screen"), still to send \(state.outbox.filter { $0.state != .blocked }.count)")
        let reservation = completionReservation
        let spent = completionSpent
        completionDeadline?.cancel()
        completionDeadline = nil
        completionBoundEndsAt = nil
        completionActive = false
        completionBatch &+= 1
        completionReservation = nil
        completionSpent = false
        completionExpired = false
        completionIDs = []
        completionRequests = 0
        completionBytes = 0
        // The Mac's answer is saved before the time goes back: suspended first, the phone kept the
        // message marked unsent on disk until it was next opened (seen in the simulator check).
        let batch = completionBatch
        await lastWrite?.value
        // A batch begun meanwhile keeps the time and gives it back itself.
        if completionBatch == batch, !completionActive { endBackgroundTime() }
        if !spent, let token = await reservation?.value { await runner.refundCompletion(token) }
    }

}
