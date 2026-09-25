import SwiftUI

/// The full-screen moments (`.takeover`): pairing, the six words, consent, removed from the Mac, a
/// saved session that needs a newer app, and a required update. One calm screen, one primary action.
///
/// At large text sizes the screen scrolls and its actions stay reachable at the end of it; nothing is
/// clipped and no word runs past the edge (accessibility audit F10, F14, O2).
struct TakeoverView: View {
    let takeover: ScreenModel.Takeover
    let smallDevice: Bool
    let send: (Intent) -> Void
    @Environment(\.palette) private var palette
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        TakeoverScaffold(topPadding: isBlocking ? 40 : 28) {
            content
        } actions: {
            actions
        }
        .accessibilityIdentifier("takeover.\(identifier)")
    }

    private var isBlocking: Bool { if case .updateRequired = takeover { return true } else { return false } }

    private var identifier: String {
        switch takeover {
        case .pairIntro: return "pair-intro"
        case .pairProgress: return "pair-progress"
        case .pairWords: return "pair-words"
        case .pairAwaitingMac: return "pair-awaiting-mac"
        case .pairStale: return "pair-stale"
        case .consent: return "pair-consent"
        case .removedFromMac: return "conn-revoked"
        case .updateRequired: return "upd-blocking"
        }
    }

    @ViewBuilder private var content: some View {
        switch takeover {
        case .pairIntro(let problem):
            BigMark()
            Eyebrow("Your conversation, with you")
            Heading("Take Rich with you", small: smallDevice)
            Lede("Rich works on your Mac. Pair this iPhone once and your conversation comes along wherever you are.")
            // Every card: what happened, that nothing was paired, and the one action, "scan it again",
            // which is the button below it. The final words are Urban's review of the pairing words
            // (richos-hq docs/verification/2026-09-24-native-pair-v2/urban-review.md, states 4 to 9),
            // the same text the Android app and the PWA carry ("open it on this phone" there).
            switch problem {
            case .refused?:
                ErrorCard(title: "Your Mac did not accept this code",
                          detail: "Nothing was paired. Show a fresh code on your Mac and scan it again.")
                    .padding(.top, 18)
            case .invalidLink(let why)?:
                ErrorCard(title: "That is not a pairing code", detail: why)
                    .padding(.top, 18)
            case .macNeedsUpdate?:
                // Sage's pair-v2 hypotheses review §3: the older Mac shows its own "Your phone said the
                // six words did not match", because this phone's one signed "They do not match" is the
                // only way to make it forget the key. The middle sentence accounts for that and must
                // NOT reassure: a relay that strips `pair-v2` from a current Mac makes the same two
                // screens. Worded as the PWA (`web/web-app/app.js`), which says "open it on this phone".
                ErrorCard(title: "Your Mac needs an update",
                          detail: "This phone cannot pair with the version of RichOS on it. Your Mac may say the six words did not match: it stopped because this phone did. Update RichOS on your Mac, then show a fresh code there and scan it again.")
                    .padding(.top, 18)
            case .notAcceptedByMac?:
                ErrorCard(title: "Your Mac did not accept this phone",
                          detail: "Nothing was paired. Either someone said the words did not match on your Mac, or pairing was stopped there. Show a fresh code on your Mac and scan it again.")
                    .padding(.top, 18)
            case .macAnswerExpired?:
                ErrorCard(title: "Pairing timed out",
                          detail: "This phone did not hear back from your Mac in time, so it stopped. Show a fresh code on your Mac and scan it again.")
                    .padding(.top, 18)
            case .wordsRejected?:
                ErrorCard(title: "Stopped, and nothing was paired",
                          detail: "If the words on this phone and your Mac were different, this phone was not talking to your Mac. Tell Rich on your Mac before you pair again.")
                    .padding(.top, 18)
            case .macUnreachable?:
                // The Android app's card, which Urban's review passes as it is (state 11).
                ErrorCard(title: "Your Mac could not be reached",
                          detail: "Nothing was paired. Keep the Mac awake with RichOS running, then scan again.")
                    .padding(.top, 18)
            case nil:
                EmptyView()
            }
            VStack(alignment: .leading, spacing: 14) {
                Step(n: 1, text: Text("On your Mac, open ") + Text("Use Rich from your phone").run(Typography.body.weight(600), dynamicTypeSize)
                     + Text(" and choose ") + Text("RichOS Connect").run(Typography.body.weight(600), dynamicTypeSize) + Text("."))
                Step(n: 2, text: Text("Scan the code it shows you."))
            }
            .padding(.top, 22)
        case .pairProgress:
            BigMark()
            Eyebrow("Almost there")
            Heading("Pairing with your Mac", small: smallDevice)
            HStack(spacing: 12) {
                Spinner()
                Text("Setting up a private connection…").type(Typography.body)
            }
            .foregroundStyle(palette.ink)
            .padding(.top, 26)
            .accessibilityElement(children: .combine)
        case .pairWords(let words):
            Eyebrow("Check these words")
            Heading("Do they match your Mac?", small: smallDevice)
            // Never "the same six words": telling the answer before the check primes a skimmer to
            // press They match (Urban's review, state 2; the Mac's own "If they are the same six").
            Lede("Your Mac shows six words too. If they are the same six, this connection is private to you.")
            SixWords(words: words, small: smallDevice).padding(.top, 26)
        case .pairAwaitingMac(let words):
            // The waiting screen (the PWA's `showWaitingForMac`, the Android app's `WaitingForMac`):
            // which press is missing, the words still up to compare, and "They do not match" as the
            // way out. Nothing animates while it waits. The lede is Urban's (state 3): "carries on by
            // itself" is true however long the next probe takes, and the control's name is set in
            // SemiBold, as the intro's steps set theirs.
            Eyebrow("Almost there")
            Heading("Now press They match on your Mac", small: smallDevice)
            Lede(Text("This phone carries on by itself once you do. If the words on your Mac are different, press ")
                 + Text("They do not match").run(Typography.answer.weight(600), dynamicTypeSize)
                 + Text(", here or on your Mac."))
            SixWords(words: words, small: smallDevice).padding(.top, 26)
        case .pairStale:
            BigMark()
            Eyebrow("Newer app version needed")
            Heading("This saved session needs a newer app", small: smallDevice)
            Lede("Your data has been kept. Update this RichConnect app and everything picks up where it left off.")
        case .consent:
            Eyebrow("Before your first message")
            Heading("Where your words go", small: smallDevice)
            Lede("One thing to know before you talk to Rich from this iPhone.")
            ConsentRows().padding(.top, 26)
        case .removedFromMac:
            BigMark()
            Eyebrow("Pairing ended")
            Heading("This phone was removed from your Mac", small: smallDevice)
            Lede("Someone chose “Forget this phone” on the Mac. Nothing here was lost, but Rich cannot be reached from this iPhone until you pair it again.")
        case .updateRequired(_, let message):
            BigMark()
            Eyebrow("Update required")
            Text("This version of RichConnect can no longer send")
                .type(Typography.displayBlocking)
                .foregroundStyle(palette.ink)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 14)
                .accessibilityAddTraits(.isHeader)
            Lede(message)
            Soft("Your drafts, queued messages and recordings stay on this phone.")
        }
    }

    @ViewBuilder private var actions: some View {
        switch takeover {
        case .pairIntro:
            // One primary action, with or without a card: the cards say "scan it again", and this
            // is that button. Never "Pair again" here: on these screens nothing was paired (Urban's
            // review, question 1); "Pair again" stays on the removed-from-Mac screen, where it is true.
            Button { send(.scan) } label: { IconLabel(icon: .qr, text: "Scan your Mac’s code") }
                .buttonStyle(RButtonStyle(kind: .primary, tall: true, wide: true))
                .accessibilityIdentifier("pair.scan")
            Button { send(.usePairingLink) } label: { QuietLabel(text: "Use a pairing link instead") }
                .buttonStyle(RButtonStyle(kind: .quiet, wide: true))
                .accessibilityIdentifier("pair.link")
        case .pairProgress:
            EmptyView()
        case .pairWords:
            Button { send(.confirmWords) } label: { IconLabel(icon: .check, text: "They match") }
                .buttonStyle(RButtonStyle(kind: .primary, tall: true, wide: true))
                .accessibilityIdentifier("pair.match")
            Button { send(.rejectWords) } label: { QuietLabel(text: "They do not match") }
                .buttonStyle(RButtonStyle(kind: .quiet, wide: true))
                .accessibilityIdentifier("pair.noMatch")
        case .pairAwaitingMac:
            // "They match" was pressed here once; the one way out is the same "They do not match".
            Button { send(.rejectWords) } label: { QuietLabel(text: "They do not match") }
                .buttonStyle(RButtonStyle(kind: .quiet, wide: true))
                .accessibilityIdentifier("pair.noMatch")
        case .pairStale:
            Button { send(.openAppStore) } label: { IconLabel(icon: .down, text: "Update in App Store") }
                .buttonStyle(RButtonStyle(kind: .primary, tall: true, wide: true))
            Button { send(.openSupport) } label: { QuietLabel(text: "Support") }
                .buttonStyle(RButtonStyle(kind: .quiet, wide: true))
        case .consent:
            Button { send(.acceptConsent) } label: { Text("Continue") }
                .buttonStyle(RButtonStyle(kind: .primary, tall: true, wide: true))
                .accessibilityIdentifier("consent.continue")
            Button { send(.learnMore) } label: { QuietLabel(text: "Learn more") }
                .buttonStyle(RButtonStyle(kind: .quiet, wide: true))
        case .removedFromMac:
            Button { send(.pairAgain) } label: { IconLabel(icon: .qr, text: "Pair again") }
                .buttonStyle(RButtonStyle(kind: .primary, tall: true, wide: true))
                .accessibilityIdentifier("pair.again")
        case .updateRequired:
            Button { send(.openAppStore) } label: { IconLabel(icon: .down, text: "Update in App Store") }
                .buttonStyle(RButtonStyle(kind: .primary, tall: true, wide: true))
                .accessibilityIdentifier("update.store")
            Button { send(.openSupport) } label: { QuietLabel(text: "Support") }
                .buttonStyle(RButtonStyle(kind: .quiet, wide: true))
        }
    }
}

