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
    public func currentState() async throws -> AppState { state }

    public func dispatch(_ action: Action) async throws -> AppState {
        await apply(action).value
        try check()
        return state
    }

    public func replace(with newState: AppState) async throws -> AppState {
        // A fixture is a still frame: close any live connection, then stop effects and ticks.
        await apply(.backgrounded(at: 0)).value
        effectsSuspended = true
        // A paired fixture is a phone that paired, so it holds that Mac's device key. Without it a
        // relaunch that resumes effects shows "Pair again", which is right for a phone whose key is
        // gone (security review I-2) and wrong for a fixture.
        if newState.pairing == .paired, let origin = newState.mac?.origin {
            _ = try? await PlatformEffects.identityStore().signer(for: origin)
        }
        await replaceOverwritingUnreadable(newState).value
        try check()
        return state
    }

    public func restart() async throws -> AppState {
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
    /// tests and `bin/rios sim launch <fixture>` reach a screen with no navigation.
    static let fixtureArgument = "rios-fixture"
    /// `-rios-appearance dark|light`, applied after the fixture, so every fixture can be
    /// photographed in both themes.
    static let appearanceArgument = "rios-appearance"
    /// Gesture tests advance the real clock and core against controlled effects.
    /// Screenshot fixtures retain their default still-frame behavior.
    static var interactiveFixture: Bool {
        UserDefaults.standard.string(forKey: fixtureArgument) != nil &&
        UserDefaults.standard.bool(forKey: "rios-interactive-fixture")
    }

    /// `-rios-microphone denied|granted|unknown`: the controlled microphone answer an interactive
    /// fixture starts with, standing in for the OS's (granted when absent). How the UI tests reach the
    /// microphone-off card (D03) through a real press.
    static var interactiveMicrophone: Permission {
        UserDefaults.standard.string(forKey: "rios-microphone").flatMap(Permission.init(rawValue:)) ?? .granted
    }

    @MainActor
    static func start(store: AppStore) async {
        if let name = UserDefaults.standard.string(forKey: fixtureArgument) {
            do {
                _ = try await store.replace(with: try Fixture.named(name).state)
                if interactiveFixture {
                    store.effectsSuspended = false
                    _ = try await store.dispatch(.microphonePermission(interactiveMicrophone))
                }
            } catch {
                print("rios: launch fixture refused: \(error)")
            }
        }
        if let raw = UserDefaults.standard.string(forKey: appearanceArgument) {
            if let appearance = Appearance(rawValue: raw) {
                _ = try? await store.dispatch(.setAppearance(appearance))
            } else {
                print("rios: launch appearance refused: '\(raw)'; known: dark, light")
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
