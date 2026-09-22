import SwiftUI

// Round 12's shared pieces (`round-12/shared/app.css`): buttons, cards, round buttons, the toggle, the
// spinner, and the floating shadow. Screens compose these; they do not restyle them.

extension View {
    /// `--sh-float`: every floating element (bubbles, cards, the capsule, the nameplate) wears it.
    func floatShadow(_ palette: Palette) -> some View {
        shadow(color: palette.floatShadow, radius: 12, x: 0, y: 10)
            .shadow(color: palette.floatShadowNear, radius: 3, x: 0, y: 2)
    }

    /// A surface with round 12's hairline and shadow.
    func floatingSurface(_ palette: Palette, radius: CGFloat, fill: Color? = nil, dashed: Bool = false) -> some View {
        background(
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(fill ?? palette.surface)
                .floatShadow(palette))
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(palette.lineFaint,
                                  style: StrokeStyle(lineWidth: 1, dash: dashed ? [5, 4] : [])))
    }
}

/// `.btn` and its variants. Heights are minimums: at large text sizes a label wraps and the button
/// grows rather than clipping (accessibility audit F10, F14).
struct RButtonStyle: ButtonStyle {
    enum Kind { case primary, ghost, quiet, danger }
    var kind: Kind = .primary
    /// `.tall`: 52 pt, 17 pt label (the one primary action of a takeover).
    var tall = false
    /// `.wide`: full width.
    var wide = false
    var compact = false
    @Environment(\.palette) private var palette
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let height: CGFloat = tall ? 52 : (compact ? 38 : 44)
        configuration.label
            .type(tall ? Typography.body.weight(600) : Typography.read.weight(600))
            .multilineTextAlignment(.center)
            .lineLimit(nil)
            .foregroundStyle(foreground)
            .padding(.horizontal, kind == .quiet ? 10 : (compact ? 14 : 18))
            .padding(.vertical, 6)
            .frame(minHeight: height)
            .frame(maxWidth: wide ? .infinity : nil)
            .background(background(height: height))
            .contentShape(Rectangle())
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }

    private var foreground: Color {
        switch kind {
        case .primary: return palette.onSignal
        case .ghost, .quiet: return palette.ink
        case .danger: return palette.danger
        }
    }

    @ViewBuilder private func background(height: CGFloat) -> some View {
        switch kind {
        case .primary:
            Capsule(style: .continuous).fill(palette.signal)
        case .ghost, .danger:
            Capsule(style: .continuous).strokeBorder(palette.line, lineWidth: 1)
        case .quiet:
            Color.clear
        }
    }
}

/// The quiet button's label: ink, underlined in gold (`.btn.quiet`). Underlining is in the label so the
/// underline follows wrapped lines.
struct QuietLabel: View {
    let text: String
    @Environment(\.palette) private var palette
    var body: some View {
        Text(text)
            .underline(true, color: palette.signal)
    }
}

/// A button label with a leading icon (`.btn .icon`, 18 pt).
struct IconLabel: View {
    let icon: Icon
    let text: String
    var body: some View {
        HStack(spacing: 8) {
            IconView(icon, size: 18)
            Text(text)
        }
    }
}

/// `.roundbtn`: a 52 pt circle on the surface, the settings and close buttons. The glyph is fixed at
/// 22 pt at every text size (audit F4).
struct RoundButton: View {
    let icon: Icon
    let label: String
    let identifier: String
    let action: () -> Void
    @Environment(\.palette) private var palette

    var body: some View {
        Button(action: action) {
            IconView(icon, size: 22)
                .foregroundStyle(palette.ink)
                .frame(width: 52, height: 52)
                .floatingSurface(palette, radius: 26)
        }
        .buttonStyle(PressScale(scale: 0.94))
        .accessibilityLabel(label)
        .accessibilityIdentifier(identifier)
    }
}

struct PressScale: ButtonStyle {
    var scale: CGFloat = 0.94
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

/// `.card`: the quiet cards above the composer (recovery, permission, offers, waiting to send).
struct CardView<Content: View>: View {
    @ViewBuilder var content: Content
    @Environment(\.palette) private var palette
    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .floatingSurface(palette, radius: 18)
    }
}

/// A card's title and description (`.card .t`, `.card .d`).
struct CardText: View {
    let title: String
    var detail: String?
    @Environment(\.palette) private var palette
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .type(Typography.body.weight(600))
                .foregroundStyle(palette.ink)
            if let detail {
                Text(detail)
                    .type(Typography.read)
                    .foregroundStyle(palette.inkSoft)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
    }
}

/// `.toggle`: 52 × 32. Off: a trim ring with the ink knob at 72% (7.36:1, NOTES GAP 1); on: gold with the
/// dark knob. Wraps a native `Toggle`, so VoiceOver reads it as a switch with its value (audit F13).
struct RToggleStyle: ToggleStyle {
    @Environment(\.palette) private var palette
    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            HStack(spacing: 12) {
                configuration.label
                Spacer(minLength: 0)
                ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                    Capsule(style: .continuous)
                        .fill(configuration.isOn ? palette.signal : Color.clear)
                        .overlay(Capsule(style: .continuous)
                            .strokeBorder(configuration.isOn ? palette.signal : palette.line, lineWidth: 2))
                    Circle()
                        .fill(configuration.isOn ? palette.onSignal : palette.ink.opacity(0.72))
                        .frame(width: 22, height: 22)
                        .padding(5)
                }
                .frame(width: 52, height: 32)
                .animation(Motion.outQuint(200), value: configuration.isOn)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// `.spin`: a 16 pt ring in the faint line with a gold arc, one turn a second.
struct Spinner: View {
    var size: CGFloat = 16
    @Environment(\.palette) private var palette
    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            ZStack {
                Circle().stroke(palette.lineFaint, lineWidth: 2)
                Circle().trim(from: 0, to: 0.25).stroke(palette.signal, style: StrokeStyle(lineWidth: 2, lineCap: .butt))
                    .rotationEffect(.degrees(t.truncatingRemainder(dividingBy: 1) * 360 - 90))
            }
            .frame(width: size, height: size)
        }
        .accessibilityHidden(true)
    }
}

/// The ground and its lamp, behind every screen.
struct GroundBackground: View {
    @Environment(\.palette) private var palette
    var body: some View {
        ZStack {
            palette.ground
            GeometryReader { proxy in
                RadialGradient(colors: [palette.lamp, palette.lamp.opacity(0)],
                               center: UnitPoint(x: 0.5, y: -0.1),
                               startRadius: 0,
                               endRadius: max(proxy.size.width, proxy.size.height) * 0.6)
            }
        }
        .ignoresSafeArea()
    }
}
