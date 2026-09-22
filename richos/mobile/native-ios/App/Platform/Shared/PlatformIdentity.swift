import Foundation

// Compiled into the app AND both extensions (Release/platform.yml), and into the macOS platform
// tests. Foundation only.

/// The names the app and its two extensions agree on, read from each bundle's own Info.plist
/// (`Release/App-Info.plist`, `NotificationService/Info.plist`, `ShareExtension/Info.plist`), which
/// take them from one build setting each in `Release/platform.yml`. Nothing is hard-coded, so the
/// production identifier is one change.
enum PlatformIdentity {
    /// `group.<bundle id>`: the container the Share extension hands items to the app through.
    static var appGroup: String? { value("RichOSAppGroup") }
    /// `<team prefix>.<bundle id>.shared`: the Keychain group holding the reply-preview key.
    static var keychainGroup: String? { value("RichOSKeychainGroup") }

    /// The shared container, or `nil` when this build has no App Group (a unit test, or signing
    /// that dropped the entitlement). Callers say so in plain words; they never fall back to a
    /// private directory the other process cannot see.
    static var sharedContainer: URL? {
        appGroup.flatMap { FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: $0) }
    }

    private static func value(_ key: String) -> String? {
        guard let text = Bundle.main.object(forInfoDictionaryKey: key) as? String,
              !text.isEmpty, !text.contains("$(") else { return nil }
        return text
    }
}
