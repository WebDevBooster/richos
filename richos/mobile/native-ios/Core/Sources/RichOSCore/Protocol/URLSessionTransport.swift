import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The real network: `URLSession`, ephemeral (no cookies, no cache, no stored credentials), with
/// the system's TLS trust — both routes present publicly trusted certificates (Tailscale's and the
/// Connect tunnel's), so nothing is pinned or bypassed. Requests never follow a redirect to another
/// origin.
public final class URLSessionTransport: NSObject, HTTPTransport, EventStreamTransport, URLSessionTaskDelegate, @unchecked Sendable {
    private let session: URLSession
    private let requestTimeout: TimeInterval

    /// How long one request may take. It must outlast the longest hold a `pair-wait` Mac is asked for
    /// (14 s; `pairing.json` `pair_wait.request_timeout_must_exceed_ms`), so a held ask is answered by
    /// the Mac rather than cut off by the phone.
    public static let defaultRequestTimeout: TimeInterval = 30

    public init(requestTimeout: TimeInterval = URLSessionTransport.defaultRequestTimeout) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.waitsForConnectivity = false
        self.requestTimeout = requestTimeout
        session = URLSession(configuration: configuration)
        super.init()
    }

    private func urlRequest(_ request: HTTPRequest, origin: String, timeout: TimeInterval) throws -> URLRequest {
        guard let url = URL(string: origin + request.target) else { throw CoreError("not a URL: \(origin)\(request.target)") }
        var r = URLRequest(url: url, timeoutInterval: timeout)
        r.httpMethod = request.method
        r.httpBody = request.body
        for (name, value) in request.headers { r.setValue(value, forHTTPHeaderField: name) }
        return r
    }

    private static func head(_ response: URLResponse) throws -> HTTPResponse {
        guard let http = response as? HTTPURLResponse else { throw CoreError("not an HTTP response") }
        var headers: [String: String] = [:]
        for (key, value) in http.allHeaderFields { headers["\(key)"] = "\(value)" }
        return HTTPResponse(status: http.statusCode, headers: headers)
    }

    public func send(_ request: HTTPRequest, origin: String) async throws -> HTTPResponse {
        let (data, response) = try await session.data(for: try urlRequest(request, origin: origin, timeout: requestTimeout), delegate: self)
        var answer = try Self.head(response)
        answer.body = data
        return answer
    }

    public func open(_ request: HTTPRequest, origin: String) async throws -> (response: HTTPResponse, bytes: AsyncThrowingStream<Data, Error>) {
        // A stream stays open indefinitely; the Mac's heartbeat keeps it alive, and silence longer
        // than this is a dead connection the owner reopens.
        var r = try urlRequest(request, origin: origin, timeout: 60)
        r.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        let (bytes, response) = try await session.bytes(for: r, delegate: self)
        let head = try Self.head(response)
        let stream = AsyncThrowingStream<Data, Error> { continuation in
            let task = Task {
                var line = Data()
                do {
                    for try await byte in bytes {
                        line.append(byte)
                        // Deliver a line as soon as it ends, so a reply streams word by word.
                        if byte == 0x0A { continuation.yield(line); line.removeAll(keepingCapacity: true) }
                    }
                    if !line.isEmpty { continuation.yield(line) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
        return (head, stream)
    }

    /// Never follow a redirect: a Mac does not send them, and following one could leave the paired origin.
    public func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                           newRequest request: URLRequest) async -> URLRequest? {
        nil
    }
}
