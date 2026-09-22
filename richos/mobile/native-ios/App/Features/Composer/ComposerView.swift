import RichOSCore
import SwiftUI
import UIKit

/// The floating capsule with the gold microphone inside its right end (round-12 `comp-*`, `voice-*`),
/// and the + in its left end (round-12 attachments).
///
/// Text: the field grows with the draft; the moment there is a draft (or something in the tray) the
/// microphone morphs into the send arrow. Voice: the view reports the finger (press, move, release,
/// the locked Send and Cancel) and draws the core's `VoiceSession`; every outcome and threshold is the
/// core's (`VoiceGeometry`, build plan §3.2). Nothing here decides whether a recording is sent.
struct ComposerView: View {
    let composer: ScreenModel.Composer
    let voice: VoiceSession?
    let pending: [ScreenModel.PendingItem]
    let attachMenuOpen: Bool
    let send: (Intent) -> Void

    @Environment(\.palette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @FocusState private var fieldFocused: Bool

    /// Presentation only: when this view saw the gesture end or lock, so the end ritual and the badge's
    /// settle can play. Outcomes are never decided here.
    @State private var endedAt: Date?
    @State private var lockedAt: Date?
    @State private var touching = false
    @State private var startedLocked = false
    @GestureState private var gestureActive = false
    @State private var fieldHeight: CGFloat = 24

    private var hasPending: Bool { !pending.isEmpty }
    private var typing: Bool { (composer.hasDraft || hasPending) && voice == nil }

    var body: some View {
        let lineHeight = max(52, fieldHeight + 28)
        let trayHeight: CGFloat = hasPending ? 80 : 0
        GeometryReader { proxy in
            let width = proxy.size.width
            let anchor = CGPoint(x: width - 26, y: trayHeight + lineHeight / 2)
            TimelineView(.animation(paused: !isAnimating)) { context in
                let clock = VoiceClock(session: voice, wall: context.date, endedAt: endedAt, lockedAt: lockedAt)
                ZStack(alignment: .topLeading) {
                    capsule(width: width, lineHeight: lineHeight, trayHeight: trayHeight)
                    if let voice {
                        VoiceChrome(session: voice, clock: clock, anchor: anchor, capsuleWidth: width,
                                    reduceMotion: reduceMotion) { send(.voiceLockedCancel(atMs: VoiceClock.nowMs())) }
                    }
                    orb(anchor: anchor, clock: clock, width: width)
                }
            }
        }
        .frame(height: lineHeight + trayHeight)
        .animation(Motion.outQuint(280), value: trayHeight)
        .onAppear { observe(voice?.phase, from: nil, appearing: true) }
        .onChange(of: voice?.phase) { old, new in observe(new, from: old, appearing: false) }
        .onChange(of: composer.focused) { _, focused in if fieldFocused != focused { fieldFocused = focused } }
        .onChange(of: fieldFocused) { _, focused in
            if focused != composer.focused { send(.setComposerFocus(focused)) }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active, voice != nil { send(.voiceInterrupted(atMs: VoiceClock.nowMs())) }
        }
        .task(id: isLiveGesture) {
            // The frame clock the core's gesture runs on (press delay, ceiling). The view reports time;
            // the core decides what it means.
            while isLiveGesture, !Task.isCancelled {
                send(.voiceTick(atMs: VoiceClock.nowMs()))
                try? await Task.sleep(for: .milliseconds(16))
            }
        }
    }

    private var isLiveGesture: Bool {
        guard let voice else { return false }
        return !VoiceClock.isPose(voice) && !isEnding
    }

    private var isEnding: Bool { if case .ending? = voice?.phase { return true } else { return false } }

    private var isAnimating: Bool {
        guard let voice, !reduceMotion else { return false }
        return !VoiceClock.isPose(voice)
    }

    /// Notes when the gesture locks or ends, to play the settle and the end ritual; tells the core when
    /// the ritual is over.
    private func observe(_ new: VoiceSession.Phase?, from old: VoiceSession.Phase?, appearing: Bool) {
        guard let voice, let new else {
            endedAt = nil; lockedAt = nil
            return
        }
        if VoiceClock.isPose(voice) { return }  // a posed fixture draws at its own instant
        if case .locked = new, old != .locked, !appearing {
            lockedAt = Date()
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }
        if case .ending(let ending) = new {
            if case .ending? = old { return }
            let started = Date()
            endedAt = started
            let ms = VoiceClock.endDurationMs(ending, wasLocked: voice.wasLocked)
            DispatchQueue.main.asyncAfter(deadline: .now() + ms / 1000) {
                guard endedAt == started else { return }
                send(.voiceSettled)
            }
        }
    }

    // MARK: The capsule

    private func capsule(width: CGFloat, lineHeight: CGFloat, trayHeight: CGFloat) -> some View {
        let recording = voice != nil && voice?.phase != .pressed
        return ZStack(alignment: .topLeading) {
            if hasPending {
                AttachTray(items: pending, send: send)
                    .frame(width: width, height: trayHeight)
            }
            if !recording {
                field
                    .padding(.leading, 54)
                    .padding(.trailing, 62)
                    .frame(width: width, height: lineHeight, alignment: .leading)
                    .offset(y: trayHeight)
                    .transition(.opacity)
            }
            attachButton(recording: recording)
                .frame(width: width, height: trayHeight + lineHeight, alignment: .bottomLeading)
        }
        .frame(width: width, height: trayHeight + lineHeight, alignment: .topLeading)
        .floatingSurface(palette, radius: 26, dashed: composer.disabledReason != nil)
        .animation(Motion.outQuint(200), value: lineHeight)
    }

    /// The + in the capsule's left end: 44 pt target, 24 pt glyph, 4 pt from the left and bottom
    /// edges; while recording it turns and shrinks away and the red dot takes its slot
    /// (round-12 `attachments-NOTES.md` "The one idea" and "Motion"); it turns into × while its menu is open.
    private func attachButton(recording: Bool) -> some View {
        let disabled = composer.disabledReason != nil
        return Button { send(attachMenuOpen ? .closeAttachMenu : .openAttachMenu) } label: {
            IconView(.plus, size: 24, weight: 2.2)
                .rotationEffect(.degrees(attachMenuOpen ? 45 : 0))
                .foregroundStyle(attachMenuOpen ? palette.ink : palette.inkSoft)
                .frame(width: 44, height: 44)
                .background(Circle().fill(attachMenuOpen ? palette.signalWash : Color.clear))
                .contentShape(Circle())
        }
        .buttonStyle(PressScale(scale: 0.9))
        .opacity(recording ? 0 : (disabled ? 0.45 : 1))
        .scaleEffect(recording ? 0.6 : 1)
        .rotationEffect(.degrees(recording ? -45 : 0))
        .animation(Motion.outQuint(200), value: recording)
        .animation(Motion.outQuint(200), value: attachMenuOpen)
        .disabled(disabled || recording)
        .padding(.leading, 4).padding(.bottom, 4)
        .accessibilityLabel(attachMenuOpen ? "Close the attach menu" : "Attach a photo or file")
        .accessibilityIdentifier("composer.attach")
        .accessibilityHidden(recording)
    }

    @ViewBuilder private var field: some View {
        if let reason = composer.disabledReason {
            Text(reason)
                .type(Typography.body)
                .foregroundStyle(palette.inkSoft)
                .lineLimit(2)
                .accessibilityLabel("Message field. \(reason)")
                .accessibilityIdentifier("composer.disabled")
        } else {
            TextField("", text: Binding(get: { composer.draft }, set: { send(.compose($0)) }),
                      prompt: Text(hasPending ? "Add a message" : "Message Rich").foregroundColor(palette.inkSoft),
                      axis: .vertical)
                .type(Typography.body)
                .foregroundStyle(palette.ink)
                .tint(palette.signal)
                .lineLimit(1...6)
                .focused($fieldFocused)
                .background(GeometryReader { p in
                    Color.clear.preference(key: FieldHeightKey.self, value: p.size.height)
                })
                .onPreferenceChange(FieldHeightKey.self) { fieldHeight = $0 }
                .accessibilityLabel(hasPending ? "Add a message" : "Message")
                .accessibilityIdentifier("composer.field")
                .padding(.vertical, 12)
        }
    }

    // MARK: The orb

    @ViewBuilder private func orb(anchor: CGPoint, clock: VoiceClock, width: CGFloat) -> some View {
        let disabled = composer.disabledReason != nil || (!composer.voiceAvailable && !typing)
        let look = OrbLook(session: voice, clock: clock, reduceMotion: reduceMotion)
        ZStack {
            if disabled {
                // Disabled keeps a 3:1 edge (accessibility audit F6): an ink-soft ring and glyph, not a
                // faded gold circle (round 12's 45% gold falls below the non-text floor in light).
                Circle().strokeBorder(palette.inkSoft, lineWidth: 1.5)
                IconView(.mic, size: 22, weight: 2.2).foregroundStyle(palette.inkSoft)
            } else {
                Circle().fill(palette.signal)
                    .shadow(color: palette.orbShadow, radius: 12, y: 8)
                ZStack {
                    IconView(.mic, size: 22, weight: 2.2)
                        .opacity(look.showsSend || typing ? 0 : 1)
                        .scaleEffect(look.showsSend || typing ? 0.6 : 1)
                        .rotationEffect(.degrees(typing ? -20 : 0))
                    IconView(.send, size: 22, weight: 2.2)
                        .opacity(look.showsSend || typing ? 1 : 0)
                        .scaleEffect(look.showsSend || typing ? 1 : 0.6)
                }
                .foregroundStyle(palette.onSignal)
                .animation(Motion.glyphMorph, value: typing)
                if look.tick > 0 {
                    Circle().stroke(palette.signal, lineWidth: 2)
                        .padding(-6)
                        .scaleEffect(0.9 + 0.6 * (1 - look.tick))
                        .opacity(0.9 * look.tick)
                }
            }
        }
        .frame(width: 44, height: 44)
        .scaleEffect(look.scale)
        .offset(x: look.follow)
        .contentShape(Circle().inset(by: -6))
        .position(anchor)
        .gesture(orbGesture(width: width), including: disabled ? .none : .all)
        .onChange(of: gestureActive) { _, active in
            // The system ended the touch without a release (a call, Control Center, a system gesture):
            // report it as canceled, never as a release (PRD §5).
            guard !active, touching else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                guard touching else { return }
                touching = false
                send(.voiceTouchCanceled(atMs: VoiceClock.nowMs()))
            }
        }
        .accessibilityElement()
        .accessibilityLabel(accessibilityLabel(disabled: disabled))
        .accessibilityHint(typing || disabled ? "" : "Double-tap and hold to record. Or use the actions to record hands-free.")
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier(typing ? "composer.send" : (isLocked ? "voice.send" : "composer.mic"))
        .accessibilityActions {
            if !typing && !disabled {
                if isLocked {
                    Button("Send voice message") { send(.voiceLockedSend(atMs: VoiceClock.nowMs())) }
                    Button("Cancel recording") { send(.voiceLockedCancel(atMs: VoiceClock.nowMs())) }
                } else if voice == nil {
                    // VoiceOver cannot slide: record hands-free, as if locked (ledger X1: named actions).
                    Button("Record hands-free") { send(.voiceRecordHandsFree(width: Double(width), atMs: VoiceClock.nowMs())) }
                }
            }
        }
        .accessibilityAction {
            if typing { send(.sendText) } else if isLocked { send(.voiceLockedSend(atMs: VoiceClock.nowMs())) }
        }
    }

