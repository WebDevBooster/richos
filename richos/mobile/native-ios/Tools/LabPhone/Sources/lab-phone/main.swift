import Foundation
import RichOSCore
import RichOSFixtures

// lab-phone --lab LAB_CACHE --marks FILE [--tries N] [--mode fresh|return] [--home-after S] [--hidden S]
//
//   --lab         the isolated lab's cache (`mobile.mjs lab mac --manual`, fresh, so its pairing window
//                 is open). Refused unless its data directory carries the isolated lab's owner marker,
//                 so this never pairs with a real Mac.
//   --marks       a file this appends PHONE_STEP mark lines to ("PAUSE MAC n" one second before Send,
//                 "hidden n" half a second after leaving the screen), for `qa/lab-pause.py --log`.
//   --tries       send-then-Home cycles (default 3).
//   --mode        fresh: each cycle begins with a new launch (a new store, network handler and
//                 URLSession over the same saved state and keys, like a relaunch); return: each begins
//                 after the previous return to the screen (default fresh).
//   --home-after  seconds from Send to leaving the screen (default 2.0, the phone runner's tap-then-Home).
//   --hidden      seconds kept off screen (default 25, the walk's).
//
// Prints one line per event on the UTC clock (the core's `send:` account, marks, launches), then one
// JSON line: {"tries":N,"stayed":K,"perTry":[...]}. Exit 0 when every message left while hidden, 1 when
// any stayed until the return, 2 when it could not run (lab refused, pairing failed).
//
// Storage is in memory (`MemoryStorage`): every run starts with a fresh background allowance, so tries
// are never limited by the six-an-hour lease the phone keeps.

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(("lab-phone: " + message + "\n").data(using: .utf8)!)
    exit(2)
}

var options: [String: String] = [:]
var argv = CommandLine.arguments.dropFirst()
while let flag = argv.first {
    argv = argv.dropFirst()
    guard flag.hasPrefix("--"), let value = argv.first else { fail("expected --flag value pairs; see the header of main.swift") }
    argv = argv.dropFirst()
    options[String(flag.dropFirst(2))] = value
}
guard let labPath = options["lab"], let marksPath = options["marks"] else { fail("--lab and --marks are required") }
let tries = Int(options["tries"] ?? "3") ?? 0
let mode = options["mode"] ?? "fresh"
let homeAfter = Double(options["home-after"] ?? "2.0") ?? -1
let hiddenFor = Double(options["hidden"] ?? "25") ?? -1
guard tries >= 1, ["fresh", "return"].contains(mode), homeAfter >= 0, hiddenFor >= 1 else { fail("bad --tries, --mode, --home-after or --hidden") }

struct LabState: Decodable { var pairLink: String?; var data: String }
guard let labData = FileManager.default.contents(atPath: labPath + "/mac.json"),
      let lab = try? JSONDecoder().decode(LabState.self, from: labData) else { fail("cannot read \(labPath)/mac.json") }
guard let owner = FileManager.default.contents(atPath: lab.data + "/lab-owner"),
      String(decoding: owner, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) == "richos-mobile-isolated-v1" else {
    fail("\(lab.data) has no isolated lab owner marker: refusing to pair with it")
}
guard let link = lab.pairLink else { fail("the lab has no open pairing link (already paired? start a fresh lab)") }
guard FileManager.default.fileExists(atPath: marksPath) || FileManager.default.createFile(atPath: marksPath, contents: nil) else {
    fail("cannot write \(marksPath)")
}

@Sendable func say(_ line: String) {
    let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "HH:mm:ss.SSS"
    f.timeZone = TimeZone(identifier: "UTC")
    print("\(f.string(from: Date()))Z \(line)"); fflush(stdout)
}
func mark(_ label: String) {
    let line = "PHONE_STEP {\"do\":\"mark\",\"detail\":{\"label\":\"\(label)\"},\"end\":\(Date().timeIntervalSince1970)}\n"
    guard let handle = FileHandle(forWritingAtPath: marksPath) else { fail("cannot append to \(marksPath)") }
    handle.seekToEndOfFile(); handle.write(line.data(using: .utf8)!); try? handle.close()
    say("mark: \(label)")
}
func nowMs() -> Int64 { SystemClock().nowMs() }
func pause(_ seconds: Double) async { try? await Task.sleep(nanoseconds: UInt64(seconds * 1e9)) }

