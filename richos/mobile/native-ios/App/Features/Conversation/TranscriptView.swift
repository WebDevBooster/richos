import SwiftUI
import UIKit
import RichOSCore

/// The conversation list. It follows the newest message unless the reader scrolls up, keeps
/// following through growing replies, keyboard and composer changes, and resumes following on every
/// send (PRD §5; round-12 NOTES "What an engineer should know").
///
/// Ledger §2.8 M2: `BottomAnchoredTranscriptCollectionView` is T3's, adopted as-is (below, with its
/// attribution); the coordinator's follow and prepend rules copy T3's design
/// (`ThreadDetailView.swift:1957-2108`, `:2245-2286`) with RichOS's addition: a message of yours
/// arriving at the end always resumes following. A virtualized `UICollectionView`, not a paginated
/// list: older history loads in chunks as the reader nears the top (standing rule: no pagination).
struct TranscriptView: UIViewRepresentable {
    let transcript: ScreenModel.Transcript
    let palette: Palette
    let topInset: CGFloat
    let bottomInset: CGFloat
    let calendar: Calendar
    let now: Date
    /// Bumped by the Latest pill; each new value jumps to the newest message and resumes following.
    let jumpToken: Int
    let send: (Intent) -> Void
    let onShowsLatest: (Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> BottomAnchoredTranscriptCollectionView {
        let layout = UICollectionViewCompositionalLayout { _, environment in
            let size = NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: .estimated(64))
            let item = NSCollectionLayoutItem(layoutSize: size)
            let group = NSCollectionLayoutGroup.vertical(layoutSize: size, subitems: [item])
            let section = NSCollectionLayoutSection(group: group)
            section.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 12, bottom: 0, trailing: 12)
            _ = environment
            return section
        }
        let view = BottomAnchoredTranscriptCollectionView(frame: .zero, collectionViewLayout: layout)
        view.backgroundColor = .clear
        view.contentInsetAdjustmentBehavior = .always
        view.showsVerticalScrollIndicator = false
        view.keyboardDismissMode = .interactive
        view.alwaysBounceVertical = true
        view.accessibilityIdentifier = "conversation.list"
        view.delegate = context.coordinator
        context.coordinator.attach(to: view)
        return view
    }

    func updateUIView(_ view: BottomAnchoredTranscriptCollectionView, context: Context) {
        let c = context.coordinator
        c.parent = self
        view.onShowsLatest = onShowsLatest
        let insets = UIEdgeInsets(top: topInset, left: 0, bottom: bottomInset, right: 0)
        view.setViewportInsets(insets)
        c.apply(TranscriptItem.build(transcript, calendar: calendar, now: now), to: view,
                wantsFollowing: transcript.following, palette: palette)
        if jumpToken != c.lastJumpToken {
            c.lastJumpToken = jumpToken
            view.jumpToLatest()
        }
    }

    // MARK: Coordinator — T3's follow and prepend design, in RichOS's code

    @MainActor
    final class Coordinator: NSObject, UICollectionViewDelegate {
        enum Section { case main }

        var parent: TranscriptView?
        var lastJumpToken = 0
        private var dataSource: UICollectionViewDiffableDataSource<Section, String>?
        private var items: [String: TranscriptItem] = [:]
        private var orderedIDs: [String] = []
        private var loaded = false
        private var freshIDs: Set<String> = []
        private var askedForOlderAt: Int?
        private var lastPalette: Palette?
        private var restoredAnchor = false

        func attach(to view: UICollectionView) {
            let registration = UICollectionView.CellRegistration<UICollectionViewCell, String> { [weak self] cell, _, id in
                guard let self, let parent = self.parent, let item = self.items[id] else { return }
                let fresh = self.freshIDs.remove(id) != nil
                let width = max(0, view.bounds.width - 24)
                cell.contentConfiguration = UIHostingConfiguration {
                    TranscriptItemView(item: item, width: width, calendar: parent.calendar, send: parent.send)
                        .modifier(EnterOnce(active: fresh))
                        .environment(\.palette, parent.palette)
                }
                .margins(.all, 0)
                .minSize(width: 0, height: 0)
                cell.backgroundConfiguration = .clear()
            }
            dataSource = UICollectionViewDiffableDataSource<Section, String>(collectionView: view) { view, indexPath, id in
                view.dequeueConfiguredReusableCell(using: registration, for: indexPath, item: id)
            }
        }

        func apply(_ newItems: [TranscriptItem], to view: BottomAnchoredTranscriptCollectionView, wantsFollowing: Bool,
                   palette: Palette) {
            guard let dataSource else { return }
            let newIDs = newItems.map(\.id)
            var changed: [String] = []
            var byID: [String: TranscriptItem] = [:]
            // A theme change redraws every row: hosted cells hold the palette they were configured with.
            let repaint = lastPalette != nil && lastPalette != palette
            lastPalette = palette
            for item in newItems {
                byID[item.id] = item
                if let old = items[item.id], old != item || repaint { changed.append(item.id) }
            }
            let previousIDs = orderedIDs
            let idsChanged = newIDs != previousIDs
            if !idsChanged && changed.isEmpty { return }

            let isInitialLoad = !loaded
            let wasNearBottom = isNearBottom(view)
            let lastIDChanged = previousIDs.last != newIDs.last
            // RichOS: a message of yours newly at the end means you just sent: resume following.
            var sentByMe = false
            if lastIDChanged, !isInitialLoad, case .row(let row, _, _)? = newItems.last, row.author == .me,
               !previousIDs.contains(row.listID) {
                sentByMe = true
            }
            let prepended = !isInitialLoad && newIDs.count > previousIDs.count
                && Array(newIDs.suffix(previousIDs.count)) == previousIDs
            // T3: self-sizing cells can grow before the next layout restores the bottom offset; keep
            // following until an actual drag releases it.
            let shouldFollow: Bool
            if isInitialLoad {
                shouldFollow = wantsFollowing
            } else {
                shouldFollow = sentByMe || wasNearBottom || view.maintainsBottomAnchor
            }
            let remembered = parent?.transcript.readingAnchor
            let savedAnchor = !restoredAnchor && !wantsFollowing ? remembered.flatMap { value in
                newIDs.contains(value.messageID) ? VisibleAnchor(id: value.messageID, offsetFromViewportTop: value.offset) : nil
            } : nil
            if savedAnchor != nil { restoredAnchor = true }
            let anchor = savedAnchor ?? (!shouldFollow && prepended ? visibleAnchor(in: view) : nil)

            if !isInitialLoad {
                for id in newIDs where !previousIDs.contains(id) && !id.hasPrefix("~") { freshIDs.insert(id) }
            }
            items = byID
            orderedIDs = newIDs
            view.maintainsBottomAnchor = shouldFollow
            if isInitialLoad, !wantsFollowing {
                // At the very top when the loading line or the beginning is showing (round 12 opens
                // those at scrollTop 0); a little way down otherwise (`conv-scrolled`: 40).
                let atTop = newIDs.first == "~loading" || newIDs.first == "~beginning"
                view.startsAwayFromBottom(below: atTop ? 0 : 40)
            }
            loaded = true

            var snapshot = NSDiffableDataSourceSnapshot<Section, String>()
            snapshot.appendSections([.main])
            snapshot.appendItems(newIDs, toSection: .main)
            let reconfigure = changed.filter { newIDs.contains($0) }
            if !reconfigure.isEmpty { snapshot.reconfigureItems(reconfigure) }
            if !byID.keys.contains(where: { $0 == "~loading" }) { askedForOlderAt = nil }

            dataSource.apply(snapshot, animatingDifferences: false) { [weak self, weak view] in
                guard let self, let view else { return }
                DispatchQueue.main.async {
                    // T3: a streaming delta lands every ~80 ms. Never fight a finger on the list.
                    let userIsScrolling = view.isTracking || view.isDragging || view.isDecelerating
                    if view.maintainsBottomAnchor, !userIsScrolling {
                        self.scrollToBottom(view, animated: !isInitialLoad && lastIDChanged)
                    } else if !userIsScrolling, let anchor {
                        self.restore(anchor, in: view)
                    }
                    // RichOS: PRD §7's launch boundary, after the first load's final positioning.
                    if isInitialLoad { view.markInitialPosition() }
                }
            }
        }

        private struct VisibleAnchor {
            let id: String
            let offsetFromViewportTop: CGFloat
        }

        private func visibleAnchor(in view: UICollectionView) -> VisibleAnchor? {
            guard let dataSource else { return nil }
            for indexPath in view.indexPathsForVisibleItems.sorted() {
                guard let id = dataSource.itemIdentifier(for: indexPath), !id.hasPrefix("~"),
                      let attributes = view.layoutAttributesForItem(at: indexPath) else { continue }
                return VisibleAnchor(id: id, offsetFromViewportTop: attributes.frame.minY - view.contentOffset.y)
            }
            return nil
        }

        private func restore(_ anchor: VisibleAnchor, in view: UICollectionView) {
            guard let dataSource else { return }
            view.layoutIfNeeded()
            guard let indexPath = dataSource.indexPath(for: anchor.id),
                  let attributes = view.layoutAttributesForItem(at: indexPath) else { return }
            let minimumY = -view.adjustedContentInset.top
            let maximumY = max(minimumY, view.contentSize.height - view.bounds.height + view.adjustedContentInset.bottom)
            let targetY = min(maximumY, max(minimumY, attributes.frame.minY - anchor.offsetFromViewportTop))
            (view as? BottomAnchoredTranscriptCollectionView)?.maintainsBottomAnchor = false
            view.setContentOffset(CGPoint(x: view.contentOffset.x, y: targetY), animated: false)
        }

        private func isNearBottom(_ view: UICollectionView) -> Bool {
            let visibleBottom = view.contentOffset.y + view.bounds.height - view.adjustedContentInset.bottom
            return view.contentSize.height - visibleBottom < TranscriptViewportGeometry.followThreshold
        }

        private func scrollToBottom(_ view: BottomAnchoredTranscriptCollectionView, animated: Bool) {
            view.layoutIfNeeded()
            let geometry = TranscriptViewportGeometry(
                contentHeight: view.contentSize.height, viewportHeight: view.bounds.height,
                topInset: view.adjustedContentInset.top, bottomInset: view.adjustedContentInset.bottom)
            view.setContentOffset(CGPoint(x: view.contentOffset.x, y: geometry.bottomOffset), animated: animated)
            view.maintainsBottomAnchor = true
        }

        // MARK: UIScrollViewDelegate (T3's drag rules)

        func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
            (scrollView as? BottomAnchoredTranscriptCollectionView)?.maintainsBottomAnchor = false
        }

        func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
            guard !decelerate else { return }
            updateBottomAnchor(for: scrollView)
        }

        func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
            updateBottomAnchor(for: scrollView)
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            // Chunked loading, never pagination: near the top, ask for the next older chunk once.
            guard scrollView.isDragging || scrollView.isDecelerating,
                  scrollView.contentOffset.y + scrollView.adjustedContentInset.top < 240,
                  let first = orderedIDs.first, first != "~beginning", askedForOlderAt == nil else { return }
            askedForOlderAt = orderedIDs.count
            parent?.send(.loadOlder)
        }

        private func updateBottomAnchor(for scrollView: UIScrollView) {
            guard let view = scrollView as? BottomAnchoredTranscriptCollectionView else { return }
            view.maintainsBottomAnchor = isNearBottom(view)
            parent?.send(.setFollowing(view.maintainsBottomAnchor))
            if !view.maintainsBottomAnchor, let anchor = visibleAnchor(in: view) {
                restoredAnchor = true
                parent?.send(.rememberReading(ReadingAnchor(messageID: anchor.id, offset: anchor.offsetFromViewportTop)))
            }
        }
    }
}

