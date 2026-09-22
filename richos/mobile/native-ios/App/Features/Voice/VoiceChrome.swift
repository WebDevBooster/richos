import RichOSCore
import SwiftUI

/// Everything a recording draws around the circle: the halo, the lock pill, and inside the capsule the
/// red dot (or the bin), the timer, `‹ Slide to cancel` and `Cancel`. The only words during a recording
/// are the timer, the hint and Cancel (round-12 NOTES "The one idea").
///
/// Pure: a function of the core's `VoiceSession` and the instant it is drawn at (`VoiceClock`). Numbers
/// are round 12's motion table (`Motion.Voice`).
struct VoiceChrome: View {
    let session: VoiceSession
    let clock: VoiceClock
    let anchor: CGPoint
    let capsuleWidth: CGFloat
    let reduceMotion: Bool
    let onCancelTap: () -> Void

    @Environment(\.palette) private var palette

    private var phase: VoiceSession.Phase { session.phase }
    private var recordedSeconds: Double {
        Double(session.recordingStartedAtMs.map { clock.nowMs - $0 } ?? 0) / 1000
    }
    private var ending: VoiceEnding? { if case .ending(let e) = phase { return e } else { return nil } }
    private var isLocked: Bool { if case .locked = phase { return true } else { return false } }
    private var lockedLook: Bool { isLocked || (ending == .canceled && session.wasLocked) || (ending == .sent && session.wasLocked) }

    var body: some View {
        ZStack(alignment: .topLeading) {
            if phase != .pressed {
                halos
                lockPill
                recordingRow
            }
        }
        .frame(width: capsuleWidth, height: anchor.y + 26, alignment: .topLeading)
    }

    // MARK: Halo

