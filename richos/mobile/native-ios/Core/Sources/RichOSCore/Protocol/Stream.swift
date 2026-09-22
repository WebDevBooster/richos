import Foundation

/// `GET /api/events`: Server-Sent Events with three event names, `hello`, `message`, `delta`
/// (contract §5.4). Checked against `conformance/vectors/events.json`, including every chunking —
/// one byte at a time, inside a field name, between the two newlines of a frame end, inside a
/// multibyte character — and CRLF line endings.
public struct SSEParser: Sendable {
    public struct Event: Equatable, Sendable {
        public var event: String
        public var data: String
    }

    private var buffer = Data()
    private var eventName = ""
    private var dataLines: [String] = []

    public init() {}

    /// Feeds raw bytes; returns every event completed by them. Comments (`:` lines — keep-alives and
    /// the re-snapshot notice) are returned separately so the connection owner can act on them.
    public mutating func feed(_ bytes: Data) -> (events: [Event], comments: [String]) {
        buffer.append(bytes)
        var events: [Event] = []
        var comments: [String] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            var lineBytes = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            if lineBytes.last == 0x0D { lineBytes = lineBytes.dropLast() }
            // A line is complete here, so a multibyte character split across chunks is whole again.
            let line = String(decoding: lineBytes, as: UTF8.self)
            if line.isEmpty {
                if !dataLines.isEmpty {
                    events.append(Event(event: eventName.isEmpty ? "message" : eventName, data: dataLines.joined(separator: "\n")))
                }
                eventName = ""
                dataLines = []
            } else if line.hasPrefix(":") {
                comments.append(String(line.dropFirst()).trimmingCharacters(in: .whitespaces))
            } else {
                let field: Substring, value: Substring
                if let colon = line.firstIndex(of: ":") {
                    field = line[..<colon]
                    var v = line[line.index(after: colon)...]
                    if v.first == " " { v = v.dropFirst() }
                    value = v
                } else {
                    field = Substring(line)
                    value = ""
                }
                switch field {
                case "event": eventName = String(value)
                case "data": dataLines.append(String(value))
                default: break  // `id` and anything else: the reference parser ignores them
                }
            }
        }
        return (events, comments)
    }
}

/// One conversation row as the Mac sends it (`phone/rows.rs`).
public struct StreamRow: Codable, Equatable, Sendable {
    public var id: String
    public var threadID: String?
    public var cursor: Int
    /// `ceo` (the person) or `rich`.
    public var role: String
    public var kind: String?
    public var text: String
    public var createdAt: String?
    public var clientID: String?
    public var complete: Bool

    enum CodingKeys: String, CodingKey {
        case id, cursor, role, kind, text, complete
        case threadID = "thread_id", createdAt = "created_at", clientID = "client_id"
    }

    public init(id: String, threadID: String?, cursor: Int, role: String, kind: String? = "text", text: String,
                createdAt: String? = nil, clientID: String? = nil, complete: Bool) {
        self.id = id; self.threadID = threadID; self.cursor = cursor; self.role = role; self.kind = kind; self.text = text
        self.createdAt = createdAt; self.clientID = clientID; self.complete = complete
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        threadID = try c.decodeIfPresent(String.self, forKey: .threadID)
        cursor = try c.decode(Int.self, forKey: .cursor)
        role = try c.decode(String.self, forKey: .role)
        kind = try c.decodeIfPresent(String.self, forKey: .kind)
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        createdAt = try c.decodeIfPresent(String.self, forKey: .createdAt)
        clientID = try c.decodeIfPresent(String.self, forKey: .clientID)
        complete = try c.decodeIfPresent(Bool.self, forKey: .complete) ?? true
    }
}

public struct StreamDelta: Codable, Equatable, Sendable {
    public var messageID: String
    public var threadID: String?
    public var cursor: Int?
    public var text: String
    enum CodingKeys: String, CodingKey { case cursor, text; case messageID = "message_id", threadID = "thread_id" }
}

/// `hello`: the challenge, the Mac's conversations, what it offers, and the selected thread's rows.
public struct StreamHello: Decodable, Equatable, Sendable {
    public var challenge: String?
    public var apiBase: String?
    public var threadID: String?
    public var latestCursor: Int?
    public var capabilities: [String]?
    public var protocolVersion: Int?
    public var build: String?
    public var messages: [StreamRow]?
    enum CodingKeys: String, CodingKey {
        case challenge, capabilities, build, messages
        case apiBase = "api_base", threadID = "thread_id", latestCursor = "latest_cursor", protocolVersion = "protocol_version"
    }
}

