import SwiftUI

/// Which part of a `wholeLines` region shows at one scroll position: the room between the arrows'
/// strips, moved inward off any line or control it would cut. Pure arithmetic, so it is unit-tested.
enum EdgeWindow {
    /// The content's own coordinate space, in which lines and controls report where they are.
    static let space = "edge-cued-content"
    /// The strip a hiding edge keeps for its arrow (14 pt) and nothing else.
    static let band: CGFloat = 16

    /// In the region's coordinates; nil when nothing is hidden, so everything is drawn.
    static func shown(offset: CGFloat, viewport: CGFloat, above: Bool, below: Bool,
                      guards: [ClosedRange<CGFloat>]) -> ClosedRange<CGFloat>? {
        guard viewport > 0, above || below else { return nil }
        let plainTop = above ? band : 0
        let plainBottom = max(plainTop, below ? viewport - band : viewport)
        let top = above ? clear(below: offset + plainTop, guards) - offset : plainTop
        let bottom = below ? clear(above: offset + plainBottom, guards) - offset : plainBottom
        // One line or control taller than the room between the strips: show that room, rather than nothing.
        guard bottom - top >= 1 else { return plainTop...plainBottom }
        return top...bottom
    }

    /// Where a scroll comes to rest near `offset`: either end, or where the room below the top strip
    /// starts at the top of a line or control. Resting anywhere else could leave the room between the
    /// strips holding only the gap between two of them (a card's bare surface), at the 80 pt floor.
    static func restingOffset(near offset: CGFloat, maxOffset: CGFloat, guards: [ClosedRange<CGFloat>]) -> CGFloat {
        guard !guards.isEmpty, maxOffset > 0, offset > 0, offset < maxOffset else { return min(max(offset, 0), max(maxOffset, 0)) }
        let stops = [0, maxOffset] + guards.map { $0.lowerBound - band }.filter { $0 > 0 && $0 < maxOffset }
        return stops.min { abs($0 - offset) < abs($1 - offset) } ?? offset
    }

    /// The first place at or below `y` that is inside no line or control.
    static func clear(below y: CGFloat, _ guards: [ClosedRange<CGFloat>]) -> CGFloat {
        var y = y
        var moved = true
        while moved {
            moved = false
            for g in guards where g.lowerBound < y && y < g.upperBound { y = g.upperBound; moved = true }
        }
        return y
    }

    /// The last place at or above `y` that is inside no line or control.
    static func clear(above y: CGFloat, _ guards: [ClosedRange<CGFloat>]) -> CGFloat {
        var y = y
        var moved = true
        while moved {
            moved = false
            for g in guards where g.lowerBound < y && y < g.upperBound { y = g.lowerBound; moved = true }
        }
        return y
    }

    /// A text block's lines, each with a point of margin: `lineSpacing` is the room SwiftUI adds between
    /// lines (`TypeRoleModifier`), so a block of n lines is n lines and n − 1 spacings tall.
    static func lines(top: CGFloat, height: CGFloat, line: CGFloat, spacing: CGFloat) -> [ClosedRange<CGFloat>] {
        guard height > 0, line > 0 else { return [] }
        let count = max(1, Int(((height + spacing) / (line + spacing)).rounded()))
        let pitch = (height + spacing) / CGFloat(count)
        let box = max(1, pitch - spacing)
        return (0..<count).map { k in
            let y = top + CGFloat(k) * pitch
            return (y - 1)...(y + box + 1)
        }
    }
}

/// A `wholeLines` region comes to rest at `EdgeWindow.restingOffset`. With no guards (any other
/// region) it changes nothing.
struct EdgeSnap: ScrollTargetBehavior {
    var guards: [ClosedRange<CGFloat>]

    func updateTarget(_ target: inout ScrollTarget, context: TargetContext) {
        guard !guards.isEmpty else { return }
        let maxOffset = max(0, context.contentSize.height - context.containerSize.height)
        target.rect.origin.y = EdgeWindow.restingOffset(near: target.rect.minY, maxOffset: maxOffset, guards: guards)
    }
}

/// The lines and controls inside a `wholeLines` region, in its content's coordinates.
struct EdgeGuardKey: PreferenceKey {
    static let defaultValue: [ClosedRange<CGFloat>] = []
    static func reduce(value: inout [ClosedRange<CGFloat>], nextValue: () -> [ClosedRange<CGFloat>]) { value += nextValue() }
}

extension View {
    /// Text in `role`: a `wholeLines` region's edge falls between its lines, never through one.
    func edgeGuardLines(_ role: Typography.Role) -> some View { modifier(EdgeGuardLines(role: role)) }
    /// A control or a row of them: a `wholeLines` region shows it whole or not at all.
    func edgeGuardBlock() -> some View {
        background(GeometryReader { p in
            let f = p.frame(in: .named(EdgeWindow.space))
            Color.clear.preference(key: EdgeGuardKey.self, value: [(f.minY - 1)...(f.maxY + 1)])
        })
    }
}

struct EdgeGuardLines: ViewModifier {
    let role: Typography.Role
    @Environment(\.dynamicTypeSize) private var size

    func body(content: Content) -> some View {
        // The same font and spacing `type(role)` sets.
        let font = Typography.uiFont(role, size)
        let spacing = role.lineHeight.map { max(0, $0 * font.pointSize - font.lineHeight) } ?? 0
        content.background(GeometryReader { p in
            let f = p.frame(in: .named(EdgeWindow.space))
            Color.clear.preference(key: EdgeGuardKey.self,
                                   value: EdgeWindow.lines(top: f.minY, height: f.height, line: font.lineHeight, spacing: spacing))
        })
    }
}
