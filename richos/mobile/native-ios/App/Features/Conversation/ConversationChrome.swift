import SwiftUI

/// The nameplate and the settings button floating over the conversation (`.header`, `.nameplate`).
/// Healthy operation is never announced: the nameplate's second line exists only for a persistent
/// interruption (PRD §5 CEO experience gate; round-12 `conn-*`).
struct ConversationHeader: View {
    let connection: ScreenModel.ConnectionLine?
    let send: (Intent) -> Void
    @Environment(\.palette) private var palette
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        // At the accessibility sizes the status sentence leaves the nameplate for its own full-width
        // line, so it never breaks inside words in a narrow column (accessibility audit F3).
        let lineBelow = dynamicTypeSize.isAccessibilitySize
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                nameplate(showLine: !lineBelow)
                Spacer(minLength: 0)
                RoundButton(icon: .settings, label: "Settings", identifier: "header.settings") { send(.openSettings) }
            }
            if lineBelow, let connection {
                ConnectionText(line: connection)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .floatingSurface(palette, radius: 18)
            }
        }
        .dynamicTypeSize(...DynamicTypeSize.accessibility3)
        .padding(.horizontal, 14)
        .padding(.top, 8)
    }

    private func nameplate(showLine: Bool) -> some View {
        HStack(spacing: 12) {
            MarkView()
                .frame(width: 24, height: 24)
                .frame(width: 40, height: 40)
                .background(Circle().fill(palette.ground))
            VStack(alignment: .leading, spacing: 2) {
                Text("Rich")
                    .type(Typography.body.weight(600).lineHeight(1.2))
                    .foregroundStyle(palette.ink)
                    .accessibilityAddTraits(.isHeader)
                if showLine, let connection {
                    ConnectionText(line: connection)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.leading, 8).padding(.trailing, 18).padding(.vertical, 6)
        .frame(minHeight: 52)
        .floatingSurface(palette, radius: 28)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("header.nameplate")
        .animation(Motion.outQuint(280), value: connection)
    }
}

/// The one-line status sentence, with its reassurance in ink (`.nameplate .line`, `.line b`).
struct ConnectionText: View {
    let line: ScreenModel.ConnectionLine
    @Environment(\.palette) private var palette
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let (lead, reassurance) = Self.words(line.kind)
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            if line.kind == .reconnecting { PulseDot() }
            (Text(lead + " ").foregroundColor(palette.inkSoft)
             + Text(reassurance).run(Typography.read.weight(500).lineHeight(1.3), dynamicTypeSize).foregroundColor(palette.ink))
                .type(Typography.read.lineHeight(1.3))
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("connection.line")
    }

    /// Round 12's sentences (`screens.js` group 7, `rec-unsupported`, `upd-feature-off`).
    static func words(_ kind: ScreenModel.ConnectionLine.Kind) -> (String, String) {
        switch kind {
        case .reconnecting: return ("Reconnecting…", "Your messages are saved.")
        case .phoneOffline: return ("No internet connection.", "Messages stay on this phone.")
        case .serviceUnavailable: return ("RichOS Connect is temporarily unavailable.", "Messages stay on this phone.")
        case .macUnreachable: return ("Your Mac cannot be reached. Keep it awake with RichOS running.", "Messages stay on this phone.")
        case .incompatible: return ("This Mac needs a newer RichOS app.", "Your queued messages are kept.")
        case .voiceUnsupported: return ("This Mac cannot accept voice yet.", "Your recording stays on this phone.")
        case .voicePaused: return ("Voice messages are paused while we fix a problem.", "Typing works.")
        case .attachmentsUnsupported: return ("This Mac needs a newer RichOS for photos and files.", "Text and voice work.")
        }
    }
}

