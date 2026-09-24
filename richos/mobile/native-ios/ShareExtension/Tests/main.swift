// Share platform tests, on this Mac with no simulator (loop L1 for stream I3).
//
// Built by `richos/app/scripts/native-ios-share.test.sh` with swiftc from this file,
// App/Platform/Shared/*.swift, App/Platform/SharePlatform.swift, and the core (RichOSCore) as a
// module. Argument 1: a scratch directory the run owns (deleted by the suite).
// Argument 2: ShareExtension/Info.plist, whose activation rule is evaluated here.
import CoreGraphics
import Foundation
import ImageIO
import RichOSCore
import UniformTypeIdentifiers

var passed = 0
var failures: [String] = []
func check(_ name: String, _ condition: @autoclosure () throws -> Bool) {
    do {
        if try condition() { passed += 1 } else { failures.append(name) }
    } catch {
        failures.append("\(name) (threw \(error))")
    }
}

let scratch = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let fm = FileManager.default
try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
var counter = 0
func nextID() -> String { counter += 1; return String(format: "00000000-0000-4000-a000-%012d", counter) }
func staged(_ name: String, _ mediaType: String, bytes: Int = 64, fill: UInt8 = 7) throws -> StagedShareFile {
    let url = scratch.appendingPathComponent("staged-\(UUID().uuidString)-\(name)")
    try Data(repeating: fill, count: bytes).write(to: url)
    return StagedShareFile(url: url, suggestedName: name, mediaType: mediaType)
}
/// Read straight from the file system, not through the code under test.
func excludedFromBackup(_ url: URL) -> Bool {
    (try? url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup) == true
}
@MainActor
func checkAsync(_ name: String, _ condition: @autoclosure () async throws -> Bool) async {
    do {
        if try await condition() { passed += 1 } else { failures.append(name) }
    } catch {
        failures.append("\(name) (threw \(error))")
    }
}
// Share directory names used below (lowercase UUIDs, as the extension makes them).
let shareA = "aaaaaaaa-aaaa-4aaa-aaaa-aaaaaaaaaaaa"
let shareRefused = "bbbbbbbb-bbbb-4bbb-abbb-bbbbbbbbbbbb"
let shareDead = "cccccccc-cccc-4ccc-accc-cccccccccccc"
let shareWriting = "dddddddd-dddd-4ddd-addd-dddddddddddd"

// --- the Mac's accepted types (Echo 22e59ed8) ---------------------------------------------------
check("S1 a camera JPEG is accepted as image/jpeg", AttachmentRules.mediaType(forTypeIdentifier: "public.jpeg") == "image/jpeg")
check("S2 HEIC is accepted", AttachmentRules.mediaType(forTypeIdentifier: "public.heic") == "image/heic")
check("S3 a Word document (OOXML) is accepted",
      AttachmentRules.mediaType(forTypeIdentifier: "org.openxmlformats.wordprocessingml.document")?.hasSuffix("wordprocessingml.document") == true)
check("S4 legacy Word (.doc) is refused, as the Mac refuses it", AttachmentRules.mediaType(forTypeIdentifier: "com.microsoft.word.doc") == nil)
check("S5 a Keynote file is refused", AttachmentRules.mediaType(forTypeIdentifier: "com.apple.keynote.key") == nil)
check("S6 a ZIP archive is refused", AttachmentRules.mediaType(forTypeIdentifier: "public.zip-archive") == nil)
check("S7 a movie is refused (photos and files only, §75)", AttachmentRules.mediaType(forTypeIdentifier: "public.mpeg-4") == nil)
check("S8 thirteen media types, the Mac's own count", AttachmentRules.accepted.count == 13)
check("S9 the Mac's per-file limit is 25 MiB", AttachmentRules.maxFileBytes == 26_214_400)
check("S10 ids follow the Mac's rule", AttachmentRules.isValidID(nextID()) && !AttachmentRules.isValidID("a/b") && !AttachmentRules.isValidID(""))

