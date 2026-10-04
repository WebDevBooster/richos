import Foundation
import SwiftUI
import Testing
import UIKit
@testable import RichOSNative

/// The CEO's rule (richos-hq §105): the first screen never waits on anything. The app's window shows
/// `LaunchRoot` until the saved state is read (`Boot`); here it is put on screen exactly as the app puts
/// it there, and no store ever arrives, as when the read never completes. The conversation's screen must
/// still appear, in its quiet state, instead of the logo staying up.
@Suite("Launch root")
@MainActor
struct LaunchRootTests {
    final class Recorder { var stages: [LaunchRoot.Stage] = [] }

    @Test func aRestoreThatNeverCompletesStillShowsTheFirstScreen() async throws {
        let recorder = Recorder()
        let window = Self.window(LaunchRoot(quietAfter: .milliseconds(100)) { recorder.stages.append($0) })
        defer { window.isHidden = true }
        // Two seconds is twenty times the bound; the store never arrives in this test.
        for _ in 0..<40 where !recorder.stages.contains(.quiet) { try await Task.sleep(for: .milliseconds(50)) }
        #expect(recorder.stages == [.logo, .quiet],
                "with the saved state never read, the window showed \(recorder.stages): the logo stayed up")
    }

    @Test func aRestoreThatLandsInTimeNeverShowsTheQuietScreen() async throws {
        let recorder = Recorder()
        let window = Self.window(LaunchRoot(quietAfter: .seconds(30)) { recorder.stages.append($0) })
        defer { window.isHidden = true }
        try await Task.sleep(for: .milliseconds(300))
        // The app swaps LaunchRoot for the conversation when the read lands: here, taking it off screen.
        window.rootViewController = UIViewController()
        try await Task.sleep(for: .milliseconds(100))
        #expect(recorder.stages == [.logo])
    }

    /// The quiet screen is the conversation's: no takeover, no messages, no first-minute hello.
    @Test func theQuietScreenIsTheConversationWithNothingInIt() {
        let model = ScreenModel.quiet(.light)
        #expect(model.quiet && model.takeover == nil && model.thread.isEmpty && model.sheet == nil && model.dialog == nil)
        #expect(model.appearance == .light)
        #expect(ScreenModel.quiet(.dark).appearance == .dark)
    }

    private static func window<V: View>(_ view: V) -> UIWindow {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 375, height: 667))
        if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first {
            window.windowScene = scene
        }
        window.rootViewController = UIHostingController(rootView: view)
        window.makeKeyAndVisible()
        return window
    }
}
