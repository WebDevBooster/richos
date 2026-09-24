import RichOSCore

// Storage location and backup policy belong to the iOS platform; orchestration is shared
// with the headless tests through the real core AppStore.
extension AppStore {
    /// Where the app keeps its state: `Application Support/RichOS`, not user-visible and kept out of
    /// iCloud and Finder backups with everything under it (attachments, recordings; security review
    /// I-2). The mark is set on every launch. If it cannot be set the state is still saved here:
    /// losing a draft to a backup flag would be the worse failure.
    static func defaultStorage() -> FileStorage {
        let root = LocalOnlyStorage.appRoot
        _ = try? LocalOnlyStorage.prepare(root)
        return FileStorage(directory: root)
    }

}
