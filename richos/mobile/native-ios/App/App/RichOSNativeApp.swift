import SwiftUI
import UIKit
import RichOSCore

/// The app entry. It loads the store, wires the effect handlers, keeps the core's clock ticking while
/// the app is on screen, tells the core when the app comes and goes, starts the Debug development
/// bridge, and hands the store to the screens.
///
/// COMPOSITION SEAM: the screens stream's (I2) `RootView` (`App/Features/Root/`) takes the state and
/// a send function, never the store type, so the screens depend only on the core.
/// EFFECT SEAM: the platform adapter (stream I3, `App/Platform/`) handles the microphone, recorder,
/// notifications and Settings, and hands every network effect to the core's `NetworkEffects`.
@main
struct RichOSNativeApp: App {
    @UIApplicationDelegateAdaptor(PlatformAppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase
    @State private var store: AppStore?
    @State private var platform: PlatformEffects?

    var body: some Scene {
        WindowGroup {
            Group {
                if let store {
                    RootView(state: store.state, send: { store.send($0) })  // ← the composition seam
                } else {
                    // Loading the saved state takes milliseconds; nothing is announced meanwhile.
                    Color.clear
                }
            }
            .task {
                guard store == nil else { return }
                let transport = URLSessionTransport()
                // The courier reads voice messages from the same files the recorder writes.
                let network = NetworkEffects(transport: transport, stream: transport, identities: PlatformEffects.identityStore(),
                                             recordings: FileRecordingStore(directory: VoiceRecorder.defaultDirectory()),
                                             attachments: FileAttachmentStore(directory: ShareIntake.attachmentsDirectory()))
                let platform = PlatformEffects(network: network, attachments: ShareIntake.attachmentsDirectory())
                let loaded = await AppStore.launch(storage: AppStore.defaultStorage(), effects: platform)
                platform.dispatch = { loaded.receive($0) }
                await network.setSink { action in await MainActor.run { loaded.receive(action) } }
                await network.setPreviewKeyProvider { origin, previews in
                    await MainActor.run { try? NotificationPlatform.shared.configurePreviews(origin: origin, previews: previews).key }
                }
                NotificationPlatform.shared.onToken = { token in
                    Task {
                        let actions = await network.setPushToken(token, sandbox: PushRegistration.buildEnvironment == .sandbox, state: loaded.state)
                        for action in actions { loaded.receive(action) }
                    }
                }
                NotificationPlatform.shared.onOpen = { target in
                    let state = loaded.state
                    if let action = NotificationTapRouter.action(for: target, state: state, hostID: state.notifications.hostID) {
                        loaded.send(action)
                    } else if target.belongs(toHost: state.notifications.hostID, thread: state.mac?.threadID) {
                        // The reply is not loaded yet: the core fetches older history until it appears.
                        loaded.send(.openedFromNotificationReference(target.event))
                    }
                }
                PlatformEffects.permissionMirror().forEach { loaded.send($0) }
                NotificationPlatform.shared.deliverPending()
                self.platform = platform
                #if DEBUG
                await DevBridge.start(store: loaded)
                #endif
                // Before the first frame, so a phone set to light never flashes dark.
                loaded.followPhone(SystemAppearance.current())
                SystemAppearance.observe { loaded.followPhone($0) }
                store = loaded
                loaded.becameActive(at: SystemClock().nowMs())
                await ShareIntake.takeWaiting(into: loaded, nowMs: SystemClock().nowMs())
            }
            .task(id: scenePhase) {
                // The core's clock: the outbox's retries, the voice timer and the quiet period before
                // "Reconnecting…" all move on `tick`. Ten times a second, only while on screen.
                guard scenePhase == .active else { return }
                while !Task.isCancelled {
                    if let store, store.ticking { store.send(.tick(at: SystemClock().nowMs())) }
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
            }
            .onChange(of: scenePhase) { _, phase in
                guard let store else { return }
                switch phase {
                case .active:
                    // The OS's microphone answer is mirrored, never stored (PRD §3).
                    PlatformEffects.permissionMirror().forEach { store.send($0) }
                    store.followPhone(SystemAppearance.current())
                    store.becameActive(at: SystemClock().nowMs())
                    // What was shared while the app was away goes into the outbox now.
                    Task { await ShareIntake.takeWaiting(into: store, nowMs: SystemClock().nowMs()) }
                case .background:
                    // Backgrounding keeps a recording in progress, never sends it (the core's rule).
                    store.wentToBackground(at: SystemClock().nowMs())
                default:
                    break
                }
            }
            .onChange(of: store?.state) { _, state in
                guard let state else { return }
                SharePlatform.mirror(state, macAcceptsAttachments: state.attachmentLimits != nil, limits: state.attachmentLimits)
            }
        }
    }
}

/// The phone's light or dark setting, read from the screen: the app's window carries the app's own
/// `preferredColorScheme`, the screen carries the system's.
@MainActor
enum SystemAppearance {
    static func current() -> Appearance {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let style = scene?.screen.traitCollection.userInterfaceStyle ?? UITraitCollection.current.userInterfaceStyle
        return style == .light ? .light : .dark
    }

    /// Calls `change` when the phone switches between light and dark while the app is on screen
    /// (Control Center, or the automatic schedule). A trait registration: no polling, no timer.
    static func observe(_ change: @escaping @MainActor (Appearance) -> Void) {
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else { return }
        registration = scene.registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (_: UIWindowScene, _: UITraitCollection) in
            MainActor.assumeIsolated { change(current()) }
        }
    }

    private static var registration: (any UITraitChangeRegistration)?
}
