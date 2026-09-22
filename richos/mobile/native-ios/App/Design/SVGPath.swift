import CoreGraphics
import SwiftUI

/// Parses SVG path data (`d="…"`) into a `CGPath`, so round 12's icons and the RichOS mark are drawn
/// from the very path data the approved mockup draws (`round-12/shared/app.js` `I`), not redrawn by
/// hand or replaced by a system symbol (ceo-decisions §22: nothing the product shows comes from the
/// operating system).
///
/// Supports every command in SVG 1.1 (`M L H V C S Q T A Z`, absolute and relative). Numbers may run
/// together the way minified SVG writes them (`-85.2-120.4`, `.9.9`).
enum SVGPath {
    static func parse(_ d: String) -> CGPath {
        var parser = Parser(Array(d.utf8))
        return parser.run()
    }

    private struct Parser {
        let bytes: [UInt8]
        var i = 0
        let path = CGMutablePath()
        var current = CGPoint.zero
        var start = CGPoint.zero
        var lastControl: CGPoint?
        var lastCommand: UInt8 = 0

        init(_ bytes: [UInt8]) { self.bytes = bytes }

        mutating func run() -> CGPath {
            var command: UInt8 = 0
            while true {
                skipSeparators()
                guard i < bytes.count else { break }
                let b = bytes[i]
                if isCommand(b) {
                    command = b
                    i += 1
                } else if command == 0 {
                    break  // numbers before any command: malformed, stop
                }
                apply(command)
                // After a moveto, further coordinate pairs are implicit linetos.
                if command == UInt8(ascii: "M") { command = UInt8(ascii: "L") }
                if command == UInt8(ascii: "m") { command = UInt8(ascii: "l") }
                if command == UInt8(ascii: "Z") || command == UInt8(ascii: "z") { command = 0 }
            }
            return path.copy() ?? path
        }

        mutating func apply(_ c: UInt8) {
            let rel = c >= UInt8(ascii: "a")
            let upper = rel ? c - 32 : c
            func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
                rel ? CGPoint(x: current.x + x, y: current.y + y) : CGPoint(x: x, y: y)
            }
            switch upper {
            case UInt8(ascii: "M"):
                guard let x = number(), let y = number() else { return skip() }
                current = pt(x, y); start = current
                path.move(to: current); lastControl = nil
            case UInt8(ascii: "L"):
                guard let x = number(), let y = number() else { return skip() }
                current = pt(x, y); path.addLine(to: current); lastControl = nil
            case UInt8(ascii: "H"):
                guard let x = number() else { return skip() }
                current = CGPoint(x: rel ? current.x + x : x, y: current.y); path.addLine(to: current); lastControl = nil
            case UInt8(ascii: "V"):
                guard let y = number() else { return skip() }
                current = CGPoint(x: current.x, y: rel ? current.y + y : y); path.addLine(to: current); lastControl = nil
            case UInt8(ascii: "C"):
                guard let x1 = number(), let y1 = number(), let x2 = number(), let y2 = number(),
                      let x = number(), let y = number() else { return skip() }
                let c1 = pt(x1, y1), c2 = pt(x2, y2), end = pt(x, y)
                path.addCurve(to: end, control1: c1, control2: c2)
                lastControl = c2; current = end
            case UInt8(ascii: "S"):
                guard let x2 = number(), let y2 = number(), let x = number(), let y = number() else { return skip() }
                let c1 = reflected(for: [UInt8(ascii: "C"), UInt8(ascii: "S")])
                let c2 = pt(x2, y2), end = pt(x, y)
                path.addCurve(to: end, control1: c1, control2: c2)
                lastControl = c2; current = end
            case UInt8(ascii: "Q"):
                guard let x1 = number(), let y1 = number(), let x = number(), let y = number() else { return skip() }
                let c = pt(x1, y1), end = pt(x, y)
                path.addQuadCurve(to: end, control: c)
                lastControl = c; current = end
            case UInt8(ascii: "T"):
                guard let x = number(), let y = number() else { return skip() }
                let c = reflected(for: [UInt8(ascii: "Q"), UInt8(ascii: "T")])
                let end = pt(x, y)
                path.addQuadCurve(to: end, control: c)
                lastControl = c; current = end
            case UInt8(ascii: "A"):
                guard let rx = number(), let ry = number(), let rotation = number(),
                      let large = flag(), let sweep = flag(), let x = number(), let y = number() else { return skip() }
                let end = pt(x, y)
                addArc(from: current, to: end, rx: rx, ry: ry, rotation: rotation, large: large, sweep: sweep)
                current = end; lastControl = nil
            case UInt8(ascii: "Z"):
                path.closeSubpath(); current = start; lastControl = nil
            default:
                skip()
            }
            lastCommand = upper
        }

