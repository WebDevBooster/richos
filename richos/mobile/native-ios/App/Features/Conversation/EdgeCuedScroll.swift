import SwiftUI

/// A scroll region whose cut edges are visible (the iPhone re-walk, R1). Where its content is taller
/// than the room it was given, the edge that hides more fades out and carries a small arrow, so what
/// reaches an edge reads as "more this way", never as a sentence or a button cut off. When everything
/// fits, nothing is drawn: no fade, no arrow. It is plain layout state: it changes only when the
/// content's size or the scroll position does, and asks for no timer, animation loop or redraw.
struct EdgeCuedScroll<Content: View>: View {
    /// Names the arrows for tests and VoiceOver (`<id>.moreBelow`, `<id>.moreAbove`).
    let id: String
    @ViewBuilder var content: Content
    @Environment(\.palette) private var palette
    @State private var viewport: CGFloat = 0
    @State private var contentHeight: CGFloat = 0
    /// How far the content has scrolled up (zero at rest), from where its frame sits in the region.
    @State private var offset: CGFloat = 0

    /// How far the fade reaches into the region.
    static var fade: CGFloat { 18 }

    private var hidesAbove: Bool { offset > 1 }
    private var hidesBelow: Bool { viewport > 0 && contentHeight - offset > viewport + 1 }

    var body: some View {
        ScrollView {
            content
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
                .background(GeometryReader { p in
                    Color.clear.preference(key: ContentTopKey.self, value: p.frame(in: .named(Self.space)).minY)
                })
        }
        .coordinateSpace(name: Self.space)
        .onPreferenceChange(ContentTopKey.self) { offset = max(0, -$0) }
        .scrollBounceBehavior(.basedOnSize)
        .scrollIndicators(.hidden)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { viewport = $0 }
        .mask(
            LinearGradient(stops: [
                .init(color: hidesAbove ? .clear : .black, location: 0),
                .init(color: .black, location: min(0.5, Self.fade / max(viewport, 1))),
                .init(color: .black, location: 1 - min(0.5, Self.fade / max(viewport, 1))),
                .init(color: hidesBelow ? .clear : .black, location: 1),
            ], startPoint: .top, endPoint: .bottom))
        .overlay(alignment: .top) { if hidesAbove { cue(pointsDown: false) } }
        .overlay(alignment: .bottom) { if hidesBelow { cue(pointsDown: true) } }
    }

    private static var space: String { "edge-cued-scroll" }

    /// The arrow says there is more; VoiceOver is told the same, and the content is all reachable.
    private func cue(pointsDown: Bool) -> some View {
        IconView(.arrowD, size: 14)
            .foregroundStyle(palette.ink)
            .rotationEffect(.degrees(pointsDown ? 0 : 180))
            .frame(maxWidth: .infinity)
            .allowsHitTesting(false)
            .accessibilityElement()
            .accessibilityLabel(pointsDown ? "More below" : "More above")
            .accessibilityIdentifier("\(id).\(pointsDown ? "moreBelow" : "moreAbove")")
    }
}

private struct ContentTopKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}
