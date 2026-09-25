// Notification platform tests, on this Mac with no simulator (loop L1 for stream I3).
//
// Built by `richos/app/scripts/native-ios-share.test.sh` with swiftc from:
//   this file, NotificationService/Sources/NotificationService.swift, App/Platform/Shared/*.swift,
//   App/Platform/NotificationTapRouter.swift, and the core (RichOSCore) as a module.
// Argument 1: the preserved preview fixture (richos/mobile/test/fixtures/notification-preview.json),
// the bytes the Mac's WebCrypto sealed — so CryptoKit here is checked against the real sealer.
import Foundation
import RichOSCore
import UserNotifications

var passed = 0
var failures: [String] = []
func check(_ name: String, _ condition: @autoclosure () throws -> Bool) {
    do {
        if try condition() { passed += 1 } else { failures.append(name) }
    } catch {
        failures.append("\(name) (threw \(error))")
    }
}

let fixture = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))) as! [String: Any]
let key = Base64URL.decode(fixture["key"] as! String)!
let payload = fixture["payload"] as! [String: Any]
let expected = fixture["text"] as! String

// --- decrypt: the Mac's sealer and this opener agree; every tampering fails closed ---------------
check("N1 the Mac's sealed preview opens to its text", try NotificationPreview.decrypt(payload, key: key) == expected)
check("N2 a wrong key fails", (try? NotificationPreview.decrypt(payload, key: Data(repeating: 0, count: 32))) == nil)
var moved = payload
var refs = payload["richos"] as! [String: String]
refs["event"] = String(repeating: "d", count: 64)
moved["richos"] = refs
check("N3 a preview moved to another reply fails", (try? NotificationPreview.decrypt(moved, key: key)) == nil)
var oversized = payload
var preview = payload["preview"] as! [String: Any]
preview["body"] = String(repeating: "a", count: 2000)
oversized["preview"] = preview
check("N4 oversized ciphertext is refused", (try? NotificationPreview.decrypt(oversized, key: key)) == nil)
check("N5 a generic alert has no preview", (try? NotificationPreview.decrypt([:], key: key)) == nil)
var version2 = payload
var v2 = payload["preview"] as! [String: Any]
v2["v"] = 2
version2["preview"] = v2
check("N6 an unknown preview version is refused", (try? NotificationPreview.decrypt(version2, key: key)) == nil)
check("N7 a 31-byte key is refused before any work", (try? NotificationPreview.decrypt(payload, key: key.prefix(31))) == nil)

// --- the extension's decision -------------------------------------------------------------------
let content = UNMutableNotificationContent()
content.title = "RichOS"
content.body = "Rich has replied."
content.userInfo = payload
let on = PreviewKeyStore.Settings(previews: true, origin: "https://c-x.richos.ceo", key: key)
check("N8 previews on: the body becomes the reply", NotificationService.rewrite(content) { on }.body == expected)
check("N9 previews on: replies group by conversation",
      NotificationService.rewrite(content) { on }.threadIdentifier == (payload["richos"] as! [String: String])["thread"])
var off = on
off.previews = false
check("N10 previews off: the generic alert is kept", NotificationService.rewrite(content) { off }.body == "Rich has replied.")
check("N11 no key yet: the generic alert is kept",
      NotificationService.rewrite(content) { PreviewKeyStore.Settings() }.body == "Rich has replied.")
check("N12 the Keychain unreadable (locked since restart): the generic alert is kept",
      NotificationService.rewrite(content) { throw PreviewKeyStore.Failure.keychain(-25308) }.body == "Rich has replied.")

// --- the tap: strict parsing, the Mac's reference derivation, routing ---------------------------
let refsOK = payload["richos"] as! [String: String]
check("T1 a RichOS payload parses", NotificationTarget(userInfo: payload) != nil)
var extra = refsOK
extra["url"] = "https://example.com"
check("T2 a fourth key is refused", NotificationTarget(userInfo: ["richos": extra]) == nil)
var upper = refsOK
upper["event"] = String(repeating: "C", count: 64)
check("T3 uppercase hex is refused", NotificationTarget(userInfo: ["richos": upper]) == nil)
var short = refsOK
short["host"] = String(repeating: "a", count: 31)
check("T4 a short host id is refused", NotificationTarget(userInfo: ["richos": short]) == nil)
// The Mac's own derivation (phone protocol contract fixtures push.json "ref_derivation").
check("T5 thread reference matches the Mac's vector",
      NotificationTarget.reference("thr_5c1e") == "7dd23bca47ea16f3219c3809ad44f2ef9b416cafa3781792c97e30ff5cfb1fc0")
check("T6 event reference matches the Mac's vector",
      NotificationTarget.reference("turn_9:text:0") == "ec2086bf2cc13468dc720141665044e98194c001062dbac9421043e23db20106")