    private var isLocked: Bool { if case .locked? = voice?.phase { return true } else { return false } }

    private func accessibilityLabel(disabled: Bool) -> String {
        if typing { return "Send" }
        if disabled { return "Voice messages are unavailable" }
        if isLocked { return "Send voice message" }
        if voice != nil { return "Recording" }
        return "Record a voice message"
    }

    /// One finger, reported as it moves. A tap on the send arrow sends the draft; on the locked circle,
    /// the recording.
    ///
    /// A touch that STARTED on the locked circle is the locked Send; the finger that slid up to lock
    /// lifting off is a release, which the core ignores while locked (the recording goes on).
    private func orbGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .updating($gestureActive) { _, active, _ in active = true }
            .onChanged { value in
                let now = VoiceClock.nowMs()
                if !touching {
                    touching = true
                    startedLocked = isLocked
                    if typing || startedLocked { return }
                    send(.voicePress(width: Double(width), atMs: now))
                    return
                }
                if typing || startedLocked || isLocked { return }
                send(.voiceMove(dx: value.translation.width, dy: value.translation.height, atMs: now))
            }
            .onEnded { _ in
                defer { touching = false }
                let now = VoiceClock.nowMs()
                if typing { send(.sendText); return }
                if startedLocked { send(.voiceLockedSend(atMs: now)); return }
                send(.voiceRelease(atMs: now))
            }
    }
}

