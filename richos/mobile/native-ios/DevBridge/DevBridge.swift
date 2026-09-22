// DEVELOPMENT ONLY. Compiled only in Debug: this file is wrapped in `#if DEBUG` AND excluded from
// Release by `EXCLUDED_SOURCE_FILE_NAMES` in `project.yml`. `bin/rios sim check-release` proves the
// Release binary carries none of its markers.
//
// The Part 0 design that already passed on the preserved app (build plan §3.1 "Device bridge"): a
// command mailbox of UUID-named files in the app's own sandbox, polled by the app. No network
// listener, no URL scheme, nothing another app can reach. `bin/rios sim <command>` writes
// `<uuid>.request.json` into `Documents/rios-commands/` (found with `simctl get_app_container` on
// the simulator the CLI created) and reads `<uuid>.response.json`.
#if DEBUG
import Foundation
import RichOSCore
import RichOSFixtures

extension AppStore: CommandHost {
    func currentState() async -> AppState { state }

    func dispatch(_ action: Action) async throws -> AppState {
        await apply(action).value
        try check()
        return state
    }

    func replace(with newState: AppState) async throws -> AppState {
        await replace(newState).value
        try check()
        return state
    }

    func restart() async throws -> AppState {
        try await reloadFromStorage()
        return state
    }

    private func check() throws {
        if let persistenceProblem { throw CoreError(persistenceProblem) }
    }
}

enum DevBridge {
    static let directoryName = "rios-commands"
    /// `-rios-fixture <name>` on the launch command line starts the app in that fixture — how UI
    /// tests and `bin/rios sim launch --fixture` reach a screen with no navigation.
    static let fixtureArgument = "rios-fixture"

    @MainActor
    static func start(store: AppStore) async {
        if let name = UserDefaults.standard.string(forKey: fixtureArgument) {
            do {
                _ = try await store.replace(with: try Fixture.named(name).state)
            } catch {
                print("rios: launch fixture refused: \(error)")
            }
        }
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let mailbox = documents.appendingPathComponent(directoryName, isDirectory: true)
        try? FileManager.default.createDirectory(at: mailbox, withIntermediateDirectories: true)
        Task.detached(priority: .utility) { await poll(mailbox, store: store) }
    }

    /// Every 50 ms: answer each request once, atomically, then remove it.
    private static func poll(_ mailbox: URL, store: AppStore) async {
        let fm = FileManager.default
        while !Task.isCancelled {
            let names = (try? fm.contentsOfDirectory(atPath: mailbox.path)) ?? []
            for name in names.sorted() where name.hasSuffix(".request.json") {
                let request = mailbox.appendingPathComponent(name)
                guard let data = try? Data(contentsOf: request) else { continue }
                try? fm.removeItem(at: request)
                let reply = await CommandRunner.respond(to: data, on: store)
                let token = String(name.dropLast(".request.json".count))
                let response = mailbox.appendingPathComponent("\(token).response.json")
                let staging = mailbox.appendingPathComponent("\(token).response.json.new")
                do {
                    try reply.write(to: staging, options: .atomic)
                    try fm.moveItem(at: staging, to: response)
                } catch {
                    print("rios: could not write \(response.lastPathComponent): \(error)")
                }
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
    }
}
#endif