/// Stands in for UIKit's background time: records the core asking for it and giving it back.
@MainActor final class LoggedBackgroundTime: BackgroundContinuation {
    func begin(expired: @escaping @MainActor @Sendable () -> Void) { say("os: background time asked for") }
    func end() { say("os: background time given back") }
}

@MainActor func until(_ what: String, _ seconds: Double, _ condition: @MainActor () -> Bool) async -> Bool {
    let end = Date().addingTimeInterval(seconds)
    while Date() < end { if condition() { return true }; await pause(0.05) }
    say("timed out waiting for \(what)")
    return false
}

let storage = MemoryStorage()
let identities = MemoryIdentityStore()

/// A launch: a new store, network handler and URLSession over the saved state and keys.
@MainActor func launch(_ why: String) async -> AppStore {
    let transport = URLSessionTransport()
    let network = NetworkEffects(transport: transport, stream: transport, identities: identities)
    let store = await AppStore.launch(storage: storage, effects: network)
    store.sendLog = { say("send: " + $0) }
    store.backgroundContinuation = LoggedBackgroundTime()
    await network.setSink { action in await MainActor.run { store.receive(action) } }
    say("launched (\(why))")
    return store
}

/// The app's clock while on screen (`TickSchedule` in the app): pairing's asks and retries need it.
@MainActor func clockTicks(_ store: AppStore, _ onScreen: @escaping @MainActor () -> Bool) -> Task<Void, Never> {
    Task { @MainActor in
        while !Task.isCancelled {
            if onScreen(), store.ticking { store.send(.tick(at: nowMs())) }
            await pause(0.25)
        }
    }
}

@MainActor func run() async -> Int32 {
    var store = await launch("first")
    var onScreen = true
    var ticks = clockTicks(store) { onScreen }
    store.becameActive(at: nowMs())
    store.send(.submitPairingLink(text: link))
    guard await until("the six words", 30, { store.state.pairing == .confirming }) else { return 2 }
    store.send(.confirmWords)
    guard await until("the Mac's press", 40, { store.state.pairing == .paired }) else { return 2 }
    if !store.state.consentGiven { store.send(.acceptConsent) }
    guard await until("the stream", 20, { store.state.linkOpen }) else { return 2 }
    say("paired with the isolated lab")

    var perTry: [String] = []
    for n in 1...tries {
        if mode == "fresh" {
            onScreen = false
            store.wentToBackground(at: nowMs())
            await store.settle()
            ticks.cancel()
            store = await launch("fresh, try \(n)")
            onScreen = true
            ticks = clockTicks(store) { onScreen }
            store.becameActive(at: nowMs())
            _ = await until("the stream", 20, { store.state.linkOpen })
            await pause(4)
        } else {
            await pause(3)
        }
        mark("PAUSE MAC \(n)")
        await pause(1)
        store.send(.compose(text: "in flight \(n)"))
        store.send(.sendDraft(clientID: UUID().uuidString.lowercased(), at: nowMs()))
        await pause(homeAfter)
        onScreen = false
        store.wentToBackground(at: nowMs())
        await pause(0.5)
        mark("hidden \(n)")
        var leftWhileHidden = false
        let back = Date().addingTimeInterval(hiddenFor)
        while Date() < back {
            if store.state.outbox.isEmpty { leftWhileHidden = true }
            await pause(0.1)
        }
        mark("returning \(n)")
        onScreen = true
        store.becameActive(at: nowMs())
        perTry.append(leftWhileHidden ? "left while hidden" : "stayed until the return")
        say("try \(n): \(perTry.last!)")
        _ = await until("the reply to try \(n)", 30, { store.state.messages.contains { $0.text.contains("ack: in flight \(n)") } })
    }
    onScreen = false
    store.wentToBackground(at: nowMs())
    await store.settle()
    ticks.cancel()
    let stayed = perTry.filter { $0 != "left while hidden" }.count
    let result: [String: Any] = ["tries": tries, "stayed": stayed, "perTry": perTry, "mode": mode]
    print(String(decoding: try! JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), as: UTF8.self))
    return stayed == 0 ? 0 : 1
}

Task { @MainActor in exit(await run()) }
RunLoop.main.run()