var state = AppState()
state.pairing = .paired
state.consentGiven = true
state.mac = MacLink(origin: "https://c-x.richos.ceo", route: .connect, threadID: "thr_5c1e")
state.messages = [Message(id: "turn_8:text:0", author: .rich, text: "Earlier", sentAt: 1),
                  Message(id: "turn_9:user", author: .me, text: "Question", sentAt: 2),
                  Message(id: "turn_9:text:0", author: .rich, text: "Answer", sentAt: 3)]
let host = String(repeating: "a", count: 32)
let target = NotificationTarget(userInfo: ["richos": ["host": host, "thread": NotificationTarget.reference("thr_5c1e"),
                                                      "event": NotificationTarget.reference("turn_9:text:0")]])!
check("T7 a tap opens exactly that reply",
      NotificationTapRouter.action(for: target, state: state, hostID: host) == .openedFromNotification(messageID: "turn_9:text:0"))
check("T8 a tap from another Mac opens nothing",
      NotificationTapRouter.action(for: target, state: state, hostID: String(repeating: "f", count: 32)) == nil)
var otherThread = state
otherThread.mac?.threadID = "thr_other"
check("T9 a tap about another conversation opens nothing", NotificationTapRouter.action(for: target, state: otherThread, hostID: host) == nil)
var notLoaded = state
notLoaded.messages.removeLast()
check("T10 a reply not loaded yet is left to the core's backfill", NotificationTapRouter.action(for: target, state: notLoaded, hostID: host) == nil)
check("T11 no registration answer yet (no host id): nothing opens", NotificationTapRouter.action(for: target, state: state, hostID: nil) == nil)

let mailbox = NotificationRouteMailbox()
mailbox.put(target)
check("T12 the mailbox hands a cold-launch tap over once", mailbox.take() == target && mailbox.take() == nil)

// --- D04: which delivered notifications a read conversation withdraws ----------------------------
func delivered(_ id: String, host h: String = host, thread: String = "thr_5c1e", event: String) -> (identifier: String, userInfo: [AnyHashable: Any]) {
    (id, ["richos": ["host": h, "thread": NotificationTarget.reference(thread), "event": NotificationTarget.reference(event)]])
}
let shade = [delivered("n-earlier", event: "turn_8:text:0"), delivered("n-answer", event: "turn_9:text:0"),
             delivered("n-unseen", event: "turn_10:text:0"), delivered("n-other-mac", host: String(repeating: "f", count: 32), event: "turn_9:text:0"),
             delivered("n-other-thread", thread: "thr_other", event: "turn_9:text:0"), ("n-foreign", ["aps": ["alert": "x"]])]
let readAll = ReadReplies.of(state)!
check("W1 the open conversation, following, has read both loaded replies", readAll.replyIDs == ["turn_8:text:0", "turn_9:text:0"])
check("W2 read replies from this Mac and conversation are withdrawn, and only those",
      NotificationWithdrawal.identifiers(of: shade, read: readAll, hostID: host) == ["n-earlier", "n-answer"])
check("W3 a reply not on this phone yet keeps its notification",
      !NotificationWithdrawal.identifiers(of: shade, read: readAll, hostID: host).contains("n-unseen"))
var scrolled = state
scrolled.following = false
scrolled.readingAnchor = ReadingAnchor(messageID: "turn_8:text:0", offset: 0)
check("W4 scrolled up to the earlier reply: the answer below it stays",
      NotificationWithdrawal.identifiers(of: shade, read: ReadReplies.of(scrolled)!, hostID: host) == ["n-earlier"])
check("W5 no registration answer yet (no host id): nothing is withdrawn",
      NotificationWithdrawal.identifiers(of: shade, read: readAll, hostID: nil).isEmpty)
check("W6 nothing delivered: nothing to do", NotificationWithdrawal.identifiers(of: [], read: readAll, hostID: host).isEmpty)

// --- the registration body and its answers (contract §7.2) --------------------------------------
let token = String(repeating: "ab", count: 32)
let body = PairingWire.pushRegistrationBody(tokenHex: token, sandbox: true, previewKey: key, previews: true)
let decoded = try JSONSerialization.jsonObject(with: body) as! [String: [String: Any]]
let push = decoded["native_push"]!
check("R1 the core's registration body carries exactly the Mac's APNs fields",
      Set(push.keys) == ["token", "environment", "topic", "preview_key", "previews"])
