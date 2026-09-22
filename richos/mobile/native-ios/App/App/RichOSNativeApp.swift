import SwiftUI
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
                let network = NetworkEffects(transport: transport, stream: transport, identities: KeychainIdentityStore(),
                                             recordings: FileRecordingStore(directory: VoiceRecorder.defaultDirectory()))
                let platform = PlatformEffects(network: network)
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
                    if let action = NotificationTapRouter.action(for: target, state: loaded.state, hostID: loaded.state.notifications.hostID) {
                        loaded.send(action)
                    }
                }
                PlatformEffects.permissionMirror().forEach { loaded.send($0) }
                NotificationPlatform.shared.deliverPending()
                self.platform = platform
                #if DEBUG
                await DevBridge.start(store: loaded)
                #endif
                store = loaded
                loaded.send(.foregrounded(at: SystemClock().nowMs()))
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
                    store.send(.foregrounded(at: SystemClock().nowMs()))
                case .background:
                    // Backgrounding keeps a recording in progress, never sends it (the core's rule).
                    store.send(.backgrounded(at: SystemClock().nowMs()))
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
