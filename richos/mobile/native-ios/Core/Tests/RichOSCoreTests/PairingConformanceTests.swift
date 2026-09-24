import Foundation
import Testing
@testable import RichOSCore

/// `conformance/vectors/pairing.json` `pair_exchanges`, `pair_v2`, `platform_field` and
/// `fingerprint_confirmations`; plus the signed pair bodies in `signing.json`. This phone is a v2
/// phone: every exchange sends `native_v2_body_fields`, and there is no v1 request to fall back to.
@Suite struct PairingExchangeConformance {
    let identity = DeviceIdentity(publicPoint: Corpus.testKey.publicKey.x963Representation)

    /// Replays one recorded exchange: the one unsigned request with the v2 native fields, then the
    /// recorded outcome and the state the phone holds afterwards.
    func replay(_ c: [String: Any], fields: [String]) async throws -> PairingExchange.Outcome {
        let name = c["name"] as? String ?? "?"
        let mac = ScriptedMac(try #require(c["mac_answers"] as? [[String: Any]]))
        let link = try PairLink.parse("https://mm1.tail1a2b3c.ts.net:8443/#pair=K7M2QX9H")
        let result = await PairingExchange.pair(link: link, identity: identity, deviceName: "iPhone", transport: mac)
        let sent = await mac.requests
        let recorded = try #require(c["requests"] as? [[String: Any]])
        #expect(sent.count == recorded.count && sent.first?.target == "/api/pair" && sent.first?.headers["Authorization"] == nil, "\(name): one unsigned request, and no second (no fallback)")
        #expect(sent.first?.headers["Content-Type"] == "application/json", "\(name): JSON")
        let ours = try #require(try JSONSerialization.jsonObject(with: sent.first?.body ?? Data()) as? [String: Any])
        let theirs = try #require(try JSONSerialization.jsonObject(with: Corpus.body(recorded[0]) ?? Data()) as? [String: Any])
        #expect(StreamConformance.same(ours["code"] as Any, theirs["code"] as Any) && StreamConformance.same(ours["public_key_jwk"] as Any, theirs["public_key_jwk"] as Any), "\(name): code and key")
        #expect(Set(ours.keys) == Set(fields) && ours["platform"] as? String == "ios" && ours["pairing_version"] as? Int == 2, "\(name): the native v2 body fields")
        // The key order is the corpus's list (the body is unsigned, but it is the bytes the Mac reads).
        let order = fields.compactMap { String(decoding: sent.first?.body ?? Data(), as: UTF8.self).range(of: "\"\($0)\":")?.lowerBound }
        #expect(order.count == fields.count && order == order.sorted(), "\(name): the fields in the corpus's order")
        let after = try #require(c["state_after"] as? [String: Any])
        let outcome = try #require(c["outcome"] as? [String: Any])
        switch result {
        case .paired(let paired), .macNeedsUpdate(let paired):
            #expect(paired.answer.deviceID == after["device_id"] as? String && paired.challenge == after["challenge"] as? String, "\(name): id and challenge")
            #expect(paired.apiBase == after["api_base"] as? String && paired.apiBaseRefusal == after["api_base_refusal"] as? String, "\(name): origin kept")
        case .failed:
            #expect(after["device_id"] is NSNull && after["challenge"] is NSNull, "\(name): nothing held")
        }
        if let want = outcome["error"] as? [String: Any] {
            let error = try #require(result.error, "\(name): refused")
            #expect(error.reason.rawValue == want["reason"] as? String && error.status == want["status"] as? Int && error.retryable == want["retryable"] as? Bool
                    && error.aboutThisMessage == want["about_this_message"] as? Bool, "\(name): error")
        } else {
            #expect(outcome["ok"] as? Bool == true && result.error == nil, "\(name): pairs")
        }
        return result
    }

    @Test func everyExchangeSendsTheV2ShapeAndEndsAsRecorded() async throws {
        let file = try Corpus.load("pairing")
        let fields = try #require((file["pair_v2"] as? [String: Any])?["native_v2_body_fields"] as? [String])
        for c in try Corpus.cases(file, "pair_exchanges") { _ = try await replay(c, fields: fields) }
    }

