import Foundation

/// Opens `GET /api/events` and yields its bytes as they arrive. `URLSession.bytes(for:)` in the app;
/// a scripted stream in tests.
public protocol EventStreamTransport: Sendable {
    func open(_ request: HTTPRequest, origin: String) async throws -> (response: HTTPResponse, bytes: AsyncThrowingStream<Data, Error>)
}

/// The one owner of the live stream (build plan §3.2; T3's single connection owner, adoption ledger
/// §2.8 C1, written for RichOS's signed HTTP + SSE). One stream at a time; a superseded attempt never
/// publishes; retries wait 1 s doubling to 30 s (the reference `web/web-app/lib/link.js`) and the wait
/// resets when a stream opens, which is also when the phone is connected; a stream silent past
/// `silenceLimitMs` is lost like a dropped one; a challenge is asked for only when none is held; after
/// an open the Mac refused, a revocation probe tells "removed from the Mac" from other refusals; `: re-snapshot` ends
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
    /// The wait behind the silence limit: the real clock in the app, a clock the test moves in tests.
    private let silence: Sleep
    private var threadID: String?
    private var model: ThreadModel
    /// What the store has been told, by row id, so only changes are sent.
    private var told: [String: StreamRow] = [:]
    /// The last frame's `id:` (the live cursor). A reconnect resumes from it — never from a row's
    /// history cursor or `latest_cursor`, which drift apart (Echo's measurement: three live cursors
    /// per phone message, two history positions).
    private var lastFrameID: Int?
    /// **WHETHER `lastFrameID` IS A `hello`'S AND NO LIVE FRAME HAS COME SINCE.** A `hello`'s id is the
    /// Mac's cursor when it was built, and the Mac may hold no frame at or after it: right after pairing
    /// (nothing published yet), or after its cursor was seeded from the conversation's row count. A
    /// resume from there (`since` = id - 1) is answered with an EMPTY opening, and the Mac's listener
    /// sends no response head until the stream's first bytes, which are its keep-alive 15 s later
    /// (`app/src-tauri/src/phone/listen.rs` `open_stream`, `KEEPALIVE_MS`). For those 15 s the phone is
    /// not connected: a waiting message is not sent and a reply that arrived while it was away is not
    /// shown (the headless lab with this core: 15.3 s after the return, `Tools/LabPhone --away-before`).
    /// So after a `hello` the stream is opened without `since`: the Mac answers with a `hello`, which is
    /// never empty, and the thread model merges it by row id, so nothing is shown twice.
    private var lastFrameIsHello = false
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

    /// **HOW LONG AN OPEN STREAM MAY STAY SILENT BEFORE IT IS TREATED AS LOST.** The Mac writes a
    /// `: keep-alive` comment after every 15 s without a frame (`app/src-tauri/src/phone/mod.rs`
    /// `KEEPALIVE_MS`, written in `listen.rs` `open_stream`), so a healthy stream is never quiet for
    /// longer than that; 5 s more covers the route's own delay. Past it, the stream is half-open (the
    /// Mac stopped answering, or the route dropped it without a word) and is closed and opened again
    /// like any other loss. Before, the only detector was the stream request's 60 s idle timeout, so a
    /// Mac that stopped answering with the app open went unexplained for over a minute and a message
    /// sent meanwhile drew "Sending…" (iPhone walk D5, 2026-10-01). T3's single connection owner treats
    /// an unanswered keepalive the same way (adoption ledger §2.8 C1, COPY THE DESIGN). Every byte
    /// starts the wait again, and the wait exists only while a stream is open, on screen: no timer at
    /// rest or in the background.
    public static let silenceLimitMs: Int64 = 20_000

    public init(api: APIClient, stream: any EventStreamTransport, threadID: String?, clock: any Clock = SystemClock(),
                sleep: @escaping Sleep = { try await Task.sleep(nanoseconds: UInt64(max(0, $0)) * 1_000_000) },
                silence: @escaping Sleep = { try await Task.sleep(nanoseconds: UInt64(max(0, $0)) * 1_000_000) },
                sink: @escaping Sink) {
        self.api = api; self.stream = stream; self.clock = clock; self.sink = sink; self.sleep = sleep
        self.silence = silence
        self.threadID = threadID
        model = ThreadModel(selectedThread: threadID)
    }

    /// An in-memory replay checkpoint survives a warm return without keeping a socket alive.
    struct Replay: Sendable {
        var model: ThreadModel
        var told: [String: StreamRow]
        var lastFrameID: Int?
        var threadID: String?
        var lastFrameIsHello = false
    }

    func restore(_ replay: Replay) {
        guard task == nil, !stopped else { return }
        model = replay.model; told = replay.told
        lastFrameID = replay.lastFrameID; threadID = replay.threadID
        lastFrameIsHello = replay.lastFrameIsHello
    }

    func stopAndCheckpoint() -> Replay {
        stop()
        return Replay(model: model, told: told, lastFrameID: lastFrameID, threadID: threadID, lastFrameIsHello: lastFrameIsHello)
    }

    /// Where a stream resumes: one frame before the last one seen, so the Mac's opening repeats that
    /// row and is never empty; `nil` (a `hello`) when nothing was seen, or when the last thing seen was
    /// a `hello` (see `lastFrameIsHello`).
    private func resumePoint() -> Int? {
        guard !lastFrameIsHello else { return nil }
        return lastFrameID.map { max(0, $0 - 1) }
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
        var since = resumePoint()
        while mine == generation, !Task.isCancelled {
            // **NOTHING STANDS BETWEEN A FAILED STREAM AND THE NEXT OPEN** (andy-opus-resume1's
            // second Android wait, the same code here). Only with no challenge held is one asked for
            // first: after a relaunch none is stored, and signing needs one. With one held, a retry
            // opens at once like a first attempt: a stale challenge is answered with a 404 offering
            // the new one, which `openSigned` re-signs with at once, at the cost the probe had. Before,
            // every retry asked for a challenge first (link.js's `refresh`), a request with the 30 s
            // timeout that `wake` could not cut short, on the stalled network where retries happen.
            if await api.challenge == nil { _ = try? await api.probeChallenge() }
            attempts += 1
            var path = "/api/events"
            var query: [String] = []
            if let threadID { query.append("thread_id=\(Delivery.formEncode(threadID))") }
            if let since { query.append("since=\(since)") }
            if !query.isEmpty { path += "?" + query.joined(separator: "&") }
            var resnapshot = false
            /// The Mac answered the open, and not with a stream.
            var refused = false
            do {
                let (response, bytes) = try await openSigned(path)
                if response.status != 200 {
                    if response.status == 403, APIClient.classify(response).reason == .revoked {
                        await sink(.pairingRevoked)
                        return
                    }
                    refused = true
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
                let watched = Self.watched(bytes, limitMs: Self.silenceLimitMs, wait: silence)
                for try await chunk in watched {
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
                lastFrameIsHello = false
                told = [:]
                model = ThreadModel(selectedThread: threadID)
            } else {
                since = resumePoint()
                await sink(.connectionLost(at: clock.nowMs()))
                // Asked only when the Mac answered the open with a refusal. A removed phone's open is
                // answered 403 `{"revoked":true}` by the Mac itself, before any other check
                // (`app/src-tauri/src/phone/device.rs` `Refusal::Revoked`), which the open above
                // reads; after an open nobody answered, or a stream that dropped, the next open is
                // the question, and a probe there was a request with the 30 s timeout in front of it
                // that nothing could cut short (andy-opus-resume1's second Android wait).
                if refused, await probeRevoked() {
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
        if let id = event.id {
            lastFrameID = id
            lastFrameIsHello = event.event == "hello"
        }
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
                await sink(.macQuestionCapability(capabilities.contains("questions")))
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

    /// The stream went quiet for longer than `silenceLimitMs`: lost, like a dropped socket.
    struct StreamWentSilent: Error {}

    /// `bytes`, ended with `StreamWentSilent` when nothing arrives for `limitMs`. Each chunk starts the
    /// wait again. However this stream ends (silence, the Mac closing it, an error, or its reader
    /// walking away), the wait is canceled and `bytes` is closed, so neither the timer nor the socket
    /// outlives it.
    static func watched(_ bytes: AsyncThrowingStream<Data, Error>, limitMs: Int64, wait: @escaping Sleep) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            let watchdog = SilenceWatchdog(limitMs: limitMs, wait: wait) {
                continuation.finish(throwing: StreamWentSilent())
            }
            let reader = Task {
                await watchdog.arm()
                do {
                    for try await chunk in bytes {
                        await watchdog.arm()
                        continuation.yield(chunk)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
                await watchdog.disarm()
            }
            continuation.onTermination = { _ in
                reader.cancel()
                Task { await watchdog.disarm() }
            }
        }
    }
}

/// One silence wait at a time for one open stream. `arm` replaces the wait in progress; a wait that
/// was replaced or disarmed while it ran never fires.
private actor SilenceWatchdog {
    private let limitMs: Int64
    private let wait: LiveConnection.Sleep
    private let silent: @Sendable () -> Void
    private var timer: Task<Void, Never>?
    private var round = 0
    private var over = false

    init(limitMs: Int64, wait: @escaping LiveConnection.Sleep, silent: @escaping @Sendable () -> Void) {
        self.limitMs = limitMs; self.wait = wait; self.silent = silent
    }

    func arm() {
        guard !over else { return }
        timer?.cancel()
        round += 1
        let mine = round
        let wait = self.wait, limitMs = self.limitMs
        // Written without `do`/`catch` and with a weak capture: the actor-isolated form
        // (`do { try await wait(limitMs) } catch { return }` capturing `self`) aborted the process
        // in `swift_task_dealloc` ("freed pointer was not the last allocation") under Xcode 26.3.
        timer = Task { [weak self] in
            guard (try? await wait(limitMs)) != nil else { return }
            await self?.ranOut(mine)
        }
    }

    func disarm() {
        over = true
        timer?.cancel()
        timer = nil
    }

    private func ranOut(_ mine: Int) {
        guard !over, mine == round else { return }
        over = true
        timer = nil
        silent()
    }
}
