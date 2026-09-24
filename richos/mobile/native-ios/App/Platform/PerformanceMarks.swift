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

/// The useful root has entered the render tree. One draw per revision, with no clock or polling.
/// Pair these markers with the platform's frame presentation trace, not with network completion.
struct UsefulFrameMarker: UIViewRepresentable {
    let active: Bool
    let revision: Revision
    struct Revision: Equatable { var count: Int; var last: Message?; var reply: ReplyActivity? }
    func makeUIView(context: Context) -> MarkerView { MarkerView() }
    func updateUIView(_ view: MarkerView, context: Context) {
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