    private var halos: some View {
        let look = OrbLook(session: session, clock: clock, reduceMotion: reduceMotion)
        let level = CGFloat(look.level)
        let w = reduceMotion ? 0 : clock.seconds
        let hs = look.scale + 0.45 + level * 0.6
        let hs2 = (look.scale + 0.2 + level * 0.35) * 1.25
        let fading: Double
        if let ending {
            let start: Double = ending == .canceled ? (session.wasLocked ? 550 : 30) : 0
            fading = max(0, 1 - (clock.endMs - start) / 200)
        } else {
            fading = 1
        }
        return ZStack {
            BlobShape(time: w * 0.9, seed: 2)
                .fill(palette.signalWash)
                .frame(width: 44, height: 44)
                .scaleEffect(hs2)
                .rotationEffect(.degrees(-w * 25))
                .opacity((0.35 + Double(level) * 0.35) * fading)
            BlobShape(time: w * 1.3, seed: 0)
                .fill(palette.signalHalo)
                .frame(width: 44, height: 44)
                .scaleEffect(hs)
                .rotationEffect(.degrees(w * 40))
                .opacity((0.55 + Double(level) * 0.4) * fading)
        }
        .offset(x: look.follow)
        .position(anchor)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    // MARK: Lock pill

    @ViewBuilder private var lockPill: some View {
        let V = Motion.Voice.self
        let settleK = lockedLook ? min(1, max(0, (clock.lockMs - 100) / 350)) : 0
        let settled = lockedLook && clock.lockMs > 100
        let emerge = min(1, recordedSeconds / 0.28)
        let rise = CGFloat(session.lockProgress) * V.lockDistance
        let y: CGFloat = lockedLook
            ? V.pillRest + (V.pillLocked - V.pillRest) * springCurve(settleK)
            : V.pillRest + rise
        let hidden: Double = {
            guard let ending else { return 1 }
            if ending == .canceled && session.wasLocked { return clock.endMs >= 700 ? 0 : 1 }
            return max(0, 1 - clock.endMs / 200)
        }()
        let glyph: CGFloat = settled ? 18 : 22
        ZStack {
            Capsule(style: .continuous).fill(palette.surface)
                .floatShadow(palette)
                .overlay(Capsule(style: .continuous).strokeBorder(palette.lineFaint, lineWidth: 1))
            ZStack {
                IconPart(d: Icon.lockShackle, size: glyph)
                    .offset(y: lockedLook ? 0 : -3 * glyph / 24)
                    .animation(Motion.outQuint(120), value: lockedLook)
                IconPart(d: Icon.lockBody, size: glyph)
                Circle().frame(width: 2.4 * glyph / 24, height: 2.4 * glyph / 24)
                    .offset(y: 4 * glyph / 24)
            }
            .foregroundStyle(palette.ink)
        }
        .frame(width: settled ? 38 - 4 * CGFloat(settleK) : 38, height: settled ? 54 - 20 * CGFloat(settleK) : 54)
        .scaleEffect(lockedLook ? 1 : 0.4 + 0.6 * springCurve(emerge))
        .opacity((lockedLook ? 1 : min(1, emerge / 0.7)) * hidden)
        .position(x: anchor.x, y: anchor.y - y)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    // MARK: Inside the capsule

    private var recordingRow: some View {
        let V = Motion.Voice.self
        let cp = session.cancelProgress
        let recordedMs = Int(max(0, recordedSeconds * 1000))
        let ritualStart: Double? = ending == .canceled ? (session.wasLocked ? 100 : 0) : nil
        let r = ritualStart.map { clock.endMs - $0 }  // ms into the bin ritual
        let timerOpacity: Double = {
            if let r { return r < 420 ? 1 : max(0, 1 - (r - 420) / 180) }
            if ending != nil { return 0 }
            return 1
        }()
        let lineY = anchor.y
        return ZStack(alignment: .topLeading) {
            // The red dot, or the bin once canceled.
            if let r, r >= 0 {
                BinGlyph(ms: r).position(x: 14 + 12, y: lineY)
            } else if ending == nil {
                Circle().fill(palette.danger)
                    .frame(width: 11, height: 11)
                    .opacity(reduceMotion ? 1 : pulse(period: V.dotPeriod))
                    .position(x: 20 + 5.5, y: lineY)
            }
            // The timer, at 15% of the capsule: M:SS.t, whole digits rolling.
            TimerText(ms: recordedMs)
                .opacity(timerOpacity)
                .fixedSize()
                .alignmentGuide(.leading) { _ in -capsuleWidth * 0.15 }
                .alignmentGuide(.top) { d in -(lineY - d.height / 2) }
            // ‹ Slide to cancel — follows the finger at 0.9× and fades out by 67% of the distance.
            if case .held = phase {
                HStack(spacing: 2) {
                    IconView(.chevL, size: 18)
                    Text("Slide to cancel")
                }
                .type(Typography.read.weight(500), cap: .xxxLarge)
                .lineLimit(1)
                .fixedSize()
                .foregroundStyle(palette.inkSoft)
                .offset(x: reduceMotion ? 0 : -V.nudge * CGFloat(nudge()))
                .offset(x: CGFloat(min(0, session.dx)) * 0.9)
                .opacity(min(1, max(0, 1 - cp * 1.5)))
                .position(x: capsuleWidth * 0.54, y: lineY)
                .accessibilityHidden(true)
            }
            // Cancel, at exactly the center, once locked (and while it fades after a tap).
            if isLocked || (ending == .canceled && session.wasLocked) {
                CancelButton(tappedMs: ending == .canceled ? clock.endMs : nil,
                             appearMs: clock.lockMs, action: onCancelTap)
                    .position(x: capsuleWidth * 0.5, y: lineY)
            }
        }
        .frame(width: capsuleWidth, height: anchor.y + 26, alignment: .topLeading)
        .accessibilityElement(children: .contain)
    }

    private func pulse(period: Double) -> Double {
        let t = recordedSeconds.truncatingRemainder(dividingBy: period) / period
        return t < 0.5 ? t * 2 : (1 - t) * 2  // linear 0 → 1 → 0
    }

    private func nudge() -> Double {
        let t = recordedSeconds.truncatingRemainder(dividingBy: Motion.Voice.nudgePeriod) / Motion.Voice.nudgePeriod
        return 0.5 - 0.5 * cos(t * 2 * .pi)
    }

    /// `cubic-bezier(.34, 1.56, .64, 1)` evaluated at `k` (the overshooting settle).
    private func springCurve(_ k: Double) -> CGFloat {
        CGFloat(CubicBezier(0.34, 1.56, 0.64, 1).value(at: k))
    }
}

/// `M:SS.t` with whole digits that roll vertically in 140 ms; tenths tick (round-12 NOTES "Timer").
struct TimerText: View {
    let ms: Int
    @Environment(\.palette) private var palette

    var body: some View {
        let tenths = (ms / 100) % 10
        let seconds = ms / 1000
        let whole = "\(seconds / 60):" + String(format: "%02d", seconds % 60)
        HStack(spacing: 0) {
            Text(whole)
                .contentTransition(.numericText(countsDown: false))
                .animation(Motion.inOut(Motion.Voice.rollMs), value: whole)
            Text(".\(tenths)")
        }
        .type(Typography.body.weight(500), cap: .xxxLarge)
        .monospacedDigit()
        .lineLimit(1)
        .foregroundStyle(palette.ink)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Recording, \(DayLabel.spokenDuration(ms))")
        .accessibilityIdentifier("voice.timer")
    }
}

/// Locked Cancel: ink, 17 pt, at the center; enters from 20% above over 200 ms; a gold ripple under
/// it when tapped (450 ms), then it fades.
struct CancelButton: View {
    let tappedMs: Double?
    let appearMs: Double
    let action: () -> Void
    @Environment(\.palette) private var palette

    var body: some View {
        let enter = min(1, appearMs / 200)
        let ripple = tappedMs.map { min(1, $0 / 450) }
        Button(action: action) {
            Text("Cancel")
                .type(Typography.body.weight(600), cap: .xxxLarge)
                .lineLimit(1)
                .fixedSize()
                .foregroundStyle(palette.ink)
                .padding(.horizontal, 16).padding(.vertical, 8)
                .frame(minHeight: 44)
                .background {
                    if let ripple {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(palette.signalWash)
                            .scaleEffect(0.7 + 0.45 * ripple)
                            .opacity(1 - ripple)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(tappedMs.map { $0 < 100 ? 1 : max(0, 1 - ($0 - 100) / 200) } ?? enter)
        .offset(y: -10 * (1 - enter))
        .accessibilityLabel("Cancel recording")
        .accessibilityIdentifier("voice.cancel")
    }
}

/// The bin of the cancel ritual: red dot → open bin → lid lifts (150 ms) and shuts (350 ms) → the bin
/// fills (420 ms) → it fades (700 ms). `ms` is time into the ritual.
struct BinGlyph: View {
    let ms: Double
    @Environment(\.palette) private var palette

    var body: some View {
        let open = ms >= 150 && ms < 350
        let filled = ms >= 420
        let fade = ms >= 700 ? max(0, 1 - (ms - 700) / 150) : 1
        ZStack {
            if filled {
                SVGShape(Icon.trashBody, box: 24).fill(palette.danger).frame(width: 24, height: 24)
            }
            IconPart(d: Icon.trashBody, size: 24, weight: 2.2)
            IconPart(d: Icon.trashBars, size: 24, weight: 2.2)
                .foregroundStyle(filled ? palette.surface : palette.danger)
            IconPart(d: Icon.trashLid, size: 24, weight: 2.2)
                .rotationEffect(.degrees(open ? -18 : 0), anchor: UnitPoint(x: 12 / 24, y: 6 / 24))
                .offset(x: open ? -1 : 0, y: open ? -4 : 0)
                .animation(Motion.outQuint(180), value: open)
        }
        .foregroundStyle(palette.danger)
        .opacity(fade)
        .accessibilityHidden(true)
    }
}

/// The halo's wobbling blob: a circle whose radius breathes by a few percent around its edge
/// (round 12 animates `border-radius` at 0.9 and 1.3 rad/s).
struct BlobShape: Shape {
    var time: Double
    var seed: Double

    func path(in rect: CGRect) -> Path {
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let base = min(rect.width, rect.height) / 2
        var p = Path()
        let n = 48
        for i in 0...n {
            let a = Double(i) / Double(n) * 2 * .pi
            let r = base * CGFloat(1 + 0.07 * sin(2 * a + time + seed) + 0.05 * cos(3 * a + time * 1.3 + 1 + seed))
            let pt = CGPoint(x: c.x + r * CGFloat(cos(a)), y: c.y + r * CGFloat(sin(a)))
            if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
        }
        p.closeSubpath()
        return p
    }
}

/// A CSS cubic-bezier timing function, evaluated by bisection on x.
struct CubicBezier {
    let x1, y1, x2, y2: Double
    init(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double) {
        self.x1 = x1; self.y1 = y1; self.x2 = x2; self.y2 = y2
    }
    func value(at x: Double) -> Double {
        let x = min(max(x, 0), 1)
        var lo = 0.0, hi = 1.0, t = x
        for _ in 0..<30 {
            t = (lo + hi) / 2
            let bx = 3 * (1 - t) * (1 - t) * t * x1 + 3 * (1 - t) * t * t * x2 + t * t * t
            if bx < x { lo = t } else { hi = t }
        }
        return 3 * (1 - t) * (1 - t) * t * y1 + 3 * (1 - t) * t * t * y2 + t * t * t
    }
}