private struct FieldHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 24
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

/// The instant a voice session is drawn at. A live session is drawn at the wall clock; a session that
/// arrived already posed (a fixture: its `nowMs` is far from now) is drawn at its own `nowMs`, so every
/// run of `voice-holding` is the same picture.
struct VoiceClock {
    /// Milliseconds since 1970 at which to draw.
    let nowMs: Int64
    /// Seconds, for the halo's wobble.
    let seconds: Double
    /// Milliseconds into the end ritual, and since the lock.
    let endMs: Double
    let lockMs: Double

    init(session: VoiceSession?, wall: Date, endedAt: Date?, lockedAt: Date?) {
        guard let session else {
            nowMs = 0; seconds = 0; endMs = 0; lockMs = 10_000
            return
        }
        if Self.isPose(session) {
            nowMs = session.nowMs
            seconds = Double(session.nowMs % 100_000) / 1000
            switch session.phase {
            case .ending(let e): endMs = Self.posedEndMs(e, wasLocked: session.wasLocked)
            default: endMs = 0
            }
            // A posed lock under a second old is mid-transition (round-12 `voice-lock-transition`).
            lockMs = session.elapsedMs < 1000 ? Double(max(0, session.elapsedMs - 500)) : 10_000
        } else {
            let wallMs = Int64((wall.timeIntervalSince1970 * 1000).rounded())
            nowMs = max(session.nowMs, wallMs)
            seconds = wall.timeIntervalSinceReferenceDate
            endMs = endedAt.map { wall.timeIntervalSince($0) * 1000 } ?? 0
            lockMs = lockedAt.map { wall.timeIntervalSince($0) * 1000 } ?? 10_000
        }
    }

