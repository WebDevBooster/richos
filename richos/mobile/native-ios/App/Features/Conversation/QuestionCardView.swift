import SwiftUI
import RichOSCore

/// Round 13 (HQ c50ed191): the question bubble and its inline keyboard are separate planes.
struct QuestionCardView: View {
    let question: QuestionCard
    let pending: String?
    let savedAnswer: String?
    let canEditLocal: Bool
    let send: (Intent) -> Void
    @State private var selected: Set<String> = []
    @State private var other = false
    @State private var text = ""
    @State private var editing = false
    @Environment(\.palette) private var palette
    private var goldText: Color { palette.appearance == .dark ? palette.signal : Color(hex: 0x715715) }
    private var boundary: Color { palette.appearance == .dark ? palette.ink.opacity(0.46) : palette.trim }
    private var canEdit: Bool { !question.delivered && question.handoff_started != true && (pending == nil || canEditLocal) }
    private var active: Bool { (pending == nil && question.state == "open") || editing && canEdit }
    private var savedStatus: String {
        if let pending { return pending }
        if question.delivered { return "Rich has your answer" }
        if (question.remaining ?? 0) > 0 { return "Waiting for the remaining answers" }
        return question.waiting_for_turn == true ? "It reaches Rich when his current reply ends" : "On its way to Rich"
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let asker = question.asker, asker != "Rich" {
                Text(asker + " · through Rich").type(Typography.read).foregroundStyle(palette.inkSoft).padding(.leading, 6)
            }
            VStack(alignment: .leading, spacing: 4) {
                if (question.set_count ?? 0) > 1 { Text("Question \(question.set_index ?? 1) of \(question.set_count ?? 1)").type(Typography.read).foregroundStyle(palette.inkSoft) }
                Text(question.text)
                    .type(Typography.Role(.serif, active ? 22 : 18, style: .body, lineHeight: 1.32))
                    .foregroundStyle(question.state == "withdrawn" ? palette.inkSoft : palette.ink)
                    .fixedSize(horizontal: false, vertical: true)
                if !active { result }
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 10).padding(.horizontal, 16)
            .background(RoundedRectangle(cornerRadius: 20).fill(palette.surface).floatShadow(palette))
            .overlay(alignment: .leading) { Capsule().fill(question.state == "withdrawn" ? palette.trim : palette.signal).frame(width: 3).padding(.vertical, 12) }
            if active { choices }
        }
        .foregroundStyle(palette.ink)
        .onChange(of: question.revision) { _, _ in editing = false }
    }
    private var choices: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(question.options, id: \.id) { option in optionButton(option) }
            HStack(spacing: 12) {
                if question.free_answer { Button("Other answer") { other = true }.type(Typography.read).underline(color: palette.signal).buttonStyle(.plain).padding(12) }
                if question.multiple {
                    Button("Send answer") { submit(Array(selected).sorted(), "") }
                        .type(Typography.read.weight(600)).padding(.horizontal, 18).frame(minHeight: 44)
                        .background(Capsule().fill(palette.signal)).foregroundStyle(palette.onSignal)
                        .buttonStyle(.plain).disabled(selected.isEmpty).opacity(selected.isEmpty ? 0.42 : 1)
                }
            }
            if other {
                HStack(alignment: .bottom, spacing: 8) {
                    TextField("Your answer", text: $text, axis: .vertical).accessibilityIdentifier("question-other-answer").type(Typography.body).padding(.vertical, 9)
                    Button("Send") { submit(question.multiple ? Array(selected).sorted() : [], text) }
                        .type(Typography.read.weight(600)).padding(10).foregroundStyle(palette.onSignal).background(Capsule().fill(palette.signal))
                        .buttonStyle(.plain).disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }.padding(.leading, 16).padding(5).background(RoundedRectangle(cornerRadius: 22).fill(palette.surface))
                    .overlay(RoundedRectangle(cornerRadius: 22).stroke(boundary, lineWidth: 1))
            }
        }
    }
    private func optionButton(_ option: QuestionCard.Option) -> some View {
        Button {
            if question.multiple { if selected.contains(option.id) { selected.remove(option.id) } else { selected.insert(option.id) } }
            else { submit([option.id], "") }
        } label: {
            HStack(alignment: .top, spacing: 12) {
                if question.multiple {
                    Text(selected.contains(option.id) ? "✓" : "").type(Typography.read.weight(600)).foregroundStyle(palette.onSignal)
                        .frame(width: 24, height: 24).background(RoundedRectangle(cornerRadius: 7).fill(selected.contains(option.id) ? palette.signal : Color.clear))
                        .overlay(RoundedRectangle(cornerRadius: 7).stroke(selected.contains(option.id) ? palette.signal : boundary, lineWidth: 1.5)).accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(option.label).type(Typography.body.weight(600))
                    Text(option.description).type(Typography.read).foregroundStyle(palette.inkSoft)
                    if question.recommended == option.id {
                        HStack(spacing: 7) { Circle().fill(palette.signal).frame(width: 7, height: 7); Text(question.asker == "Your team" ? "Your team recommends" : "Rich recommends").type(Typography.read.weight(500)) }.foregroundStyle(goldText).padding(.top, 4)
                    }
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 11).padding(.horizontal, 14)
                .background(RoundedRectangle(cornerRadius: 18).fill(selected.contains(option.id) ? palette.signalWash : palette.surface).floatShadow(palette))
                .overlay(RoundedRectangle(cornerRadius: 18).stroke(selected.contains(option.id) ? palette.signal : boundary, lineWidth: 1))
        }.buttonStyle(.plain).accessibilityIdentifier("question-option-" + option.id).accessibilityAddTraits(selected.contains(option.id) ? .isSelected : [])
    }
    @ViewBuilder private var result: some View {
        if question.state == "answered" || savedAnswer != nil {
            HStack(alignment: .firstTextBaseline, spacing: 8) { Text("✓").foregroundStyle(goldText); Text("You answered: " + (savedAnswer ?? question.answerText)) }.type(Typography.body).padding(.top, 8)
            if let answer = question.answer { Text(provenance(answer)).type(Typography.read).foregroundStyle(palette.inkSoft) }
            Text(savedStatus).type(Typography.read).foregroundStyle(question.delivered ? goldText : palette.inkSoft).padding(.top, 6)
            if canEdit {
                Button("Change answer") { editing = true; selected = Set(question.answer?.option_ids ?? []); text = question.answer?.text ?? "" }
                    .type(Typography.read.weight(500)).underline(color: palette.signal).buttonStyle(.plain).frame(minHeight: 44)
            }
        } else if question.state == "withdrawn" {
            Text("Rich no longer needs this: " + (question.withdrawal_reason ?? "The work has ended")).type(Typography.read).foregroundStyle(palette.inkSoft).padding(.top, 8)
        }
    }
    private func provenance(_ answer: QuestionCard.Answer) -> String {
        let methods = ["click":"click", "keyboard":"keyboard", "typed":"typing", "spoken":"voice", "phone_tap":"tap", "phone_typed":"typing", "phone_voice":"voice note"]
        return "By \(methods[answer.method] ?? "your words"), on \(answer.surface == "mac" ? "your Mac" : "your phone")"
    }
    private func submit(_ ids: [String], _ words: String) {
        send(.answerQuestion(id: question.id, options: ids, text: words, revision: editing ? question.revision : nil))
        editing = false
    }
}