/// The selected conversation as the stream builds it (the reference `web/web-app/lib/thread.js`,
/// with the contract's thread filter: the stream is global, so rows and deltas for any other
/// conversation are dropped, and a delta for a row not held is dropped — the final row carries the
/// full text). Replaying the same frames after a reconnect changes nothing.
public struct ThreadModel: Equatable, Sendable {
    public var selectedThread: String?
    public private(set) var rows: [String: StreamRow] = [:]
    public private(set) var reachedBeginning = false

    public init(selectedThread: String?) { self.selectedThread = selectedThread }

    private func belongs(_ threadID: String?) -> Bool {
        guard let selectedThread, let threadID else { return true }
        return selectedThread == threadID
    }

    private static func isStandIn(_ row: StreamRow) -> Bool { row.role == "ceo" && row.id.hasPrefix("intake_") }

    public mutating func merge(_ row: StreamRow) {
        guard belongs(row.threadID) else { return }
        rows[row.id] = row
        if row.role == "ceo", !Self.isStandIn(row) {
            // The Mac's own stand-in retires when the projected row with the same text arrives.
            for (id, held) in rows where Self.isStandIn(held) && held.text == row.text { rows[id] = nil }
        }
    }

    public mutating func apply(_ delta: StreamDelta) {
        guard belongs(delta.threadID), var row = rows[delta.messageID] else { return }
        row.text += delta.text
        row.complete = false
        rows[delta.messageID] = row
    }

    public mutating func apply(hello: StreamHello) {
        for row in hello.messages ?? [] { merge(row) }
    }

    /// An older page (`before=`); `more: false` marks the beginning of the conversation.
    public mutating func prependOlder(_ page: [StreamRow], more: Bool) {
        for row in page { merge(row) }
        if !more { reachedBeginning = true }
    }

    /// Rows in cursor order.
    public var view: [StreamRow] { rows.values.sorted { $0.cursor != $1.cursor ? $0.cursor < $1.cursor : $0.id < $1.id } }

    /// Applies one decoded SSE event; unknown event names are ignored (additive protocol).
    public mutating func apply(_ event: SSEParser.Event) throws {
        let data = Data(event.data.utf8)
        switch event.event {
        case "hello": apply(hello: try CoreJSON.decode(StreamHello.self, from: data))
        case "message": merge(try CoreJSON.decode(StreamRow.self, from: data))
        case "delta": apply(try CoreJSON.decode(StreamDelta.self, from: data))
        default: break
        }
    }
}

/// What a `hello` or pairing answer tells the phone about the Mac (contract §5.4, Echo's `194fcb75`).
public enum MacAdvertisement {
    public struct Refusal: Error, Equatable, CustomStringConvertible, Sendable {
        public var description: String
    }

    /// An advertised `api_base` is accepted only when it IS the paired origin (a trailing slash
    /// allowed); anything else is refused and the paired origin kept. Reasons are the reference's
    /// (`conformance/vectors/pairing.json` `api_base_validation`).
    public static func validateAPIBase(_ value: String, pairedOrigin: String) throws -> String {
        func refuse(_ why: String) -> Refusal { Refusal(description: why) }
        guard !value.isEmpty else { throw refuse("not an address") }
        guard !value.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) }) else {
            throw refuse("whitespace in the address")
        }
        guard let url = URLComponents(string: value), let scheme = url.scheme, url.host != nil else {
            throw refuse("not an absolute URL")
        }
        guard scheme.lowercased() == "https" else { throw refuse("not an https address") }
        guard url.user == nil, url.password == nil else { throw refuse("credentials in the address") }
        guard url.percentEncodedPath.isEmpty || url.percentEncodedPath == "/" else { throw refuse("a path in the address") }
        guard url.percentEncodedQuery == nil else { throw refuse("a query string in the address") }
        guard url.percentEncodedFragment == nil else { throw refuse("a fragment in the address") }
        var origin = "https://\(url.host!.lowercased())"
        if let port = url.port, port != 443 { origin += ":\(port)" }
        guard origin == pairedOrigin else { throw refuse("a different origin from the app") }
        return origin
    }

    public static func offers(_ capability: String, in capabilities: [String]?) -> Bool {
        capabilities?.contains(capability) ?? false
    }
}
