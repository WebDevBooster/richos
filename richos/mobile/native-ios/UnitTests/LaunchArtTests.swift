import Foundation
import SwiftUI
import Testing
import UIKit
@testable import RichOSNative

/// The launch screen's art IS the app's own drawing (LaunchShell): every image the launch screen shows
/// (Assets.xcassets `Launch*`, placed by LaunchScreen.storyboard) is rendered here from the same views the
/// app draws as its first frame, in both appearances, and compared with the committed file. A change to
/// the conversation's chrome that the launch screen no longer matches fails here, instead of showing the
/// person a frame that jumps.
///
/// Every render is also written to `/Volumes/E1TB/tmp/launch-art-rendered/` (when that volume is
/// mounted), named as committed, so new art is copied from there after a deliberate change.
@Suite("Launch screen art")
@MainActor
struct LaunchArtTests {
    static let assets = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("App/Platform/Assets.xcassets")
    static let out = URL(fileURLWithPath: "/Volumes/E1TB/tmp/launch-art-rendered")

    enum Look: String, CaseIterable { case light, dark
        var palette: Palette { self == .light ? .daybreak : .sovereign }
    }

    /// Every committed launch image: its imageset, and how it is drawn at a scale in a look.
    static func pieces(_ look: Look, scale: CGFloat) -> [(name: String, image: CGImage)] {
        let m = LaunchShell.margin
        let palette = look.palette
        let composer = render(LaunchComposer(width: LaunchShell.composerArtWidth).padding(m), palette, scale)
        let w = LaunchShell.composerArtWidth
        func cut(_ x0: CGFloat, _ x1: CGFloat) -> CGImage {
            composer.cropping(to: CGRect(x: (x0 * scale).rounded(), y: 0, width: ((x1 - x0) * scale).rounded(),
                                         height: CGFloat(composer.height)))!
        }
        return [
            ("LaunchNameplate", render(LaunchNameplate().padding(m), palette, scale)),
            ("LaunchSettings", render(LaunchSettingsButton().padding(m), palette, scale)),
            ("LaunchComposerLeft", cut(0, m + LaunchShell.leftCap)),
            ("LaunchComposerMiddle", cut(m + LaunchShell.leftCap, m + LaunchShell.leftCap + 1)),
            ("LaunchComposerRight", cut(m + w - LaunchShell.rightCap, m + w + m)),
        ]
    }

    static func render<V: View>(_ view: V, _ palette: Palette, _ scale: CGFloat) -> CGImage {
        let renderer = ImageRenderer(content: view.environment(\.palette, palette))
        renderer.scale = scale
        renderer.isOpaque = false
        return renderer.cgImage!
    }

    /// The lamp over the ground, opaque, at one point per pixel: a smooth gradient the launch screen
    /// stretches to the phone's screen.
    static func lamp(_ look: Look) -> CGImage {
        let size = LaunchShell.lampArtSize
        let renderer = ImageRenderer(content: GroundBackground().frame(width: size.width, height: size.height)
            .environment(\.palette, look.palette))
        renderer.scale = 1
        renderer.isOpaque = true
        return renderer.cgImage!
    }

    @Test func everyLaunchImageIsTheAppsOwnDrawing() throws {
        var problems: [String] = []
        var rendered: [(file: String, image: CGImage)] = []
        for look in Look.allCases {
            for scale in [CGFloat(2), 3] {
                for piece in Self.pieces(look, scale: scale) {
                    rendered.append(("\(piece.name).imageset/\(piece.name)-\(look.rawValue)@\(Int(scale))x.png", piece.image))
                }
            }
            rendered.append(("LaunchLamp.imageset/LaunchLamp-\(look.rawValue).png", Self.lamp(look)))
        }
        for (file, image) in rendered {
            Self.keep(image, as: file)
            let url = Self.assets.appendingPathComponent(file)
            guard let data = try? Data(contentsOf: url), let committed = UIImage(data: data)?.cgImage else {
                problems.append("\(file): not committed")
                continue
            }
            if let difference = Self.difference(committed, image) { problems.append("\(file): \(difference)") }
        }
        #expect(problems.isEmpty, "the launch screen's art no longer matches the app's first frame (new art is in \(Self.out.path)):\n\(problems.joined(separator: "\n"))")
    }

    /// nil when the two images are the same picture: same size, and no pixel more than 4 levels apart in
    /// any channel (anti-aliasing can differ by a level between simulator runtimes).
    static func difference(_ a: CGImage, _ b: CGImage) -> String? {
        guard a.width == b.width, a.height == b.height else {
            return "size \(a.width)x\(a.height) committed, \(b.width)x\(b.height) drawn"
        }
        let pa = rgba(a), pb = rgba(b)
        var off = 0
        for i in stride(from: 0, to: pa.count, by: 4) {
            for c in 0..<4 where abs(Int(pa[i + c]) - Int(pb[i + c])) > 4 { off += 1; break }
        }
        return off == 0 ? nil : "\(off) of \(a.width * a.height) pixels differ"
    }

    static func rgba(_ image: CGImage) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = CGContext(data: &bytes, width: image.width, height: image.height, bitsPerComponent: 8,
                                bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return bytes
    }

    static func keep(_ image: CGImage, as file: String) {
        guard FileManager.default.fileExists(atPath: "/Volumes/E1TB/tmp") else { return }
        let url = out.appendingPathComponent(file)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? UIImage(cgImage: image).pngData()?.write(to: url)
    }
}
