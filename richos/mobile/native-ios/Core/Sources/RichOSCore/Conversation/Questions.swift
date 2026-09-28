import Foundation

/// The app-owned question snapshot. Unknown wire fields remain additive.
public struct QuestionCard: Codable, Equatable, Sendable {
    public struct Option: Codable, Equatable, Sendable { public var id: String; public var label: String; public var description: String }
    public struct Answer: Codable, Equatable, Sendable {
        public var option_ids: [String]; public var text: String; public var method: String; public var surface: String
    }
    public var id: String
    public var thread_id: String
    public var text: String
    public var options: [Option]
    public var multiple: Bool
    public var free_answer: Bool
    public var recommended: String?
    public var state: String
    public var answer: Answer?
    public var revision: Int
    public var handoff_started: Bool?
    public var waiting_for_turn: Bool?
    public var remaining: Int?
    public var set_index: Int?
    public var set_count: Int?
    public var asker: String?
    public var delivered: Bool
    public var withdrawal_reason: String?
    public var answerText: String {
        guard let answer else { return "" }
        return (options.filter { answer.option_ids.contains($0.id) }.map(\.label) + [answer.text]).filter { !$0.isEmpty }.joined(separator: "; ")
    }
}

extension ConversationReducer {
    static func questionAnswer(_ s: inout AppState, id: String, options: [String], text: String, revision: Int?, clientID: String, at: Int64, _ effects: inout [Effect]) {
        guard s.pairing == .paired, s.mac?.questionAnswers == true, let q = s.messages.first(where: { $0.question?.id == id })?.question,
              s.outbox.count < outboxLimit else { return }
        let previous = s.outbox.first { $0.questionID == id && $0.state != .blocked }
        if let previous { guard previous.state == .waiting, previous.attempts == 0, revision == q.revision else { return } }
        guard !options.isEmpty || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              Set(options).count == options.count, q.multiple || options.count <= 1,
              options.allSatisfy({ id in q.options.contains { $0.id == id } }), q.free_answer || text.isEmpty else { return }
        var body: [String: Any] = ["kind": "answer", "client_id": clientID, "thread_id": q.thread_id, "question_id": id, "option_ids": options, "text": text]
        if let revision, q.state == "answered" { body["expected_revision"] = revision }
        guard let bytes = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]) else { return }
        var item = OutboxItem(clientID: clientID, kind: .text, body: String(decoding: bytes, as: UTF8.self), queuedAt: at)
        item.questionID = id
        item.questionAnswerText = (q.options.filter { options.contains($0.id) }.map(\.label) + [text]).filter { !$0.isEmpty }.joined(separator: "; ")
        if let previous { s.outbox.removeAll { $0.clientID == previous.clientID } }
        s.outbox.append(item)
        pump(&s, at: at, &effects)
    }
}

// Project the saved submission without claiming that the Mac has accepted it.
extension OutboxItem {
    public var localQuestionAnswer: QuestionCard.Answer? {
        guard questionID != nil, let body, let data = body.data(using: .utf8),
              let fields = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let options = fields["option_ids"] as? [String], let text = fields["text"] as? String else { return nil }
        return QuestionCard.Answer(option_ids: options, text: text, method: text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "phone_tap" : "phone_typed", surface: "phone")
    }
}
