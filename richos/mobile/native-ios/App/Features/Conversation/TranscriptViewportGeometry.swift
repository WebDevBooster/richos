// Adapted from T3 Code (https://github.com/pingdotgg/t3code) at 2eb6a53343ffb4ce747617746ee85433115ad18f,
// apps/swift-ios/Features/Chat/ThreadDetailView.swift:2365-2401, MIT License, Copyright (c) 2026 T3 Tools Inc.
// Adoption ledger §2.8 M2: ADOPT AS-IS. RichOS changes, each marked below: the "away from the newest
// message" distance is round 12's 80 pt (round-12 NOTES.md "What an engineer should know") instead of
// T3's 120 pt, and it is a named constant because the list and the Latest pill must agree on it.
import CoreGraphics

struct TranscriptViewportGeometry: Equatable {
    /// RichOS: round 12 stops following, and shows the Latest pill, once the reader is more than 80 pt
    /// from the newest message. (T3: 120.)
    static let followThreshold: CGFloat = 80

    let contentHeight: CGFloat
    let viewportHeight: CGFloat
    let topInset: CGFloat
    let bottomInset: CGFloat

    var bottomOffset: CGFloat {
        max(-topInset, contentHeight - viewportHeight + bottomInset)
    }

    func showsScrollToBottom(at offset: CGFloat) -> Bool {
        viewportHeight > 0 && bottomOffset - offset >= Self.followThreshold  // RichOS: T3 wrote 120.
    }

    func restoredBottomOffset(
        after previous: Self?,
        maintainsBottomAnchor: Bool,
        isInteracting: Bool
    ) -> CGFloat? {
        guard maintainsBottomAnchor, !isInteracting else {
            return nil
        }

        guard let previous,
              previous.contentHeight > 0,
              previous.viewportHeight > 0 else {
            return contentHeight > 0 && viewportHeight > 0 ? bottomOffset : nil
        }

        let contentChanged = abs(contentHeight - previous.contentHeight) > 0.5
        let viewportChanged = abs(viewportHeight - previous.viewportHeight) > 0.5
            || abs(bottomInset - previous.bottomInset) > 0.5
        guard contentChanged || viewportChanged else { return nil }

        return bottomOffset
    }
}
