import SwiftUI
import RichOSCore

/// The app entry. It loads the store, wires the effect handlers, keeps the core's clock ticking while
/// the app is on screen, tells the core when the app comes and goes, starts the Debug development
/// bridge, and hands the store to the screens.
///
/// COMPOSITION SEAM: the screens stream's (I2) `RootView` (`App/Features/Root/`) takes the state and
/// a send function, never the store type, so the screens depend only on the core.
/// EFFECT SEAM: `Effects.make()` is where the platform adapter (stream I3, `App/Platform/`) joins the
/// network handler.
@main
struct RichOSNativeApp: App {
    @State private var store: AppStore?
    @Environment(\.scenePhase) private var scenePhase

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
                let effects = Effects.make()
                let loaded = await AppStore.launch(storage: AppStore.defaultStorage(), effects: effects.handler)
                await effects.network.setSink { action in await MainActor.run { loaded.receive(action) } }
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
                case .active: store.send(.foregrounded(at: SystemClock().nowMs()))
                case .background: store.send(.backgrounded(at: SystemClock().nowMs()))
                default: break
                }
            }
        }
    }
}

/// Every effect handler the app runs, composed once. The network half is here; the platform half
/// (microphone, recorder, notifications, Settings) joins `handlers` from stream I3.
enum Effects {
    struct Composed {
        var handler: any EffectHandler
        var network: NetworkEffects
    }

    static func make() -> Composed {
        let transport = URLSessionTransport()
        let network = NetworkEffects(transport: transport, stream: transport, identities: KeychainIdentityStore())
        let handlers: [any EffectHandler] = [network]  // ← I3: the platform handler joins here
        return Composed(handler: CompositeEffectHandler(handlers), network: network)
    }
}