// --- the inbox -----------------------------------------------------------------------------------
let container = scratch.appendingPathComponent("group", isDirectory: true)
let inbox = ShareInbox(container: container)
counter = 0
let photo1 = try staged("IMG_0001.jpg", "image/jpeg")
let photo2 = try staged("IMG_0002.png", "image/png", fill: 9)
let pdf = try staged("Q3 plan & notes.pdf", "application/pdf", fill: 3)
let envelope = try inbox.write(caption: "  For the board  ", files: [pdf, photo1, photo2], threadID: "thr_5c1e",
                               nowMs: 1_758_000_000_000, id: shareA, newID: nextID)
check("I1 one share, three items, stored inside the inbox",
      envelope.items.count == 3 && envelope.items.allSatisfy { inbox.fileURL(for: $0).map { fm.fileExists(atPath: $0.path) } == true })
check("I2 photos go as one album, then each file (NOTES \"Order of sending\")",
      envelope.messages.map(\.itemIDs.count) == [2, 1] && envelope.messages[0].itemIDs.allSatisfy { id in envelope.items.first { $0.id == id }!.isPhoto })
let album = try JSONSerialization.jsonObject(with: Data(envelope.messages[0].commitBody.utf8)) as! [String: Any]
let fileMessage = try JSONSerialization.jsonObject(with: Data(envelope.messages[1].commitBody.utf8)) as! [String: Any]
check("I3 the caption rides on the album, trimmed", album["text"] as? String == "For the board" && fileMessage["text"] == nil)
check("I4 the commit is the Mac's shape",
      Set(album.keys) == ["client_id", "thread_id", "kind", "text", "attachments", "sent_at"] && album["kind"] as? String == "attachments"
      && album["thread_id"] as? String == "thr_5c1e" && album["sent_at"] as? String == "2025-09-16T05:20:00.000Z")
let refs = album["attachments"] as! [[String: String]]
check("I5 each file is named by its id and the SHA-256 of its bytes",
      refs.count == 2 && refs.allSatisfy { ref in envelope.items.contains { $0.id == ref["id"] && $0.sha256 == ref["sha256"] && $0.sha256.count == 64 } })
check("I6 the commit bytes are serialized once and stored",
      inbox.loadAll().first?.messages.map(\.commitBody) == envelope.messages.map(\.commitBody))
let captionOnFile = try inbox.write(caption: "Read this", files: [try staged("a.pdf", "application/pdf"), try staged("b.csv", "text/csv")],
                                    threadID: "thr_5c1e", nowMs: 1_758_000_000_001, newID: nextID)
check("I7 with no photos the caption rides on the last file",
      captionOnFile.messages.map { (try? JSONSerialization.jsonObject(with: Data($0.commitBody.utf8)) as? [String: Any])?["text"] as? String }
          == [nil, "Read this"])
check("I19 waiting shares stay out of iCloud and Finder backups (security review I-2)",
      inbox.root.deletingLastPathComponent().lastPathComponent == "RichOS" && excludedFromBackup(inbox.root.deletingLastPathComponent()))
check("I8 a file name cannot become a path", ShareInbox.safeFileName("../../etc/passwd", fallback: "x") == "passwd"
      && ShareInbox.safeFileName("..", fallback: "x") == "x" && ShareInbox.safeFileName(".hidden", fallback: "x") == "x")
var escaping = envelope.items[0]
escaping.relativePath = "\(ShareInbox.relativeRoot)/../../outside.txt"
check("I9 an item path that leaves the inbox is refused", inbox.fileURL(for: escaping) == nil)
check("I10 eleven files are refused (the Mac takes ten)",
      (try? inbox.write(caption: "", files: try (0..<11).map { try staged("p\($0).jpg", "image/jpeg") }, threadID: "t", nowMs: 1)) == nil)
