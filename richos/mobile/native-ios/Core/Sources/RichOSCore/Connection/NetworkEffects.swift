import Foundation

/// The network half of the effect handler: pairing, the signed six-word answer, deliveries, older
/// history and the live connection. The platform half (microphone, recorder, notifications, opening
/// Settings) is stream I3's; `CompositeEffectHandler` puts the two together.
public actor NetworkEffects: EffectHandler {
    private let transport: any HTTPTransport
    private let stream: any EventStreamTransport
    private let identities: any IdentityStore
    private let recordings: (any RecordingStore)?
    private let clock: any Clock
    private let deviceName: String
    private let sleep: LiveConnection.Sleep
    private var sink: LiveConnection.Sink?
    private var api: APIClient?
    private var live: LiveConnection?

    public init(transport: any HTTPTransport, stream: any EventStreamTransport, identities: any IdentityStore,
                recordings: (any RecordingStore)? = nil, clock: any Clock = SystemClock(), deviceName: String = "iPhone",
                sleep: @escaping LiveConnection.Sleep = { try await Task.sleep(nanoseconds: UInt64(max(0, $0)) * 1_000_000) }) {
        self.transport = transport; self.stream = stream; self.identities = identities; self.recordings = recordings
        self.clock = clock; self.deviceName = deviceName; self.sleep = sleep
    }

    /// Where the live connection's actions go (the store). Set once, before the first `connect`.
    public func setSink(_ sink: @escaping LiveConnection.Sink) { self.sink = sink }

    public nonisolated func handles(_ effect: Effect) -> Bool {
        switch effect {
        case .pair, .confirmFingerprint, .forgetIdentity, .deliver, .connect, .disconnect, .loadOlder: return true
        default: return false
        }
    }

    public func handle(_ effect: Effect, state: AppState) async -> [Action] {
        switch effect {
        case .pair(let link):
            do {
                let signer = try await identities.signer(for: link.origin)
                let identity = DeviceIdentity(publicPoint: try await signer.publicPoint())
                switch await PairingExchange.pair(link: link, identity: identity, deviceName: deviceName, transport: transport) {
                case .success(let paired):
                    api = APIClient(origin: link.origin, deviceID: paired.answer.deviceID, challenge: paired.challenge, signer: signer, transport: transport)
                    var actions: [Action] = [.pairingAnswered(PairAnswer(deviceID: paired.answer.deviceID, fingerprintHex: paired.answer.caFingerprint,
                                                                         threadID: paired.answer.threadID))]
                    if let capabilities = paired.answer.capabilities, !capabilities.isEmpty {
                        actions.append(.macCapabilities(text: capabilities.contains("text"), voice: capabilities.contains("voice")))
                    }
                    return actions
                case .failure(let error):
                    return [error.reason == .unreachable ? .pairingUnreachable : .pairingRefused]
                }
            } catch {
                return [.pairingRefused]
            }
        case .confirmFingerprint(let matches):
            guard let api = await client(for: state) else { return [] }
            let deviceID = state.mac?.deviceID ?? api.deviceID
            _ = try? await api.signed("POST", "/api/pair", body: PairingWire.confirmationBody(deviceID: deviceID, matches: matches),
                                      contentType: "application/json")
            if matches { await startLive(state) }
            return []
        case .forgetIdentity(let origin):
            await stopLive()
            api = nil
            try? await identities.forget(origin: origin)
            return []
        case .deliver(let clientID):
            guard let item = state.outbox.first(where: { $0.clientID == clientID }), let api = await client(for: state) else {
                return [.deliveryFailed(clientID: clientID, failure: .retryable(reason: "unreachable", afterMs: nil), at: clock.nowMs())]
            }
            return [await Courier(api: api, recordings: recordings).deliver(item, at: clock.nowMs()).action]
        case .connect:
            await startLive(state)
            return []
        case .disconnect:
            await stopLive()
            return []
        case .loadOlder:
            guard let api = await client(for: state), let oldest = await live?.oldestCursor(), oldest > 0 else {
                return [.olderLoaded([], reachedBeginning: live != nil)]
            }
            var path = "/api/events?"
            if let thread = state.mac?.threadID { path += "thread_id=\(Delivery.formEncode(thread))&" }
            path += "before=\(oldest)&limit=50"
            guard let response = try? await api.signed("GET", path, credential: .query), response.status == 200,
                  let page = try? CoreJSON.decode(OlderPage.self, from: response.body) else {
                return [.olderLoaded([], reachedBeginning: false)]
            }
            await live?.prepend(page.messages, more: page.more)
            return [.olderLoaded(page.messages.filter(\.complete).map(\.message), reachedBeginning: !page.more)]
        default:
            return []
        }
    }

    private struct OlderPage: Decodable { var messages: [StreamRow]; var more: Bool }

    /// The client for the paired Mac, rebuilt after a relaunch from the persisted pairing. With no
    /// challenge held, its first signed request probes for one.
    private func client(for state: AppState) async -> APIClient? {
        guard let mac = state.mac, let deviceID = mac.deviceID ?? api?.deviceID else { return api }
        if let api, api.origin == mac.origin, api.deviceID == deviceID { return api }
        guard let signer = try? await identities.signer(for: mac.origin) else { return nil }
        let fresh = APIClient(origin: mac.origin, deviceID: deviceID, challenge: nil, signer: signer, transport: transport)
        api = fresh
        return fresh
    }

    private func startLive(_ state: AppState) async {
        guard live == nil, state.pairing == .paired, let sink, let api = await client(for: state) else { return }
        let connection = LiveConnection(api: api, stream: stream, threadID: state.mac?.threadID, clock: clock, sleep: sleep, sink: sink)
        live = connection
        await connection.start()
    }

    private func stopLive() async {
        await live?.stop()
        live = nil
    }
}

/// Routes each effect to the first handler that takes it; anything no handler takes is recorded.
public actor CompositeEffectHandler: EffectHandler {
    private let handlers: [any EffectHandler]
    public private(set) var unhandled: [Effect] = []

    public init(_ handlers: [any EffectHandler]) { self.handlers = handlers }

    public nonisolated func handles(_ effect: Effect) -> Bool { handlers.contains { $0.handles(effect) } }

    public func handle(_ effect: Effect, state: AppState) async -> [Action] {
        guard let handler = handlers.first(where: { $0.handles(effect) }) else {
            unhandled.append(effect)
            return []
        }
        return await handler.handle(effect, state: state)
    }
}
