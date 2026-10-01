import SwiftUI

/// A scroll region whose cut edges are visible (the iPhone re-walk, R1). Where its content is taller
/// than the room it was given, the edge that hides more carries a small arrow, so what reaches an edge
/// reads as "more this way", never as a sentence or a button cut off. When everything fits, nothing is
/// drawn: no arrow, no mask. It is plain layout state: it changes only when the content's size or the
/// scroll position does, and asks for no timer, animation loop or redraw.
///
/// `wholeLines` (iPhone re-walk 4, R2 at the floor): the edge that hides more keeps a strip that holds
/// only its arrow, and the content shows from the first whole line past that strip to the last whole
/// line before the other edge's. Lines and controls say where they are (`edgeGuardLines`,
/// `edgeGuardBlock`), so at any resting place a line of text or a button is drawn whole or not at all,
/// and no arrow is ever drawn over text; a scroll comes to rest with a whole line or control at the top
/// of that room (`EdgeSnap`), never between two of them. Without it, the hiding edge fades as before.
struct EdgeCuedScroll<Content: View>: View {
    /// Names the arrows for tests and VoiceOver (`<id>.moreBelow`, `<id>.moreAbove`).
    let id: String
    var wholeLines = false
    @ViewBuilder var content: Content
    @Environment(\.palette) private var palette
    @State private var viewport: CGFloat = 0
    @State private var contentHeight: CGFloat = 0
    /// How far the content has scrolled up (zero at rest), from where its frame sits in the region.
    @State private var offset: CGFloat = 0
    /// Where an edge may not fall, in the content's own coordinates: its lines and its controls.
    @State private var guards: [ClosedRange<CGFloat>] = []

    /// How far the fade reaches into the region.
    static var fade: CGFloat { 18 }

    private var hidesAbove: Bool { offset > 1 }
    private var hidesBelow: Bool { viewport > 0 && contentHeight - offset > viewport + 1 }

    var body: some View {
        let shown = wholeLines ? EdgeWindow.shown(offset: offset, viewport: viewport, above: hidesAbove, below: hidesBelow,
                                                  guards: guards) : nil
        ScrollView {
            content
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
                .background(GeometryReader { p in
                    Color.clear.preference(key: ContentTopKey.self, value: p.frame(in: .named(Self.space)).minY)
                })
                .coordinateSpace(name: EdgeWindow.space)
                .onPreferenceChange(EdgeGuardKey.self) { found in
                    if wholeLines { guards = found }
                }
        }
        .coordinateSpace(name: Self.space)
        // At rest the room between the strips starts at a whole line or control (`EdgeWindow.restingOffset`).
        .scrollTargetBehavior(EdgeSnap(guards: wholeLines ? guards : []))
        .onPreferenceChange(ContentTopKey.self) { top in
            if #unavailable(iOS 18) { offset = max(0, -top) }
        }
        .scrollOffset($offset)
        .scrollBounceBehavior(.basedOnSize)
        .scrollIndicators(.hidden)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { viewport = $0 }
        .mask(alignment: .top) {
            if wholeLines {
                if let shown {
                    VStack(spacing: 0) {
                        Color.clear.frame(height: shown.lowerBound)
                        Color.black.frame(height: shown.upperBound - shown.lowerBound)
                        Spacer(minLength: 0)
                    }
                } else {
                    Color.black
                }
            } else {
                LinearGradient(stops: [
                    .init(color: hidesAbove ? .clear : .black, location: 0),
                    .init(color: .black, location: min(0.5, Self.fade / max(viewport, 1))),
                    .init(color: .black, location: 1 - min(0.5, Self.fade / max(viewport, 1))),
                    .init(color: hidesBelow ? .clear : .black, location: 1),
                ], startPoint: .top, endPoint: .bottom)
            }
        }
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

private extension View {
    /// Where the content has scrolled to, as the system reports it where it can (iOS 18 and later); on
    /// iOS 17 the content's own frame in the region says it (`ContentTopKey`).
    @ViewBuilder func scrollOffset(_ offset: Binding<CGFloat>) -> some View {
        if #available(iOS 18, *) {
            onScrollGeometryChange(for: CGFloat.self) { max(0, $0.contentOffset.y + $0.contentInsets.top) } action: { _, new in
                offset.wrappedValue = new
            }
        } else {
            self
        }
    }
}