let big = try staged("big.pdf", "application/pdf", bytes: AttachmentRules.maxFileBytes + 1)
do {
    _ = try inbox.write(caption: "", files: [big], threadID: "t", nowMs: 1, id: shareRefused)
    check("I11 a file over 25 MiB is refused", false)
} catch ShareInboxError.tooLarge(let name, let bytes) {
    check("I11 a file over 25 MiB is refused, by name and size", name == "big.pdf" && bytes == AttachmentRules.maxFileBytes + 1)
}
check("I12 a refused share leaves no directory behind", !fm.fileExists(atPath: inbox.root.appendingPathComponent(shareRefused).path))
check("I13 an unsupported type is refused", (try? inbox.write(caption: "", files: [try staged("a.zip", "application/zip")], threadID: "t", nowMs: 1)) == nil)
// A share whose writer died: a directory with a start mark and no manifest.
let dead = inbox.root.appendingPathComponent(shareDead, isDirectory: true)
try fm.createDirectory(at: dead, withIntermediateDirectories: true)
try Data("1000".utf8).write(to: dead.appendingPathComponent(ShareInbox.startedName))
let writing = inbox.root.appendingPathComponent(shareWriting, isDirectory: true)
try fm.createDirectory(at: writing, withIntermediateDirectories: true)
try Data("1758000000000".utf8).write(to: writing.appendingPathComponent(ShareInbox.startedName))
check("I14 a share with no manifest is never loaded", inbox.loadAll().count == 2)
check("I15 a dead writer's share is swept; one still being written is left",
      inbox.sweepIncomplete(nowMs: 1_758_000_060_000) == [shareDead] && fm.fileExists(atPath: writing.path))
let sent = try inbox.markSent(envelope, atMs: 1_758_000_000_500)
check("I16 an accepted share is recorded as sent", inbox.loadAll().first { $0.id == shareA }?.delivery == .sent(atMs: 1_758_000_000_500) && sent.delivery != .saved)
try inbox.remove(id: shareA)
check("I17 a taken share is removed", !fm.fileExists(atPath: inbox.root.appendingPathComponent(shareA).path))
check("I18 removal refuses a name that is not a share", (try? inbox.remove(id: "../group")) == nil)

// --- the context the app mirrors for the extension -----------------------------------------------
var state = AppState()
check("C1 a new install is unpaired for the extension", SharePlatform.context(for: state, macAcceptsAttachments: true) == .unpaired)
state.pairing = .paired
state.consentGiven = true
state.mac = MacLink(origin: "https://c-x.richos.ceo", route: .connect, threadID: "thr_5c1e", name: "Alex’s Mac")
state.appearance = .light
let context = SharePlatform.context(for: state, macAcceptsAttachments: true)
check("C2 paired: the Mac's name, the conversation and the appearance reach the extension",
      context.paired && context.macName == "Alex’s Mac" && context.threadID == "thr_5c1e" && context.appearance == "light")
var noConsent = state
noConsent.consentGiven = false
check("C3 paired but the disclosure not yet accepted: nothing is sent from Share", !SharePlatform.context(for: noConsent, macAcceptsAttachments: true).paired)
try context.write(container: container)
check("C4 the context round-trips through the App Group", ShareContext.read(container: container) == context)
check("C6 the pairing context stays out of backups (security review I-2)",
      excludedFromBackup(container.appendingPathComponent(ShareContext.fileName)))
check("C5 no context file reads as unpaired", ShareContext.read(container: scratch.appendingPathComponent("none")) == .unpaired)

