import SwiftUI
import RichOSCore

/// The app entry. It loads the store, starts the Debug development bridge, and hands the store to
/// the root view.
///
/// COMPOSITION SEAM: the screens stream's (I2) `RootView` (`App/Features/Root/`) takes the state and
/// a send function, never the store type, so the screens depend only on the core.
@main
struct RichOSNativeApp: App {
    @State private var store: AppStore?

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
                let loaded = await AppStore.launch(storage: AppStore.defaultStorage())
                #if DEBUG
                await DevBridge.start(store: loaded)
                #endif
                store = loaded
            }
        }
    }
}
