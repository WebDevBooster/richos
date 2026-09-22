import SwiftUI
import RichOSCore

/// A STAND-IN, not a design. It exists so the app shell builds, launches and can be driven before
/// the screens stream (I2) lands the round-12 screens; it is replaced at the composition seam in
/// `RichOSNativeApp`. It shows the semantic screen the core is on and one real control wired to a
/// core action, so a tap and a CLI command can be seen to do the same thing.
///
/// It uses system colors and the system face, which clear WCAG AA in both appearances; the ruled
/// palette and the vendored faces arrive with I2's design system.
struct PlaceholderRootView: View {
    let store: AppStore

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("RichOS")
                .font(.largeTitle.weight(.semibold))
            Text("Screen: \(store.state.screen.rawValue)")
                .font(.body)
                .accessibilityIdentifier("placeholder.screen")
            // The system placeholder gray is under 4.5:1 in dark; ink at 72% clears it in both
            // appearances (10.6:1 on black, 9.3:1 on white, computed with the WCAG formula).
            TextField("Message Rich", text: Binding(
                get: { store.state.draft },
                set: { store.send(.compose(text: $0)) }),
                prompt: Text("Message Rich").foregroundStyle(Color.primary.opacity(0.72)))
                .textFieldStyle(.roundedBorder)
                .font(.body)
                .accessibilityIdentifier("placeholder.draft")
            if let problem = store.persistenceProblem {
                Text(problem).font(.body)
            }
            Spacer()
        }
        .padding(24)
        .preferredColorScheme(store.state.appearance == .dark ? .dark : .light)
    }
}
