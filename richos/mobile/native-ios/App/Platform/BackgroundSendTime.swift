import RichOSCore
import UIKit

/// The extra time iOS gives an app that leaves the screen in the middle of a send:
/// `UIApplication.beginBackgroundTask` ("Extending your app's background execution time"). Without
/// it iOS suspends the app moments after Home, and a message whose request was still on its way
/// stayed on the phone until the app was next opened (iPhone walk D3, 2026-10-01).
///
/// The core decides when (`AppStore.backgroundContinuation`): it begins when a send starts on screen
/// and ends the moment that send and the messages queued with it are answered, or the core's own
/// bound runs out (five seconds after leaving, three requests, 256 KiB; six times an hour, 24 a day,
/// `EffectRunner.reserveCompletion`). The OS's expiration handler is the outer bound: it tells the
/// core, which gives up the request in flight, and ends the task itself, as Apple requires.
@MainActor
final class BackgroundSendTime: BackgroundContinuation {
    private var task: UIBackgroundTaskIdentifier = .invalid

    func begin(expired: @escaping @MainActor @Sendable () -> Void) {
        guard task == .invalid else { return }
        task = UIApplication.shared.beginBackgroundTask(withName: "Finish sending a message") { [weak self] in
            // UIKit calls the expiration handler on the main thread.
            MainActor.assumeIsolated {
                expired()
                self?.end()
            }
        }
    }

    func end() {
        guard task != .invalid else { return }
        UIApplication.shared.endBackgroundTask(task)
        task = .invalid
    }
}
