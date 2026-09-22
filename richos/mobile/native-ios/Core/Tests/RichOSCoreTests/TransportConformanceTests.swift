import Foundation
import Testing
@testable import RichOSCore
@testable import RichOSFixtures

/// A Mac that answers from a script and records every request, as `conformance/generator/harness.mjs`
/// does for the reference client.
actor ScriptedMac: HTTPTransport {
    struct TransportFailure: Error {}
    private var answers: [[String: Any]]
    private(set) var requests: [HTTPRequest] = []

    init(_ answers: [[String: Any]]) { self.answers = answers }

    func send(_ request: HTTPRequest, origin: String) async throws -> HTTPResponse {
        requests.append(request)
        guard !answers.isEmpty else { throw TransportFailure() }
        let answer = answers.removeFirst()
        if answer["transport"] as? Bool == true { throw TransportFailure() }
        let body: Data
        switch answer["body"] {
        case let text as String: body = Data(text.utf8)
        case nil, is NSNull: body = Data()
        case let object?: body = try JSONSerialization.data(withJSONObject: object)
        }
        return HTTPResponse(status: answer["status"] as? Int ?? 0, headers: answer["headers"] as? [String: String] ?? [:], body: body)
    }
}

/// Recordings held as bytes, for voice deliveries in tests.
struct MemoryRecordings: RecordingStore {
    var files: [String: Data]
    func wavBytes(id: String) async throws -> Data {
        guard let data = files[id] else { throw CoreError("no recording \(id)") }
        return data
    }
}

@Suite struct ErrorsConformance {
    @Test func everyMacAnswerTakesTheRequiredClientAction() throws {
        for c in try Corpus.cases(try Corpus.load("errors"), "cases") {
            let name = c["name"] as? String ?? "?"
            let answer = try #require(c["mac_answer"] as? [String: Any])
            let required = try #require(c["required"] as? [String: Any])
            let action: ClientAction
            if answer["transport"] as? Bool == true {
                action = ClientAction.transportFailed(attempt: 1)
            } else {
                let body: Data
                switch answer["body"] {
                case let text as String: body = Data(text.utf8)
                case let object?: body = try JSONSerialization.data(withJSONObject: object)
                case nil: body = Data()
                }
                action = ClientAction.classify(HTTPResponse(status: answer["status"] as? Int ?? 0, headers: answer["headers"] as? [String: String] ?? [:], body: body), attempt: 1)
            }
            let (kind, after): (String, Int64?) = {
                switch action {
                case .delivered: return ("delivered", nil)
                case .retrySameBytes(let ms): return ("retry_same_bytes_after_backoff", ms)
                case .finalForThisItem: return ("final_for_this_item_queue_continues", nil)
                case .finalStopQueue: return ("final_stop_queue", nil)
                case .phoneForgotten: return ("phone_forgotten_stop_queue_and_unpair", nil)
                }
            }()
            #expect(kind == required["client_action"] as? String, "\(name)")
            #expect(after == (required["retry_after_ms"] as? Int).map(Int64.init), "\(name): retry after")
        }
    }
}

@Suite struct ChallengeConformance {
    @Test func everyChallengeScriptSendsTheRecordedRequestsAndEndsAsRecorded() async throws {
        for c in try Corpus.cases(try Corpus.load("challenge"), "cases") {
            let name = c["name"] as? String ?? "?"
            let recorded = try #require(c["requests"] as? [[String: Any]])
            let mac = ScriptedMac(try #require(c["mac_answers"] as? [[String: Any]]))
            let api = APIClient(origin: "https://mm1.tail1a2b3c.ts.net:8443", deviceID: "dev_8d4c57b7ff82",
                                challenge: c["challenge_held_before"] as? String, signer: SoftwareSigner(key: Corpus.testKey), transport: mac)
            let first = recorded[0]
            let outcome = try #require(c["outcome"] as? [String: Any])
            if first["target"] as? String == "/api/challenge" {
                do {
                    let got = try await api.probeChallenge()
                    #expect(outcome["ok"] as? Bool == true && got == outcome["value"] as? String, "\(name)")
                } catch let error as APIError {
                    let want = try #require(outcome["error"] as? [String: Any])
                    #expect(error.reason.rawValue == want["reason"] as? String, "\(name)")
                }
            } else {
                let signed = try #require(first["signed"] as? [String: Any])
                let response = try await api.signed(first["method"] as! String, signed["path_with_query"] as! String, body: Corpus.body(first),
                                                    contentType: (first["headers"] as? [String: String])?["Content-Type"],
                                                    credential: signed["credential"] as? String == "query" ? .query : .header)
                if outcome["ok"] as? Bool == true {
                    #expect((200..<300).contains(response.status), "\(name): succeeds")
                    let value = try JSONSerialization.jsonObject(with: response.body)
                    #expect(StreamConformance.same(value, outcome["value"] as Any), "\(name): value")
                } else {
                    let want = try #require(outcome["error"] as? [String: Any])
                    let error = APIClient.classify(response)
                    #expect(error.reason.rawValue == want["reason"] as? String && error.status == want["status"] as? Int, "\(name): error")
                }
            }
            let sent = await mac.requests
            #expect(sent.count == recorded.count, "\(name): request count")
            for (ours, theirs) in zip(sent, recorded) {
                #expect(ours.method == theirs["method"] as? String && ours.body == Corpus.body(theirs), "\(name): same request")
                if let signed = theirs["signed"] as? [String: Any] {
                    let wire: [String: Any] = ["method": ours.method, "target": ours.target, "headers": ours.headers]
                    #expect(RequestSigning.parseAuthorization(Corpus.credential(wire) ?? "")?.challenge == signed["challenge"] as? String,
                            "\(name): signed with the recorded challenge")
                    #expect(MacVerifier.verify(wire.merging(["body": ours.body.map { ["base64": $0.base64EncodedString()] } as Any]) { $1 },
                                               publicKey: Corpus.testKey.publicKey).accepted, "\(name): verifies")
                }
            }
            #expect(await api.challenge == c["challenge_held_after"] as? String, "\(name): challenge held after")
        }
    }
}