/// The 8 pt gold dot that breathes beside "Reconnecting…" (1.4 s) for its first 10 seconds, then rests
/// at full opacity until the state changes (`PulseSchedule`). Resting, it is a plain circle: the
/// `TimelineView` leaves the hierarchy, so nothing asks for another frame however long the Mac sleeps.
struct PulseDot: View {
    @Environment(\.palette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// When this dot appeared; a new "Reconnecting…" is a new dot with its own start.
    @State private var appeared = Date()
    @State private var resting = false

    var body: some View {
        Group {
            if resting || !PulseSchedule.animates(elapsed: 0, reduceMotion: reduceMotion) {
                dot(PulseSchedule.restingOpacity)
            } else {
                TimelineView(.animation) { context in
                    dot(PulseSchedule.opacity(elapsed: context.date.timeIntervalSince(appeared)))
                }
            }
        }
        // One sleep, not a clock: after it the dot is still, and a dot that left the screen is cancelled.
        .task {
            try? await Task.sleep(nanoseconds: UInt64(PulseSchedule.restsAt * 1_000_000_000))
            if !Task.isCancelled { resting = true }
        }
        .accessibilityHidden(true)
    }

    private func dot(_ opacity: Double) -> some View {
        Circle().fill(palette.signal)
            .frame(width: 8, height: 8)
            .opacity(opacity)
    }
}

/// "Latest": floats above the composer while the reader is up in older messages (`.latest`).
struct LatestPill: View {
    let action: () -> Void
    @Environment(\.palette) private var palette
    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                IconView(.arrowD, size: 18)
                Text("Latest").type(Typography.read.weight(600))
            }
            .foregroundStyle(palette.ink)
            .padding(.leading, 14).padding(.trailing, 16)
            .frame(minHeight: 40)
            .floatingSurface(palette, radius: 20)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressScale(scale: 0.96))
        .accessibilityLabel("Latest messages")
        .accessibilityIdentifier("conversation.latest")
    }
}

/// The first minute: the mark, one line, the composer ready (`conv-empty`).
struct EmptyConversation: View {
    @Environment(\.palette) private var palette
    var body: some View {
        VStack(spacing: 0) {
            MarkView().frame(width: 56, height: 56).padding(.bottom, 8)
            Text("Say something to Rich")
                .type(Typography.emptyTitle)
                .foregroundStyle(palette.ink)
                .padding(.bottom, 6)
            Text("Your conversation will appear here.")
                .type(Typography.read)
                .foregroundStyle(palette.inkSoft)
            // The CEO's paragraph, below a hairline, in full ink, at a 300 pt measure (Urban's G7).
            Text("Press and hold the gold microphone to record a voice message. Release to send. Or slide left to cancel. Or slide up to lock. Because then you don't need to hold and can scroll.")
                .type(Typography.read.lineHeight(RoundSpec.howToLineHeight))
                .foregroundStyle(RoundSpec.howToInk(palette))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: RoundSpec.howToMeasure)
                .padding(.top, RoundSpec.howToTextGap)
                .overlay(alignment: .top) {
                    Rectangle().fill(RoundSpec.howToRule(palette)).frame(height: 1)
                        .accessibilityHidden(true)
                }
                .padding(.top, RoundSpec.howToRuleGap)
        }
        .multilineTextAlignment(.center)
        .padding(.horizontal, 24)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("conversation.empty")
    }
}

