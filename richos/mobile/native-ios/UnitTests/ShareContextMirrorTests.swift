// What the Share extension is told changes only when pairing, the Mac, the appearance or the Mac's
// limits change. `RichOSNativeApp` mirrors it to the App Group keyed on this value, so the ordinary
// traffic of a conversation — typing, a streamed reply, the recording clock — reads and writes no
// file on the main thread (Sage's review T3, richos-hq e642db4f; before, the mirror was keyed on the
// whole state and read and decoded `share-context.json` on every one of them).
import Foundation
import Testing
import RichOSCore
import RichOSFixtures
@testable import RichOSNative

@Suite struct ShareContextMirrorTests {
    func context(_ s: AppState) -> ShareContext {
        SharePlatform.context(for: s, macAcceptsAttachments: s.attachmentLimits != nil, limits: s.attachmentLimits)
    }

    @Test func aConversationsTrafficLeavesTheShareContextAlone() throws {
        var s = try Fixture.named("conv-empty").state
        s.microphone = .granted
        let before = context(s)
        for action: Action in [
            .compose(text: "B"), .compose(text: "Bo"), .compose(text: "Book the 7:10"),
            .replyStarted, .replyDelta(text: "Thursday "), .replyDelta(text: "Thursday is clear."),
            .voicePress(id: "v1", width: 386, at: 1_000), .tick(at: 1_100), .tick(at: 1_200), .tick(at: 1_300),
            .connectionLost(at: 2_000), .tick(at: 5_000), .connected(at: 6_000),
        ] {
            s = Reducer.reduce(s, action).state
            #expect(context(s) == before, "\(action) changed what the Share extension is told")
        }
    }

    @Test func whatTheExtensionNeedsStillReachesIt() throws {
        let paired = try Fixture.named("conv-empty").state
        var light = paired
        light.appearance = paired.appearance == .dark ? .light : .dark
        #expect(context(light) != context(paired), "the appearance")
        #expect(context(Reducer.reduce(paired, .pairingRevoked).state) != context(paired), "the pairing")
        var limited = paired
        limited.attachmentLimits = .macDefault
        #expect(context(limited) != context(paired), "the Mac's attachments")
    }
}
