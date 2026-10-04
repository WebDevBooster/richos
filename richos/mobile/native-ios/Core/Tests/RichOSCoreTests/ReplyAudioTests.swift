import Foundation
import Testing
@testable import RichOSCore

/// App Review rehearsal 2026-10-04, row 2: "Hear it" never appeared, because nothing read the row's
/// `has_audio` or the Mac's `audio` capability, and nothing fetched the reply's audio.
@Suite struct ReplyAudioTests {
    /// A Mac that answers the challenge probe and serves one reply's audio.
    actor AudioMac: HTTPTransport {
        private(set) var targets: [String] = []
        private(set) var authorized: [Bool] = []
        let status: Int
        init(status: Int = 200) { self.status = status }
        func send(_ request: HTTPRequest, origin: String) async throws -> HTTPResponse {
            targets.append(request.target)
            authorized.append(request.headers["Authorization"] != nil)
            let challenge = ["X-RichOS-Challenge": "Xqra0YQOgVJ9WLmQy9eYs1LSoxDt1Ggv"]
            if request.target.hasPrefix("/api/audio/") {
                return HTTPResponse(status: status, headers: challenge.merging(["Content-Type": "audio/wav"]) { a, _ in a },
                                    body: status == 200 ? Data("RIFF....WAVE".utf8) : Data(#"{"retry":false}"#.utf8))
            }
            return HTTPResponse(status: 200, headers: challenge)
        }
    }

    func row(_ json: String) throws -> Message {
        try CoreJSON.decode(StreamRow.self, from: Data(json.utf8)).message
    }

    @Test func theRowsHasAudioReachesRichsReplyOnly() throws {
        let rich = try row(#"{"id":"turn_9:text:0","thread_id":"thr_1","cursor":9,"role":"rich","kind":"text","text":"Done.","has_audio":true,"complete":true}"#)
        #expect(rich.hasAudio == true)
        let said = try row(#"{"id":"turn_9:text:0","thread_id":"thr_1","cursor":9,"role":"rich","kind":"text","text":"Done.","has_audio":false,"complete":true}"#)
        #expect(said.hasAudio == nil)
        let absent = try row(#"{"id":"turn_9:text:0","thread_id":"thr_1","cursor":9,"role":"rich","kind":"text","text":"Done.","complete":true}"#)
        #expect(absent.hasAudio == nil)
        let mine = try row(#"{"id":"t1:user","thread_id":"thr_1","cursor":8,"role":"ceo","kind":"text","text":"Hi","has_audio":true,"complete":true}"#)
        #expect(mine.hasAudio == nil)
    }

    @Test func aReplyIsHeardWhenItHasAudioOrTheMacOffersAudio() {
        var reply = Message(id: "turn_9:text:0", author: .rich, text: "Done.", sentAt: 1)
        #expect(!ReplyAudio.hearable(reply, macOffersAudio: false), "a real Mac sends has_audio false: without the capability, nothing to hear")
        #expect(ReplyAudio.hearable(reply, macOffersAudio: true), "a Mac that offers audio reads any finished reply")
        reply.hasAudio = true
        #expect(ReplyAudio.hearable(reply, macOffersAudio: false), "has_audio true is enough on its own")

        #expect(!ReplyAudio.hearable(Message(id: "t1:user", author: .me, text: "Hi", sentAt: 1), macOffersAudio: true), "never your own message")
        #expect(!ReplyAudio.hearable(Message(id: "v", author: .rich, kind: .voice, text: "", sentAt: 1), macOffersAudio: true), "never a voice note")
        #expect(!ReplyAudio.hearable(Message(id: "notified:abc", author: .rich, text: "Preview…", sentAt: 1), macOffersAudio: true),
                "never a notification's preview, whose id is the phone's")
        #expect(!ReplyAudio.hearable(Message(id: "e", author: .rich, text: "  ", sentAt: 1), macOffersAudio: true), "never an empty reply")
    }

    @Test func theMacsAudioCapabilityIsKept() throws {
        var s = AppState()
        s.mac = MacLink(origin: "https://mac.example", route: .connect, deviceID: "dev_8d4c57b7ff82", threadID: "thr_1")
        s = Reducer.reduce(s, .macAudioCapability(true)).state
        #expect(s.mac?.replyAudio == true)
        #expect(try CoreJSON.decode(Action.self, from: Data(#"{"type":"mac-audio-capability","acceptsAudio":true}"#.utf8)) == .macAudioCapability(true))
        s = Reducer.reduce(s, .macAudioCapability(false)).state
        #expect(s.mac?.replyAudio == false)
    }

    @Test func hearItAsksTheMacForThatReplysAudioSignedInTheHeader() async throws {
        let origin = "https://mac.example"
        let identities = MemoryIdentityStore()
        _ = await identities.signer(for: origin)
        let mac = AudioMac()
        let network = NetworkEffects(transport: mac, stream: LifecycleStream([]), identities: identities, clock: FixedClock(ms: 100))
        var s = AppState()
        s.pairing = .paired
        s.mac = MacLink(origin: origin, route: .connect, deviceID: "dev_8d4c57b7ff82", threadID: "thr_5c1e")
        let bytes = await network.replyAudio(messageID: "turn_9:text:0", state: s)
        #expect(bytes == Data("RIFF....WAVE".utf8))
        let targets = await mac.targets
        #expect(targets.last == "/api/audio/turn_9%3Atext%3A0?thread_id=thr_5c1e", "the Android corpus spelling (ProtocolTest.kt)")
        #expect(await mac.authorized.last == true, "the Mac's audio route takes the credential in the header only")

        // The Mac's refusal ("Audio playback is unavailable") is no audio, and "Hear it" comes back.
        let refusing = NetworkEffects(transport: AudioMac(status: 503), stream: LifecycleStream([]), identities: identities, clock: FixedClock(ms: 100))
        #expect(await refusing.replyAudio(messageID: "turn_9:text:0", state: s) == nil)
    }
}
