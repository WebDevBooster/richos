import Foundation
import Testing
@testable import RichOSNative

/// R2 at the floor (iPhone re-walk 4, light-38): the cards' region rested with a line cut at its top
/// edge and the "More above" arrow over it. Which part of a `wholeLines` region shows is arithmetic.
@Suite("Edge window")
struct EdgeWindowTests {
    /// The card text of the re-walk's pose: 16 pt Inter at line height 1.35 is a 21.6 pt pitch.
    private static let lines = EdgeWindow.lines(top: 208, height: 62.6, line: 19.36, spacing: 2.24)

    @Test func aBlockOfThreeLinesIsThreeLines() {
        #expect(Self.lines.count == 3)
        #expect(abs(Self.lines[1].lowerBound - (208 + 21.6 - 1)) < 0.05)
        #expect(abs(Self.lines[2].upperBound - (208 + 62.6 + 1)) < 0.05)
    }

    /// The re-walk's numbers, in content coordinates: the region's top edge at 259 cut the line at
    /// 251.2–270.6. The window starts after the arrow's strip and after that whole line.
    @Test func theTopEdgeMovesPastTheLineItWouldCut() throws {
        let offset: CGFloat = 259 - 16
        let shown = try #require(EdgeWindow.shown(offset: offset, viewport: 80, above: true, below: false, guards: Self.lines))
        #expect(shown.lowerBound >= EdgeWindow.band)
        let top = offset + shown.lowerBound
        #expect(!Self.lines.contains { $0.lowerBound < top && top < $0.upperBound })
        #expect(top >= Self.lines[2].upperBound - 0.01)
        #expect(shown.upperBound == 80)
    }

    @Test func theBottomEdgeMovesAboveTheLineItWouldCut() throws {
        let shown = try #require(EdgeWindow.shown(offset: 190, viewport: 60, above: false, below: true, guards: Self.lines))
        let bottom = 190 + shown.upperBound
        #expect(shown.upperBound <= 60 - EdgeWindow.band)
        #expect(!Self.lines.contains { $0.lowerBound < bottom && bottom < $0.upperBound })
    }

    @Test func aButtonIsWholeOrNotShown() throws {
        let button: ClosedRange<CGFloat> = 99...145
        let shown = try #require(EdgeWindow.shown(offset: 0, viewport: 120, above: false, below: true, guards: [button]))
        #expect(shown.upperBound <= button.lowerBound)
    }

    /// At rest the room below the top strip starts at the top of a line or control, or the region sits
    /// at either end: never between two of them, where an 80 pt region showed only a card's bare surface.
    @Test func aScrollRestsWithAWholeLineAtTheTopOfTheRoom() {
        let maxOffset: CGFloat = 200
        let lines = Self.lines.map { ($0.lowerBound - 100)...($0.upperBound - 100) }
        // Lines start at 107, 128.6 and 150.2; a scroll ending at 120 rests where the second starts the room.
        let rest = EdgeWindow.restingOffset(near: 120, maxOffset: maxOffset, guards: lines)
        #expect(abs(rest + EdgeWindow.band - lines[1].lowerBound) < 0.01)
        let shown = EdgeWindow.shown(offset: rest, viewport: 52 + 2 * EdgeWindow.band, above: true, below: true, guards: lines)
        #expect(shown.map { $0.upperBound - $0.lowerBound > 20 } == true)
        #expect(EdgeWindow.restingOffset(near: 3, maxOffset: maxOffset, guards: lines) == 0)
        #expect(EdgeWindow.restingOffset(near: 198, maxOffset: maxOffset, guards: []) == 198)
        #expect(EdgeWindow.restingOffset(near: 197, maxOffset: maxOffset, guards: [0...10]) == maxOffset)
    }

    @Test func nothingHiddenMasksNothing() {
        #expect(EdgeWindow.shown(offset: 0, viewport: 300, above: false, below: false, guards: Self.lines) == nil)
    }

    /// A single line taller than the room between the strips: the room shows, never nothing.
    @Test func aLineTallerThanTheRoomStillShowsTheRoom() throws {
        let shown = try #require(EdgeWindow.shown(offset: 10, viewport: 50, above: true, below: true, guards: [0...200]))
        #expect(shown == EdgeWindow.band...(50 - EdgeWindow.band))
    }
}
