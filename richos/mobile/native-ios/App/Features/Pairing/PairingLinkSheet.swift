import SwiftUI

/// "Use a pairing link instead": paste the link the Mac shows, for when the camera cannot scan
/// (round-12 `.linkfield`). The text is only handed to the core, which parses it and never follows it.
struct PairingLinkSheet: View {
    let problem: String?
    let send: (Intent) -> Void
    @Environment(\.palette) private var palette
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("Use a pairing link")
                    .type(Typography.sheetTitle)
                    .foregroundStyle(palette.ink)
                    .padding(.top, 20)
                    .accessibilityAddTraits(.isHeader)
                Text("On your Mac, open Use Rich from your phone, copy the pairing link, and paste it here.")
                    .type(Typography.body)
                    .foregroundStyle(palette.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 10)
                TextField("", text: $text, prompt: Text("Paste the link").foregroundColor(palette.inkSoft), axis: .vertical)
                    .type(Typography.body)
                    .foregroundStyle(palette.ink)
                    .tint(palette.signal)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .focused($focused)
                    .padding(.horizontal, 18).padding(.vertical, 14)
                    .frame(minHeight: 52)
                    .background(RoundedRectangle(cornerRadius: 26, style: .continuous).fill(palette.surface))
                    .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).strokeBorder(palette.line, lineWidth: 1))
                    .padding(.top, 18)
                    .accessibilityLabel("Pairing link")
                    .accessibilityIdentifier("pairlink.field")
                if let problem {
                    HStack(alignment: .top, spacing: 8) {
                        IconView(.alert, size: 20).foregroundStyle(palette.danger)
                        Text(problem).type(Typography.read).foregroundStyle(palette.ink)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.top, 10)
                    .accessibilityElement(children: .combine)
                }
                Button { send(.submitPairingLink(text)) } label: { Text("Pair with this link") }
                    .buttonStyle(RButtonStyle(kind: .primary, tall: true, wide: true))
                    .padding(.top, 20)
                    .accessibilityIdentifier("pairlink.submit")
            }
            .padding(.horizontal, 20).padding(.bottom, 20)
        }
        .background(palette.ground.ignoresSafeArea())
        .onAppear { focused = true }
    }
}