// --- delivery against a fake Mac -----------------------------------------------------------------
struct Sent: Equatable {
    var method: String
    var pathAndQuery: String
    var contentType: String
    var body: Data
}
final class FakeMac: MacRequests, @unchecked Sendable {
    let lock = NSLock()
    var requests: [Sent] = []
    let answer: (Sent, Int) -> HTTPResponse
    var delayMs: UInt64 = 0
    init(_ answer: @escaping (Sent, Int) -> HTTPResponse) { self.answer = answer }
    func send(_ method: String, _ target: String, body: Data, contentType: String) async throws -> HTTPResponse {
        if delayMs > 0 { try await Task.sleep(nanoseconds: delayMs * 1_000_000) }
        return record(Sent(method: method, pathAndQuery: target, contentType: contentType, body: body))
    }
    private func record(_ request: Sent) -> HTTPResponse {
        lock.lock(); defer { lock.unlock() }
        requests.append(request)
        return answer(request, requests.count)
    }
}
func json(_ status: Int, _ text: String) -> HTTPResponse { HTTPResponse(status: status, body: Data(text.utf8)) }
let two = try inbox.write(caption: "Two", files: [try staged("x.jpg", "image/jpeg"), try staged("y.pdf", "application/pdf", fill: 1)],
                          threadID: "thr_5c1e", nowMs: 1_758_000_000_000, newID: nextID)
