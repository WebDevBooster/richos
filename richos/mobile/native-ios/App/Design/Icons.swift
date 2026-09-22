import SwiftUI

/// Round 12's icons, from the same path data (`round-12/shared/app.js` `I`): the product's own
/// convention — a 24 × 24 box, no fill, stroked in the current color, width 2, round caps and joins.
///
/// These replace system symbols on purpose (ceo-decisions §22). They also answer accessibility audit
/// F5 (the settings "gear" was a color emoji on iOS at 2.21:1 in light mode): every icon here is drawn
/// in a palette color, and every icon has a fixed size inside a fixed control, so none grows with
/// Dynamic Type and overflows its button (audit F2, F4).
enum Icon: String, CaseIterable, Sendable {
    case mic, send, lock, trash, play, stop, settings, close, check, ringc, clock, alert
    case chevR, chevL, arrowD, camera, bell, link, mac, phone, shield, cloud, spark, refresh, qr, down, life
    /// The attach entry point and its menu (round-12 `attach/attach.js` `AI.plus`, `AI.image`, `AI.folder`).
    case plus, image, folder

    /// Stroked outline, as one path.
    var stroke: String {
        switch self {
        case .mic: return rect(9, 3, 6, 11, 3) + "M5 11a7 7 0 0 0 14 0M12 18v3"
        case .send: return "M12 19V5M6 11l6-6 6 6"
        case .lock: return Icon.lockShackle + rect(5, 11, 14, 10, 2.5)
        case .trash: return Icon.trashLid + Icon.trashBody + Icon.trashBars
        case .play, .stop: return ""
        case .settings: return "M4 8h9M17 8h3M4 16h3M11 16h9" + circle(14.5, 8, 2.5) + circle(8.5, 16, 2.5)
        case .close: return "M6 6l12 12M18 6L6 18"
        case .check: return "M5 12.5l4.5 4.5L19 7"
        case .ringc: return "M12 4a8 8 0 1 1-8 8"
        case .clock: return circle(12, 12, 8) + "M12 8v4l3 2"
        case .alert: return circle(12, 12, 8.5) + "M12 8v5"
        case .chevR: return "M9 6l6 6-6 6"
        case .chevL: return "M15 6l-6 6 6 6"
        case .arrowD: return "M12 5v14M6 13l6 6 6-6"
        case .camera: return "M4 8.5A1.5 1.5 0 0 1 5.5 7H8l1.5-2h5L16 7h2.5A1.5 1.5 0 0 1 20 8.5V18a1.5 1.5 0 0 1-1.5 1.5h-13A1.5 1.5 0 0 1 4 18z" + circle(12, 13, 3.5)
        case .bell: return "M6 16V11a6 6 0 0 1 12 0v5l1.5 2h-15zM10 20a2 2 0 0 0 4 0"
        case .link: return "M10 14a4 4 0 0 0 5.7 0l3-3a4 4 0 0 0-5.7-5.7l-1 1M14 10a4 4 0 0 0-5.7 0l-3 3a4 4 0 0 0 5.7 5.7l1-1"
        case .mac: return rect(3, 4, 18, 12, 2) + "M8 20h8M12 16v4"
        case .phone: return rect(7, 2.5, 10, 19, 2.5) + "M11 18h2"
        case .shield: return "M12 3l7 3v5c0 5-3.5 8.5-7 10-3.5-1.5-7-5-7-10V6z"
        case .cloud: return "M7 18a4 4 0 0 1-.5-8A5.5 5.5 0 0 1 17 8.5a3.8 3.8 0 0 1 .5 7.5z"
        case .spark: return "M12 3v4M12 17v4M3 12h4M17 12h4M6 6l2.5 2.5M15.5 15.5L18 18M18 6l-2.5 2.5M8.5 15.5L6 18"
        case .refresh: return "M20 12a8 8 0 1 1-2.3-5.7M20 4v5h-5"
        case .qr: return rect(4, 4, 6, 6, 1) + rect(14, 4, 6, 6, 1) + rect(4, 14, 6, 6, 1) + "M14 14h2v2h-2zM18 14h2M14 18h2M18 18h2v2"
        case .down: return "M12 4v12M7 11l5 5 5-5M5 20h14"
        case .plus: return "M12 5v14M5 12h14"
        case .image: return rect(3.5, 4.5, 17, 15, 2.5) + circle(9, 10, 1.8) + "M20.5 15.5l-4.8-4.8L6.5 19.5"
        case .folder: return "M3.5 7.5a2 2 0 0 1 2-2h4l2 2.5h7a2 2 0 0 1 2 2v7.5a2 2 0 0 1-2 2h-13a2 2 0 0 1-2-2z"
        case .life: return circle(12, 12, 8.5) + circle(12, 12, 3.5) + "M6 6l3.5 3.5M14.5 14.5L18 18M18 6l-3.5 3.5M9.5 14.5L6 18"
        }
    }