        func reflected(for previous: [UInt8]) -> CGPoint {
            guard previous.contains(lastCommand), let c = lastControl else { return current }
            return CGPoint(x: 2 * current.x - c.x, y: 2 * current.y - c.y)
        }

        mutating func skip() { i = bytes.count }

        func isCommand(_ b: UInt8) -> Bool {
            switch b {
            case UInt8(ascii: "M"), UInt8(ascii: "m"), UInt8(ascii: "L"), UInt8(ascii: "l"),
                 UInt8(ascii: "H"), UInt8(ascii: "h"), UInt8(ascii: "V"), UInt8(ascii: "v"),
                 UInt8(ascii: "C"), UInt8(ascii: "c"), UInt8(ascii: "S"), UInt8(ascii: "s"),
                 UInt8(ascii: "Q"), UInt8(ascii: "q"), UInt8(ascii: "T"), UInt8(ascii: "t"),
                 UInt8(ascii: "A"), UInt8(ascii: "a"), UInt8(ascii: "Z"), UInt8(ascii: "z"):
                return true
            default:
                return false
            }
        }

        mutating func skipSeparators() {
            while i < bytes.count, bytes[i] == 32 || bytes[i] == 44 || bytes[i] == 9 || bytes[i] == 10 || bytes[i] == 13 {
                i += 1
            }
        }

        /// An arc flag is a single `0` or `1`, which minified SVG may run into the next number.
        mutating func flag() -> Bool? {
            skipSeparators()
            guard i < bytes.count else { return nil }
            let b = bytes[i]
            guard b == UInt8(ascii: "0") || b == UInt8(ascii: "1") else { return nil }
            i += 1
            return b == UInt8(ascii: "1")
        }

        mutating func number() -> CGFloat? {
            skipSeparators()
            let begin = i
            if i < bytes.count, bytes[i] == UInt8(ascii: "-") || bytes[i] == UInt8(ascii: "+") { i += 1 }
            var sawDot = false, sawDigit = false
            while i < bytes.count {
                let b = bytes[i]
                if b >= 48 && b <= 57 { sawDigit = true; i += 1; continue }
                if b == UInt8(ascii: "."), !sawDot { sawDot = true; i += 1; continue }
                if (b == UInt8(ascii: "e") || b == UInt8(ascii: "E")), sawDigit {
                    i += 1
                    if i < bytes.count, bytes[i] == UInt8(ascii: "-") || bytes[i] == UInt8(ascii: "+") { i += 1 }
                    continue
                }
                break
            }
            guard sawDigit, let s = String(bytes: bytes[begin..<i], encoding: .ascii), let v = Double(s) else {
                i = begin
                return nil
            }
            return CGFloat(v)
        }