/// The takeover frame: the ground and its lamp, content from the top, actions at the bottom; it
/// scrolls when the text is too large to fit.
struct TakeoverScaffold<Content: View, Actions: View>: View {
    var topPadding: CGFloat = 28
    @ViewBuilder var content: Content
    @ViewBuilder var actions: Actions

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    content
                    Spacer(minLength: 24)
                    VStack(spacing: 10) { actions }
                }
                .padding(.top, topPadding)
                .padding(.horizontal, 26)
                .padding(.bottom, 20)
                .frame(minHeight: proxy.size.height, alignment: .top)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .background(GroundBackground())
    }
}

struct BigMark: View {
    var body: some View { MarkView().frame(width: 64, height: 64).padding(.bottom, 18) }
}

/// The all-caps micro-label (`.eyebrow`): 14 pt, declared skippable (round-12 NOTES "Type"); gold in
/// the dark, ink in the light. The heading below it says the same thing in full.
struct Eyebrow: View {
    let text: String
    init(_ text: String) { self.text = text }
    @Environment(\.palette) private var palette
    var body: some View {
        Text(text.uppercased())
            .type(Typography.eyebrow)
            .foregroundStyle(palette.accentGlyph)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityLabel(text)
    }
}

struct Heading: View {
    let text: String
    let small: Bool
    init(_ text: String, small: Bool) { self.text = text; self.small = small }
    @Environment(\.palette) private var palette
    var body: some View {
        Text(text)
            .type(small ? Typography.displaySmall : Typography.display)
            .foregroundStyle(palette.ink)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 14)
            .accessibilityAddTraits(.isHeader)
    }
}

