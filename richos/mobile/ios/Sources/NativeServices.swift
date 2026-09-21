import Foundation
import WebKit
import CryptoKit
import Security
import AVFoundation

// Device services only. Session, queue, pairing and retry actions live in shared JavaScript.
final class NativeServices: NSObject, WKScriptMessageHandlerWithReply, URLSessionDataDelegate, AVAudioRecorderDelegate {
    weak var webView: WKWebView?
    private var origin: URL?
    private var stream: URLSessionDataTask?
    private var streamID: String?
    private var recorder: AVAudioRecorder?
    private var recordingID: String?
    private var permissionGeneration = 0
    private let folder: URL
    private var requestBuffers: [Int: Data] = [:]
    private var requestReplies: [Int: (Any?, String?) -> Void] = [:]
    private var requestResponses: [Int: HTTPURLResponse] = [:]
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.urlCache = nil
        config.timeoutIntervalForRequest = 30
        return URLSession(configuration: config, delegate: self, delegateQueue: OperationQueue.main)
    }()
    override init() {
        folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("RichOSMobile", isDirectory: true)
        super.init()
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        NotificationCenter.default.addObserver(self, selector: #selector(interrupted), name: AVAudioSession.interruptionNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(routeChanged), name: AVAudioSession.routeChangeNotification, object: nil)
    }
    private func fail(_ message: String) -> NSError { NSError(domain: "RichOSMobile", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    private func audioTrace(_ stage: String) {
        #if DEBUG
        NSLog("RichOS recording stage: %@", stage)
        #endif
    }
    private func string(_ args: [String: Any], _ key: String) throws -> String {
        guard let value = args[key] as? String else { throw fail("Missing \(key)") }; return value
    }
    private func protectedWrite(_ bytes: Data, to url: URL) throws {
        try bytes.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        var value = url; var resources = URLResourceValues(); resources.isExcludedFromBackup = true
        try value.setResourceValues(resources)
    }
    private func endpoint(_ value: String) throws -> URL {
        guard let expected = origin, let url = URL(string: value), url.scheme == "https", url.user == nil, url.password == nil,
              url.host == expected.host, (url.port ?? 443) == (expected.port ?? 443), url.fragment == nil,
              ["/api/pair", "/api/messages", "/api/events", "/api/challenge"].contains(url.path) else { throw fail("Request is outside the paired HTTPS endpoint") }
        return url
    }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage, replyHandler reply: @escaping (Any?, String?) -> Void) {
        guard message.frameInfo.isMainFrame, message.frameInfo.request.url?.isFileURL == true,
              let body = message.body as? [String: Any], let method = body["method"] as? String,
              let args = body["args"] as? [String: Any] else { reply(nil, "Invalid native request"); return }
        do {
            switch method {
            case "configure":
                let value = try string(args, "origin")
                guard let u = URL(string: value), u.scheme == "https", u.host != nil, u.user == nil, u.password == nil,
                      u.query == nil, u.fragment == nil, u.path.isEmpty || u.path == "/", !value.contains("\\"), !value.contains(where: { $0.isWhitespace }) else { throw fail("An HTTPS origin is required") }
                closeStream(); origin = u; reply(true, nil)
            case "publicKey": reply(try publicKey(), nil)
            case "sign": reply(try sign(string(args, "input")), nil)
            case "hash": reply(SHA256.hash(data: Data(try string(args, "value").utf8)).map { String(format: "%02x", $0) }.joined(), nil)
            case "load":
                let file = folder.appendingPathComponent("session.json")
                reply(FileManager.default.fileExists(atPath: file.path) ? try JSONSerialization.jsonObject(with: Data(contentsOf: file)) : NSNull(), nil)
            case "save":
                guard let value = args["value"], JSONSerialization.isValidJSONObject(value) else { throw fail("Invalid session") }
                let bytes = try JSONSerialization.data(withJSONObject: value)
                guard bytes.count <= 8 * 1024 * 1024 else { throw fail("Local session exceeds its storage limit") }
                try protectedWrite(bytes, to: folder.appendingPathComponent("session.json")); reply(true, nil)
            case "request":
                guard requestReplies.count < 8 else { throw fail("Too many pending requests") }
                let url = try endpoint(string(args, "url")); let verb = try string(args, "method")
                guard ["GET", "POST"].contains(verb) else { throw fail("Unsupported method") }
                let text = try string(args, "body"); guard text.utf8.count <= 65536 else { throw fail("Request exceeds the text limit") }
                var request = URLRequest(url: url); request.httpMethod = verb
                for (name, value) in args["headers"] as? [String: String] ?? [:] {
                    guard ["authorization", "content-type"].contains(name.lowercased()) else { throw fail("Unsupported header") }
                    request.setValue(value, forHTTPHeaderField: name)
                }
                if !text.isEmpty { request.httpBody = Data(text.utf8) }
                let task = session.dataTask(with: request); requestReplies[task.taskIdentifier] = reply; requestBuffers[task.taskIdentifier] = Data(); task.resume()
            case "streamOpen":
                let url = try endpoint(string(args, "url")); guard url.path == "/api/events" else { throw fail("Invalid stream route") }
                closeStream(); streamID = try string(args, "id")
                var request = URLRequest(url: url); request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                stream = session.dataTask(with: request); stream?.resume(); reply(true, nil)
            case "streamClose":
                if args["id"] as? String == streamID { closeStream() }; reply(true, nil)
            case "recordStart": startRecording(reply)
            case "recordStop": try stopRecording(cancel: false); reply(true, nil)
            case "recordCancel": permissionGeneration += 1; try stopRecording(cancel: true); reply(true, nil)
            case "recordings": reply(try recordings(), nil)
            case "recordDelete":
                let id = try string(args, "id"); guard UUID(uuidString: id) != nil, id != recordingID else { throw fail("Invalid recording") }
                for ext in ["wav", "json"] { let file = folder.appendingPathComponent(id + "." + ext); if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) } }; reply(true, nil)
            default: throw fail("Unknown native operation")
            }
        } catch { reply(nil, error.localizedDescription) }
    }
    private func key() throws -> SecKey {
        guard let origin else { throw fail("Pairing endpoint is not configured") }
        let tag = Data(("dev.richos.mobile.identity." + origin.absoluteString).utf8)
        let query: [String: Any] = [kSecClass as String: kSecClassKey, kSecAttrApplicationTag as String: tag, kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom, kSecReturnRef as String: true]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecSuccess, let result { return (result as! SecKey) }
        guard status == errSecItemNotFound else { throw fail("Protected signing key is unavailable (\(status))") }
        var error: Unmanaged<CFError>?
        let privateAttributes: [String: Any] = [kSecAttrIsPermanent as String: true, kSecAttrApplicationTag as String: tag,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let attributes: [String: Any] = [kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom, kSecAttrKeySizeInBits as String: 256, kSecPrivateKeyAttrs as String: privateAttributes]
        guard let key = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else { throw error!.takeRetainedValue() as Error }
        return key
    }
    private func base64url(_ bytes: Data) -> String { bytes.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") }
    private func publicKey() throws -> [String: String] {
        var error: Unmanaged<CFError>?
        guard let pub = SecKeyCopyPublicKey(try key()), let bytes = SecKeyCopyExternalRepresentation(pub, &error) as Data?, bytes.count == 65 else { throw fail("Cannot read public signing key") }
        return ["kty": "EC", "crv": "P-256", "x": base64url(bytes.subdata(in: 1..<33)), "y": base64url(bytes.subdata(in: 33..<65))]
    }
    private func sign(_ input: String) throws -> String {
        let fields = input.components(separatedBy: "\n")
        guard fields.count == 4, fields[0].range(of: "^[A-Za-z0-9_-]{1,256}$", options: .regularExpression) != nil,
              ["GET", "POST"].contains(fields[1]), fields[3].isEmpty || fields[3].range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil,
              let origin, fields[2].hasPrefix("/api/"), !fields[2].contains("#"), !fields[2].contains("\\") else { throw fail("Only RichOS protocol requests may be signed") }
        _ = try endpoint(origin.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + fields[2])
        var error: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(try key(), .ecdsaSignatureMessageX962SHA256, Data(input.utf8) as CFData, &error) as Data? else { throw fail("Signing failed") }
        return base64url(try P256.Signing.ECDSASignature(derRepresentation: signature).rawRepresentation)
    }
    func emit(_ value: [String: Any]) {
        webView?.callAsyncJavaScript("globalThis.RichOSNativeEvent?.(event)", arguments: ["event": value], in: nil, in: .page, completionHandler: nil)
    }
    private func closeStream() { let old = stream; stream = nil; streamID = nil; old?.cancel() }
    func background() { permissionGeneration += 1; try? stopRecording(cancel: false); closeStream(); emit(["kind": "background"]) }
    func foreground() { emit(["kind": "foreground"]) }
    @objc private func interrupted(_ notification: Notification) {
        if notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt == AVAudioSession.InterruptionType.began.rawValue { try? stopRecording(cancel: false) }
    }
    @objc private func routeChanged(_ notification: Notification) {
        if notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue { try? stopRecording(cancel: false) }
    }
    private func recordings() throws -> [[String: Any]] {
        try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" && UUID(uuidString: $0.deletingPathExtension().lastPathComponent) != nil }
            .compactMap { try JSONSerialization.jsonObject(with: Data(contentsOf: $0)) as? [String: Any] }
            .sorted { ($0["createdAt"] as? String ?? "") < ($1["createdAt"] as? String ?? "") }
    }
    private func startRecording(_ reply: @escaping (Any?, String?) -> Void) {
        guard recorder == nil else { reply(nil, "Already recording"); return }
        permissionGeneration += 1; let generation = permissionGeneration
        audioTrace("requesting permission")
        AVAudioSession.sharedInstance().requestRecordPermission { [weak self] granted in
            DispatchQueue.main.async {
                guard let self else { reply(nil, "Recording unavailable"); return }
                self.audioTrace(granted ? "permission granted" : "permission denied")
                guard generation == self.permissionGeneration else { reply(nil, "Recording cancelled"); return }
                guard granted else { reply(nil, "Microphone access is denied. Enable RichOS in Settings > Privacy & Security > Microphone."); return }
                var candidate: AVAudioRecorder?
                do {
                    guard try self.recordings().count < 10 else { throw self.fail("Delete an old recording before making another") }
                    let session = AVAudioSession.sharedInstance()
                    self.audioTrace("configuring audio session")
                    try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetooth])
                    try session.setActive(true)
                    self.audioTrace("audio session active")
                    let id = UUID().uuidString; let url = self.folder.appendingPathComponent(id + ".wav")
                    let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16000, AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false]
                    let recorder = try AVAudioRecorder(url: url, settings: settings)
                    candidate = recorder
                    recorder.delegate = self
                    guard recorder.prepareToRecord(), recorder.record(forDuration: 60) else { throw self.fail("Microphone did not start") }
                    try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)
                    var file = url; var resources = URLResourceValues(); resources.isExcludedFromBackup = true; try file.setResourceValues(resources)
                    self.recordingID = id; self.recorder = recorder
                    self.audioTrace("recorder started"); reply(true, nil)
                } catch {
                    candidate?.stop()
                    if let url = candidate?.url { try? FileManager.default.removeItem(at: url) }
                    try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
                    self.audioTrace("start failed; audio session released")
                    reply(nil, error.localizedDescription)
                }
            }
        }
    }
    private func stopRecording(cancel: Bool) throws {
        guard let active = recorder, let id = recordingID else { return }
        recorder = nil; recordingID = nil
        active.stop(); try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        audioTrace(cancel ? "cancelled; audio session released" : "stopped; audio session released")
        if cancel { try FileManager.default.removeItem(at: active.url) }
        else {
            let file = try AVAudioFile(forReading: active.url)
            let seconds = Double(file.length) / file.processingFormat.sampleRate
            let bytes = try FileManager.default.attributesOfItem(atPath: active.url.path)[.size] as? Int ?? 0
            guard bytes <= 2_000_000 else { try FileManager.default.removeItem(at: active.url); throw fail("Recording exceeded its size limit") }
            let metadata: [String: Any] = ["id": id, "seconds": seconds, "bytes": bytes, "sampleRate": 16000, "codec": "wav16k", "createdAt": ISO8601DateFormatter().string(from: Date())]
            try protectedWrite(JSONSerialization.data(withJSONObject: metadata), to: folder.appendingPathComponent(id + ".json"))
        }
        emit(["kind": "record-finished"])
    }
    func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) { try? stopRecording(cancel: !flag) }
    func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) { try? stopRecording(cancel: true) }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse else { completionHandler(.cancel); return }
        if dataTask == stream {
            guard http.statusCode == 200, http.mimeType == "text/event-stream" else { completionHandler(.cancel); return }
            emit(["kind": "stream-open", "id": streamID ?? ""])
        } else { requestResponses[dataTask.taskIdentifier] = http }
        completionHandler(.allow)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        if dataTask == stream { emit(["kind": "stream-data", "id": streamID ?? "", "data": data.base64EncodedString()]); return }
        guard requestBuffers[dataTask.taskIdentifier] != nil else { return }
        requestBuffers[dataTask.taskIdentifier]?.append(data)
        if (requestBuffers[dataTask.taskIdentifier]?.count ?? 0) > 2_000_000 { dataTask.cancel() }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if task == stream { emit(["kind": "stream-error", "id": streamID ?? ""]); stream = nil; streamID = nil; return }
        let reply = requestReplies.removeValue(forKey: task.taskIdentifier)
        let bytes = requestBuffers.removeValue(forKey: task.taskIdentifier)
        let response = requestResponses.removeValue(forKey: task.taskIdentifier)
        if let error { reply?(nil, error.localizedDescription); return }
        guard let response, let bytes, let text = String(data: bytes, encoding: .utf8) else { reply?(nil, "Invalid response"); return }
        reply?(["status": response.statusCode, "headers": response.allHeaderFields, "body": text], nil)
    }
}