@Suite struct VoiceUploadConformance {
    @Test func everyUploadTargetIsBuiltExactly() throws {
        for c in try Corpus.cases(try Corpus.load("voice"), "uploads") {
            let name = c["name"] as? String ?? "?"
            let input = try #require(c["input"] as? [String: Any])
            let target = Delivery.voiceTarget(clientID: input["clientId"] as! String, threadID: input["threadId"] as? String,
                                              seconds: input["seconds"] as? Double, sentAtISO: input["sentAt"] as! String)
            #expect(target == (c["request"] as? [String: Any])?["target"] as? String, "\(name)")
        }
    }
}

@Suite struct RetryConformance {
    /// Replays each case against the real reducer and courier: the outbox's passes, the bytes.
    @Test func everyRetryScriptPassesAsRecorded() async throws {
        let paired = try Fixture.named("conv-empty").state
        for c in try Corpus.cases(try Corpus.load("retry"), "cases") {
            let name = c["name"] as? String ?? "?"
            let mac = ScriptedMac(try #require(c["mac_answers"] as? [[String: Any]]))
            let firstChallenge = RequestSigning.parseAuthorization(Corpus.credential(try #require((c["requests"] as? [[String: Any]])?.first)) ?? "")?.challenge
            let api = APIClient(origin: "https://mm1.tail1a2b3c.ts.net:8443", deviceID: "dev_8d4c57b7ff82", challenge: firstChallenge,
                                signer: SoftwareSigner(key: Corpus.testKey), transport: mac)
            var recordings: [String: Data] = [:]
            var state = paired
            for item in try #require(c["items"] as? [[String: Any]]) {
                let id = item["clientId"] as! String
                let sentAt = item["sentAt"] as! String
                if item["kind"] as? String == "voice" {
                    recordings[id] = Data((item["bytes"] as! [Int]).map(UInt8.init))
                    state.outbox.append(OutboxItem(clientID: id, kind: .voice, body: nil, recordingID: id,
                                                   target: Delivery.voiceTarget(clientID: id, threadID: item["threadId"] as? String,
                                                                                seconds: item["seconds"] as? Double, sentAtISO: sentAt),
                                                   queuedAt: 0))
                } else {
                    let ms = Int64(try #require(ISO8601DateFormatter.withMillis.date(from: sentAt)).timeIntervalSince1970 * 1000)
                    state.outbox.append(OutboxItem(clientID: id, kind: .text,
                                                   body: ConversationReducer.textBody(clientID: id, threadID: item["threadId"] as? String, text: item["text"] as! String, sentAt: ms),
                                                   queuedAt: 0))
                }
                state.messages.append(Message(id: id, author: .me, text: item["text"] as? String ?? "", sentAt: 0, delivery: .waiting))
            }
            let courier = Courier(api: api, recordings: MemoryRecordings(files: recordings))
            for pass in try #require(c["passes"] as? [[String: Any]]) {
                let at = Int64(pass["at_ms"] as! Int)
                var sent = 0, duplicates = 0
                var (next, effects) = Reducer.reduce(state, .tick(at: at))
                state = next
                while let effect = effects.first(where: { if case .deliver = $0 { return true }; return false }), case .deliver(let id) = effect {
                    let item = try #require(state.outbox.first { $0.clientID == id })
                    let result = await courier.deliver(item, at: at)
                    if case .deliveryAccepted = result.action { sent += 1; if result.duplicate { duplicates += 1 } }
                    (next, effects) = Reducer.reduce(state, result.action)
                    state = next
                }
                let open = state.outbox.filter { $0.state != .blocked }
                #expect(sent == pass["sent"] as? Int, "\(name) @\(at): sent")
                #expect(duplicates == pass["duplicates"] as? Int, "\(name) @\(at): duplicates")
                #expect(open.count == pass["waiting"] as? Int, "\(name) @\(at): waiting")
                #expect(state.outbox.count - open.count == pass["blocked"] as? Int, "\(name) @\(at): blocked")
                #expect(open.first?.lastReason == pass["reason"] as? String, "\(name) @\(at): reason")
                #expect(open.first.map { $0.notBefore - at } == (pass["due_in_ms"] as? Int).map(Int64.init), "\(name) @\(at): due in")
            }
            let sentRequests = await mac.requests
            let recorded = try #require(c["requests"] as? [[String: Any]])
            #expect(sentRequests.count == recorded.count, "\(name): request count")
            for (ours, theirs) in zip(sentRequests, recorded) {
                #expect(ours.body == Corpus.body(theirs) && ours.target == theirs["target"] as? String, "\(name): the exact recorded bytes and target")
            }
        }
    }
}

extension ISO8601DateFormatter {
    static let withMillis: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}
