import SwiftUI
import RichOSCore

/// The app entry. It loads the store, starts the Debug development bridge, and hands the store to
/// the root view.
///
/// COMPOSITION SEAM: `PlaceholderRootView` stands in until the screens stream (I2) delivers its
/// root view under `App/Features/`. Swapping it is the one line marked below; per build plan §5.0
/// the I2 handoff names the line and I1 applies it.
@main
struct RichOSNativeApp: App {
    @State private var store: AppStore?

    var body: some Scene {
        WindowGroup {
            Group {
                if let store {
                    PlaceholderRootView(store: store)  // ← the composition seam
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