/// Round 12's row entrance, played only for an entry that just arrived (not when a cell is reused on
/// scroll).
private struct EnterOnce: ViewModifier {
    let active: Bool
    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        let p: CGFloat = (!active || shown || reduceMotion) ? 1 : 0
        content
            .opacity(p)
            .scaleEffect(0.96 + 0.04 * p, anchor: .bottom)
            .offset(y: 10 * (1 - p))
            .onAppear {
                guard active, !shown else { return }
                withAnimation(Motion.rowIn) { shown = true }
            }
    }
}

// Adapted from T3 Code (https://github.com/pingdotgg/t3code) at 2eb6a53343ffb4ce747617746ee85433115ad18f,
// apps/swift-ios/Features/Chat/ThreadDetailView.swift:2637-2740, MIT License, Copyright (c) 2026 T3 Tools Inc.
// Adoption ledger §2.8 M2: ADOPT AS-IS. RichOS changes, each marked "RichOS:" below: T3's own
// jump-to-bottom UIButton is replaced by a callback, because round 12 draws its Latest pill in
// SwiftUI above the composer; `startsAwayFromBottom()` lets a restored reading position open where
// it was; T3's colors are gone.
/// Self-sizing hosted Markdown can change the transcript height after a snapshot finishes,
/// while presenting the keyboard changes the viewport without changing the content at all.
/// Preserve the visual bottom only while the reader is already following the latest turn.
final class BottomAnchoredTranscriptCollectionView: UICollectionView {
    var maintainsBottomAnchor = false
    /// RichOS: replaces T3's `bottomButton`; called when the Latest pill should appear or go.
    var onShowsLatest: ((Bool) -> Void)?

