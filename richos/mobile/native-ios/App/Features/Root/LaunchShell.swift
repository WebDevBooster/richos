import RichOSCore
import SwiftUI

/// WHAT THE PHONE SHOWS FROM THE TAP UNTIL THE CONVERSATION IS DRAWN.
///
/// The CEO, 2026-10-02: from the moment any part of the app is visible there must be something useful
/// or pleasing on screen; a blank or white screen never is. Before this, iOS showed its generated
/// (empty, white in light mode) launch screen from the tap to the app's first frame, and the app's first
/// frame was `Color.clear` over the window's white until the saved state was read.
///
/// Now both are the conversation's own frame, without its words: the ground and its lamp, the
/// nameplate with the mark, Settings, and the composer capsule with its + and its gold microphone, each
/// exactly where the conversation draws it (Apple, Human Interface Guidelines, "Launching": a launch
/// screen is nearly identical to the first screen, with no text, since it cannot change with the
/// person's text size or language). When the conversation arrives, the words and the transcript appear
/// in place; nothing moves.
///
/// - `LaunchShellView` is the app's frame while the saved state is read (RichOSNativeApp).
/// - `LaunchScreen.storyboard` draws the same pieces as images (Assets.xcassets `Launch*`), rendered from
///   these views by `LaunchArtTests`, which fails when a committed image no longer matches them.
///
/// Every number here is the conversation's (ScreenView, ConversationHeader, ComposerView, RoundButton);
/// change one there and the art test says so. The splash never carries the speckle (the CEO,
/// 2026-09-29): the ground here is the flat ground and its lamp, nothing else.
///
/// What it cannot match: the conversation at another text size lays the nameplate and the composer out
/// taller, so they grow in place when it arrives; and the first launch before pairing opens on the
/// pairing screen, which replaces this frame once.
enum LaunchShell {
    /// Room the art leaves around each piece for its shadow to fade out whole: floatShadow is radius 12
    /// at y 10, the orb's radius 12 at y 8, and at 28 pt the first render still cut them visibly.
    static let margin: CGFloat = 56
    /// ConversationHeader: `.padding(.top, 8)` and `.padding(.horizontal, 14)`.
    static let headerTop: CGFloat = 8
    static let headerSide: CGFloat = 14
    /// ScreenView.bottomZone: the composer's `.padding(.horizontal, 8)` and `.padding(.bottom, 8)`.
    static let zoneSide: CGFloat = 8
    static let zoneBottom: CGFloat = 8
    /// ComposerView's one-line capsule: `max(52, fieldHeight + 28)`.
    static let capsuleHeight: CGFloat = 52
    /// The composer art is cut in three: the + end, one stretchable point of capsule, the orb end.
    static let leftCap: CGFloat = 60
    /// Wide enough that the orb's gold glow on the capsule has faded out where the stretch begins.
    static let rightCap: CGFloat = 100
    /// The width the composer art is rendered at before it is cut (any width with a flat middle).
    static let composerArtWidth: CGFloat = 200
    /// The lamp art's screen, in points (a 19.5:9 iPhone); the launch screen stretches it to the phone.
    static let lampArtSize = CGSize(width: 390, height: 844)
}

/// The nameplate, with "Rich" laid out but not drawn, so the pill is exactly as wide as the real one.
struct LaunchNameplate: View {
    @Environment(\.palette) private var palette

    var body: some View {
        HStack(spacing: 12) {
            MarkView()
                .frame(width: 24, height: 24)
                .frame(width: 40, height: 40)
                .background(Circle().fill(palette.ground))
            Text("Rich")
                .type(Typography.body.weight(600).lineHeight(1.2))
                .hidden()
        }
        .padding(.leading, 8).padding(.trailing, 18).padding(.vertical, 6)
        .frame(minHeight: 52)
        .floatingSurface(palette, radius: 28)
    }
}

/// Settings, as RoundButton draws it.
struct LaunchSettingsButton: View {
    @Environment(\.palette) private var palette

    var body: some View {
        IconView(.settings, size: 22)
            .foregroundStyle(palette.ink)
            .frame(width: 52, height: 52)
            .floatingSurface(palette, radius: 26)
    }
}

/// The composer capsule at rest: the + at its left end, the gold microphone at its right end, no words.
struct LaunchComposer: View {
    let width: CGFloat
    @Environment(\.palette) private var palette

    var body: some View {
        let height = LaunchShell.capsuleHeight
        ZStack(alignment: .topLeading) {
            Color.clear
                .frame(width: width, height: height)
                .floatingSurface(palette, radius: 26)
            IconView(.plus, size: 24, weight: 2.2)
                .foregroundStyle(palette.inkSoft)
                .frame(width: 44, height: 44)
                .padding(.leading, 4).padding(.bottom, 4)
                .frame(width: width, height: height, alignment: .bottomLeading)
            ZStack {
                Circle().fill(palette.signal)
                    .shadow(color: palette.orbShadow, radius: 12, y: 8)
                IconView(.mic, size: 22, weight: 2.2)
                    .foregroundStyle(palette.onSignal)
            }
            .frame(width: 44, height: 44)
            .position(x: width - 26, y: height / 2)
        }
        .frame(width: width, height: height, alignment: .topLeading)
    }
}

/// The app's frame until the saved state is read: the launch screen, drawn live, so the first frame
/// continues it exactly. It reads the phone's light or dark setting from the environment (the app sets no
/// scheme of its own), as the launch screen's assets do.
struct LaunchShellView: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let palette = Palette.for(scheme == .light ? .light : .dark)
        GeometryReader { root in
            ZStack(alignment: .top) {
                GroundBackground()
                VStack(spacing: 0) {
                    HStack(alignment: .top, spacing: 10) {
                        LaunchNameplate()
                        Spacer(minLength: 0)
                        LaunchSettingsButton()
                    }
                    .padding(.horizontal, LaunchShell.headerSide)
                    .padding(.top, LaunchShell.headerTop)
                    Spacer(minLength: 0)
                    LaunchComposer(width: max(0, root.size.width - 2 * LaunchShell.zoneSide))
                        .padding(.horizontal, LaunchShell.zoneSide)
                        .padding(.bottom, LaunchShell.zoneBottom)
                }
            }
            .frame(width: root.size.width, height: root.size.height)
        }
        .environment(\.palette, palette)
        .accessibilityHidden(true)
    }
}
