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
    /// `<team prefix>.<bundle id>`: the app's own application identifier, which is always one of its
    /// Keychain groups and is no extension's (each extension's application identifier is its own).
    /// The device signing key lives here, where only the app can read it (security review I-4).
    /// Derived from the shared group, which `Release/platform.yml` builds from the app's identifier
    /// (`$(AppIdentifierPrefix)$(RICHOS_BUNDLE_ID).shared`; the share suite's S4 checks that
    /// RICHOS_BUNDLE_ID is the app's). `nil` in an extension or wherever the names do not agree.
    static var appOnlyKeychainGroup: String? {
        guard let shared = keychainGroup, let bundleID = Bundle.main.bundleIdentifier,
              shared.hasSuffix(".\(bundleID).shared") || shared == "\(bundleID).shared" else { return nil }
        return String(shared.dropLast(".shared".count))
    }

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

/// Where RichConnect keeps what must never go into an iCloud or Finder backup (security review I-2):
/// the conversation, unsent messages, their attachments and recordings, and shares waiting to be
/// sent. They belong to this iPhone and its paired Mac. A backup restored onto another phone would
/// bring them back without the device key they belong to (that Keychain item is `…ThisDeviceOnly`
/// and never leaves the phone), so they are kept out of backups altogether, as the voice recordings
/// already were and as the Android app keeps everything.
enum LocalOnlyStorage {
    /// The app's own files: `Application Support/RichOS` (the saved state, `Attachments/`,
    /// `Recordings/`).
    static var appRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("RichOS", isDirectory: true)
    }

    /// Creates `directory` when needed and excludes it, and so everything under it, from backups.
    /// Called every time, not once: the mark belongs to the directory, and a directory removed and
    /// made again would otherwise go back into backups.
    @discardableResult
    static func prepare(_ directory: URL) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try exclude(directory)
        return directory
    }

    /// Excludes one existing file or directory from backups.
    static func exclude(_ item: URL) throws {
        var url = item
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try url.setResourceValues(values)
    }
}
