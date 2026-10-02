import Darwin
import Foundation
import UIKit
import UIKit.UIGestureRecognizerSubclass

/// Launch and return times on the app's own clocks, with no profiler attached (`mobile/perf/ios.py`
/// `--tap-launches`, `--tap-returns`). Off unless the measuring tool has put `perf-launch-timing.on`
/// into the app's saved-state directory (`Application Support/RichOS`), which it does only on a phone
/// it has seeded, and which its restore removes with the rest of the seeded state.
///
/// Each event is one JSON line in `perf-launch-timing.jsonl` beside it: static names and numbers only,
/// no message, account or device data. `process` carries the kernel's start time of this process
/// (`sysctl` KERN_PROC_PID `p_starttime`, the wall clock at the spawn), the start of a tap launch as
/// the app can see it. Every line has the wall clock (`wallUs`) and the uptime clock UIKit stamps
/// touches with (`uptime`), so the tool can join the phone runner's tap times and each touch's own
/// time. A `touch` line is a touch the app's window received, with the scene's activation state at
/// that moment: whether iOS hands the app touches before it makes the scene active on a return.
///
/// Battery: nothing when off but one file-existence check at launch. When on: no timer, no polling;
/// a few lines per launch or return, appended on a utility queue after the event.
@MainActor
enum LaunchTiming {
    static let markerName = "perf-launch-timing.on"
    static let fileName = "perf-launch-timing.jsonl"

    /// Read once, at the app's first line of code (`RichOSNativeApp.init`).
    static let enabled: Bool = FileManager.default.fileExists(
        atPath: LocalOnlyStorage.appRoot.appendingPathComponent(markerName).path)

    private static let queue = DispatchQueue(label: "dev.richos.connect.launch-timing", qos: .utility)
    private static var observers: [NSObjectProtocol] = []
    private static var started = false
    private static var observedWindows: Set<ObjectIdentifier> = []

    /// The process line, and the scene transitions from here on.
    static func start() {
        guard enabled, !started else { return }
        started = true
        record("process", ["startUs": processStartMicros() ?? -1])
        let transitions: [(Notification.Name, String)] = [
            (UIScene.willEnterForegroundNotification, "will-enter-foreground"),
            (UIScene.didActivateNotification, "did-activate"),
            (UIScene.willDeactivateNotification, "will-deactivate"),
            (UIScene.didEnterBackgroundNotification, "did-enter-background"),
        ]
        for (name, event) in transitions {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { record(event) }
            })
        }
    }

    /// Every touch the window receives, before any view handles it; it never recognizes, delays or
    /// cancels anything.
    static func observeTouches(in window: UIWindow) {
        guard enabled, observedWindows.insert(ObjectIdentifier(window)).inserted else { return }
        window.addGestureRecognizer(TouchProbe())
    }

    static func record(_ event: String, _ extra: [String: Any] = [:]) {
        guard enabled else { return }
        var tv = timeval()
        gettimeofday(&tv, nil)
        var line: [String: Any] = ["e": event, "pid": Int(getpid()),
                                   "wallUs": Int64(tv.tv_sec) * 1_000_000 + Int64(tv.tv_usec),
                                   "uptime": ProcessInfo.processInfo.systemUptime]
        for (key, value) in extra { line[key] = value }
        guard var data = try? JSONSerialization.data(withJSONObject: line, options: [.sortedKeys]) else { return }
        data.append(0x0A)
        let url = LocalOnlyStorage.appRoot.appendingPathComponent(fileName)
        queue.async { append(data, to: url) }
    }

    nonisolated private static func append(_ data: Data, to url: URL) {
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
    }

    /// The kernel's start time of this process, microseconds since 1970 (the wall clock at spawn).
    nonisolated static func processStartMicros() -> Int64? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let start = info.kp_proc.p_un.__p_starttime
        return Int64(start.tv_sec) * 1_000_000 + Int64(start.tv_usec)
    }

    nonisolated static func stateName(_ state: UIScene.ActivationState?) -> String {
        switch state {
        case .foregroundActive: return "foregroundActive"
        case .foregroundInactive: return "foregroundInactive"
        case .background: return "background"
        case .unattached: return "unattached"
        default: return "none"
        }
    }
}

/// Records each touch as the window receives it, then fails at once, so every other recognizer and
/// view gets the touch exactly as without it.
private final class TouchProbe: UIGestureRecognizer, UIGestureRecognizerDelegate {
    init() {
        super.init(target: nil, action: nil)
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
        delegate = self
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        let hit = touches.first?.view.map { String(describing: type(of: $0)) } ?? "none"
        let state = LaunchTiming.stateName(view?.window?.windowScene?.activationState)
        LaunchTiming.record("touch", ["eventUptime": event.timestamp, "scene": state, "view": hit,
                                      "appState": UIApplication.shared.applicationState.rawValue])
        self.state = .failed
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
}
