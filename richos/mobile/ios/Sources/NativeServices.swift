import Foundation
import WebKit
import CryptoKit
import Security
import AVFoundation
import UIKit
import Network

// Device services only. Session, queue, pairing and retry actions live in shared JavaScript.
final class NativeServices: NSObject, WKScriptMessageHandlerWithReply, URLSessionDataDelegate, AVAudioRecorderDelegate, AVAudioPlayerDelegate {
    weak var webView: WKWebView?
    private var origin: URL?
    private var pendingLink: String?
    private var player: AVAudioPlayer?
    private let updates = UpdateService()
    let push = PushService()
    private let network = NWPathMonitor()
    private var lastNetwork: NWPath.Status?
    private var stream: URLSessionDataTask?
    private var streamID: String?
    private var recorder: AVAudioRecorder?
    private var recordingID: String?
    private var permissionGeneration = 0
    private let maxRecordingSeconds: TimeInterval = 30 * 60
    private let maxRecordingBytes = 60_000_000
    private var recordingContext: [String: Any] = [:]
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
        updates.emit = { [weak self] event in self?.emit(event) }
        push.emit = { [weak self] event in self?.emit(event) }
        network.pathUpdateHandler = { [weak self] path in
            DispatchQueue.main.async {
                guard let self else { return }
                if path.status == .satisfied && self.lastNetwork != .satisfied { self.emit(["kind": "network-recovered"]) }
                self.lastNetwork = path.status
            }
        }
        network.start(queue: DispatchQueue(label: "dev.richos.mobile.network"))
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        NotificationCenter.default.addObserver(self, selector: #selector(interrupted), name: AVAudioSession.interruptionNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(routeChanged), name: AVAudioSession.routeChangeNotification, object: nil)
    }
    #if DEBUG
    // Only the disposable integration app may reset its session for a new lab server.
    // Keep the same run marker through relaunch so persistence is still exercised.
    func prepareIntegrationTest() throws {
        guard Bundle.main.bundleIdentifier == "dev.richos.mobile.integration",
              let arg = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--integration-session=") }) else { return }
        let run = String(arg.dropFirst("--integration-session=".count))
        guard UUID(uuidString: run) != nil else { throw fail("Invalid integration run") }
        let marker = folder.appendingPathComponent("integration-run")
        if (try? String(contentsOf: marker, encoding: .utf8)) != run {
            let sessionFile = folder.appendingPathComponent("session.json")
            if FileManager.default.fileExists(atPath: sessionFile.path) { try FileManager.default.removeItem(at: sessionFile) }
            // An explicitly requested integration fixture may reuse the operator's previous
            // spoken check in a fresh isolated test conversation. Copy it, never mutate the
            // original recording or relax production origin/conversation ownership.
            let arguments = ProcessInfo.processInfo.arguments
            if let targetArg = arguments.first(where: { $0.hasPrefix("--integration-copy-voice-to=") }),
               let originArg = arguments.first(where: { $0.hasPrefix("--integration-copy-voice-origin=") }) {
                let target = String(targetArg.dropFirst("--integration-copy-voice-to=".count))
                let origin = String(originArg.dropFirst("--integration-copy-voice-origin=".count))
                guard target.range(of: "^thr_[a-f0-9]{32}$", options: .regularExpression) != nil,
                      URL(string: origin)?.scheme == "https" else { throw fail("Invalid recovery fixture destination") }
                if var previous = try recordings().filter({ $0["origin"] as? String == origin }).max(by: { ($0["bytes"] as? Int ?? 0) < ($1["bytes"] as? Int ?? 0) }),
                   let source = previous["id"] as? String, UUID(uuidString: source) != nil {
                    let id = UUID().uuidString
                    try FileManager.default.copyItem(at: folder.appendingPathComponent(source + ".wav"), to: folder.appendingPathComponent(id + ".wav"))
                    previous["id"] = id; previous["threadId"] = target
                    previous["createdAt"] = ISO8601DateFormatter().string(from: Date())
                    try protectedWrite(JSONSerialization.data(withJSONObject: previous), to: folder.appendingPathComponent(id + ".json"))
                } else { throw fail("No saved spoken integration recording is available") }
            }
            try protectedWrite(Data(run.utf8), to: marker)
        }
    }
    #endif
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
              (["/api/pair", "/api/messages", "/api/events", "/api/challenge"].contains(url.path) || url.path.range(of:"^/api/audio/[A-Za-z0-9_:-]{1,256}$",options:.regularExpression) != nil) else { throw fail("Request is outside the paired HTTPS endpoint") }
        return url
    }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage, replyHandler reply: @escaping (Any?, String?) -> Void) {
        guard message.frameInfo.isMainFrame, message.frameInfo.request.url?.isFileURL == true,
              let body = message.body as? [String: Any], let method = body["method"] as? String,
              let args = body["args"] as? [String: Any] else { reply(nil, "Invalid native request"); return }
        do {
            switch method {
            case "pushInfo": push.info(reply)
            case "pushRequest": push.request(reply)
            case "pushIncoming": reply(push.takeIncoming() as Any? ?? NSNull(), nil)
            case "incomingLink": reply(pendingLink as Any? ?? NSNull(), nil); pendingLink = nil
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
            case "recordHash":
                let file = try recordingFile(string(args,"id"))
                reply(SHA256.hash(data: try Data(contentsOf:file)).map { String(format:"%02x",$0) }.joined(),nil)
            case "request":
                guard requestReplies.count < 8 else { throw fail("Too many pending requests") }
                let url = try endpoint(string(args, "url")); let verb = try string(args, "method")
                guard ["GET", "POST"].contains(verb) else { throw fail("Unsupported method") }
                let reference = args["body"] as? [String:String]
                let text = args["body"] as? String ?? ""; guard text.utf8.count <= 65536 else { throw fail("Request exceeds the text limit") }
                var request = URLRequest(url: url); request.httpMethod = verb
                for (name, value) in args["headers"] as? [String: String] ?? [:] {
                    guard ["authorization", "content-type"].contains(name.lowercased()) else { throw fail("Unsupported header") }
                    request.setValue(value, forHTTPHeaderField: name)
                }
                let client = updates.info()
                request.setValue("1", forHTTPHeaderField: "X-RichOS-Protocol")
                request.setValue(client["version"] as? String, forHTTPHeaderField: "X-RichOS-Client-Version")
                request.setValue(client["build"] as? String, forHTTPHeaderField: "X-RichOS-Client-Build")
                if !text.isEmpty { request.httpBody = Data(text.utf8) }
                let task: URLSessionTask
                if let reference {
                    guard reference.count == 1, let id=reference["recordingFile"], verb == "POST", url.path == "/api/messages", request.value(forHTTPHeaderField:"Content-Type") == "audio/wav" else { throw fail("Invalid recording upload") }
                    request.timeoutInterval=110
                    task=session.uploadTask(with:request,fromFile:try recordingFile(id))
                } else { task=session.dataTask(with:request) }
                requestReplies[task.taskIdentifier] = reply; requestBuffers[task.taskIdentifier] = Data(); task.resume()
            case "streamOpen":
                let url = try endpoint(string(args, "url")); guard url.path == "/api/events" else { throw fail("Invalid stream route") }
                closeStream(); streamID = try string(args, "id")
                var request = URLRequest(url: url); request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                request.setValue("1", forHTTPHeaderField: "X-RichOS-Protocol")
                stream = session.dataTask(with: request); stream?.resume(); reply(true, nil)
            case "streamClose":
                if args["id"] as? String == streamID { closeStream() }; reply(true, nil)
            case "connectHealth":
                if lastNetwork == .unsatisfied { reply(["phoneOnline": false], nil); return }
                guard origin?.absoluteString.range(of: "^https://c-[a-f0-9]{32}-g[1-9][0-9]*\\.richos\\.ceo$", options: .regularExpression) != nil else {
                    reply(["serviceState": "unknown"], nil); return
                }
                guard requestReplies.count < 8 else { reply(["serviceState": "unknown"], nil); return }
                var request = URLRequest(url: URL(string: "https://connect.richos.ceo/healthz")!)
                request.timeoutInterval = 6
                request.cachePolicy = .reloadIgnoringLocalCacheData
                let task = session.dataTask(with: request)
                requestBuffers[task.taskIdentifier] = Data()
                requestReplies[task.taskIdentifier] = { [weak self] result, _ in
                    if self?.lastNetwork == .unsatisfied { reply(["phoneOnline": false], nil); return }
                    guard let payload = result as? [String: Any], let text = payload["body"] as? String,
                          let bytes = text.data(using: .utf8),
                          let body = (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any] else {
                        reply(["serviceState": "unknown"], nil); return
                    }
                    let ready = payload["status"] as? Int == 200 && body["service"] as? String == "richos-connect" && body["ready"] as? Bool == true
                    reply(["serviceState": ready ? "available" : "unavailable"], nil)
                }
                task.resume()
            case "updateInfo": reply(updates.info(), nil)
            case "updateMetric": updates.metric(try string(args, "event"), revision: args["revision"] as? Int ?? 0); reply(true, nil)
            case "updateFetch": updates.fetch(reply)
            case "updateSubscribe": updates.subscribe(try string(args, "id")); reply(true, nil)
            case "updateUnsubscribe": updates.close(try string(args, "id")); reply(true, nil)
            case "openStore": updates.open("store", reply: reply)
            case "openSupport": updates.open("support", reply: reply)
            case "openSettings":
                UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!, options: [:]) { opened in reply(opened, nil) }
            case "openLink":
                let value = try string(args, "url")
                guard let url = URL(string: value), url.scheme == "https", url.host != nil, url.user == nil, url.password == nil,
                      !value.contains("\\"), !value.contains(where: { $0.isWhitespace }) else { throw fail("Only HTTPS links can be opened") }
                UIApplication.shared.open(url, options: [:]) { opened in reply(opened ? true : nil, opened ? nil : "Could not open this link") }
            case "scanPair":
                guard let controller = webView?.window?.rootViewController, controller.presentedViewController == nil else { throw fail("Camera is unavailable") }
                let scanner = PairScanner(); scanner.completion = reply
                controller.present(scanner, animated: true); scanner.presentationController?.delegate = scanner
            case "playbackStop":
                player?.stop(); player=nil; try? AVAudioSession.sharedInstance().setActive(false,options:.notifyOthersOnDeactivation); reply(true,nil)
            case "replyPlay":
                let id=try string(args,"id"); guard UUID(uuidString:id) != nil, recorder == nil else { throw fail("Invalid reply playback") }
                player?.stop();try AVAudioSession.sharedInstance().setCategory(.playback);try AVAudioSession.sharedInstance().setActive(true)
                do { player=try AVAudioPlayer(contentsOf:folder.appendingPathComponent("replies").appendingPathComponent(id+".wav"));player?.delegate=self
                    guard player?.play() == true else { throw fail("Could not play this reply") };reply(true,nil)
                } catch { try? AVAudioSession.sharedInstance().setActive(false,options:.notifyOthersOnDeactivation); throw error }
            case "recordPlay":
                let id = try string(args, "id")
                guard recorder == nil, UUID(uuidString: id) != nil else { throw fail("Stop recording before playback") }
                player?.stop(); try AVAudioSession.sharedInstance().setCategory(.playback)
                try AVAudioSession.sharedInstance().setActive(true)
                do {
                    player = try AVAudioPlayer(contentsOf: folder.appendingPathComponent(id + ".wav")); player?.delegate = self
                    guard player?.play() == true else { throw fail("This recording cannot be played") }; reply(true, nil)
                } catch {
                    try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation); throw error
                }
            case "recordStart": startRecording(args, reply)
            case "recordStop": try stopRecording(cancel: false); reply(true, nil)
            case "recordCancel": permissionGeneration += 1; try stopRecording(cancel: true); reply(true, nil)
            case "recordings": reply(try recordings(), nil)
            case "recordPrune":
                let sent=Set(args["sent"] as? [String] ?? [])
                let files=try recordings()
                var retainedBytes=0, retainedCount=0
                for note in files.reversed() {
                    guard let id=note["id"] as? String, sent.contains(id), id != recordingID else {continue}
                    retainedBytes += note["bytes"] as? Int ?? 0; retainedCount += 1
                    if retainedBytes > 200_000_000 || retainedCount > 50 {
                        for ext in ["wav","json"] {try? FileManager.default.removeItem(at:folder.appendingPathComponent(id+"."+ext))}
                    }
                }
                reply(true,nil)
            case "recordDelete":
                let id = try string(args, "id"); guard UUID(uuidString: id) != nil, id != recordingID else { throw fail("Invalid recording") }
                for ext in ["wav", "json"] { let file = folder.appendingPathComponent(id + "." + ext); if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) } }; reply(true, nil)
            default: throw fail("Unknown native operation")
            }
        } catch { reply(nil, error.localizedDescription) }
    }
    private func recordingFile(_ id:String) throws -> URL {
        guard UUID(uuidString:id) != nil, recordingID != id else { throw fail("Choose a saved recording") }
        let url=folder.appendingPathComponent(id+".wav")
        let size=try FileManager.default.attributesOfItem(atPath:url.path)[.size] as? Int ?? 0
        guard size>44,size<=maxRecordingBytes else {throw fail("Recording exceeds its upload limit")};return url
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
    func receiveLink(_ url: URL) {
        guard url.absoluteString.count <= 4096 else { return }
        pendingLink = url.absoluteString; emit(["kind": "incoming-link"])
    }
    func background() { updates.close(); player?.stop(); try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation); permissionGeneration += 1; try? stopRecording(cancel: false); closeStream(); emit(["kind": "background"]) }
    func foreground() { emit(["kind": "foreground"]) }
    @objc private func interrupted(_ notification: Notification) {
        if notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt == AVAudioSession.InterruptionType.began.rawValue { try? stopRecording(cancel: false) }
    }
    @objc private func routeChanged(_ notification: Notification) {
        if notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue { try? stopRecording(cancel: false) }
    }
    private func recordings() throws -> [[String: Any]] {
        for url in try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) where url.pathExtension == "wav" {
            let id = url.deletingPathExtension().lastPathComponent, metadata = url.deletingPathExtension().appendingPathExtension("json")
            if id != recordingID && UUID(uuidString: id) != nil {
                if (try? AVAudioFile(forReading: url).length) ?? 0 == 0,
                   let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= maxRecordingBytes,
                   let bytes = try? Data(contentsOf: url, options: .mappedIfSafe),
                   let repaired = recoverInterruptedRecording(bytes) { try protectedWrite(repaired, to: url) }
                guard let file = try? AVAudioFile(forReading: url) else { continue }
                let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
                var value: [String: Any] = ["id": id, "seconds": Double(file.length) / file.processingFormat.sampleRate,
                    "bytes": attributes[.size] as? Int ?? 0, "sampleRate": 16000, "codec": "wav16k", "recovered": true,
                    "createdAt": ISO8601DateFormatter().string(from: attributes[.creationDate] as? Date ?? Date())]
                if let previous=(try? JSONSerialization.jsonObject(with:Data(contentsOf:metadata))) as? [String:Any] {
                    for key in ["threadId","origin","sent"] {value[key]=previous[key]}
                }
                try protectedWrite(JSONSerialization.data(withJSONObject: value), to: metadata)
            }
        }
        return try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" && UUID(uuidString: $0.deletingPathExtension().lastPathComponent) != nil }
            .compactMap { try JSONSerialization.jsonObject(with: Data(contentsOf: $0)) as? [String: Any] }
            .sorted { ($0["createdAt"] as? String ?? "") < ($1["createdAt"] as? String ?? "") }
    }
    private func startRecording(_ context: [String:Any], _ reply: @escaping (Any?, String?) -> Void) {
        guard recorder == nil else { reply(nil, "Already recording"); return }
        player?.stop()
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
                    let capacity = try self.folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage ?? 0
                    guard capacity > Int64(self.maxRecordingBytes + 10_000_000) else { throw self.fail("Your iPhone needs more free space to record. Your unsent messages are kept.") }
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
                    guard recorder.prepareToRecord(), recorder.record(forDuration: self.maxRecordingSeconds) else { throw self.fail("Microphone did not start") }
                    try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)
                    var file = url; var resources = URLResourceValues(); resources.isExcludedFromBackup = true; try file.setResourceValues(resources)
                    self.recordingID = id; self.recorder = recorder
                    self.recordingContext = [:]
                    for key in ["threadId", "origin"] { if let value=context[key] as? String { self.recordingContext[key]=value } }
                    var metadata=self.recordingContext;metadata["id"]=id;metadata["seconds"]=0;metadata["createdAt"]=ISO8601DateFormatter().string(from:Date())
                    try self.protectedWrite(JSONSerialization.data(withJSONObject:metadata),to:self.folder.appendingPathComponent(id+".json"))
                    UIApplication.shared.isIdleTimerDisabled = true
                    self.audioTrace("recorder started"); reply(true, nil)
                } catch {
                    candidate?.stop()
                    self.recorder = nil; self.recordingID = nil; self.recordingContext = [:]
                    UIApplication.shared.isIdleTimerDisabled = false
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
        UIApplication.shared.isIdleTimerDisabled = false
        active.stop(); try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        audioTrace(cancel ? "cancelled; audio session released" : "stopped; audio session released")
        if cancel { try FileManager.default.removeItem(at: active.url); try? FileManager.default.removeItem(at:folder.appendingPathComponent(id+".json")) }
        else {
            let file = try AVAudioFile(forReading: active.url)
            let seconds = Double(file.length) / file.processingFormat.sampleRate
            let bytes = try FileManager.default.attributesOfItem(atPath: active.url.path)[.size] as? Int ?? 0
            guard bytes <= maxRecordingBytes else { throw fail("This recording exceeds the sending limit. It has been kept on your phone.") }
            var metadata: [String: Any] = ["id": id, "seconds": seconds, "bytes": bytes, "sampleRate": 16000, "codec": "wav16k", "createdAt": ISO8601DateFormatter().string(from: Date())]
            metadata.merge(recordingContext) { _,new in new }
            try protectedWrite(JSONSerialization.data(withJSONObject: metadata), to: folder.appendingPathComponent(id + ".json"))
        }
        emit(["kind": "record-finished"])
    }
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) { emit(["kind":"playback-ended"]); try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation) }
    func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) { try? stopRecording(cancel: false) }
    func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) { try? stopRecording(cancel: false) }
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
        if (requestBuffers[dataTask.taskIdentifier]?.count ?? 0) > (dataTask.originalRequest?.url?.path.hasPrefix("/api/audio/") == true ? 6_000_000 : 2_000_000) { dataTask.cancel() }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if task == stream { emit(["kind": "stream-error", "id": streamID ?? ""]); stream = nil; streamID = nil; return }
        let reply = requestReplies.removeValue(forKey: task.taskIdentifier)
        let bytes = requestBuffers.removeValue(forKey: task.taskIdentifier)
        let response = requestResponses.removeValue(forKey: task.taskIdentifier)
        if let error { reply?(nil, error.localizedDescription); return }
        if let response, let bytes, response.statusCode == 200, response.mimeType == "audio/wav", task.originalRequest?.url?.path.hasPrefix("/api/audio/") == true {
            do {
                let directory=folder.appendingPathComponent("replies",isDirectory:true)
                try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
                let files=try FileManager.default.contentsOfDirectory(at:directory,includingPropertiesForKeys:[.creationDateKey]).sorted { (try? $0.resourceValues(forKeys:[.creationDateKey]).creationDate) ?? .distantPast < (try? $1.resourceValues(forKeys:[.creationDateKey]).creationDate) ?? .distantPast }
                for file in files.prefix(max(0,files.count-9)) {try FileManager.default.removeItem(at:file)}
                let id=UUID().uuidString;try protectedWrite(bytes,to:directory.appendingPathComponent(id+".wav"))
                reply?(["status":200,"headers":response.allHeaderFields,"body":"","audioId":id],nil)
            } catch {reply?(nil,error.localizedDescription)}
            return
        }
        guard let response, let bytes, let text = String(data: bytes, encoding: .utf8) else { reply?(nil, "Invalid response"); return }
        reply?(["status": response.statusCode, "headers": response.allHeaderFields, "body": text], nil)
    }
}
