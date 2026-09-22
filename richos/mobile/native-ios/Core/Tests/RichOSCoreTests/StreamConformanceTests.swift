import Foundation
import Testing
@testable import RichOSCore

/// `conformance/vectors/events.json` and the `api_base_validation` block of `pairing.json`.
@Suite struct StreamConformance {
    /// Splits bytes as a chunking plan says: `{"every": n}` or `{"cut_at": [offsets]}`.
    static func chunks(_ bytes: Data, _ plan: [String: Any]) -> [Data] {
        let raw = [UInt8](bytes)
        if let every = plan["every"] as? Int {
            return stride(from: 0, to: raw.count, by: every).map { Data(raw[$0..<min($0 + every, raw.count)]) }
        }
        var out: [Data] = [], start = 0
        for cut in (plan["cut_at"] as? [Int] ?? []) where cut > start && cut < raw.count {
            out.append(Data(raw[start..<cut])); start = cut
        }
        out.append(Data(raw[start...]))
        return out
    }

    /// Compares JSON values semantically (key order and number spelling do not matter).
    static func same(_ a: Any, _ b: Any) -> Bool {
        let opts: JSONSerialization.WritingOptions = [.sortedKeys, .fragmentsAllowed]
        return (try? JSONSerialization.data(withJSONObject: a, options: opts)) == (try? JSONSerialization.data(withJSONObject: b, options: opts))
    }

