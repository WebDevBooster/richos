import Foundation

/// One HTTP exchange with the Mac, relative to the paired origin.
public struct HTTPRequest: Equatable, Sendable {
    public var method: String
    /// Path and query as sent on the wire (for `/api/events`, including the `auth` parameter).
    public var target: String
    public var headers: [String: String]
    public var body: Data?

    public init(method: String, target: String, headers: [String: String] = [:], body: Data? = nil) {
        self.method = method; self.target = target; self.headers = headers; self.body = body
    }
}

public struct HTTPResponse: Equatable, Sendable {
    public var status: Int
    public var headers: [String: String]
    public var body: Data

    public init(status: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.status = status; self.headers = headers; self.body = body
    }

    /// Header lookup is case-insensitive, as HTTP's is.
    public func header(_ name: String) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }
}

/// The network. Throws when a request never reached a Mac (the reference's "unreachable").
/// `URLSession` in the app; a scripted Mac in tests and the headless CLI.
public protocol HTTPTransport: Sendable {
    func send(_ request: HTTPRequest, origin: String) async throws -> HTTPResponse
}

/// The reference client's error shape (`web/web-app/lib/api.js`), which the corpus records.
public struct APIError: Error, Equatable, Sendable {
    public enum Reason: String, Sendable { case unreachable, revoked, refused, fault }
    public var reason: Reason
    public var status: Int
    public var retryable: Bool
    /// A refusal about this one message (`retry: false`), not about the phone.
    public var aboutThisMessage: Bool
}

/// Signs and sends requests with the challenge rule of contract §3.3/§4.3, checked against
/// `conformance/vectors/challenge.json`: every response's `X-RichOS-Challenge` replaces the one
/// held; a signed request answered 404 with a DIFFERENT challenge is re-signed with it and sent
/// exactly once more; a second 404 is final. The body bytes are never re-serialized.
public actor APIClient {
    public let origin: String
    public let deviceID: String
    private let signer: any Signer
    private let transport: any HTTPTransport
    public private(set) var challenge: String?

    public init(origin: String, deviceID: String, challenge: String?, signer: any Signer, transport: any HTTPTransport) {
        self.origin = origin; self.deviceID = deviceID; self.challenge = challenge; self.signer = signer; self.transport = transport
    }

    public enum Credential: Sendable { case header, query }

    /// Takes a challenge learned elsewhere (`hello`, the pairing answer).
    public func adopt(challenge: String) { self.challenge = challenge }

    /// A signed request with the challenge held now, not sent (the event stream opens it itself).
    public func signedRequest(_ method: String, _ pathWithQuery: String, body: Data? = nil, contentType: String? = nil,
                              credential: Credential = .header) async throws -> HTTPRequest {
        guard let current = challenge else { throw APIError(reason: .fault, status: 0, retryable: true, aboutThisMessage: false) }
        let auth = try await signer.authorization(deviceID: deviceID, challenge: current, method: method, pathWithQuery: pathWithQuery, body: body)
        var request = HTTPRequest(method: method.uppercased(), target: pathWithQuery, body: body)
        if let contentType { request.headers["Content-Type"] = contentType }
        switch credential {
        case .header: request.headers["Authorization"] = auth
        case .query: request.target = RequestSigning.withQueryCredential(pathWithQuery, authorization: auth)
        }
        return request
    }

    /// A signed request. `pathWithQuery` excludes `auth`. Returns the Mac's answer (any status) after
    /// the one re-sign; throws `APIError` only when no Mac answered (`.unreachable`) or no challenge is held.
    /// `unsignedHeaders` are sent as they are and never signed: `Prefer` is the only one, unsigned on
    /// purpose (Sage's pair-v2 hypotheses review, "Security, plainly": stripping or forging it changes
    /// only how long an answer takes).
    public func signed(_ method: String, _ pathWithQuery: String, body: Data? = nil, contentType: String? = nil,
                       credential: Credential = .header, unsignedHeaders: [String: String] = [:]) async throws -> HTTPResponse {
        var resigned = false
        // After a relaunch no challenge is held: the probe asks for one (contract §5.7).
        if challenge == nil { try await probeChallenge() }
        while true {
            try Task.checkCancellation()
            guard let current = challenge else { throw APIError(reason: .fault, status: 0, retryable: true, aboutThisMessage: false) }
            var request = try await signedRequest(method, pathWithQuery, body: body, contentType: contentType, credential: credential)
            for (name, value) in unsignedHeaders { request.headers[name] = value }
            let response: HTTPResponse
            do {
                response = try await transport.send(request, origin: origin)
            } catch {
                throw APIError(reason: .unreachable, status: 0, retryable: true, aboutThisMessage: false)
            }
            let offered = response.header("X-RichOS-Challenge")
            if let offered { challenge = offered }
            if response.status == 404, !resigned, let offered, offered != current {
                resigned = true
                continue
            }
            return response
        }
    }

    /// `GET /api/challenge`: unsigned, its status ignored, its header taken (contract §5.7).
    @discardableResult
    public func probeChallenge() async throws -> String {
        try Task.checkCancellation()
        let response: HTTPResponse
        do {
            response = try await transport.send(HTTPRequest(method: "GET", target: "/api/challenge"), origin: origin)
        } catch {
            throw APIError(reason: .unreachable, status: 0, retryable: true, aboutThisMessage: false)
        }
        guard let offered = response.header("X-RichOS-Challenge") else {
            throw APIError(reason: .fault, status: 0, retryable: true, aboutThisMessage: false)
        }
        challenge = offered
        return offered
    }

    /// The reference classification of a non-2xx answer.
    public static func classify(_ response: HTTPResponse) -> APIError {
        let json = (try? JSONSerialization.jsonObject(with: response.body)) as? [String: Any]
        if response.status == 403, json?["revoked"] as? Bool == true {
            return APIError(reason: .revoked, status: 403, retryable: false, aboutThisMessage: false)
        }
        if response.status == 404 || response.status == 403 {
            return APIError(reason: .refused, status: response.status, retryable: false, aboutThisMessage: false)
        }
        if json?["retry"] as? Bool == false {
            return APIError(reason: .refused, status: response.status, retryable: false, aboutThisMessage: true)
        }
        return APIError(reason: .fault, status: response.status, retryable: true, aboutThisMessage: false)
    }
}

