import UIKit
import WebKit

@main
final class AppDelegate: UIResponder, UIApplicationDelegate, WKNavigationDelegate {
    var window: UIWindow?
    private var webView: WKWebView!
    private var contentRoot: URL!
    private let native = NativeServices()
    #if DEBUG && targetEnvironment(simulator)
    private var pendingRefresh: String?
    private var busy = false
    private var commandTimer: Timer?
    #endif

    func application(_ application: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        #if DEBUG
        do { try native.prepareIntegrationTest() }
        catch { NSLog("Integration setup failed: %@", error.localizedDescription); return false }
        #endif
        let controller = UIViewController()
        controller.view.backgroundColor = .systemBackground
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.addScriptMessageHandler(native, contentWorld: .page, name: "richos")
        webView = WKWebView(frame: .zero, configuration: configuration)
        native.webView = webView
        webView.navigationDelegate = self
        webView.translatesAutoresizingMaskIntoConstraints = false
        controller.view.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: controller.view.safeAreaLayoutGuide.topAnchor),
            webView.bottomAnchor.constraint(equalTo: controller.view.safeAreaLayoutGuide.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: controller.view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: controller.view.trailingAnchor)
        ])
        window = UIWindow(frame: UIScreen.main.bounds)
        window?.rootViewController = controller
        window?.makeKeyAndVisible()
        loadContent()
        #if DEBUG && targetEnvironment(simulator)
        commandTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in self?.pollCommands() }
        #endif
        return true
    }

    func applicationDidEnterBackground(_ application: UIApplication) { native.background() }
    func applicationWillEnterForeground(_ application: UIApplication) { native.foreground() }

    private func loadContent() {
        var root = Bundle.main.url(forResource: "mobile-ui", withExtension: nil)!
        #if DEBUG && targetEnvironment(simulator)
        let development = documents.appendingPathComponent("mobile-ui", isDirectory: true)
        if FileManager.default.fileExists(atPath: development.appendingPathComponent("index.html").path) { root = development }
        #endif
        contentRoot = root.standardizedFileURL
        let page = ProcessInfo.processInfo.arguments.contains("--native-client") ? "client.html" : "index.html"
        webView.loadFileURL(root.appendingPathComponent(page), allowingReadAccessTo: root)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        // The shell loads only bundled/local assets. Remote content cannot gain this context.
        guard let url = navigationAction.request.url, url.isFileURL,
              url.standardizedFileURL.path.hasPrefix(contentRoot.path + "/") else {
            decisionHandler(.cancel); return
        }
        decisionHandler(.allow)
    }

    #if DEBUG && targetEnvironment(simulator)
    private var documents: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0] }
    private var inbox: URL { documents.appendingPathComponent("mobile-commands", isDirectory: true) }

    private func pollCommands() {
        guard !busy, let files = try? FileManager.default.contentsOfDirectory(atPath: inbox.path) else { return }
        for file in files.sorted() where file.hasSuffix(".request.json") {
            let id = String(file.dropLast(".request.json".count))
            guard UUID(uuidString: id) != nil,
                  !FileManager.default.fileExists(atPath: inbox.appendingPathComponent("\(id).response.json").path),
                  let data = try? Data(contentsOf: inbox.appendingPathComponent(file)),
                  let request = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            busy = true
            if request["refreshAssets"] as? Bool == true { pendingRefresh = id; loadContent() }
            else { execute(id, attempts: 100) }
            break
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if let id = pendingRefresh { pendingRefresh = nil; execute(id, attempts: 100) }
    }

    private func execute(_ id: String, attempts: Int) {
        webView.evaluateJavaScript("Boolean(globalThis.RichOSDev)") { [weak self] value, error in
            guard let self else { return }
            guard value as? Bool == true else {
                if attempts > 0 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { self.execute(id, attempts: attempts - 1) }
                } else { self.finish(id, ["ok": false, "error": "Development runtime did not become ready"] ) }
                return
            }
            do {
                let data = try Data(contentsOf: self.inbox.appendingPathComponent("\(id).request.json"))
                guard data.count < 1_048_576,
                      let request = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    self.finish(id, ["ok": false, "error": "Invalid command document"]); return
                }
                self.webView.callAsyncJavaScript("return await globalThis.RichOSDev.execute(request)", arguments: ["request": request], in: nil, in: .page) { result in
                    switch result {
                    case .success(let value): self.finish(id, ["ok": true, "result": value ?? NSNull()])
                    case .failure(let error): self.finish(id, ["ok": false, "error": error.localizedDescription])
                    }
                }
            } catch { self.finish(id, ["ok": false, "error": error.localizedDescription]) }
        }
    }
    private func finish(_ id: String, _ result: [String: Any]) { reply(id, result); busy = false }
    private func reply(_ id: String, _ result: [String: Any]) {
        do {
            try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
            try data.write(to: inbox.appendingPathComponent("\(id).response.json"), options: .atomic)
        } catch { NSLog("Development response failed: %@", error.localizedDescription) }
    }
    #endif
}
