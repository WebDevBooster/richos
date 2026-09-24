import RichOSCore
import SwiftUI

/// The app's one root view: it renders `AppState` and sends `Action`s, and nothing else.
///
/// COMPOSITION SEAM (stream I1 applies it in `App/App/RichOSNativeApp.swift`):
/// `RootView(state: store.state, send: store.send)`. It takes no store type, so the screens never
/// depend on how the core is wired. Every round-12 screen is reached by putting the core in that
/// state — `-rios-fixture <id>` at launch or `bin/rios sim fixture <id>` — never by navigating.
struct RootView: View {
    let state: AppState
    let send: (Action) -> Void
    /// The recording whose "Hold the button while you speak." is still up (`TooShortLine`).
    @State private var tooShortLine: String?
    @State private var projection = ScreenProjectionCache()

    var body: some View {
        let model = TooShortLine.apply(tooShortLine, to: projection.model(state, attachments: Self.attachments))
        ScreenView(model: model) { intent in
            // An intent the core has no action for yet changes nothing: a screen never pretends.
            if let action = intent.action() { send(action) }
        }
        .environment(\.screenClock, Self.clock)
        .onChange(of: TooShortLine.ending(state.voice, posed: state.voice.map(VoiceClock.isPose) ?? false), initial: true) { _, id in
            if let id { tooShortLine = id }
        }
        .task(id: tooShortLine) {
            // One bounded sleep while a line is up; nothing runs otherwise.
            guard tooShortLine != nil else { return }
            try? await Task.sleep(for: .milliseconds(Motion.tooShortLineMs))
            if !Task.isCancelled { tooShortLine = nil }
        }
        #if DEBUG
        // Debug-only probe for the UI tests: the core's mirror of the OS microphone permission, so a
        // test of the voice gestures can tell "the gesture is broken" from "the app has not been
        // told the permission yet" (a platform wiring step, not a screen).
        .overlay(alignment: .topLeading) {
            Color.clear.frame(width: 1, height: 1)
                .accessibilityElement()
                .accessibilityLabel("microphone \(state.microphone.rawValue)")
                .accessibilityIdentifier("debug.microphone.\(state.microphone.rawValue)")
        }
        #endif
    }

    /// Where the staged photos live, so the tray and unsent albums can show them.
    private static let attachments = ShareIntake.attachmentsDirectory()

    /// Debug builds pin the clock to the fixtures' morning (`-rios-now <ms>`), so "Today" and "8:02 AM"
    /// read the same on any day; Release always draws against now.
    private static var clock: ScreenClock {
        #if DEBUG
        if let raw = UserDefaults.standard.string(forKey: "rios-now"), let ms = Double(raw) {
            return ScreenClock(now: Date(timeIntervalSince1970: ms / 1000), calendar: .autoupdatingCurrent)
        }
        #endif
        return .live
    }
}

/// Draws a `ScreenModel`. Everything visible comes from the model; everything tapped leaves as an
/// `Intent`.
struct ScreenView: View {
    let model: ScreenModel
    let send: (Intent) -> Void

    @Environment(\.screenClock) private var clock
    @State private var headerBottom: CGFloat = 120
    @State private var zoneTop: CGFloat = 700
    @State private var showsLatest = false
    @State private var jumpToken = 0
    @State private var aboveHeight: CGFloat = 0
    /// Whether the CURRENT model has a sheet. SwiftUI may call the setter of the binding it was first
    /// given, whose captured model is stale; this box always holds the latest answer.
    @State private var sheetBox = SheetBox()

    final class SheetBox { var hasSheet = false }

