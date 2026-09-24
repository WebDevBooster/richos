import SwiftUI
import UIKit
import os
import RichOSCore

/// Release-safe points of interest. Static event names only, with no message or account data.
enum PerformanceMarks {
    static let log = OSLog(subsystem: "dev.richos.connect", category: .pointsOfInterest)
    static func record(_ event: String) {
        switch event {
        case "send-requested": os_signpost(.event, log: log, name: "send-requested")
        case "durable-queued": os_signpost(.event, log: log, name: "durable-queued")
        case "text-received": os_signpost(.event, log: log, name: "text-received")
        default: break
        }
    }
}

/// PRD §7's launch and return end marks, as three static events with no content. The measurement
/// tool (`mobile/perf/ios.py`) joins them to Core Animation's own commit signposts and to the
/// Frame Lifetimes presentation of that commit; these marks alone do not claim presentation.
///
/// - `viewport-ready`: the transcript applied its saved position (bottom, or the remembered reading
///   anchor) after its first load. Once per transcript view.
/// - `composer-ready`: the editable message field entered the hierarchy. A disabled composer shows
///   no field and never emits it.
/// - `input-ready`: the main run loop committed the turn that made both of those true while the
///   scene was active, and is about to wait for events, so a touch would be handled at once.
///   Emitted once for the launch, then once per return to the foreground.
///
/// Battery: no timer, no polling, no background work. `input-ready` is one non-repeating run-loop
/// observer, added only at those two transitions and invalidated by Core Foundation after it fires.
@MainActor
enum ReadinessMarks {
    private static var active = false
    private static var viewport = false
    private static var composer = false
    private static var launched = false

    static func viewportReady() {
        os_signpost(.event, log: PerformanceMarks.log, name: "viewport-ready")
        viewport = true
        launchIfReady()
    }

    static func composerReady() {
        os_signpost(.event, log: PerformanceMarks.log, name: "composer-ready")
        composer = true
        launchIfReady()
    }

    /// The scene's activity, from the same `scenePhase` the useful marker follows.
    static func setActive(_ now: Bool) {
        guard now != active else { return }
        active = now
        if now && launched {
            afterCommit()  // a return: the retained transcript and composer are already in place
        } else {
            launchIfReady()
        }
    }

    private static func launchIfReady() {
        guard active, viewport, composer, !launched else { return }
        launched = true
        afterCommit()
    }

    /// Core Animation commits at `beforeWaiting` with order 2,000,000; a larger order runs after
    /// that commit in the same run-loop turn.
    private static func afterCommit() {
        let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, false,
                                                          CFIndex(Int32.max)) { _, _ in
            os_signpost(.event, log: PerformanceMarks.log, name: "input-ready")
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
    }
}

/// The useful root has entered the render tree. One draw per revision, with no clock or polling.
/// Pair these markers with the platform's frame presentation trace, not with network completion.
struct UsefulFrameMarker: UIViewRepresentable {
    let active: Bool
    let revision: Revision
    struct Revision: Equatable { var count: Int; var last: Message?; var reply: ReplyActivity? }
    func makeUIView(context: Context) -> MarkerView { MarkerView() }
    func updateUIView(_ view: MarkerView, context: Context) {
        ReadinessMarks.setActive(active)
        if view.active != active || view.revision != revision {
            view.active = active
            if !active { view.leftForeground() }
            view.revision = revision
            if active { view.setNeedsDisplay() }
        }
    }
    final class MarkerView: UIView {
        var active = false
        var revision: Revision?
        private var cold = true
        private var wasActive = false
        override init(frame: CGRect) { super.init(frame: frame); isOpaque = false; isUserInteractionEnabled = false }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func draw(_ rect: CGRect) {
            guard active else { wasActive = false; return }
            if cold {
                os_signpost(.event, log: PerformanceMarks.log, name: "useful-content")
                cold = false
            }
            if !wasActive {
                os_signpost(.event, log: PerformanceMarks.log, name: "foreground-useful")
                wasActive = true
            }
            os_signpost(.event, log: PerformanceMarks.log, name: "transcript-drawn")
        }
        func leftForeground() { wasActive = false }
    }
}
