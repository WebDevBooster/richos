import Foundation
import Testing
@testable import RichOSCore
@testable import RichOSFixtures

/// D04 on iPhone (native acceptance r1; Android's fix is `279bf32d`): a reply the person has read in
/// the open conversation leaves Notification Center however the app was opened, the way Telegram
/// clears a chat's notifications once it is read. What is read is decided from the core's state
/// alone, so these run with no phone. A reply the person has not seen keeps its notification.
@Suite struct ReadRepliesTests {
    /// `conv-populated`: paired, consented, following the newest, replies o2 … r4.
    func open() throws -> AppState { try Fixture.named("conv-populated").state }

    func richIDs(_ s: AppState) -> [String] { s.messages.filter { $0.author == .rich }.map(\.id) }

    @Test func followingTheNewestReadsEveryLoadedReply() throws {
        let s = try open()
        let read = try #require(ReadReplies.of(s))
        #expect(read.threadID == "thr_5c1e")
        #expect(read.replyIDs == richIDs(s))
        #expect(read.replyIDs.last == "r4")
    }

    @Test func scrolledUpReadsOnlyUpToTheReadingPosition() throws {
        var s = try open()
        s = Reducer.reduce(s, .rememberReading(ReadingAnchor(messageID: "r2", offset: 40))).state
        let read = try #require(ReadReplies.of(s))
        let upTo = try #require(s.messages.firstIndex { $0.id == "r2" })
        #expect(read.replyIDs == s.messages[...upTo].filter { $0.author == .rich }.map(\.id))
        #expect(!read.replyIDs.contains("r3") && !read.replyIDs.contains("r4"), "replies below the reading position stay")
    }

    @Test func aReplyArrivingBelowTheReadingPositionIsNotRead() throws {
        var s = Reducer.reduce(try open(), .rememberReading(ReadingAnchor(messageID: "r4", offset: 40))).state
        let reply = Message(id: "r5", author: .rich, text: "New.", sentAt: Fixture.now + 60_000)
        s = Reducer.reduce(s, .messagesArrived([reply])).state
        #expect(s.messages.last?.id == "r5")
        #expect(!(ReadReplies.of(s)?.replyIDs.contains("r5") ?? false))
        // Latest brings it into view: read.
        s = Reducer.reduce(s, .setFollowing(true)).state
        #expect(ReadReplies.of(s)?.replyIDs.last == "r5")
    }

    @Test func notFollowingWithoutAKnownPositionReadsNothing() throws {
        var s = try open()
        s.following = false
        #expect(ReadReplies.of(s) == nil, "no reading position: nothing is assumed seen")
        s.readingAnchor = ReadingAnchor(messageID: "gone", offset: 0)
        #expect(ReadReplies.of(s) == nil, "a position no longer loaded: nothing is assumed seen")
    }

    @Test func nothingIsReadWhileTheConversationIsCovered() throws {
        let base = try open()
        var sheet = base; sheet.sheet = .settings
        #expect(ReadReplies.of(sheet) == nil, "Settings over the conversation")
        var forget = base; forget.sheet = .forget
        #expect(ReadReplies.of(forget) == nil, "a dialog over it")
        var asking = base; asking.sheet = .microphonePrompt
        #expect(ReadReplies.of(asking) == nil, "the system's microphone question over it")
        var dialog = base; dialog.update = UpdateNotice(prominence: .dialog, version: "1.1", message: "")
        #expect(ReadReplies.of(dialog) == nil, "an update dialog over it")
        var required = base; required.update = UpdateNotice(prominence: .required, version: "1.1", message: "")
        #expect(ReadReplies.of(required) == nil, "a required update in its place")
        var banner = base; banner.update = UpdateNotice(prominence: .banner, version: "1.1", message: "")
        #expect(ReadReplies.of(banner) != nil, "a banner leaves the conversation in view")
        var revoked = base; revoked.pairing = .revoked
        #expect(ReadReplies.of(revoked) == nil, "removed from the Mac")
        var consent = base; consent.consentGiven = false
        #expect(ReadReplies.of(consent) == nil, "consent not given yet")
        var blocked = base; blocked.pairingProblem = .blockedByUnsentWork(count: 1)
        #expect(ReadReplies.of(blocked) == nil, "the pair-blocked dialog over it")
    }

    @Test func noConversationOrNoReplyReadsNothing() throws {
        #expect(ReadReplies.of(AppState.initial) == nil)
        #expect(ReadReplies.of(try Fixture.named("conv-empty").state) == nil)
        var mine = try open()
        mine.messages = mine.messages.filter { $0.author == .me }
        #expect(ReadReplies.of(mine) == nil)
        var noThread = try open()
        noThread.mac?.threadID = nil
        #expect(ReadReplies.of(noThread) == nil)
    }

    @Test func turningNotificationsOffWithdrawsEveryDeliveredOne() throws {
        let effects = Reducer.reduce(try open(), .turnOffNotifications).effects
        #expect(effects.contains(.withdrawNotifications))
        #expect(effects.contains(.unregisterNotifications))
    }

    @Test func forgettingTheMacWithdrawsEveryDeliveredOne() throws {
        for status: Notifications.Status in [.on, .off, .denied] {
            var s = try open()
            s.notifications.status = status
            s = Reducer.reduce(s, .forgetPairing).state
            let effects = Reducer.reduce(s, .confirmForget).effects
            #expect(effects.contains(.withdrawNotifications), "status \(status)")
        }
    }

    @Test func nothingElseWithdrawsThemAll() throws {
        let s = try open()
        for action: Action in [.foregrounded(at: 1), .backgrounded(at: 2), .turnOnNotifications, .setPreviews(false),
                               .openSheet(.settings), .forgetPairing, .pairingRevoked, .setFollowing(true)] {
            #expect(!Reducer.reduce(s, action).effects.contains(.withdrawNotifications), "\(action)")
        }
    }
}