    var body: some View {
        let palette = Palette.for(model.appearance)
        let _ = { sheetBox.hasSheet = model.sheet != nil }()
        GeometryReader { root in
            let safeTop = root.safeAreaInsets.top
            let small = root.size.width < 380 || root.size.height < 700
            ZStack(alignment: .top) {
                GroundBackground()
                conversation(root: root, safeTop: safeTop)
                    .accessibilityHidden(model.takeover != nil || model.dialog != nil || model.scanner != nil
                                         || model.attach.viewer != nil)
                if let dialog = model.dialog {
                    DialogView(dialog: dialog, send: send)
                        .transition(.opacity)
                        .zIndex(5)
                }
                if let takeover = model.takeover {
                    TakeoverView(takeover: takeover, smallDevice: small, send: send)
                        .transition(.opacity)
                        .zIndex(4)
                        .accessibilityHidden(model.dialog != nil || model.scanner != nil)
                }
                if let scanner = model.scanner {
                    ScannerView(state: scanner, send: send)
                        .transition(.opacity)
                        .zIndex(6)
                }
                if let viewer = model.attach.viewer, let content = viewerContent(viewer) {
                    content.transition(.opacity).zIndex(7)
                }
            }
            .frame(width: root.size.width, height: root.size.height)
        }
        .palette(palette)
        // Only a person's swipe closes the sheet here; when the core replaces it (Forget → its dialog),
        // the model already has no sheet and nothing is sent, so the dialog is not closed with it.
        .sheet(isPresented: Binding(get: { model.sheet != nil },
                                    set: { [box = sheetBox] in if !$0, box.hasSheet { send(.closeSheet) } })) {
            sheetContent(palette: palette)
        }
        .animation(Motion.outQuint(320), value: model.takeover)
        .animation(Motion.outQuint(250), value: model.dialog)
        .animation(Motion.outQuint(250), value: model.scanner)
    }

    // MARK: The conversation

    private func conversation(root: GeometryProxy, safeTop: CGFloat) -> some View {
        let palette = Palette.for(model.appearance)
        let fullHeight = root.size.height + root.safeAreaInsets.top + root.safeAreaInsets.bottom
        return ZStack(alignment: .top) {
            if model.thread.isEmpty {
                EmptyConversation()
                    .frame(maxWidth: .infinity)
                    .padding(.top, safeTop + root.size.height * 0.30)
                    .frame(maxHeight: .infinity, alignment: .top)
            } else {
                TranscriptView(
                    transcript: model.thread, palette: palette,
                    topInset: headerBottom + 16, bottomInset: max(0, fullHeight - zoneTop) + 20,
                    calendar: clock.calendar, now: clock.now, jumpToken: jumpToken, send: send,
                    onShowsLatest: { shows in
                        DispatchQueue.main.async { withAnimation(Motion.latest) { showsLatest = shows } }
                    })
                    // With the out-of-reach line up, the fade follows the taller block down to it, so the
                    // list fades under the line as it does under the header (I02). Otherwise, as before.
                    .mask(fadeUnderHeader(safeTop: model.thread.cached ? max(safeTop, headerBottom - 60) : safeTop,
                                          height: fullHeight))
                    .ignoresSafeArea()
            }
            if model.attach.menuOpen {
                palette.scrim.opacity(0.55)
                    .ignoresSafeArea()
                    .onTapGesture { send(.closeAttachMenu) }
                    .transition(.opacity)
                    .accessibilityHidden(true)
            }
            VStack(spacing: 0) {
                // The out-of-reach line belongs to the header's measured block, so the list starts
                // below it and it is never drawn under the header's fade (I02).
                VStack(spacing: 8) {
                    ConversationHeader(connection: model.connection, send: send)
                    if model.thread.cached, !model.thread.isEmpty {
                        OutOfReachLine()
                            .padding(.horizontal, 14)
                            .transition(.opacity)
                    }
                }
                .background(GeometryReader { p in
                    Color.clear.onAppear { headerBottom = p.frame(in: .global).maxY }
                        .onChange(of: p.frame(in: .global).maxY) { _, y in headerBottom = y }
                })
                if let banner = model.banner {
                    UpdateBannerView(banner: banner, send: send)
                        .padding(.horizontal, 12).padding(.top, 8)
                        .transition(.opacity.combined(with: .offset(y: 12)))
                }
                Spacer(minLength: 0)
                bottomZone(height: root.size.height)
            }
        }
    }