    @Test func everyWireCaseParsesTheSameUnderEveryChunking() throws {
        for c in try Corpus.cases(try Corpus.load("events"), "wire_cases") {
            let name = c["name"] as? String ?? "?"
            let wire = Data((c["wire_utf8"] as? String ?? "").utf8)
            #expect(wire.count == c["wire_bytes"] as? Int, "\(name): the wire is the recorded bytes")
            let expected = try #require(c["expected_events"] as? [[String: Any]])
            for (plan, spec) in try #require(c["chunkings"] as? [String: [String: Any]]) {
                var parser = SSEParser()
                var events: [SSEParser.Event] = []
                for chunk in Self.chunks(wire, spec) { events += parser.feed(chunk).events }
                #expect(events.count == expected.count, "\(name) / \(plan): event count")
                for (got, want) in zip(events, expected) {
                    #expect(got.event == want["event"] as? String, "\(name) / \(plan): event name")
                    let data = try JSONSerialization.jsonObject(with: Data(got.data.utf8), options: .fragmentsAllowed)
                    #expect(Self.same(data, want["data"] as Any), "\(name) / \(plan): data")
                }
            }
        }
    }

    @Test func everyThreadCaseShowsExactlyTheSelectedConversation() throws {
        for c in try Corpus.cases(try Corpus.load("events"), "thread_cases") {
            let name = c["name"] as? String ?? "?"
            var model = ThreadModel(selectedThread: c["selected_thread"] as? String)
            for frame in try #require(c["frames"] as? [[String: Any]]) {
                guard let event = frame["event"] as? String, let data = frame["data"] else { continue }  // comments
                let json = String(decoding: try JSONSerialization.data(withJSONObject: data), as: UTF8.self)
                try model.apply(SSEParser.Event(event: event, data: json))
            }
            let view = model.view.map { ["id": $0.id, "cursor": $0.cursor, "role": $0.role, "text": $0.text, "complete": $0.complete] as [String: Any] }
            #expect(Self.same(view, c["expected_view"] as Any), "\(name)")
        }
    }

    @Test func helloCasesKeepThePairedOriginAndReadCapabilities() throws {
        let paired = "https://mm1.tail1a2b3c.ts.net:8443"
        for c in try Corpus.cases(try Corpus.load("events"), "hello_cases") {
            let name = c["name"] as? String ?? "?"
            let hello = try CoreJSON.decode(StreamHello.self, from: JSONSerialization.data(withJSONObject: c["hello"] as Any))
            let after = try #require(c["state_after"] as? [String: Any])
            var refusal: String?
            do { _ = try MacAdvertisement.validateAPIBase(hello.apiBase ?? paired, pairedOrigin: paired) } catch { refusal = "\(error)" }
            #expect(refusal == after["api_base_refusal"] as? String, "\(name): api_base refusal")
            #expect(hello.challenge == after["challenge"] as? String, "\(name): challenge")
            #expect((hello.capabilities ?? []) == (after["capabilities"] as? [String] ?? []), "\(name): capabilities")
            #expect(MacAdvertisement.offers("voice", in: hello.capabilities) == after["offers_voice"] as? Bool, "\(name): voice")
            #expect(MacAdvertisement.offers("audio", in: hello.capabilities) == after["offers_audio"] as? Bool, "\(name): audio")
        }
    }

    @Test func anOlderPageIsPrependedAndMarksTheBeginning() throws {
        let b = try #require(try Corpus.load("events")["backfill_case"] as? [String: Any])
        var model = ThreadModel(selectedThread: "thr_5c1e")
        for row in try #require(b["held"] as? [Any]) {
            model.merge(try CoreJSON.decode(StreamRow.self, from: JSONSerialization.data(withJSONObject: row)))
        }
        let page = try #require(b["page"] as? [String: Any])
        let older = try CoreJSON.decode([StreamRow].self, from: JSONSerialization.data(withJSONObject: page["messages"] as Any))
        model.prependOlder(older, more: page["more"] as? Bool ?? true)
        let view = model.view.map { ["id": $0.id, "cursor": $0.cursor, "role": $0.role, "text": $0.text, "complete": $0.complete] as [String: Any] }
        #expect(Self.same(view, b["expected_view"] as Any))
        #expect(model.reachedBeginning == b["at_the_beginning"] as? Bool)
    }

    @Test func aVoiceNoteRowCarriesItsLengthAndARowWithoutOneShowsNone() throws {
        // Echo's 4ce79d6e: duration_ms on the note's row in hello and backfill; kind stays "text".
        let note = try CoreJSON.decode(StreamRow.self, from: Data(#"{"id":"turn_12:user","thread_id":"thr_5c1e","cursor":9,"role":"ceo","kind":"text","text":"call Dana at noon","created_at":"2026-09-22T13:09:00.000Z","complete":true,"duration_ms":8250}"#.utf8))
        #expect(note.durationMs == 8250)
        #expect(note.message == Message(id: "turn_12:user", author: .me, kind: .voice, text: "call Dana at noon", sentAt: 1_790_082_540_000, durationMs: 8250, cursor: 9))
        let live = try CoreJSON.decode(StreamRow.self, from: Data(#"{"id":"turn_12:user","thread_id":"thr_5c1e","cursor":9,"role":"ceo","kind":"text","text":"call Dana at noon","complete":true}"#.utf8))
        #expect(live.durationMs == nil && live.message.kind == .text && live.message.durationMs == nil, "absent: no length, never 0:00")
        // Every corpus row decodes, and none claims a length it was not given.
        let hello = try #require((try Corpus.cases(try Corpus.load("events"), "hello_cases")).first?["hello"] as? [String: Any])
        let rows = try CoreJSON.decode([StreamRow].self, from: JSONSerialization.data(withJSONObject: hello["messages"] ?? []))
        #expect(rows.allSatisfy { $0.durationMs == nil })
    }

    @Test func framesCarryTheirLiveCursor() throws {
        var parser = SSEParser()
        let events = parser.feed(Data("id: 9\nevent: message\ndata: {}\n\n: keep-alive\nevent: delta\ndata: {}\n\n".utf8)).events
        #expect(events.map(\.id) == [9, nil], "an id belongs to its own frame only")
    }

    @Test func everyAdvertisedAPIBaseIsAcceptedOrRefusedAsRecorded() throws {
        let v = try #require(try Corpus.load("pairing")["api_base_validation"] as? [String: Any])
        let paired = try #require(v["paired_origin"] as? String)
        for c in try Corpus.cases(v, "cases") {
            let name = c["name"] as? String ?? "?"
            let value = c["value"] as? String ?? ""
            if c["accept"] as? Bool == true {
                #expect(try MacAdvertisement.validateAPIBase(value, pairedOrigin: paired) == c["api_base"] as? String, "\(name)")
            } else {
                #expect(throws: MacAdvertisement.Refusal(description: c["reason"] as? String ?? ""), "\(name)") {
                    try MacAdvertisement.validateAPIBase(value, pairedOrigin: paired)
                }
            }
        }
    }
}