    private var requestedViewportInsets: UIEdgeInsets?

    /// UIKit owns safe-area adjustment for hosted cells. Subtract its contribution from
    /// our header/composer spacing so adjustedContentInset still describes the same viewport.
    func setViewportInsets(_ insets: UIEdgeInsets) {
        requestedViewportInsets = insets
        updateViewportInsets()
    }

    override func safeAreaInsetsDidChange() {
        super.safeAreaInsetsDidChange()
        updateViewportInsets()
    }

    private func updateViewportInsets() {
        guard let desired = requestedViewportInsets else { return }
        let safe = safeAreaInsets
        let raw = UIEdgeInsets(top: desired.top - safe.top, left: desired.left - safe.left,
                               bottom: desired.bottom - safe.bottom, right: desired.right - safe.right)
        if contentInset != raw { contentInset = raw }
    }

    private var lastLaidOutGeometry: TranscriptViewportGeometry?
    private var isRestoringBottomAnchor = false
    private var needsInitialBottomPosition = true
    private var showsLatest = false

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil, needsInitialBottomPosition {
            maintainsBottomAnchor = true
            setNeedsLayout()
        }
    }

    /// RichOS: open scrolled up (a restored reading position, `conv-scrolled`) instead of at the bottom.
    func startsAwayFromBottom(below top: CGFloat) {
        needsInitialBottomPosition = false
        maintainsBottomAnchor = false
        pendingAwayPosition = true
        awayOffset = top
        setNeedsLayout()
    }
    private var pendingAwayPosition = false
    private var awayOffset: CGFloat = 40

    /// RichOS: `viewport-ready` (`ReadinessMarks`) once the first load's saved position is applied:
    /// laid out in a window with its bottom or away position no longer pending. If it is not settled
    /// yet, the layout that settles it marks instead. It only observes: it never forces a layout.
    /// Once per view; no timer.
    private var initialPosition: InitialPositionMark = .notRequested
    private enum InitialPositionMark { case notRequested, waiting, marked }

    func markInitialPosition() {
        guard initialPosition == .notRequested else { return }
        initialPosition = .waiting
        markInitialPositionIfSettled()
    }

    private func markInitialPositionIfSettled() {
        guard initialPosition == .waiting, window != nil, bounds.height > 0, !pendingAwayPosition,
              !needsInitialBottomPosition || contentSize.height == 0 else { return }
        initialPosition = .marked
        ReadinessMarks.viewportReady()
    }

    /// RichOS: T3's `jumpToBottom` target, called by the Latest pill.
    func jumpToLatest() {
        layoutIfNeeded()
        maintainsBottomAnchor = true
        let geometry = viewportGeometry
        // Jump directly in long threads instead of rendering every intervening
        // message. Keep keyboard focus and follow subsequent streamed output.
        setContentOffset(CGPoint(x: contentOffset.x, y: geometry.bottomOffset), animated: false)
        updateBottomButton(geometry)
    }

    private var viewportGeometry: TranscriptViewportGeometry {
        TranscriptViewportGeometry(
            contentHeight: contentSize.height,
            viewportHeight: bounds.height,
            topInset: adjustedContentInset.top,
            bottomInset: adjustedContentInset.bottom
        )
    }

    private func updateBottomButton(_ geometry: TranscriptViewportGeometry) {
        let hidden = needsInitialBottomPosition || bounds.height < 64
            || !geometry.showsScrollToBottom(at: contentOffset.y)
        if showsLatest == hidden {  // RichOS: a callback instead of `bottomButton.isHidden`.
            showsLatest = !hidden
            onShowsLatest?(showsLatest)
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()

        let geometry = viewportGeometry
        defer {
            lastLaidOutGeometry = geometry
            updateBottomButton(geometry)
            markInitialPositionIfSettled()
        }

        if pendingAwayPosition, bounds.height > 0, contentSize.height > 0 {
            // RichOS: a reading position a little below the top of what is loaded (round 12 opens
            // `conv-scrolled` 40 pt down).
            pendingAwayPosition = false
            contentOffset = CGPoint(x: contentOffset.x, y: min(geometry.bottomOffset, -adjustedContentInset.top + awayOffset))
            return
        }

        let isInteracting = isTracking || isDragging || isDecelerating || isRestoringBottomAnchor
        if needsInitialBottomPosition, isInteracting {
            needsInitialBottomPosition = false
        }
        if needsInitialBottomPosition, window != nil, bounds.height > 0, contentSize.height > 0 {
            needsInitialBottomPosition = false
            maintainsBottomAnchor = true
            isRestoringBottomAnchor = true
            contentOffset = CGPoint(x: contentOffset.x, y: geometry.bottomOffset)
            isRestoringBottomAnchor = false
            return
        }

        guard let bottomY = geometry.restoredBottomOffset(
            after: lastLaidOutGeometry,
            maintainsBottomAnchor: maintainsBottomAnchor,
            isInteracting: isInteracting
        ) else {
            return
        }
        guard abs(contentOffset.y - bottomY) > 0.5 else { return }

        isRestoringBottomAnchor = true
        contentOffset = CGPoint(x: contentOffset.x, y: bottomY)
        isRestoringBottomAnchor = false
    }
}