    static func isPose(_ s: VoiceSession) -> Bool { abs(nowMs() - s.nowMs) > 2_000 }

    static func nowMs() -> Int64 { Int64((Date().timeIntervalSince1970 * 1000).rounded()) }

    /// How long each end animation plays (round-12 NOTES "Motion").
    static func endDurationMs(_ e: VoiceEnding, wasLocked: Bool) -> Double {
        switch e {
        case .canceled: return wasLocked ? Motion.Voice.lockedCancelMs : Motion.Voice.binMs
        case .sent, .ceiling: return 200
        case .tooShort: return 150
        }
    }

    /// The frame a posed ending is drawn at: the bin with its lid up, the locked cancel's swell, the
    /// send's collapse just begun.
    static func posedEndMs(_ e: VoiceEnding, wasLocked: Bool) -> Double {
        switch e {
        case .canceled: return wasLocked ? 600 : 250
        case .sent: return 60
        case .tooShort, .ceiling: return 1_000
        }
    }
}

/// How the orb looks at an instant: size, finger-follow, glyph, the lock tick, the breathing level.
struct OrbLook {
    var scale: CGFloat = 1
    var follow: CGFloat = 0
    var showsSend = false
    var tick: Double = 0
    var level: Double = 0

    init(session: VoiceSession?, clock: VoiceClock, reduceMotion: Bool) {
        guard let s = session else { return }
        let V = Motion.Voice.self
        level = reduceMotion ? 0.3 : (s.levels.last ?? 0.35)
        let recorded = Double(s.recordingStartedAtMs.map { clock.nowMs - $0 } ?? 0) / 1000
        switch s.phase {
        case .pressed:
            scale = V.pressScale
        case .held:
            // The swell: 75 ms to 2.2×, then a 200 ms settle 2.2 → 2.0 → 2.2 (NOTES "The swell").
            var spring: CGFloat = 1
            if recorded < (V.swellMs + V.settleMs) / 1000 {
                if recorded < V.swellMs / 1000 {
                    spring = (1 + (V.heldScale - 1) * CGFloat(recorded / (V.swellMs / 1000))) / V.heldScale
                } else {
                    let k = (recorded - V.swellMs / 1000) / (V.settleMs / 1000)
                    spring = 1 - 0.09 * CGFloat(sin(k * .pi) * (1 - k))
                }
            }
            let cp = CGFloat(s.cancelProgress)
            scale = (V.heldScale + CGFloat(level) * V.breath) * spring * (1 - cp * V.shrinkAtCancel)
            let dead = V.deadZone * CGFloat(s.width)
            follow = cp > 0 ? min(0, CGFloat(s.dx) + dead) : 0
        case .locked:
            scale = V.heldScale + CGFloat(level) * V.breath
            showsSend = true
            tick = max(0, 1 - clock.lockMs / 350)
        case .ending(let ending):
            let e = clock.endMs
            switch ending {
            case .sent, .ceiling, .tooShort:
                scale = max(1, V.heldScale - (V.heldScale - 1) * CGFloat(min(1, e / V.collapseMs)))
                showsSend = ending == .sent && e < V.collapseMs
            case .canceled where s.wasLocked:
                // Locked cancel: +550 ms swell to 3.0× over 150 ms; +700 ms collapse to 1× in 30 ms.
                showsSend = e < 700
                if e < 550 { scale = V.heldScale + CGFloat(level) * V.breath }
                else if e < 700 { scale = V.heldScale + (3.0 - V.heldScale) * CGFloat(min(1, (e - 550) / 150)) }
                else { scale = max(1, 3.0 - 2.0 * CGFloat(min(1, (e - 700) / 30))) }
            case .canceled:
                // The circle slides home and shrinks over 200 ms, from 30 ms after the cancel.
                let k = CGFloat(min(1, max(0, (e - 30) / 200)))
                scale = V.heldScale * (1 - V.shrinkAtCancel) * (1 - k) + k
            }
        }
    }
}