/// What the outbox does with one answer (`conformance/vectors/errors.json`), following the
/// contract where it differs from the reference: 413 is final for that request, 429 waits
/// `Retry-After`, and `{"retryable": false}` is final.
public enum ClientAction: Equatable, Sendable {
    case delivered
    case retrySameBytes(afterMs: Int64)
    case finalForThisItem(reason: String?)
    case finalStopQueue(reason: String?)
    case phoneForgotten

    /// No Mac answered: the same bytes again after the outbox's clock (`attempt` 1 = the first failure).
    public static func transportFailed(attempt: Int) -> ClientAction {
        .retrySameBytes(afterMs: ConversationReducer.retryDelayMs(attempt: attempt))
    }

    /// `attempt` is 1 for the first failure (the outbox's 1 s doubling clock, capped at 16 s).
    public static func classify(_ response: HTTPResponse, attempt: Int) -> ClientAction {
        let backoff = ConversationReducer.retryDelayMs(attempt: attempt)
        if (200..<300).contains(response.status) { return .delivered }
        return classify(status: response.status, body: response.body, retryAfter: response.header("Retry-After"), backoff: backoff,
                        fallback: APIClient.classify(response))
    }

    private static func classify(status: Int, body: Data?, retryAfter: String?, backoff: Int64, fallback: APIError) -> ClientAction {
        let json = body.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
        let reason = json?["reason"] as? String
        switch status {
        case 403 where json?["revoked"] as? Bool == true: return .phoneForgotten
        case 403, 404: return .finalStopQueue(reason: reason)
        case 413: return .finalForThisItem(reason: reason ?? "too large")
        case 429:
            let seconds = retryAfter.flatMap { Int64($0.trimmingCharacters(in: .whitespaces)) } ?? 60
            return .retrySameBytes(afterMs: seconds * 1000)
        default: break
        }
        if json?["retry"] as? Bool == false || json?["retryable"] as? Bool == false { return .finalForThisItem(reason: reason) }
        switch fallback.reason {
        case .revoked: return .phoneForgotten
        case .refused: return fallback.aboutThisMessage ? .finalForThisItem(reason: reason) : .finalStopQueue(reason: reason)
        case .unreachable, .fault: return .retrySameBytes(afterMs: backoff)
        }
    }
}
