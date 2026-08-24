import Foundation

/// Loud, out-of-band alerting for the never-silent guarantee (§6.3/§6.4). The companion IS the
/// outside-the-browser watchdog, so when it detects a stall it must surface it where a human sees it
/// even if a call app is wedged: stderr always, plus a macOS Notification Center banner via
/// `osascript` (no extra entitlement, works from a CLI). The chime stays OFF by default — an open
/// mic would pick it up (§6.4).
enum Notifier {
    static func alarm(_ message: String) {
        FileErr.write("‼️  RichOS companion ALARM: \(message)\n")
        notify(title: "RichOS capture alarm", message: message)
    }

    static func info(_ message: String) {
        FileErr.write("•  \(message)\n")
    }

    private static func notify(title: String, message: String) {
        let script = "display notification \(quote(message)) with title \(quote(title))"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", script]
        p.standardError = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        try? p.run()
    }

    private static func quote(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}

enum FileErr {
    static func write(_ s: String) {
        FileHandle.standardError.write(Data(s.utf8))
    }
}
