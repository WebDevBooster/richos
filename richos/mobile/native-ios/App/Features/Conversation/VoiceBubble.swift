import SwiftUI

/// A voice message: the gold play button, the recording's own waveform, and its length
/// (`.bubble.voice`, `.vrow`, `.vmeta`).
struct VoiceBubbleBody: View {
    let row: ScreenModel.Row
    let durationMs: Int
    let levels: [Double]
    let calendar: Calendar
    let send: (Intent) -> Void
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                PlayButton(size: 44, icon: .play, label: "Play voice message",
                           edge: row.author == .me ? palette.playEdgeOnMine : nil) { send(.playVoice(id: row.id)) }
                Waveform(levels: levels.isEmpty ? Waveform.pretend(42, seed: row.id.stableSeed) : Waveform.resample(levels, 42),
                         played: 0, barMax: 26, height: 34)
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    duration
                    Spacer(minLength: 0)
                    Meta(row: row, calendar: calendar)
                }
                VStack(alignment: .leading, spacing: 2) {
                    duration
                    Meta(row: row, calendar: calendar)
                }
            }
            .padding(.leading, 54)
        }
    }

    private var duration: some View {
        Text(DayLabel.duration(durationMs))
            .type(Typography.read.weight(500))
            .monospacedDigit()
            .foregroundStyle(palette.ink)
    }
}

/// The 44 pt gold circle with a fixed-size glyph (`.play`); its glyph never scales with text (audit F2).
struct PlayButton: View {
    let size: CGFloat
    let icon: Icon
    let label: String
    /// A 1 pt edge for where gold alone is under 3:1 against what is behind it.
    var edge: Color? = nil
    let action: () -> Void
    @Environment(\.palette) private var palette

    var body: some View {
        Button(action: action) {
            IconView(icon, size: size * 20 / 44)
                .foregroundStyle(palette.onSignal)
                .frame(width: size, height: size)
                .background(Circle().fill(palette.signal).shadow(color: palette.orbShadow, radius: 10, y: 8))
                .overlay { if let edge { Circle().strokeBorder(edge, lineWidth: 1) } }
        }
        .buttonStyle(PressScale(scale: 0.94))
        .accessibilityLabel(label)
    }
}

/// Bars from a recording's levels (`.wave`): 2 pt gaps, bars between 2 and 4 pt wide, height
/// `4 + level × barMax`, ink at 32% (played bars at 100%); near-silence is a 3 pt dot at 22%.
///
/// The bars are the audio's shape, a picture of it; the length beside them and the VoiceOver label
/// carry the information, so their low contrast is decoration — declared in the I2 handoff.
struct Waveform: View {
    let levels: [Double]
    /// 0…1 of the message already played.
    var played: Double
    var barMax: CGFloat = 26
    var height: CGFloat = 34
    @Environment(\.palette) private var palette

    var body: some View {
        GeometryReader { proxy in
            let n = CGFloat(levels.count)
            let gap: CGFloat = 2
            let bar = min(4, max(2, (proxy.size.width - gap * (n - 1)) / n))
            let used = bar * n + gap * (n - 1)
            HStack(alignment: .center, spacing: gap) {
                ForEach(Array(levels.enumerated()), id: \.offset) { index, v in
                    let on = Double(index) / Double(levels.count) < played
                    RoundedRectangle(cornerRadius: 2)
                        .fill(palette.ink)
                        .frame(width: bar, height: v < 0.12 ? 3 : 4 + CGFloat(v) * barMax)
                        .opacity(v < 0.12 ? 0.22 : (on ? 1 : 0.32))
                }
            }
            .frame(width: used, height: proxy.size.height, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 120)
        .frame(height: height)
        .accessibilityHidden(true)
    }

    /// Round 12's deterministic waveform (`app.js` `waveFor`): a fixed-seed generator, identical on
    /// every run, for a message whose levels are not available.
    static func pretend(_ n: Int, seed: Int) -> [Double] {
        var out: [Double] = []
        var x = seed
        for i in 0..<n {
            x = (x &* 1_103_515_245 &+ 12345) & 0x7FFF_FFFF
            let r = Double(x >> 8) / 8_388_608
            let v = 0.15 + abs(sin(Double(i) * 0.9 + Double(seed))) * 0.6 * r + r * 0.25
            out.append(min(max(v, 0.05), 1))
        }
        return out
    }

    /// `app.js` `resample`: n evenly spaced samples, lifted 15%.
    static func resample(_ a: [Double], _ n: Int) -> [Double] {
        guard !a.isEmpty else { return pretend(n, seed: 9) }
        return (0..<n).map { i in min(max(a[i * a.count / n] * 1.15, 0.05), 1) }
    }
}

/// Rich's reply read aloud (`.rich-audio`): Hear it → Preparing the audio… → Stop with a live waveform.
struct RichAudio: View {
    let audio: ScreenModel.Row.Audio
    let id: String
    let send: (Intent) -> Void
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(spacing: 10) {
            Rectangle().fill(palette.lineFaint).frame(height: 1)
            HStack(spacing: 12) {
                switch audio {
                case .ready:
                    mini(icon: .play, text: "Hear it", filled: true) { send(.hearReply(id: id)) }
                        .accessibilityLabel("Hear Rich's reply")
                    Spacer(minLength: 0)
                case .preparing:
                    mini(icon: .ringc, text: "Hear it", filled: false) {}
                        .disabled(true)
                        .accessibilityHidden(true)
                    HStack(spacing: 6) {
                        Spinner()
                        Text("Preparing the audio…")
                    }
                    .type(Typography.read)
                    .foregroundStyle(palette.inkSoft)
                    .accessibilityElement(children: .combine)
                    Spacer(minLength: 0)
                case .playing(let progress):
                    mini(icon: .stop, text: "Stop", filled: true) { send(.stopReply) }
                        .accessibilityLabel("Stop reading the reply")
                    Waveform(levels: Waveform.pretend(28, seed: 5), played: progress, barMax: 20, height: 28)
                }
            }
        }
        .padding(.top, 6)
    }

    private func mini(icon: Icon, text: String, filled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                IconView(icon, size: 18)
                Text(text).type(Typography.read.weight(600))
            }
            .foregroundStyle(filled ? palette.onSignal : palette.ink)
            .padding(.leading, 10).padding(.trailing, 14)
            .frame(minHeight: 40)
            .background(
                Capsule(style: .continuous).fill(filled ? palette.signal : Color.clear)
                    .overlay(Capsule(style: .continuous).strokeBorder(filled ? Color.clear : palette.line, lineWidth: 1)))
        }
        .buttonStyle(PressScale(scale: 0.96))
    }
}

extension String {
    /// A small, stable number from an identifier (the same on every run, unlike `hashValue`).
    var stableSeed: Int {
        var h = 7
        for b in utf8 { h = (h &* 31 &+ Int(b)) & 0xFFFF }
        return h % 97 + 1
    }
}
