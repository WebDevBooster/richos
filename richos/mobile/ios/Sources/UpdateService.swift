import Foundation
import UIKit
import StoreKit

// Independent of the paired Mac's origin and stream. Only bundled service configuration
// can select these endpoints; remote policy data can never supply executable code or URLs.
final class UpdateService: NSObject, URLSessionDataDelegate {
    var emit: (([String: Any]) -> Void)?
    private let config: [String: Any]
    private var stream: URLSessionDataTask?
    private var streamID: String?
    private var buffers: [Int: Data] = [:]
    private var replies: [Int: (Any?, String?) -> Void] = [:]
    private lazy var session: URLSession = {
        let value = URLSessionConfiguration.ephemeral
        value.httpShouldSetCookies = false; value.urlCache = nil
        value.timeoutIntervalForRequest = 15; value.timeoutIntervalForResource = 120
        return URLSession(configuration: value, delegate: self, delegateQueue: OperationQueue.main)
    }()
    override init() {
        if let file = Bundle.main.url(forResource: "release-config", withExtension: "json", subdirectory: "mobile-ui"),
           let bytes = try? Data(contentsOf: file), let value = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any] { config = value }
        else { config = [:] }
        super.init()
    }
    private func https(_ value: Any?) -> URL? {
        guard let text = value as? String, !text.contains(where: { $0.isWhitespace }), !text.contains("\\"),
              let url = URL(string: text), url.scheme == "https", url.host != nil, url.user == nil, url.password == nil, url.fragment == nil, url.query == nil else { return nil }
        return url
    }
    private var policyURL: URL? {
        guard let url = https(config["policyURL"]), url.path == "/v1/policy" else { return nil }; return url
    }
    private var appID: String? {
        guard let id = config["appId"] as? String, id.range(of: "^[0-9]{6,15}$", options: .regularExpression) != nil else { return nil }; return id
    }
    func info() -> [String: Any] {
        ["authority": policyURL?.absoluteString ?? "unconfigured",
         "universalHosts": config["universalHosts"] as? [String] ?? [],
         "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0",
         "build": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1",
         "osVersion": UIDevice.current.systemVersion, "appId": appID as Any? ?? NSNull(),
         "storefront": SKPaymentQueue.default().storefront?.countryCode as Any? ?? NSNull(),
         "configured": policyURL != nil, "metrics": config["metrics"] as? Bool == true, "supportConfigured": https(config["supportURL"]) != nil]
    }
    func metric(_ event: String, revision: Int) {
        guard config["metrics"] as? Bool == true, let base = policyURL,
              ["policy-visible", "policy-failed", "store-opened", "store-failed"].contains(event), revision >= 0 else { return }
        let client = info()
        var request = URLRequest(url: base.deletingLastPathComponent().appendingPathComponent("metrics"))
        request.httpMethod = "POST"; request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["event": event, "revision": revision, "version": client["version"]!, "build": client["build"]!])
        session.dataTask(with: request) { _, _, _ in }.resume()
    }
    func fetch(_ reply: @escaping (Any?, String?) -> Void) {
        guard let url = policyURL else { reply(nil, "Update service is not configured for this development build"); return }
        guard replies.isEmpty else { reply(nil, "An update check is already running"); return }
        var request = URLRequest(url: url); request.setValue("application/json", forHTTPHeaderField: "Accept")
        let task = session.dataTask(with: request)
        replies[task.taskIdentifier] = reply; buffers[task.taskIdentifier] = Data(); task.resume()
    }
    func subscribe(_ id: String) {
        close(); guard let base = policyURL else { return }
        streamID = id
        var request = URLRequest(url: base.deletingLastPathComponent().appendingPathComponent("events"))
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        stream = session.dataTask(with: request); stream?.resume()
    }
    func close(_ id: String? = nil) {
        guard id == nil || id == streamID else { return }
        let previous = stream; stream = nil; streamID = nil; previous?.cancel()
    }
    func open(_ destination: String, reply: @escaping (Any?, String?) -> Void) {
        let url: URL?
        if destination == "store", let id = appID { url = URL(string: "https://apps.apple.com/app/id\(id)") }
        else if destination == "support" { url = https(config["supportURL"]) }
        else { url = nil }
        guard let url else { reply(nil, "This destination has not been configured for release"); return }
        UIApplication.shared.open(url, options: [:]) { opened in reply(opened ? true : nil, opened ? nil : "Could not open this destination") }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              http.mimeType == (dataTask == stream ? "text/event-stream" : "application/json") else { completionHandler(.cancel); return }
        completionHandler(.allow)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        if dataTask == stream {
            // Any bytes are a hint to refetch, never policy authority. Coalescing happens in core.
            emit?(["kind": "update-signal", "id": streamID ?? ""]); return
        }
        guard buffers[dataTask.taskIdentifier] != nil else { return }
        buffers[dataTask.taskIdentifier]?.append(data)
        if (buffers[dataTask.taskIdentifier]?.count ?? 0) > 65536 { dataTask.cancel() }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if task == stream { emit?(["kind": "update-stream-closed", "id": streamID ?? ""]); stream = nil; streamID = nil; return }
        let reply = replies.removeValue(forKey: task.taskIdentifier), data = buffers.removeValue(forKey: task.taskIdentifier)
        if let error { reply?(nil, error.localizedDescription); return }
        guard let data, let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { reply?(nil, "Invalid update policy response"); return }
        reply?(value, nil)
    }
}