struct Lede: View {
    let text: Text
    init(_ text: String) { self.text = Text(text) }
    /// A lede with a styled run inside it (a control's name in SemiBold).
    init(_ text: Text) { self.text = text }
    @Environment(\.palette) private var palette
    var body: some View {
        text
            .type(Typography.answer)
            .foregroundStyle(palette.ink)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 16)
    }
}

struct Soft: View {
    let text: String
    init(_ text: String) { self.text = text }
    @Environment(\.palette) private var palette
    var body: some View {
        Text(text)
            .type(Typography.read)
            .foregroundStyle(palette.inkSoft)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 10)
    }
}

struct Step: View {
    let n: Int
    let text: Text
    @Environment(\.palette) private var palette
    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Text("\(n)")
                .type(Typography.stepNumber)
                .foregroundStyle(palette.ink)
                .frame(width: 30, height: 30)
                .background(Circle().fill(palette.surface))
                .overlay(Circle().strokeBorder(palette.lineFaint, lineWidth: 1))
                .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                .accessibilityHidden(true)
            text
                .type(Typography.body)
                .foregroundStyle(palette.ink)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel(Text("Step \(n): ") + text)
        }
    }
}

struct ErrorCard: View {
    let title: String
    let detail: String
    @Environment(\.palette) private var palette
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            IconView(.alert, size: 22).foregroundStyle(palette.danger).padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).type(Typography.read.weight(600)).foregroundStyle(palette.ink)
                Text(detail).type(Typography.read).foregroundStyle(palette.inkSoft)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .floatingSurface(palette, radius: 16)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("pair.error")
    }
}