    /// Filled parts (`fill="currentColor"`), as one path.
    var fill: String {
        switch self {
        case .play: return "M8 5.5v13a1 1 0 0 0 1.5.87l11-6.5a1 1 0 0 0 0-1.74l-11-6.5A1 1 0 0 0 8 5.5z"
        case .stop: return rect(6, 6, 12, 12, 2.5)
        case .lock: return circle(12, 16, 1.2)
        case .alert: return circle(12, 16.2, 0.9)
        default: return ""
        }
    }

    // The two icons with moving parts are drawn in parts (the lock's shackle drops at the lock; the
    // bin's lid lifts and shuts in the cancel ritual).
    static let lockShackle = "M8 11V7a4 4 0 0 1 8 0v4"
    static let lockBody = rect(5, 11, 14, 10, 2.5)
    static let trashLid = "M4 7h16M9 7V5a1 1 0 0 1 1-1h4a1 1 0 0 1 1 1v2"
    static let trashBody = "M6 7l1 13a1 1 0 0 0 1 1h8a1 1 0 0 0 1-1l1-13"
    static let trashBars = "M10 11v6M14 11v6"
}

private func rect(_ x: Double, _ y: Double, _ w: Double, _ h: Double, _ r: Double) -> String {
    "M\(x + r) \(y)H\(x + w - r)A\(r) \(r) 0 0 1 \(x + w) \(y + r)V\(y + h - r)A\(r) \(r) 0 0 1 \(x + w - r) \(y + h)"
        + "H\(x + r)A\(r) \(r) 0 0 1 \(x) \(y + h - r)V\(y + r)A\(r) \(r) 0 0 1 \(x + r) \(y)Z"
}

private func circle(_ cx: Double, _ cy: Double, _ r: Double) -> String {
    "M\(cx - r) \(cy)A\(r) \(r) 0 1 0 \(cx + r) \(cy)A\(r) \(r) 0 1 0 \(cx - r) \(cy)Z"
}

/// Parsed paths, once per process.
private enum IconCache {
    static let stroke: [Icon: CGPath] = Dictionary(uniqueKeysWithValues: Icon.allCases.map { ($0, SVGPath.parse($0.stroke)) })
    static let fill: [Icon: CGPath] = Dictionary(uniqueKeysWithValues: Icon.allCases.map { ($0, SVGPath.parse($0.fill)) })
}

/// One icon at a fixed size, in the foreground color. Decorative: the control it sits in carries the
/// accessibility label.
struct IconView: View {
    let icon: Icon
    var size: CGFloat = 24
    /// Stroke width in the 24-unit box (round 12 uses 2, 2.2 on the orb's glyphs, 2.4 on delivery marks).
    var weight: CGFloat = 2

    init(_ icon: Icon, size: CGFloat = 24, weight: CGFloat = 2) {
        self.icon = icon
        self.size = size
        self.weight = weight
    }

    var body: some View {
        ZStack {
            SVGShape(cgPath: IconCache.stroke[icon]!, box: 24)
                .stroke(style: StrokeStyle(lineWidth: weight * size / 24, lineCap: .round, lineJoin: .round))
            SVGShape(cgPath: IconCache.fill[icon]!, box: 24)
                .fill()
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// A part of an icon drawn on its own, for the two icons that animate in parts.
struct IconPart: View {
    let d: String
    var size: CGFloat = 24
    var weight: CGFloat = 2
    var body: some View {
        SVGShape(d, box: 24)
            .stroke(style: StrokeStyle(lineWidth: weight * size / 24, lineCap: .round, lineJoin: .round))
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}