check("R2 the preview key the extension decrypts with is the one registered (fixture key round-trips)", push["preview_key"] as? String == fixture["key"] as? String)
check("R3 the topic is RichConnect's permanent bundle id", push["topic"] as? String == "dev.richos.connect")
check("R4 an unregistration's answer is read as not registered",
      PushRegistration.answer(status: 200, body: Data(#"{"host_id":null,"registered":false}"#.utf8)) == .registered(hostID: nil, registered: false))
check("R5 the device token becomes lowercase hex", PushRegistration.token(Data([0xAB, 0x01, 0xFF])) == "ab01ff")
check("R5a development signing chooses sandbox independently of optimization", PushRegistration.environment(apsValue: "development") == .sandbox)
check("R5b distribution signing chooses production", PushRegistration.environment(apsValue: "production") == .production)
check("R5c missing or malformed signing metadata never guesses production", PushRegistration.environment(apsValue: nil) == nil && PushRegistration.environment(apsValue: "$(RICHOS_APS_ENVIRONMENT)") == nil)
check("R6 unregister is native_push null", String(decoding: PairingWire.pushUnregistrationBody, as: UTF8.self) == #"{"native_push":null}"#)
check("R7 200 keeps the host id",
      PushRegistration.answer(status: 200, body: Data(#"{"host_id":"\#(host)","registered":true}"#.utf8)) == .registered(hostID: host, registered: true))
check("R8 200 with a malformed host id keeps none",
      PushRegistration.answer(status: 200, body: Data(#"{"host_id":"XYZ","registered":true}"#.utf8)) == .registered(hostID: nil, registered: true))
check("R9 422 unsupported", PushRegistration.answer(status: 422, body: Data(#"{"reason":"unsupported","retryable":false}"#.utf8)) == .unsupported)
check("R10 503 unreachable keeps the Mac's words",
      PushRegistration.answer(status: 503, body: Data(#"{"reason":"unreachable","retryable":true,"message":"Try later."}"#.utf8)) == .unreachable(message: "Try later."))
check("R11 404 is a failure, not a registration", PushRegistration.answer(status: 404, body: Data()) == .failed(status: 404))

// --- the privacy manifest says what the notification service keeps, and nothing more -------------
// The hosted Connect Worker keeps a push binding (token, device-key hash) and short-lived jobs
// (`richos/mobile/service/connect/schema.sql`: hosts, nonces, allowed_hosts, push_bindings,
// push_jobs; jobs expire within one hour), with logs, traces, Logpush and tail consumers disabled
// (`service/notifications.md`). It keeps no delivery diagnostics, so the manifest declares none.
let testsDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let manifestURL = testsDir.appendingPathComponent("../../App/Platform/PrivacyInfo.xcprivacy").standardizedFileURL
let schemaURL = testsDir.appendingPathComponent("../../../service/connect/schema.sql").standardizedFileURL
let manifest = (try? PropertyListSerialization.propertyList(from: Data(contentsOf: manifestURL), format: nil)) as? [String: Any]
let collected = (manifest?["NSPrivacyCollectedDataTypes"] as? [[String: Any]] ?? []).compactMap { $0["NSPrivacyCollectedDataType"] as? String }
check("P1 the manifest declares only the Device ID the Connect service keeps", collected == ["NSPrivacyCollectedDataTypeDeviceID"])
check("P2 the manifest claims no diagnostics", !collected.contains { $0.contains("Diagnostic") })
// Apple's App Privacy definition: data tied to a device or other details, and personal data under
// the relevant privacy laws, is linked. The service keeps the token against the Mac's host record.
let deviceID = (manifest?["NSPrivacyCollectedDataTypes"] as? [[String: Any]] ?? []).first { $0["NSPrivacyCollectedDataType"] as? String == "NSPrivacyCollectedDataTypeDeviceID" }
check("P5 the Device ID is declared linked to the user (Apple: device-level data held against a record is linked)",
      deviceID?["NSPrivacyCollectedDataTypeLinked"] as? Bool == true)
check("P6 the Device ID is not used for tracking, only for app functionality",
      deviceID?["NSPrivacyCollectedDataTypeTracking"] as? Bool == false
        && deviceID?["NSPrivacyCollectedDataTypePurposes"] as? [String] == ["NSPrivacyCollectedDataTypePurposeAppFunctionality"])
let schema = (try? String(contentsOf: schemaURL, encoding: .utf8)) ?? ""
let tables = schema.components(separatedBy: "\n").filter { $0.hasPrefix("CREATE TABLE") }
    .compactMap { $0.split(separator: " ").dropFirst(5).first.map(String.init) }
check("P3 the Connect service's tables are the five the manifest accounts for (a new one needs a manifest decision)",
      tables.sorted() == ["allowed_hosts", "hosts", "nonces", "push_bindings", "push_jobs"])
check("P4 the Connect service keeps no diagnostics table", !schema.lowercased().contains("diagnos"))

if failures.isEmpty {
    print("Notification platform: \(passed) checks passed")
} else {
    print("Notification platform: \(failures.count) FAILED, \(passed) passed")
    failures.forEach { print("  FAIL \($0)") }
    exit(1)
}