        /// SVG's endpoint arc, converted to its center form and drawn as cubic segments of at most
        /// 90° each (SVG 1.1, Appendix F.6).
        func addArc(from p0: CGPoint, to p1: CGPoint, rx rxIn: CGFloat, ry ryIn: CGFloat,
                    rotation: CGFloat, large: Bool, sweep: Bool) {
            guard p0 != p1 else { return }
            var rx = abs(rxIn), ry = abs(ryIn)
            guard rx > 0, ry > 0 else { path.addLine(to: p1); return }
            let phi = rotation * .pi / 180
            let cosPhi = cos(phi), sinPhi = sin(phi)
            let dx = (p0.x - p1.x) / 2, dy = (p0.y - p1.y) / 2
            let x1p = cosPhi * dx + sinPhi * dy
            let y1p = -sinPhi * dx + cosPhi * dy
            let lambda = (x1p * x1p) / (rx * rx) + (y1p * y1p) / (ry * ry)
            if lambda > 1 { rx *= sqrt(lambda); ry *= sqrt(lambda) }
            let num = rx * rx * ry * ry - rx * rx * y1p * y1p - ry * ry * x1p * x1p
            let den = rx * rx * y1p * y1p + ry * ry * x1p * x1p
            var coef = den == 0 ? 0 : sqrt(max(0, num / den))
            if large == sweep { coef = -coef }
            let cxp = coef * rx * y1p / ry
            let cyp = -coef * ry * x1p / rx
            let cx = cosPhi * cxp - sinPhi * cyp + (p0.x + p1.x) / 2
            let cy = sinPhi * cxp + cosPhi * cyp + (p0.y + p1.y) / 2
            func angle(_ ux: CGFloat, _ uy: CGFloat, _ vx: CGFloat, _ vy: CGFloat) -> CGFloat {
                let dot = ux * vx + uy * vy
                let len = sqrt(ux * ux + uy * uy) * sqrt(vx * vx + vy * vy)
                var a = acos(max(-1, min(1, dot / len)))
                if ux * vy - uy * vx < 0 { a = -a }
                return a
            }
            let theta1 = angle(1, 0, (x1p - cxp) / rx, (y1p - cyp) / ry)
            var delta = angle((x1p - cxp) / rx, (y1p - cyp) / ry, (-x1p - cxp) / rx, (-y1p - cyp) / ry)
            if !sweep, delta > 0 { delta -= 2 * .pi }
            if sweep, delta < 0 { delta += 2 * .pi }
            let segments = max(1, Int(ceil(abs(delta) / (.pi / 2))))
            let step = delta / CGFloat(segments)
            let k = 4 / 3 * tan(step / 4)
            var t = theta1
            func point(_ a: CGFloat) -> CGPoint {
                CGPoint(x: cx + rx * cos(a) * cosPhi - ry * sin(a) * sinPhi,
                        y: cy + rx * cos(a) * sinPhi + ry * sin(a) * cosPhi)
            }
            func derivative(_ a: CGFloat) -> CGPoint {
                CGPoint(x: -rx * sin(a) * cosPhi - ry * cos(a) * sinPhi,
                        y: -rx * sin(a) * sinPhi + ry * cos(a) * cosPhi)
            }
            for _ in 0..<segments {
                let a0 = t, a1 = t + step
                let s = point(a0), e = point(a1)
                let d0 = derivative(a0), d1 = derivative(a1)
                path.addCurve(to: e,
                              control1: CGPoint(x: s.x + k * d0.x, y: s.y + k * d0.y),
                              control2: CGPoint(x: e.x - k * d1.x, y: e.y - k * d1.y))
                t = a1
            }
        }
    }
}

/// A shape drawn from SVG path data in a square `viewBox` of `0 0 box box`, scaled to fit its frame.
struct SVGShape: Shape {
    let cgPath: CGPath
    let box: CGFloat

    init(_ d: String, box: CGFloat = 24) {
        self.cgPath = SVGPath.parse(d)
        self.box = box
    }

    init(cgPath: CGPath, box: CGFloat) {
        self.cgPath = cgPath
        self.box = box
    }

    func path(in rect: CGRect) -> Path {
        let scale = min(rect.width, rect.height) / box
        var transform = CGAffineTransform(translationX: rect.midX - box * scale / 2, y: rect.midY - box * scale / 2)
            .scaledBy(x: scale, y: scale)
        return Path(cgPath.copy(using: &transform) ?? cgPath)
    }
}