    /// `pair_v2.exchanges`: a `pair-v2` Mac pairs; a Mac without it is refused
    /// (`refused_for_missing_pair_v2`) and never fallen back to.
    @Test func aV2PhoneRefusesAMacWithoutPairV2AndNeverFallsBack() async throws {
        let v2 = try #require(try Corpus.load("pairing")["pair_v2"] as? [String: Any])
        let fields = try #require(v2["native_v2_body_fields"] as? [String])
        let exchanges = try Corpus.cases(v2, "exchanges")
        #expect(exchanges.contains { $0["refused_for_missing_pair_v2"] as? Bool == true } && exchanges.contains { $0["refused_for_missing_pair_v2"] as? Bool == false })
        for c in exchanges {
            let name = c["name"] as? String ?? "?"
            #expect(c["pairing_version"] as? Int == PairingWire.pairingVersion, "\(name): the corpus's version")
            let result = try await replay(c, fields: fields)
            let refused: Bool
            if case .macNeedsUpdate = result { refused = true } else { refused = false }
            #expect(refused == (c["refused_for_missing_pair_v2"] as? Bool), "\(name): refused_for_missing_pair_v2")
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

    /// `conformance/vectors/attachments.json` (generated from Echo's Mac routes, `22e59ed8` and
    /// `194fcb75`): every upload target the corpus records is the one this phone builds, byte for byte,
    /// and every commit body is the recorded one.
    @Test func theAttachmentShapesFollowTheMacsRoute() throws {
        let file = try Corpus.load("attachments")
        let uploads = try Corpus.cases(file, "upload_cases") + (try Corpus.cases(file, "limit_sequence"))
        #expect(uploads.count == 26, "the corpus's upload cases are all read")
        for c in uploads {
            let name = c["name"] as? String ?? "?"
            let target = try #require((c["request"] as? [String: Any])?["target"] as? String)
            let query = try #require(target.components(separatedBy: "?").last)
            var fields: [String: String] = [:]
            for pair in query.components(separatedBy: "&") {
                let kv = pair.components(separatedBy: "=")
                // The Mac's reading of a query value (routes.rs percent_decode_component): `+` is a space.
                fields[kv[0]] = try #require(kv[1].replacingOccurrences(of: "+", with: " ").removingPercentEncoding)
            }
            #expect(fields["kind"] == "attachment", "\(name): kind")
            let clientID = try #require(fields["client_id"])
            let attachmentID = try #require(fields["attachment_id"])
            let ours = PairingWire.attachmentUploadTarget(clientID: clientID, attachmentID: attachmentID, name: fields["name"])
            #expect(ours == target, "\(name): the upload target")
        }
        // The commit. The phone leaves out `text` when there is none; the corpus records it as null.
        // The Mac reads the two the same way (routes.rs attachments_message: `None | Some(Value::Null)`),
        // so the recorded bytes without `"text":null` are the bytes this phone signs.
        let commits = try Corpus.cases(file, "commit_cases")
        #expect(commits.count == 3, "the corpus's commit cases are all read")
        for c in commits {
            let name = c["name"] as? String ?? "?"
            let request = try #require(c["request"] as? [String: Any])
            let recorded = try #require(Corpus.body(request))
            let object = try #require(try JSONSerialization.jsonObject(with: recorded) as? [String: Any])
            let list = try #require(object["attachments"] as? [[String: String]])
            let files = list.compactMap { item in item["id"].flatMap { id in item["sha256"].map { (id: id, sha256Hex: $0) } } }
            #expect(files.count == list.count, "\(name): every file names an id and a SHA-256")
            let clientID = try #require(object["client_id"] as? String)
            let sentAt = try #require(object["sent_at"] as? String)
            let ours = PairingWire.attachmentCommitBody(clientID: clientID, threadID: object["thread_id"] as? String,
                                                        text: object["text"] as? String, files: files, sentAtISO: sentAt)
            let expected = String(decoding: recorded, as: UTF8.self).replacingOccurrences(of: ",\"text\":null", with: "")
            #expect(String(decoding: ours, as: UTF8.self) == expected, "\(name): the commit body")
        }
        // The limits the Mac advertises decode into the phone's type, field for field.
        let advertised = try #require(file["limits"] as? [String: Any])
        let limitsJSON = try JSONSerialization.data(withJSONObject: advertised)
        let decoded = try JSONDecoder().decode(AttachmentLimits.self, from: limitsJSON)
        #expect(decoded.maxFileBytes == advertised["max_file_bytes"] as? Int && decoded.maxFilesPerMessage == advertised["max_files_per_message"] as? Int
                && decoded.maxMessageBytes == advertised["max_message_bytes"] as? Int && decoded.uploadSeconds == advertised["upload_seconds"] as? Int
                && decoded.mediaTypes == advertised["media_types"] as? [String], "the advertised limits")
    }
}
