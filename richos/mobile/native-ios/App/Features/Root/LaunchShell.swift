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
