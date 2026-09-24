import SwiftUI
import UIKit
import RichOSCore

/// The app entry. It loads the store, wires the effect handlers, ticks the core's clock when time is
/// owed while the app is on screen, tells the core when the app comes and goes, starts the Debug development
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
    @State private var networkMonitor = NetworkMonitor()

    /// When the core is next owed a `tick`, while the app is on screen; `nil` otherwise.
    private var nextTick: Int64? {
        guard scenePhase == .active, let store, store.ticking else { return nil }
        return TickSchedule.nextTick(store.state)
    }

    /// What the Share extension is told, derived from the state (`SharePlatform.context`); `nil`
    /// before the store has loaded. Small and cheap to compare, unlike the whole state.
    private var shareContext: ShareContext? {
        guard let state = store?.state else { return nil }
        return SharePlatform.context(for: state, macAcceptsAttachments: state.attachmentLimits != nil, limits: state.attachmentLimits)
    }

    private func usefulMarker(_ store: AppStore) -> some View {
        let state = store.state
        let revision = UsefulFrameMarker.Revision(count: state.messages.count, last: state.messages.last, reply: state.reply)
        return UsefulFrameMarker(active: scenePhase == .active, revision: revision)
            .frame(width: 1, height: 1).allowsHitTesting(false).accessibilityHidden(true)
    }

    private func mirrorPermissions(into store: AppStore) {
        #if DEBUG
        if DevBridge.interactiveFixture { return }
        #endif
        PlatformEffects.permissionMirror().forEach { store.send($0) }
        // Notifications: iOS's answer read once per return to the front, so a change made in iPhone
        // Settings is the truth here too (I04). An OS report, so it goes through `receive`.
        Task { @MainActor in
            let system = await NotificationPlatform.shared.systemPermission()
            if let action = NotificationPermissionCheck.action(system: system, state: store.state) { store.receive(action) }
        }
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if let store {
                    RootView(state: store.state, send: { store.send($0) })
                        // Install lifecycle observation only once the store exists. The launch
                        // task can suspend across activation, so its captured scenePhase is stale.
                        .onChange(of: scenePhase, initial: true) { _, phase in
                            switch phase {
                            case .active:
                                networkMonitor.start(store: store)
                                mirrorPermissions(into: store)
                                store.followPhone(SystemAppearance.current())
                                store.becameActive(at: SystemClock().nowMs())
                                Task { await ShareIntake.takeWaiting(into: store, nowMs: SystemClock().nowMs()) }
                            case .background:
                                networkMonitor.stop()
                                store.wentToBackground(at: SystemClock().nowMs())
                            default: break
                            }
                        }
                        .overlay(alignment: .topLeading) { usefulMarker(store) }
                        .safeAreaInset(edge: .top) {
                            if let problem = store.persistenceProblem ?? store.recordingProblem {
                                Text(problem)
                                    .font(.body)
                                    .padding()
                                    .frame(maxWidth: .infinity)
                                    .background(.regularMaterial)
                                    .accessibilityIdentifier("storage.problem")
                            }
                        }
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
                let effects: (any EffectHandler)?
                #if DEBUG
                // Gesture fixtures use the real core and storage with controlled
                // non-storage effects, just as the headless CLI does.
                effects = DevBridge.interactiveFixture ? nil : platform
                #else
                effects = platform
                #endif
                let loaded = await AppStore.launch(storage: AppStore.defaultStorage(), effects: effects, performance: PerformanceMarks.record)
                platform.dispatch = { loaded.receive($0) }
                await network.setSink { action in await MainActor.run { loaded.receive(action) } }
                await network.setPreviewKeyProvider { origin, previews in
                    await MainActor.run { try? NotificationPlatform.shared.configurePreviews(origin: origin, previews: previews).key }
                }
                NotificationPlatform.shared.onToken = { token in
                    guard let environment = PushRegistration.buildEnvironment else {
                        loaded.receive(.notificationsResult(.appleUnavailable))
                        return
                    }
                    Task {
                        let actions = await network.setPushToken(token, sandbox: environment == .sandbox, state: loaded.state)
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
                await ShareIntake.takeWaiting(into: loaded, nowMs: SystemClock().nowMs())
            }
            .task(id: nextTick) {
                // The core's clock, only when time is owed: a running recording, the end of the quiet
                // period before "Reconnecting…", an outbox retry (`TickSchedule`). One sleep to that
                // moment, one tick; a new state that moves the moment restarts it. At rest, or off
                // screen, nothing is owed and nothing wakes (the CEO's battery rule, 2026-09-24).
                guard let due = nextTick else { return }
                let wait = due - SystemClock().nowMs()
                if wait > 0 {
                    do { try await Task.sleep(nanoseconds: UInt64(wait) * 1_000_000) } catch { return }
                }
                if let store, store.ticking { store.send(.tick(at: SystemClock().nowMs())) }
            }
            .onChange(of: shareContext) { _, _ in
                // Only when what the Share extension reads changed (pairing, the Mac, appearance,
                // limits). Keyed on the whole state, this read and decoded the context file on the
                // main thread on every keystroke, streamed word and voice tick (Sage's review T3).
                guard let state = store?.state else { return }
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
