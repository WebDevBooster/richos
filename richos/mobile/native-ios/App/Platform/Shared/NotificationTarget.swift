import CryptoKit
import Foundation

// Compiled into the app, the notification service extension, and the macOS platform tests.

/// Where a reply notification points: the Mac that sent it and the reply, as the SHA-256 hashes the
/// Mac puts in `richos` (phone protocol contract §7.3). Hashes, not ids, so Apple and the relay never
/// see a conversation's identifiers.
///
/// Parsing is strict on purpose (PRD §10: "Allow only the intended schemes, hosts and payload
/// shapes"): exactly three keys, each the exact hex shape the Mac produces. Anything else is not a
/// RichOS notification and opens nothing.
struct NotificationTarget: Equatable, Sendable {
    /// 32 lowercase hex: the Mac's push host id, returned by the registration (`host_id`).
    var host: String
    /// 64 lowercase hex: SHA-256 of the conversation id.
    var thread: String
    /// 64 lowercase hex: SHA-256 of the reply's message id.
    var event: String

    init?(userInfo: [AnyHashable: Any]) {
        guard let refs = userInfo["richos"] as? [String: Any], refs.count == 3,
              let host = refs["host"] as? String, Self.isHex(host, count: 32),
              let thread = refs["thread"] as? String, Self.isHex(thread, count: 64),
              let event = refs["event"] as? String, Self.isHex(event, count: 64) else { return nil }
        self.host = host
        self.thread = thread
        self.event = event
    }

    /// `hex(SHA-256(utf8 id))`, the Mac's reference for a thread or a message id.
    static func reference(_ id: String) -> String {
        SHA256.hash(data: Data(id.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Whether this notification came from the Mac this phone is registered with (`host_id` from the
    /// registration answer) and is about this conversation.
    func belongs(toHost hostID: String?, thread threadID: String?) -> Bool {
        guard let hostID, let threadID else { return false }
        return host == hostID && thread == Self.reference(threadID)
    }

    /// The loaded message this notification is about, if it is loaded. When it is not, the core
    /// fetches older history until it appears (contract §7.3 step 3).
    func messageID(in ids: [String]) -> String? {
        ids.last { Self.reference($0) == event }
    }

    private static func isHex(_ text: String, count: Int) -> Bool {
        text.utf8.count == count && text.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}

/// One-shot hand-off from the notification delegate to the store, which may not have loaded yet when
/// a tap cold-launches the app.
///
/// COPY THE DESIGN of T3 Code's `PlatformRouteMailbox` (adoption ledger §2.8 N2; T3 Code at
/// 2eb6a53343ffb4ce747617746ee85433115ad18f, `apps/swift-ios/App/Platform/PlatformDeepLinks.swift`,
/// MIT License, Copyright (c) 2026 T3 Tools Inc.): put once, take once. What is NOT taken, and why
/// for RichOS: T3 keeps the route in `UserDefaults` because widgets and app intents deliver routes
/// from other processes. RichOS has neither; a notification tap is delivered to this process during
/// its own launch, so memory is enough, and the app stays off Apple's required-reason list.
final class NotificationRouteMailbox: @unchecked Sendable {
    static let shared = NotificationRouteMailbox()

    private let lock = NSLock()
    private var pending: NotificationTarget?

    func put(_ target: NotificationTarget) {
        lock.lock(); defer { lock.unlock() }
        pending = target
    }

    func take() -> NotificationTarget? {
        lock.lock(); defer { lock.unlock() }
        defer { pending = nil }
        return pending
    }
}
