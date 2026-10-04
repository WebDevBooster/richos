import RichOSCore
import SwiftUI

/// WHAT THE PHONE SHOWS FROM THE TAP UNTIL THE CONVERSATION IS DRAWN.
///
/// The CEO, 2026-10-02: from the moment any part of the app is visible there must be something useful
/// or pleasing on screen; a blank or white screen never is; the app's logo on its own background, the way
/// the Android app does it, is fine. Before this, iOS showed its generated (empty, white in light mode)
/// launch screen from the tap to the app's first frame, and the app's first frame was `Color.clear` over
/// the window's white until the saved state was read: on the test iPhone with a saved conversation, a
/// white screen for about 0.9 s.
///
/// Now both are Android's launch picture: the app icon centered on the launch ground, at a fixed size
/// (native-android themes.xml: windowBackground @color/launch_ground; Android 12+ draws
/// @mipmap/ic_launcher centered on it). `LaunchScreen.storyboard` draws it before the app runs;
/// `LaunchShellView` draws the same picture, from the same two assets, as the app's frame while the
/// saved state is read, so nothing changes on screen until the conversation itself appears.
enum LaunchShell {
    /// The icon's size, fixed as Android's splash icon is: 0.3583 (the share of the screen's width
    /// Android's launcher icon takes on the test phone; andy-sonnet-seen1's release recording light_5,
    /// 2026-10-02: 258 of 720 pixels once settled) of the test iPhone's 375 pt. LaunchIcon's art is
    /// rendered at this size (Tools/launch-icon.py) and both pictures draw it at its own size.
    static let iconPoints: CGFloat = 134
}

/// The app's frame until the saved state is read: the launch screen, drawn live, over the whole screen
/// as the launch screen is. The ground and the icon are the launch screen's own assets, the icon at its
/// own size (LaunchGround and LaunchIcon follow the phone's light or dark setting by themselves; the app
/// sets no scheme of its own).
struct LaunchShellView: View {
    var body: some View {
        ZStack {
            Color("LaunchGround")
            Image("LaunchIcon")
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

/// THE WINDOW UNTIL THE SAVED STATE IS READ, AND NEVER LONGER THAN `quietAfter` ON THE LOGO.
///
/// The CEO's rule (richos-hq §105): nothing the first screen shows waits on anything. The saved
/// conversation's read (`Boot`) is local and normally lands before the first frame or just after it, so
/// the launch picture (`LaunchShellView`) continues straight into the conversation. When the read has
/// not landed within `quietAfter` (counted from the app's first line, `Boot.quietBudget`), the
/// conversation's own screen appears in its quiet state (`ScreenModel.quiet`: the ground, the header,
/// the composer, nothing in between) and the conversation fills it in when the read lands, because
/// the app then swaps this view for `RootView`. Never a spinner, never a blank frame (§100).
///
/// The quiet screen takes no touches: there is no store yet to send them to, and a store made before
/// the read lands could write an empty state over the saved one. It is a still picture for VoiceOver too.
///
/// Battery: one bounded sleep, started once while this view is on screen and canceled when it leaves;
/// nothing repeats.
struct LaunchRoot: View {
    enum Stage: Equatable { case logo, quiet }

    let quietAfter: Duration
    /// Told each stage as it appears (the launch log; a test's recorder).
    var shown: (Stage) -> Void = { _ in }

    @Environment(\.colorScheme) private var scheme
    @State private var quiet = false

    var body: some View {
        if quiet {
            ScreenView(model: .quiet(scheme == .light ? .light : .dark), send: { _ in })
                .allowsHitTesting(false)
                .accessibilityHidden(true)
                .onAppear { shown(.quiet) }
        } else {
            LaunchShellView()
                .onAppear { shown(.logo) }
                .task {
                    do { try await Task.sleep(for: quietAfter) } catch { return }
                    quiet = true
                }
        }
    }
}