/// Cards and the one-line toast above the composer (`.above`): recovery, permission, offers, waiting.
struct AboveComposer: View {
    let cards: [ScreenModel.Card]
    let toast: ScreenModel.Toast?
    let send: (Intent) -> Void
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(spacing: 8) {
            ForEach(cards) { card in
                cardView(card)
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .offset(y: 12)).combined(with: .scale(scale: 0.98)),
                        removal: .opacity.combined(with: .offset(y: 8))))
            }
            if let toast {
                ToastView(text: toast.text)
                    .transition(.opacity.combined(with: .offset(y: 12)))
                    .task(id: toast) {
                        // One calm line, then it goes (too short: 1.8 s; the ceiling warning: 4 s).
                        // A limit that still holds (too long) stays until the draft changes.
                        if case .tooLong = toast { return }
                        try? await Task.sleep(for: .milliseconds(toast == .tooShort ? Motion.tooShortLineMs : 4_000))
                        send(.dismissToast)
                    }
            }
        }
        .padding(.horizontal, 2)
        .animation(Motion.card, value: cards)
        .animation(Motion.toast, value: toast)
    }

    @ViewBuilder private func cardView(_ card: ScreenModel.Card) -> some View {
        switch card {
        case .waitingToSend(let count):
            CardView {
                CardText(title: "Waiting to send",
                         detail: "Your Mac isn’t reachable from here. \(count == 1 ? "One message" : "\(count) messages") will go as soon as it is.")
                HStack(spacing: 8) {
                    Button { send(.retryNow) } label: { IconLabel(icon: .refresh, text: "Try now") }
                        .buttonStyle(RButtonStyle(kind: .ghost))
                        .accessibilityIdentifier("card.tryNow")
                }
                .padding(.top, 10)
            }
        case .notificationOffer:
            CardView {
                CardText(title: "Hear back when the app is closed",
                         detail: "Notifications are off, so Rich cannot reach you until you open the app.")
                FlowButtons {
                    Button { send(.turnOnNotifications) } label: { IconLabel(icon: .bell, text: "Turn on notifications") }
                        .buttonStyle(RButtonStyle(kind: .primary))
                        .accessibilityIdentifier("card.notificationsOn")
                    Button { send(.notificationsNotNow) } label: { QuietLabel(text: "Not now") }
                        .buttonStyle(RButtonStyle(kind: .quiet))
                        .accessibilityIdentifier("card.notNow")
                }
                .padding(.top, 10)
            }
        case .microphoneDenied:
            CardView {
                CardText(title: "The microphone is off for RichConnect",
                         detail: "Turn it on in iPhone Settings to send voice messages, or type instead.")
                    .accessibilityIdentifier("card.micDenied")
                FlowButtons {
                    Button { send(.openSystemSettings) } label: { Text("Open Settings") }
                        .buttonStyle(RButtonStyle(kind: .primary))
                        .accessibilityIdentifier("card.openSettings")
                    Button { send(.dismissCard(id: card.id)) } label: { QuietLabel(text: "Not now") }
                        .buttonStyle(RButtonStyle(kind: .quiet))
                        .accessibilityIdentifier("card.micNotNow")
                }
                .padding(.top, 10)
            }
            // The card is the press's answer (D03): VoiceOver hears it, as TalkBack does on Android.
            .onAppear {
                AccessibilityNotification.Announcement("The microphone is off for RichConnect").post()
            }
        case .keptRecording(let recording):
            KeptRecordingCard(recording: recording, send: send)
        case .attachRefused, .attachCameraDenied, .attachPhotosDenied, .attachMacUnsupported:
            AttachCards.card(card, send: send)
        }
    }
}

/// An unsent recording, kept: play it, send it, or let it go — never a library (`rec-card`).
struct KeptRecordingCard: View {
    let recording: ScreenModel.KeptRecording
    let send: (Intent) -> Void
    @Environment(\.palette) private var palette

    var body: some View {
        CardView {
            switch recording.reason {
            case .unsent:
                CardText(title: "Your unsent voice message")
            case .interrupted:
                CardText(title: "Your unsent voice message",
                         detail: "Recording was interrupted. Your voice message is kept here.")
            case .ceiling:
                CardText(title: "Your 30-minute voice message is saved below",
                         detail: "Send it, then start another.")
            }
            HStack(spacing: 10) {
                PlayButton(size: 40, icon: .play, label: "Play the unsent voice message") { send(.playVoice(id: recording.id)) }
                Waveform(levels: recording.levels.isEmpty ? Waveform.pretend(30, seed: 11) : recording.levels,
                         played: 0, barMax: 20, height: 28)
                Text(DayLabel.duration(recording.durationMs))
                    .type(Typography.read.weight(500))
                    .monospacedDigit()
                    .foregroundStyle(palette.ink)
                    .accessibilityLabel(DayLabel.spokenDuration(recording.durationMs))
            }
            .padding(.top, 10)
            FlowButtons {
                Button { send(.sendKept(id: recording.id)) } label: { IconLabel(icon: .send, text: "Send") }
                    .buttonStyle(RButtonStyle(kind: .primary))
                    .accessibilityLabel("Send the voice message")
                    .accessibilityIdentifier("kept.send")
                Button { send(.discardKept(id: recording.id)) } label: { QuietLabel(text: "Discard") }
                    .buttonStyle(RButtonStyle(kind: .quiet))
                    .accessibilityLabel("Discard the voice message")
                    .accessibilityIdentifier("kept.discard")
            }
            .padding(.top, 10)
        }
    }
}

/// Buttons in a row that wrap to a column when the text is large (`.acts { flex-wrap: wrap }`).
struct FlowButtons<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { content; Spacer(minLength: 0) }
            VStack(alignment: .leading, spacing: 8) { content }
        }
    }
}

/// `.toast`: one calm line on the surface.
struct ToastView: View {
    let text: String
    @Environment(\.palette) private var palette
    var body: some View {
        Text(text)
            .type(Typography.read.weight(500))
            .foregroundStyle(palette.ink)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 16).padding(.vertical, 9)
            .floatingSurface(palette, radius: 16)
            .accessibilityIdentifier("composer.toast")
            .accessibilityAddTraits(.updatesFrequently)
    }
}