/// The trust moment: six large serif words in two columns, numbered.
struct SixWords: View {
    let words: [String]
    let small: Bool
    @Environment(\.palette) private var palette
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let columns = dynamicTypeSize.isAccessibilitySize ? 1 : 2
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 14), count: columns), spacing: 10) {
            ForEach(Array(words.enumerated()), id: \.offset) { index, word in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text("\(index + 1)")
                        .type(Typography.skippable.weight(600))
                        .foregroundStyle(palette.inkSoft)
                    Text(word)
                        .type(small ? Typography.wordSmall : Typography.word)
                        .foregroundStyle(palette.ink)
                        .minimumScaleFactor(0.8)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, small ? 14 : 16)
                .padding(.vertical, small ? 11 : 14)
                .floatingSurface(palette, radius: 14)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Word \(index + 1): \(word)")
            }
        }
        .accessibilityIdentifier("pair.words")
    }
}

/// Apple's explicit-consent screen in plain words (App Store guideline 5.1.2(i); round-12 `pair-consent`).
struct ConsentRows: View {
    @Environment(\.palette) private var palette
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            row(.mac, "What you type or say goes to your Mac.", "Your conversation lives there, not on our servers.")
            row(.spark, "Rich (powered by your AI provider) writes the reply there.", "So, all the AI work happens on your Mac.")
            row(.cloud, "Our connection service just moves the messages between your Mac and your phone.", "Encrypted on the way, stored nowhere.")
        }
    }

    private func row(_ icon: Icon, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            IconView(icon, size: 20)
                .foregroundStyle(palette.accentGlyph)
                .frame(width: 40, height: 40)
                .background(Circle().fill(palette.surface))
                .overlay(Circle().strokeBorder(palette.lineFaint, lineWidth: 1))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).type(Typography.body.weight(600)).foregroundStyle(palette.ink)
                Text(detail).type(Typography.read).foregroundStyle(palette.inkSoft)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}