let happy = FakeMac { _, _ in json(200, #"{"duplicate":false}"#) }
await checkAsync("D1 every upload and both commits answered 200: accepted", await AttachmentDelivery.deliver(two, inbox: inbox, via: happy) == .accepted)
let paths = happy.requests.map(\.pathAndQuery)
check("D2 upload, commit, upload, commit — in outbox order",
      paths.count == 4 && paths[0].hasPrefix("/api/messages?kind=attachment&client_id=\(two.messages[0].clientID)&attachment_id=")
      && paths[1] == "/api/messages" && paths[2].contains("attachment_id=\(two.messages[1].itemIDs[0])") && paths[3] == "/api/messages")
check("D3 an upload carries the file's own media type and exact bytes",
      try happy.requests[0].contentType == "image/jpeg" && happy.requests[0].body == (try Data(contentsOf: inbox.fileURL(for: two.items.first { $0.isPhoto }!)!)))
check("D4 the commit is the stored bytes, byte for byte", happy.requests[1].body == Data(two.messages[0].commitBody.utf8))
check("D5 a name with spaces and & cannot change the query (the core's form encoding; the Mac reads + as a space)",
      AttachmentDelivery.uploadPath(clientID: "c", item: SharedItem(id: "a", fileName: "Q3 plan & notes.pdf", mediaType: "application/pdf",
                                                                   relativePath: "", byteCount: 1, sha256: ""))
          == "/api/messages?kind=attachment&client_id=c&attachment_id=a&name=Q3+plan+%26+notes.pdf")
// The Mac lost a file (evicted): 422 missing, upload that one, then the SAME commit bytes again.
let evictedID = two.messages[0].itemIDs[0]
final class Counter: @unchecked Sendable { var value = 0 }
let commits = Counter()
let evicting = FakeMac { request, _ in
    if request.pathAndQuery == "/api/messages" {
        commits.value += 1
        return commits.value == 1 ? json(422, #"{"accepted":false,"retry":true,"missing":["\#(evictedID)"],"reason":"Some files have not reached your Mac yet."}"#)
                                  : json(200, "{}")
    }
    return json(200, "{}")
}
_ = await AttachmentDelivery.deliver(two, inbox: inbox, via: evicting)
let firstMessage = evicting.requests.prefix(4).map(\.pathAndQuery)
check("D6 a missing file is uploaded again and the same commit bytes are resent",
      firstMessage.count == 4 && firstMessage[2].contains("attachment_id=\(evictedID)")
      && evicting.requests[1].body == evicting.requests[3].body)
await checkAsync("D7 409 is final and needs the person",
      await AttachmentDelivery.deliver(two, inbox: inbox, via: FakeMac { _, _ in json(409, #"{"accepted":false,"retry":false,"reason":"That file ID already belongs to a different file."}"#) })
          == .refused(reason: "That file ID already belongs to a different file."))
await checkAsync("D8 503 retry:true is tried again later",
      await AttachmentDelivery.deliver(two, inbox: inbox, via: FakeMac { _, _ in json(503, #"{"accepted":false,"retry":true,"reason":"busy"}"#) }) == .retryLater)
await checkAsync("D9 503 retry:false (the Mac may already have it) is final",
      await AttachmentDelivery.deliver(two, inbox: inbox, via: FakeMac { r, _ in r.pathAndQuery == "/api/messages" ? json(503, #"{"accepted":false,"retry":false,"reason":"Check the conversation."}"#) : json(200, "{}") })
          == .refused(reason: "Check the conversation."))
await checkAsync("D10 403 means this phone was removed", await AttachmentDelivery.deliver(two, inbox: inbox, via: FakeMac { _, _ in json(403, #"{"revoked":true}"#) }) == .revoked)
await checkAsync("D11 404 (a stale challenge, a restarted Mac) is tried again later",
      await AttachmentDelivery.deliver(two, inbox: inbox, via: FakeMac { _, _ in json(404, "") }) == .retryLater)
let stopsEarly = FakeMac { r, _ in r.pathAndQuery == "/api/messages" ? json(503, #"{"retry":true}"#) : json(200, "{}") }
_ = await AttachmentDelivery.deliver(two, inbox: inbox, via: stopsEarly)
check("D12 a later message never overtakes an earlier one that failed", stopsEarly.requests.count == 2)
await checkAsync("D13 an upload 200 alone is never 'accepted'",
      await AttachmentDelivery.deliver(two, inbox: inbox, via: FakeMac { r, _ in r.pathAndQuery == "/api/messages" ? json(422, #"{"accepted":false,"retry":false,"reason":"No."}"#) : json(200, "{}") })
          == .refused(reason: "No."))

// --- the sheet's promise: Sent only on acceptance, never a wait past 3 s ---------------------------
await checkAsync("A1 offline: Saved, with nothing sent", await ShareAttempt.run(two, inbox: inbox, transport: happy, online: false) == .saved(.offline))
await checkAsync("A2 no signed connection in this build: Saved, never Sent", await ShareAttempt.run(two, inbox: inbox, transport: nil, online: true) == .saved(.cannotSendHere))
await checkAsync("A3 accepted within the wait: Sent", await ShareAttempt.run(two, inbox: inbox, transport: FakeMac { _, _ in json(200, "{}") }, online: true) == .sent)
let slow = FakeMac { _, _ in json(200, "{}") }
slow.delayMs = 5000
let started = Date()
let slowOutcome = await ShareAttempt.run(two, inbox: inbox, transport: slow, online: true, waitMs: 300)
let waited = Date().timeIntervalSince(started)
check("A4 no answer within the wait: Saved, and the sheet did not wait for the Mac (\(Int(waited * 1000)) ms)",
      slowOutcome == .saved(.notConfirmed) && waited < 1.5)
await checkAsync("A5 a refusal is Saved with the Mac's words",
      await ShareAttempt.run(two, inbox: inbox, transport: FakeMac { _, _ in json(422, #"{"retry":false,"reason":"Not a PDF."}"#) }, online: true)
          == .saved(.refused("Not a PDF.")))

// --- a HEIC photo becomes a JPEG Rich can read ----------------------------------------------------
func makeImage(width: Int, height: Int, type: UTType, to url: URL, gps: Bool) -> Bool {
    guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
    context.setFillColor(CGColor(red: 0.8, green: 0.6, blue: 0.3, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    guard let image = context.makeImage(),
          let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else { return false }
    let properties: [CFString: Any] = gps ? [kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 51.5, kCGImagePropertyGPSLongitude: 0.12]] : [:]
    CGImageDestinationAddImage(destination, image, properties as CFDictionary)
    return CGImageDestinationFinalize(destination)
}
let heic = scratch.appendingPathComponent("camera.heic")
if makeImage(width: 4032, height: 3024, type: .heic, to: heic, gps: true) {
    let normalized = try PhotoNormalizer.normalize(heic, mediaType: "image/heic", suggestedName: "IMG_4242.HEIC", directory: scratch)
    let source = CGImageSourceCreateWithURL(normalized.url as CFURL, nil)!
    let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as! [CFString: Any]
    let w = props[kCGImagePropertyPixelWidth] as! Int, h = props[kCGImagePropertyPixelHeight] as! Int
    check("P1 HEIC becomes JPEG named for it", normalized.mediaType == "image/jpeg" && normalized.suggestedName == "IMG_4242.jpg"
          && CGImageSourceGetType(source) as String? == UTType.jpeg.identifier)
    check("P2 its long edge is 2576 px, aspect kept (\(w)×\(h))", max(w, h) == AttachmentRules.photoLongEdge && abs(Double(w) / Double(h) - 4032.0 / 3024.0) < 0.01)
    check("P3 no location leaves the phone", props[kCGImagePropertyGPSDictionary] == nil)
} else {
    failures.append("P1-P3 could not encode a HEIC test image on this Mac")
}
let png = try staged("shot.png", "image/png")
check("P4 every other accepted type is sent as it is",
      try PhotoNormalizer.normalize(png.url, mediaType: "image/png", suggestedName: "shot.png", directory: scratch).url == png.url)

// --- the activation rule: RichOS is offered only for what the Mac accepts -------------------------
let plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2])), format: nil) as! [String: Any]
let rule = ((plist["NSExtension"] as! [String: Any])["NSExtensionAttributes"] as! [String: Any])["NSExtensionActivationRule"] as! String
let predicate = NSPredicate(format: rule)
func offered(_ items: [[String]]) -> Bool {
    predicate.evaluate(with: ["extensionItems": [["attachments": items.map { ["registeredTypeIdentifiers": $0] }]]])
}
check("R1 a photo from Photos", offered([["public.heic", "public.jpeg"]]))
check("R2 three photos", offered([["public.jpeg"], ["public.png"], ["public.heic"]]))
check("R3 a PDF from Files", offered([["com.adobe.pdf"]]))
check("R4 a Word document", offered([["org.openxmlformats.wordprocessingml.document"]]))
check("R5 not a text selection (plain text is out of v1)", !offered([["public.plain-text"]]))
check("R6 not a web link", !offered([["public.url"]]))
check("R7 not a movie", !offered([["public.mpeg-4"]]))
check("R8 not a mix with something the Mac refuses", !offered([["public.jpeg"], ["public.zip-archive"]]))
check("R9 not eleven photos (the Mac takes ten)", !offered(Array(repeating: ["public.jpeg"], count: 11)))
check("R10 ten photos", offered(Array(repeating: ["public.jpeg"], count: 10)))
check("R11 not legacy Word", !offered([["com.microsoft.word.doc"]]))

// --- the recorder's level, which the voice bubble and halo draw (App/Platform/Shared/VoiceLevel) ----
check("V1 silence is 0", VoiceLevel.level(averagePowerDB: -160) == 0 && VoiceLevel.level(averagePowerDB: -50) == 0)
check("V2 full scale is 1", VoiceLevel.level(averagePowerDB: 0) == 1 && VoiceLevel.level(averagePowerDB: 3) == 1)
check("V3 speech at -20 dBFS reads 0.6", abs(VoiceLevel.level(averagePowerDB: -20) - 0.6) < 1e-6)
check("V4 a meter that reports no number reads 0", VoiceLevel.level(averagePowerDB: -.infinity) == 0 && VoiceLevel.level(averagePowerDB: .nan) == 0)

if failures.isEmpty {
    print("Share platform: \(passed) checks passed")
} else {
    print("Share platform: \(failures.count) FAILED, \(passed) passed")
    failures.forEach { print("  FAIL \($0)") }
    exit(1)
}
