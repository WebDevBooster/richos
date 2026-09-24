// Adapted from T3 Code (https://github.com/pingdotgg/t3code) at 2eb6a53343ffb4ce747617746ee85433115ad18f,
// apps/swift-ios/Tests/FeatureTests/TranscriptViewportGeometryTests.swift, MIT License,
// Copyright (c) 2026 T3 Tools Inc. Adoption ledger §2.8 M2: the tests travel with the adopted code.
// RichOS changes: the Latest threshold is round 12's 80 pt (T3: 120), so the boundary numbers move by
// 40; T3's jump-to-bottom UIButton is RichOS's `onShowsLatest` callback and `jumpToLatest()`; T3's
// back-swipe tests are not carried (RichOS has one conversation surface and no back navigation). RichOS's own
// rule, resume following on every send, is proven on the real screen by InteractionTests.
import CoreGraphics
import Testing
import UIKit
@testable import RichOSNative

@Suite("Transcript viewport anchoring")
struct TranscriptViewportGeometryTests {
    @Test func latestUsesTheVisibleViewportIncludingKeyboardInsets() {
        let geometry = TranscriptViewportGeometry(contentHeight: 1_200, viewportHeight: 400, topInset: 20, bottomInset: 100)
        #expect(geometry.showsScrollToBottom(at: 820))
        #expect(!geometry.showsScrollToBottom(at: 821))
        #expect(!geometry.showsScrollToBottom(at: 900))
        let short = TranscriptViewportGeometry(contentHeight: 100, viewportHeight: 400, topInset: 20, bottomInset: 0)
        #expect(!short.showsScrollToBottom(at: -20))
    }

    @Test @MainActor
    func transcriptOpensAtBottomAndLatestRestoresFollowing() throws {
        let layout = FixedTranscriptLayout()
        let view = BottomAnchoredTranscriptCollectionView(frame: .zero, collectionViewLayout: layout)
        var showsLatest = false
        view.onShowsLatest = { showsLatest = $0 }
        let dataSource = FixedTranscriptDataSource()
        defer { withExtendedLifetime(dataSource) {} }
        view.register(UICollectionViewCell.self, forCellWithReuseIdentifier: "message")
        view.dataSource = dataSource
        view.contentInsetAdjustmentBehavior = .never
        let controller = UIViewController()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 800))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        controller.view.addSubview(view)
        view.layoutIfNeeded()
        // The first snapshot can arrive before the destination has its final size.
        layout.height = 3_000
        view.reloadData()
        layout.invalidateLayout()
        view.frame = CGRect(x: 0, y: 0, width: 390, height: 600)
        view.layoutIfNeeded()
        #expect(view.contentOffset.y == 2_400)
        #expect(!showsLatest)

        view.maintainsBottomAnchor = false
        view.contentOffset.y = 500
        view.layoutIfNeeded()
        #expect(showsLatest)
        view.jumpToLatest()
        #expect(view.contentOffset.y == 2_400)
        #expect(view.maintainsBottomAnchor)
        #expect(!showsLatest)

        layout.height = 3_200
        layout.invalidateLayout()
        view.layoutIfNeeded()
        #expect(view.contentOffset.y == 2_600)
        view.frame.size.height = 350
        view.layoutIfNeeded()
        #expect(view.contentOffset.y == 2_850)
        #expect(!showsLatest)
    }

    @Test func firstLoadedTranscriptAnchorsToLatestMessage() {
        let empty = TranscriptViewportGeometry(contentHeight: 0, viewportHeight: 700, topInset: 0, bottomInset: 0)
        let loaded = TranscriptViewportGeometry(contentHeight: 1_200, viewportHeight: 700, topInset: 0, bottomInset: 0)
        #expect(loaded.restoredBottomOffset(after: empty, maintainsBottomAnchor: true, isInteracting: false) == 500)
    }

    @Test @MainActor
    func hostedTranscriptKeepsItsViewportWhenSafeAreaChanges() {
        let controller = UIViewController()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        let view = BottomAnchoredTranscriptCollectionView(
            frame: controller.view.bounds, collectionViewLayout: FixedTranscriptLayout())
        view.contentInsetAdjustmentBehavior = .always
        controller.view.addSubview(view)
        let requested = UIEdgeInsets(top: 138, left: 0, bottom: 114, right: 0)
        view.setViewportInsets(requested)

        for extra in [UIEdgeInsets.zero, UIEdgeInsets(top: 52, left: 8, bottom: 28, right: 8)] {
            controller.additionalSafeAreaInsets = extra
            controller.view.layoutIfNeeded()
            view.layoutIfNeeded()
            #expect(abs(view.adjustedContentInset.top - requested.top) < 0.5)
            #expect(abs(view.adjustedContentInset.bottom - requested.bottom) < 0.5)
            #expect(abs(view.adjustedContentInset.left - requested.left) < 0.5)
            #expect(abs(view.adjustedContentInset.right - requested.right) < 0.5)
        }
    }

    @Test func keyboardViewportChangeKeepsLatestMessageVisible() {
        let beforeKeyboard = TranscriptViewportGeometry(contentHeight: 1_200, viewportHeight: 700, topInset: 0, bottomInset: 0)
        let afterKeyboard = TranscriptViewportGeometry(contentHeight: 1_200, viewportHeight: 400, topInset: 0, bottomInset: 0)
        #expect(afterKeyboard.restoredBottomOffset(after: beforeKeyboard, maintainsBottomAnchor: true, isInteracting: false) == 800)
    }

    @Test func readerPositionIsUntouchedAwayFromLatestMessage() {
        let beforeKeyboard = TranscriptViewportGeometry(contentHeight: 1_200, viewportHeight: 700, topInset: 0, bottomInset: 0)
        let afterKeyboard = TranscriptViewportGeometry(contentHeight: 1_200, viewportHeight: 400, topInset: 0, bottomInset: 0)
        #expect(afterKeyboard.restoredBottomOffset(after: beforeKeyboard, maintainsBottomAnchor: false, isInteracting: false) == nil)
    }

    @Test func activeTranscriptGestureOwnsItsScrollPosition() {
        let before = TranscriptViewportGeometry(contentHeight: 1_200, viewportHeight: 700, topInset: 0, bottomInset: 0)
        let after = TranscriptViewportGeometry(contentHeight: 1_260, viewportHeight: 700, topInset: 0, bottomInset: 0)
        #expect(after.restoredBottomOffset(after: before, maintainsBottomAnchor: true, isInteracting: true) == nil)
    }
}

@MainActor
private final class FixedTranscriptLayout: UICollectionViewLayout {
    var height: CGFloat = 0
    override var collectionViewContentSize: CGSize { CGSize(width: 390, height: height) }
    override func layoutAttributesForItem(at indexPath: IndexPath) -> UICollectionViewLayoutAttributes? {
        let attributes = UICollectionViewLayoutAttributes(forCellWith: indexPath)
        attributes.frame = CGRect(x: 0, y: 0, width: 390, height: height)
        return attributes
    }
    override func layoutAttributesForElements(in rect: CGRect) -> [UICollectionViewLayoutAttributes]? {
        [layoutAttributesForItem(at: IndexPath(item: 0, section: 0))!]
    }
}

@MainActor
private final class FixedTranscriptDataSource: NSObject, UICollectionViewDataSource {
    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int { 1 }
    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        collectionView.dequeueReusableCell(withReuseIdentifier: "message", for: indexPath)
    }
}
