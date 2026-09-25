import Foundation

/// Opens `GET /api/events` and yields its bytes as they arrive. `URLSession.bytes(for:)` in the app;
/// a scripted stream in tests.
public protocol EventStreamTransport: Sendable {
    func open(_ request: HTTPRequest, origin: String) async throws -> (response: HTTPResponse, bytes: AsyncThrowingStream<Data, Error>)
}

/// The one owner of the live stream (build plan §3.2; T3's single connection owner, adoption ledger
/// §2.8 C1, written for RichOS's signed HTTP + SSE). One stream at a time; a superseded attempt never
/// publishes; retries wait 1 s doubling to 30 s (the reference `web/web-app/lib/link.js`) and the wait
/// resets when a stream opens, which is also when the phone is connected; before a retry the challenge is refreshed; after a
/// failure a revocation probe tells "removed from the Mac" from "unreachable"; `: re-snapshot` ends
/// the stream and the next one starts without `since`. Everything the stream learns reaches the
/// store as actions, so the reducer stays the only place state changes.
public actor LiveConnection {
    public typealias Sink = @Sendable (Action) async -> Void
    public typealias Sleep = @Sendable (Int64) async throws -> Void

    private let api: APIClient
    private let stream: any EventStreamTransport
    private let clock: any Clock
    private let sink: Sink
    private let sleep: Sleep
    private var threadID: String?
    private var model: ThreadModel
    /// What the store has been told, by row id, so only changes are sent.
    private var told: [String: StreamRow] = [:]
    /// The last frame's `id:` (the live cursor). A reconnect resumes from it — never from a row's
    /// history cursor or `latest_cursor`, which drift apart (Echo's measurement: three live cursors
    /// per phone message, two history positions).
    private var lastFrameID: Int?
    private var task: Task<Void, Never>?
    private var generation = 0
    /// Once stopped, never started again: a new connection is a new owner. A `stop` that reaches
    /// this actor before the `start` it followed (the app left the screen while the owner was being
    /// made) must still win.
    private var stopped = false
    private struct IncompatibleProtocol: Error {}
    public private(set) var attempts = 0
    /// The back-off wait in progress, which `wake` ends early.
    private var napping: Task<Void, Error>?
    /// A wake that came while an attempt was under way: the wait after it is skipped (Android's
    /// `wakeups` channel). Never set while the stream is open, so a healthy stream keeps nothing owed.
    private var wakeOwed = false
    private var isOpen = false

    public static let firstRetryMs: Int64 = 1000
    public static let maxRetryMs: Int64 = 30000

    public init(api: APIClient, stream: any EventStreamTransport, threadID: String?, clock: any Clock = SystemClock(),
                sleep: @escaping Sleep = { try await Task.sleep(nanoseconds: UInt64(max(0, $0)) * 1_000_000) },
                sink: @escaping Sink) {
        self.api = api; self.stream = stream; self.clock = clock; self.sink = sink; self.sleep = sleep
        self.threadID = threadID
        model = ThreadModel(selectedThread: threadID)
    }

    /// An in-memory replay checkpoint survives a warm return without keeping a socket alive.
    struct Replay: Sendable {
        var model: ThreadModel
        var told: [String: StreamRow]
        var lastFrameID: Int?
        var threadID: String?
    }

    func restore(_ replay: Replay) {
        guard task == nil, !stopped else { return }
        model = replay.model; told = replay.told
        lastFrameID = replay.lastFrameID; threadID = replay.threadID
    }

    func stopAndCheckpoint() -> Replay {
        stop()
        return Replay(model: model, told: told, lastFrameID: lastFrameID, threadID: threadID)
    }

    public func start() {
        guard task == nil, !stopped else { return }
        generation += 1
        let mine = generation
        task = Task { await self.run(mine) }
    }

    public func stop() {
        stopped = true
        generation += 1
        task?.cancel()
        task = nil
    }

    /// Try now: the person pressed "Try now", or a route came up (a tunnel, the network). What is left of
    /// the back-off is skipped and the next attempt starts at once; the back-off itself is not reset, so
    /// a Mac still out of reach is asked no more often than before (Android `ConnectionOwner.wake`).
    public func wake() {
        guard task != nil, !stopped, !isOpen else { return }
        if let napping { napping.cancel() } else { wakeOwed = true }
    }

    /// The oldest cursor held, for `before=` when older history is asked for.
    public func oldestCursor() -> Int? { model.view.first?.cursor }

    /// An older page fetched elsewhere joins the model, so later frames and pages line up with it.
    public func prepend(_ rows: [StreamRow], more: Bool) {
        model.prependOlder(rows, more: more)
        for row in rows { told[row.id] = row }
    }

    /// Waits for the current run to end (tests).
    public func finished() async { await task?.value }

    private func run(_ mine: Int) async {
        var delay = Self.firstRetryMs
        var since = lastFrameID.map { max(0, $0 - 1) }
        var first = true
        while mine == generation, !Task.isCancelled {
            // A retry asks for a live challenge first (link.js rule 2). So does a first attempt with
            // none held: after a relaunch none is stored, and signing needs one.
            let held = await api.challenge
            if !first || held == nil { _ = try? await api.probeChallenge() }
            first = false
            attempts += 1
            var path = "/api/events"
            var query: [String] = []
            if let threadID { query.append("thread_id=\(Delivery.formEncode(threadID))") }
            if let since { query.append("since=\(since)") }
            if !query.isEmpty { path += "?" + query.joined(separator: "&") }
            var resnapshot = false
            do {
                let (response, bytes) = try await openSigned(path)
                if response.status != 200 {
                    if response.status == 403, APIClient.classify(response).reason == .revoked {
                        await sink(.pairingRevoked)
                        return
                    }
                    throw APIClient.classify(response)
                }
                guard mine == generation else { return }
                // The stream is up when it opens: a 200 is a signature the Mac accepted. A reconnect
                // with `since` is answered with only the frames it missed and no `hello` (the Mac's
                // `Replay::Tail`, often empty), so waiting for a `hello` left "Reconnecting…" on a
                // healthy stream (Sage's review T9). The reference's `accepted()`
                // (`web/web-app/lib/link.js`) and Android's `Link(OPEN)`; it resets the back-off too.
                delay = Self.firstRetryMs
                isOpen = true
                wakeOwed = false
                await sink(.connected(at: clock.nowMs()))
                var parser = SSEParser()
                for try await chunk in bytes {
                    guard mine == generation else { return }
                    let (events, comments) = parser.feed(chunk)
                    for event in events {
                        try await apply(event)
                        delay = Self.firstRetryMs   // a frame proves the stream usable
                    }
                    if comments.contains(where: { $0.hasPrefix("re-snapshot") }) { resnapshot = true; break }
                }
            } catch is IncompatibleProtocol {
                return
            } catch {
                // fall through to the retry below
            }
            isOpen = false
            guard mine == generation, !Task.isCancelled else { return }
            if resnapshot {
                since = nil
                lastFrameID = nil
                told = [:]
                model = ThreadModel(selectedThread: threadID)
            } else {
                since = lastFrameID.map { max(0, $0 - 1) }
                await sink(.connectionLost(at: clock.nowMs()))
                if await probeRevoked() {
                    await sink(.pairingRevoked)
                    return
                }
            }
            if !resnapshot {
                guard await nap(delay, mine) else { return }
                delay = min(delay * 2, Self.maxRetryMs)
            }
        }
    }

    /// The back-off wait. `true` to go on: it ran out, or `wake` ended it. `false` when the owner was
    /// stopped (or the injected wait gave up), which ends the run.
    private func nap(_ ms: Int64, _ mine: Int) async -> Bool {
        if wakeOwed { wakeOwed = false; return true }
        let wait = Task { [sleep] in try await sleep(ms) }
        napping = wait
        let woke: Bool
        do {
            try await withTaskCancellationHandler { try await wait.value } onCancel: { wait.cancel() }
            woke = false
        } catch {
            woke = true
        }
        napping = nil
        guard mine == generation, !Task.isCancelled else { return false }
        // The wait threw without a wake (a test's wait that stops the owner): the run ends as before.
        if woke, !wait.isCancelled { return false }
        return true
    }

    /// Opens the stream signed with the challenge held. Every answer's `X-RichOS-Challenge` replaces
    /// the held one (the Mac puts one on every response, 404 included: `phone/listen.rs` `render`).
    /// A 404 offering a DIFFERENT challenge is the held one aged out — ten minutes
    /// (`mobile/service/CONNECT.md`), so the usual case after the phone sat in a pocket — and is
    /// re-signed with it and opened once more at once: the contract's once-only re-sign
    /// (`conformance/vectors/challenge.json`, `APIClient.signed`), with no back-off wait in front of
    /// the person who just came back. A fresh challenge costs nothing extra; only a stale one costs
    /// the second request, which a probe before every return would cost every time.
    private func openSigned(_ path: String) async throws -> (response: HTTPResponse, bytes: AsyncThrowingStream<Data, Error>) {
        var resigned = false
        while true {
            let signedWith = await api.challenge
            let request = try await api.signedRequest("GET", path, credential: .query)
            let (response, bytes) = try await stream.open(request, origin: api.origin)
            let offered = response.header("X-RichOS-Challenge")
            if let offered { await api.adopt(challenge: offered) }
            if response.status == 404, !resigned, let offered, offered != signedWith {
                resigned = true
                continue
            }
            return (response, bytes)
        }
    }

    /// After a stream error: `before=0&limit=1` on the same route answers 403 `{"revoked":true}`
    /// only when this phone was removed (the reference's revocation probe, corpus signing.json).
    private func probeRevoked() async -> Bool {
        var path = "/api/events?"
        if let threadID { path += "thread_id=\(Delivery.formEncode(threadID))&" }
        path += "before=0&limit=1"
        guard let response = try? await api.signed("GET", path, credential: .query) else { return false }
        return response.status == 403 && APIClient.classify(response).reason == .revoked
    }

    private func apply(_ event: SSEParser.Event) async throws {
        if let id = event.id { lastFrameID = id }
        if event.event == "hello" {
            let hello = try CoreJSON.decode(StreamHello.self, from: Data(event.data.utf8))
            if let version = hello.protocolVersion, version != 1 {
                lastFrameID = nil
                await sink(.macCapabilities(text: false, voice: false))
                throw IncompatibleProtocol()
            }
            if let challenge = hello.challenge { await api.adopt(challenge: challenge) }
            if threadID == nil, let thread = hello.threadID { threadID = thread; model.selectedThread = thread }
            // An older Mac advertises nothing; only an explicit list without "text" means it cannot
            // take text (the preserved client's `!negotiated || offers('text')`).
            if let capabilities = hello.capabilities, !capabilities.isEmpty {
                await sink(.macCapabilities(text: capabilities.contains("text"), voice: capabilities.contains("voice")))
                await sink(.macAttachmentLimits(capabilities.contains("attachments") ? hello.attachmentLimits : nil))
            }
        }
        try model.apply(event)
        await publish()
    }

    /// Sends the store what changed: finished rows as messages, and the one reply being written.
    private func publish() async {
        var arrived: [Message] = []
        for row in model.view where told[row.id] != row {
            let before = told[row.id]
            told[row.id] = row
            if row.complete {
                if row.role == "rich", before != nil, before?.complete == false {
                    await sink(.replyFinished(row.message))
                } else {
                    arrived.append(row.message)
                }
            } else if row.role == "rich" {
                await sink(row.text.isEmpty ? .replyStarted : .replyDelta(text: row.text))
            }
        }
        if !arrived.isEmpty { await sink(.messagesArrived(arrived)) }
    }
}