    /// The composer has priority over everything above it at every text size (accessibility audit F1,
    /// F11): cards and the toast share a region of at most 40% of the screen that scrolls when they
    /// are taller, and the compose row never scrolls away.
    private func bottomZone(height: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if showsLatest || !model.thread.following, !model.thread.isEmpty, !model.attach.menuOpen {
                LatestPill {
                    jumpToken += 1
                    send(.setFollowing(true))
                }
                .frame(maxWidth: .infinity)
                .transition(.opacity.combined(with: .offset(y: 20)))
            }
            if model.attach.menuOpen {
                AttachMenu(send: send)
                    .padding(.leading, 10)
                    .transition(.opacity)
            }
            VStack(spacing: 8) {
                if !model.cards.isEmpty || model.toast != nil {
                    ScrollView {
                        AboveComposer(cards: model.cards, toast: model.toast, send: send)
                            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { aboveHeight = $0 }
                    }
                    .scrollBounceBehavior(.basedOnSize)
                    .scrollIndicators(.hidden)
                    .frame(height: min(max(aboveHeight, 1), height * 0.4))
                }
                ComposerView(composer: model.composer, voice: model.voice, pending: model.attach.pending,
                             attachMenuOpen: model.attach.menuOpen, send: send)
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 8)
            .background(GeometryReader { p in
                Color.clear.onAppear { zoneTop = p.frame(in: .global).minY }
                    .onChange(of: p.frame(in: .global).minY) { _, y in zoneTop = y }
            })
        }
        .animation(Motion.spring(320), value: model.attach.menuOpen)
    }

    /// The thread fades out under the header (`.thread` `mask-image`). `safeTop` is where the header
    /// block's 60 pt begin; the stops sit 30, 64 and 100 pt below it.
    private func fadeUnderHeader(safeTop: CGFloat, height: CGFloat) -> some View {
        let h = max(height, 1)
        return LinearGradient(stops: [
            .init(color: .clear, location: 0),
            .init(color: .clear, location: (safeTop + 30) / h),
            .init(color: .black.opacity(0.35), location: (safeTop + 64) / h),
            .init(color: .black, location: (safeTop + 100) / h),
            .init(color: .black, location: 1),
        ], startPoint: .top, endPoint: .bottom)
        .ignoresSafeArea()
    }

    private func viewerContent(_ viewer: ScreenModel.Viewer) -> AttachViewer? {
        guard let row = model.thread.rows.first(where: { $0.id == viewer.messageID }) else { return nil }
        switch row.body {
        case .album(let photos, let caption):
            return AttachViewer(photos: photos, file: nil, index: viewer.index, caption: caption, sentAt: row.sentAt,
                                calendar: clock.calendar, send: send)
        case .file(let file, let caption):
            return AttachViewer(photos: [], file: file, index: 0, caption: caption, sentAt: row.sentAt,
                                calendar: clock.calendar, send: send)
        default:
            return nil
        }
    }

    @ViewBuilder private func sheetContent(palette: Palette) -> some View {
        Group {
            switch model.sheet {
            case .settings(let settings)?:
                SettingsSheet(settings: settings, send: send)
            case .whereMessagesGo?:
                WhereMessagesGoSheet(send: send)
            case .pairingLink(let problem)?:
                PairingLinkSheet(problem: problem, send: send)
            case nil:
                EmptyView()
            }
        }
        .palette(palette)
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(28)
        .presentationBackground(palette.ground)
    }
}

/// The time and calendar the conversation's day markers and clock times are drawn against. Live: now,
/// in the phone's time zone. Debug: `-rios-now <ms>` pins it.
struct ScreenClock: Sendable {
    var now: Date
    var calendar: Calendar

    static var live: ScreenClock { ScreenClock(now: Date(), calendar: .autoupdatingCurrent) }
}

private struct ScreenClockKey: EnvironmentKey {
    static var defaultValue: ScreenClock { .live }
}

extension EnvironmentValues {
    var screenClock: ScreenClock {
        get { self[ScreenClockKey.self] }
        set { self[ScreenClockKey.self] = newValue }
    }
}
