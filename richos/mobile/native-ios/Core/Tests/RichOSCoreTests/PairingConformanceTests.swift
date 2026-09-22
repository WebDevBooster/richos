import Foundation
import Testing
@testable import RichOSCore

/// `conformance/vectors/pairing.json` `pair_exchanges`, `platform_field` and
/// `fingerprint_confirmations`; plus the signed pair bodies in `signing.json`.
@Suite struct PairingExchangeConformance {
    let identity = DeviceIdentity(publicPoint: Corpus.testKey.publicKey.x963Representation)

    @Test func everyExchangeSendsTheRecordedShapeAndEndsAsRecorded() async throws {
        let file = try Corpus.load("pairing")
        let fields = try #require((file["platform_field"] as? [String: Any])?["android_body_fields"] as? [String])
        for c in try Corpus.cases(file, "pair_exchanges") {
            let name = c["name"] as? String ?? "?"
            let mac = ScriptedMac(try #require(c["mac_answers"] as? [[String: Any]]))
            let link = try PairLink.parse("https://mm1.tail1a2b3c.ts.net:8443/#pair=K7M2QX9H")
            let result = await PairingExchange.pair(link: link, identity: identity, deviceName: "iPhone", transport: mac)
            // The request: the reference's fields, plus `platform` as the contract requires of a native app.
            let sent = await mac.requests
            let recorded = try #require(c["requests"] as? [[String: Any]])
            #expect(sent.count == recorded.count && sent.first?.target == "/api/pair" && sent.first?.headers["Authorization"] == nil, "\(name): one unsigned request")
            let ours = try #require(try JSONSerialization.jsonObject(with: sent.first?.body ?? Data()) as? [String: Any])
            let theirs = try #require(try JSONSerialization.jsonObject(with: Corpus.body(recorded[0]) ?? Data()) as? [String: Any])
            #expect(StreamConformance.same(ours["code"] as Any, theirs["code"] as Any) && StreamConformance.same(ours["public_key_jwk"] as Any, theirs["public_key_jwk"] as Any), "\(name): code and key")
            #expect(Set(ours.keys) == Set(fields) && ours["platform"] as? String == "ios", "\(name): the native body fields")
            let after = try #require(c["state_after"] as? [String: Any])
            let outcome = try #require(c["outcome"] as? [String: Any])
            switch result {
            case .success(let paired):
                #expect(outcome["ok"] as? Bool == true, "\(name): pairs")
                #expect(paired.answer.deviceID == after["device_id"] as? String && paired.challenge == after["challenge"] as? String, "\(name): id and challenge")
                #expect(paired.apiBase == after["api_base"] as? String && paired.apiBaseRefusal == after["api_base_refusal"] as? String, "\(name): origin kept")
                #expect(try Fingerprint.words(fromHex: paired.answer.caFingerprint).count == 6, "\(name): the fingerprint is readable")
            case .failure(let error):
                let want = try #require(outcome["error"] as? [String: Any])
                #expect(error.reason.rawValue == want["reason"] as? String && error.status == want["status"] as? Int && error.retryable == want["retryable"] as? Bool, "\(name): error")
            }
        }
    }

    @Test func theConfirmationBodiesAreTheRecordedBytes() throws {
        for c in try Corpus.cases(try Corpus.load("pairing"), "fingerprint_confirmations") {
            let request = try #require((c["requests"] as? [[String: Any]])?.first)
            let body = try #require(Corpus.body(request))
            let matches = (c["name"] as? String) == "they match"
            #expect(PairingWire.confirmationBody(deviceID: "dev_8d4c57b7ff82", matches: matches) == body, "\(c["name"] ?? "?")")
        }
    }

    @Test func thePushAndReceiptBodiesAreTheSignedCorpusShapes() throws {
        let valid = try Corpus.cases(try Corpus.load("signing"), "valid")
        func body(_ name: String) throws -> Data {
            let request = try #require(valid.first { $0["name"] as? String == name }?["request"] as? [String: Any])
            return try #require(Corpus.body(request))
        }
        // The corpus registers the preserved app's topic; the native app sends its own, same shape.
        let registration = try body("native push registration (APNs shape today)")
        let ours = PairingWire.pushRegistrationBody(tokenHex: String(repeating: "ab", count: 32), sandbox: true,
                                                    previewKey: Data(repeating: 7, count: 32), previews: true)
        #expect(String(decoding: ours, as: UTF8.self).replacingOccurrences(of: PairingWire.apnsTopic, with: "dev.richos.mobile.loop")
                == String(decoding: registration, as: UTF8.self))
        #expect(PairingWire.pushUnregistrationBody == (try body("native push unregistration")))
        #expect(PairingWire.replyReceiptBody(threadID: "thr_5c1e", messageID: "turn_9:text:0") == (try body("reply receipt")))
    }

    @Test func theAttachmentShapesFollowTheMacsRoute() throws {
        // Echo's 22e59ed8 commit message; the corpus's attachments.json is still a placeholder.
        #expect(PairingWire.attachmentUploadTarget(clientID: "c 1", attachmentID: "a1", name: "Q4 deck.pdf")
                == "/api/messages?kind=attachment&client_id=c+1&attachment_id=a1&name=Q4+deck.pdf")
        let commit = PairingWire.attachmentCommitBody(clientID: "c1", threadID: "thr_5c1e", text: "see attached",
                                                      files: [("a1", String(repeating: "0", count: 64))], sentAtISO: "2026-09-22T13:00:00.000Z")
        let object = try #require(try JSONSerialization.jsonObject(with: commit) as? [String: Any])
        #expect(object["kind"] as? String == "attachments" && (object["attachments"] as? [[String: String]])?.first?["id"] == "a1")
        let placeholder = try Corpus.load("attachments")
        if placeholder["status"] as? String != "placeholder" {
            Issue.record("attachments.json now has cases: replace this check with the corpus's")
        }
    }
}
