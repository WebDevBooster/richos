import Foundation
import Testing
import UIKit
@testable import RichOSNative

/// The transcript's launch path: it opens at the newest rows without first laying out the oldest.
/// Measured on the test iPhone (2026-10-02, 100 seeded rows): the list created cells for rows 0-2 at
/// the top, then jumped to rows 91-99 at the bottom, about 118 ms from the scene becoming active to
/// the useful frame. The list here is built exactly as `makeUIView` builds it and fed the order
/// SwiftUI uses: the first snapshot before the list has a window or a size, then the window.
@Suite("Transcript launch")
@MainActor
struct TranscriptLaunchTests {
    @Test func launchCreatesCellsOnlyForTheRowsOnScreen() async throws {
        let launch = try await Self.launch(rows: 100)
        let visible = Set(launch.view.indexPathsForVisibleItems.map(\.item))
        let unseen = Set(launch.recorder.displayed).subtracting(visible)
        let last = launch.view.numberOfItems(inSection: 0) - 1
        #expect(visible.contains(last), "the newest row is on screen")
        #expect(abs(launch.view.contentOffset.y - launch.bottomOffset) < 0.5, "the list is at its bottom")
        #expect(unseen.isEmpty,
                "cells were created for rows the reader does not see: \(unseen.sorted()); creation order \(launch.recorder.displayed)")
    }

    @Test func aShortConversationStillOpensWhole() async throws {
        let launch = try await Self.launch(rows: 3)
        let count = launch.view.numberOfItems(inSection: 0)
        #expect(Set(launch.view.indexPathsForVisibleItems.map(\.item)) == Set(0..<count))
        #expect(abs(launch.view.contentOffset.y - launch.bottomOffset) < 0.5)
    }

    // MARK: Harness

    struct Launch {
        let view: BottomAnchoredTranscriptCollectionView
        let recorder: DisplayRecorder
        let window: UIWindow
        var bottomOffset: CGFloat {
            TranscriptViewportGeometry(contentHeight: view.contentSize.height, viewportHeight: view.bounds.height,
                                       topInset: view.adjustedContentInset.top,
                                       bottomInset: view.adjustedContentInset.bottom).bottomOffset
        }
    }

    /// The iPhone SE's screen, the perf condition's conversation shape (`perf/condition.py`): your short
    /// question, Rich's paragraph, alternating, three minutes apart.
    static func launch(rows: Int) async throws -> Launch {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let start: Int64 = 1_790_000_000_000
        let model = (0..<rows).map { row($0, start: start) }
        let transcript = ScreenModel.Transcript(rows: model, reachedBeginning: true, following: true)
        let now = Date(timeIntervalSince1970: TimeInterval(start) / 1000 + 86_400)
        let parent = TranscriptView(transcript: transcript, palette: .sovereign, topInset: 120, bottomInset: 110,
                                    calendar: calendar, now: now, jumpToken: 0, send: { _ in }, onShowsLatest: { _ in })
        let coordinator = TranscriptView.Coordinator()
        coordinator.parent = parent
        let view = TranscriptView.makeCollectionView(coordinator: coordinator)
        let recorder = DisplayRecorder(target: coordinator)
        view.delegate = recorder
        view.onShowsLatest = { _ in }
        view.setViewportInsets(UIEdgeInsets(top: parent.topInset, left: 0, bottom: parent.bottomInset, right: 0))
        coordinator.apply(TranscriptItem.build(transcript, calendar: calendar, now: now), to: view,
                          wantsFollowing: true, palette: .sovereign)

        let controller = UIViewController()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 375, height: 667))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        view.frame = controller.view.bounds
        controller.view.addSubview(view)
        // Layout passes and the snapshot's completion (a main-queue hop), until nothing moves.
        for _ in 0..<12 {
            view.layoutIfNeeded()
            try await Task.sleep(nanoseconds: 15_000_000)
        }
        withExtendedLifetime(recorder) {}
        return Launch(view: view, recorder: recorder, window: window)
    }

    static let reply = "Here is what I found. The quarterly numbers came in slightly above plan, and the two open "
        + "questions from Tuesday are answered in the note I left on your desk. Nothing needs you today; "
        + "I will flag anything that changes before your 3 PM."

    static func row(_ i: Int, start: Int64) -> ScreenModel.Row {
        let mine = i % 2 == 0
        let text: String = mine ? "Perf probe \(i / 2 + 1): what is on my plate this afternoon?" : "\(reply) (\(i / 2 + 1))"
        let author: ScreenModel.Row.Author = mine ? .me : .rich
        let delivery: ScreenModel.Row.Delivery? = mine ? .sent : nil
        return ScreenModel.Row(id: "row-\(i)", author: author, body: .text(text),
                               sentAt: start + Int64(i) * 180_000, delivery: delivery)
    }
}

/// Records each cell the list puts on screen and forwards everything else to the coordinator.
@MainActor
final class DisplayRecorder: NSObject, UICollectionViewDelegate {
    let target: NSObject
    private(set) var displayed: [Int] = []
    init(target: NSObject) { self.target = target }

    override func responds(to aSelector: Selector!) -> Bool {
        super.responds(to: aSelector) || target.responds(to: aSelector)
    }

    override func forwardingTarget(for aSelector: Selector!) -> Any? {
        target.responds(to: aSelector) ? target : nil
    }

    func collectionView(_ collectionView: UICollectionView, willDisplay cell: UICollectionViewCell,
                        forItemAt indexPath: IndexPath) {
        displayed.append(indexPath.item)
    }
}
