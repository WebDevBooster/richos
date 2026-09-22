import SwiftUI

/// Synthetic "photographs" for the Debug catalog and fixtures: drawn, deterministic, nothing real
/// (round-12 `attach/photos.js` draws twelve SVG scenes for the same reason). Live photos come from
/// the system picker and are drawn from their staged files instead. Simplified from the mockup's
/// scenes: the same subject and palette, fewer strokes.
struct PhotoScene: View {
    let key: String

    var body: some View {
        Canvas { context, size in
            let w = size.width, h = size.height
            func rect(_ x: CGFloat, _ y: CGFloat, _ rw: CGFloat, _ rh: CGFloat) -> Path {
                Path(CGRect(x: x * w, y: y * h, width: rw * w, height: rh * h))
            }
            func gradient(_ stops: [UInt32], _ start: UnitPoint = .top, _ end: UnitPoint = .bottom) -> GraphicsContext.Shading {
                .linearGradient(Gradient(colors: stops.map { Color(hex: $0) }),
                                startPoint: CGPoint(x: start.x * w, y: start.y * h),
                                endPoint: CGPoint(x: end.x * w, y: end.y * h))
            }
            switch key {
            case "venue":
                context.fill(rect(0, 0, 1, 0.66), with: gradient([0x1F2D57, 0x6D5586, 0xE38F6B, 0xF4C58E]))
                context.fill(Path(ellipseIn: CGRect(x: 0.55 * w, y: 0.45 * h, width: 0.3 * w, height: 0.3 * w)),
                             with: .color(Color(hex: 0xFFDF9A).opacity(0.7)))
                context.fill(rect(0, 0.65, 1, 0.35), with: gradient([0xE9A77C, 0x7A5877, 0x1A2140]))
                var lodge = Path()
                lodge.move(to: CGPoint(x: 0.07 * w, y: 0.66 * h)); lodge.addLine(to: CGPoint(x: 0.07 * w, y: 0.53 * h))
                lodge.addLine(to: CGPoint(x: 0.2 * w, y: 0.43 * h)); lodge.addLine(to: CGPoint(x: 0.32 * w, y: 0.53 * h))
                lodge.addLine(to: CGPoint(x: 0.32 * w, y: 0.66 * h)); lodge.closeSubpath()
                context.fill(lodge, with: .color(Color(hex: 0x141829)))
                for (x, y) in [(0.11, 0.57), (0.16, 0.57), (0.23, 0.57), (0.27, 0.57)] {
                    context.fill(rect(x, y, 0.025, 0.04), with: .color(Color(hex: 0xFFC96E)))
                }
            case "receipt":
                context.fill(rect(0, 0, 1, 1), with: gradient([0x7C5537, 0x3E271A], .topLeading, .bottomTrailing))
                var paper = context
                paper.rotate(by: .degrees(-6))
                paper.fill(Path(CGRect(x: 0.26 * w, y: 0.1 * h, width: 0.52 * w, height: 0.85 * h)), with: .color(Color(hex: 0xF3EFE6)))
                for i in 0..<9 {
                    paper.fill(Path(CGRect(x: 0.3 * w, y: (0.22 + Double(i) * 0.06) * h, width: (0.2 + Double(i % 3) * 0.06) * w, height: 0.015 * h)),
                               with: .color(Color(hex: 0x5D5D5D)))
                }
            case "whiteboard":
                context.fill(rect(0, 0, 1, 1), with: .color(Color(hex: 0xB9B3A8)))
                context.fill(rect(0.05, 0.07, 0.9, 0.8), with: gradient([0xF6F7F4, 0xDFE2DE], .topLeading, .bottomTrailing))
                for (x, y) in [(0.11, 0.15), (0.44, 0.13), (0.72, 0.2), (0.25, 0.5), (0.58, 0.52)] {
                    context.stroke(Path(roundedRect: CGRect(x: x * w, y: y * h, width: 0.23 * w, height: 0.17 * h), cornerRadius: 8),
                                   with: .color(Color(hex: 0x2856C4)), lineWidth: 3)
                }
            case "dinner":
                context.fill(rect(0, 0, 1, 1), with: gradient([0x2B1B14, 0x5A3522]))
                context.fill(Path(ellipseIn: CGRect(x: 0.2 * w, y: 0.25 * h, width: 0.6 * w, height: 0.5 * h)), with: .color(Color(hex: 0xEDE6DA)))
                context.fill(Path(ellipseIn: CGRect(x: 0.33 * w, y: 0.36 * h, width: 0.34 * w, height: 0.28 * h)), with: .color(Color(hex: 0xC5723A)))
            case "chart":
                context.fill(rect(0, 0, 1, 1), with: .color(Color(hex: 0xF4F2EC)))
                for i in 0..<6 {
                    let barH = [0.3, 0.42, 0.38, 0.55, 0.62, 0.74][i]
                    context.fill(rect(0.1 + Double(i) * 0.14, 0.88 - barH, 0.09, barH), with: .color(Color(hex: 0x2F4B7C)))
                }
            default:
                let seed = key.stableSeed
                let palettes: [[UInt32]] = [[0x16324F, 0x4F7CAC], [0x3B2F2F, 0xC8A27A], [0x0F3D3E, 0x7FB7A4], [0x2E1F47, 0xB57EDC]]
                context.fill(rect(0, 0, 1, 1), with: gradient(palettes[seed % palettes.count], .topLeading, .bottomTrailing))
                context.fill(Path(ellipseIn: CGRect(x: 0.3 * w, y: 0.3 * h, width: 0.4 * w, height: 0.4 * w)),
                             with: .color(.white.opacity(0.18)))
            }
        }
        .accessibilityHidden(true)
    }
}
