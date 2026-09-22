import CoreText
import SwiftUI
import UIKit

/// Type, as round 12 sets it (`round-12/NOTES.md` "Type"; `shared/app.css`): Inter throughout,
/// Newsreader for the serif headings of takeovers, sheets and the six words.
///
/// No system face is used anywhere (ceo-decisions §22: "there cannot be any reliance on any system
/// fonts"). The two faces ship inside the app (`Fonts/`, with their SIL OFL 1.1 licenses) and are
/// registered for this process on first use. Both are variable fonts; every size is built with its
/// weight AND its optical size set on the axes, which is what the web does with
/// `font-optical-sizing: auto`, so an 18 pt answer and a 38 pt heading each get the cut drawn for them.
///
/// Floors (ceo-decisions §15): 18 pt Rich's answers, 16 pt anything meant to be read, 14 pt only for
/// DECLARED skippable text (timestamps in bubbles, eyebrows). Every role scales with Dynamic Type
/// through `UIFontMetrics` for its text style, so the floors hold at the default size and grow from
/// there.
enum Typography {
    enum Face: Sendable { case sans, serif }

    struct Role: Hashable, Sendable {
        let face: Face
        /// Points at the default text size ("Large").
        let size: CGFloat
        /// 400–700 on Inter's `wght` axis; Newsreader ships one weight (400).
        let weight: CGFloat
        let style: UIFont.TextStyle
        /// Letter spacing in ems (CSS `letter-spacing`).
        let tracking: CGFloat
        /// Line height as a multiple of the size (CSS `line-height`); `nil` keeps the face's own.
        let lineHeight: CGFloat?

        init(_ face: Face, _ size: CGFloat, weight: CGFloat = 400, style: UIFont.TextStyle,
             tracking: CGFloat = 0, lineHeight: CGFloat? = nil) {
            self.face = face
            self.size = size
            self.weight = weight
            self.style = style
            self.tracking = tracking
            self.lineHeight = lineHeight
        }

        func weight(_ w: CGFloat) -> Role {
            Role(face, size, weight: w, style: style, tracking: tracking, lineHeight: lineHeight)
        }
        func lineHeight(_ l: CGFloat?) -> Role {
            Role(face, size, weight: weight, style: style, tracking: tracking, lineHeight: l)
        }
    }

    // MARK: The roles round 12 uses (app.css `--type-*`, `--line-*`).

    /// 18 pt — Rich's bubbles, takeover ledes (`--type-answer`, `--line-prose` 1.5).
    static let answer = Role(.sans, 18, style: .body, tracking: -0.005, lineHeight: 1.5)
    /// 17 pt — your bubbles, the timer, Cancel, controls, settings rows (`--type-body`).
    static let body = Role(.sans, 17, style: .body, lineHeight: 1.35)
    /// 16 pt — placeholder, hints, secondary lines, captions, card bodies, buttons (`--type-read`).
    static let read = Role(.sans, 16, style: .callout, lineHeight: 1.35)
    /// 14 pt — DECLARED SKIPPABLE ONLY: timestamps inside bubbles and the all-caps eyebrows
    /// (round-12 NOTES "Type" declares both). Never for text a person is expected to take in.
    static let skippable = Role(.sans, 14, weight: 500, style: .footnote, lineHeight: 1.2)
    /// The all-caps micro-label over a takeover heading; skippable by declaration (round-12 NOTES).
    static let eyebrow = Role(.sans, 14, weight: 600, style: .footnote, tracking: 0.14)

    /// Takeover heading: Newsreader 38 pt (34 on the small iPhone), `line-height` 1.08.
    static let display = Role(.serif, 38, style: .largeTitle, tracking: -0.01, lineHeight: 1.08)
    static let displaySmall = Role(.serif, 34, style: .largeTitle, tracking: -0.01, lineHeight: 1.08)
    /// The blocking update screen's heading, 36 pt.
    static let displayBlocking = Role(.serif, 36, style: .largeTitle, lineHeight: 1.1)
    /// Settings sheet heading, 28 pt.
    static let sheetTitle = Role(.serif, 28, style: .title1, tracking: -0.01)
    /// Dialog heading, 26 pt, `line-height` 1.15.
    static let dialogTitle = Role(.serif, 26, style: .title1, tracking: -0.01, lineHeight: 1.15)
    /// One of the six words, 28 pt (24 on the small iPhone).
    static let word = Role(.serif, 28, style: .title1, lineHeight: 1.1)
    static let wordSmall = Role(.serif, 24, style: .title2, lineHeight: 1.1)
    /// "Say something to Rich", 24 pt.
    static let emptyTitle = Role(.serif, 24, style: .title2)
    /// A pairing step's number, 18 pt serif.
    static let stepNumber = Role(.serif, 18, style: .body)

    // MARK: Building fonts

    /// The size a role renders at for a text size, after Dynamic Type and an optional cap.
    static func pointSize(_ role: Role, _ size: DynamicTypeSize, cap: DynamicTypeSize? = nil) -> CGFloat {
        let effective = cap.map { min(size, $0) } ?? size
        let traits = UITraitCollection(preferredContentSizeCategory: UIContentSizeCategory(effective))
        return UIFontMetrics(forTextStyle: role.style).scaledValue(for: role.size, compatibleWith: traits)
    }

    static func uiFont(_ role: Role, _ size: DynamicTypeSize, cap: DynamicTypeSize? = nil) -> UIFont {
        let points = pointSize(role, size, cap: cap)
        return cache.font(face: role.face, points: points, weight: role.weight)
    }

    /// The registered PostScript names of the bundled faces. `verify()` proves both loaded.
    static let sansName = "InterVariable"
    static let serifName = "Newsreader16pt-Regular"

    /// `true` when both bundled faces are registered and resolve to themselves (not a substitute).
    /// The UI tests assert it through the accessibility tree (`RootView` exposes it in Debug).
    static func verify() -> Bool {
        registerOnce
        let sans = CTFontCreateWithName(sansName as CFString, 16, nil)
        let serif = CTFontCreateWithName(serifName as CFString, 16, nil)
        return (CTFontCopyPostScriptName(sans) as String) == sansName
            && (CTFontCopyPostScriptName(serif) as String) == serifName
    }

    fileprivate static let registerOnce: Void = {
        for name in ["Inter-Variable", "Newsreader-Regular"] {
            guard let url = Bundle.main.url(forResource: name, withExtension: "woff2") else {
                assertionFailure("bundled face \(name).woff2 is missing from the app")
                continue
            }
            var error: Unmanaged<CFError>?
            if !CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) {
                // Already registered in this process is fine; anything else is a packaging defect.
                let code = error.map { CFErrorGetCode($0.takeRetainedValue()) } ?? 0
                assert(code == Int(CTFontManagerError.alreadyRegistered.rawValue),
                       "could not register \(name).woff2 (CTFontManagerError \(code))")
            }
        }
    }()

    private static let cache = FontCache()
}

/// Built fonts, by face, rounded point size and weight. Font construction through CoreText
/// variations is not free, and SwiftUI asks for the same few dozen fonts on every render.
private final class FontCache: @unchecked Sendable {
    private let lock = NSLock()
    private var fonts: [String: UIFont] = [:]

    private static let wght: UInt32 = 0x7767_6874  // 'wght'
    private static let opsz: UInt32 = 0x6F70_737A  // 'opsz'

    func font(face: Typography.Face, points: CGFloat, weight: CGFloat) -> UIFont {
        let rounded = (points * 4).rounded() / 4
        let key = "\(face)-\(rounded)-\(weight)"
        lock.lock()
        defer { lock.unlock() }
        if let font = fonts[key] { return font }
        Typography.registerOnce
        let name: String
        var variation: [NSNumber: NSNumber] = [:]
        switch face {
        case .sans:
            name = Typography.sansName
            variation[NSNumber(value: Self.wght)] = NSNumber(value: Double(min(max(weight, 400), 700)))
            variation[NSNumber(value: Self.opsz)] = NSNumber(value: Double(min(max(rounded, 14), 32)))
        case .serif:
            name = Typography.serifName
            variation[NSNumber(value: Self.opsz)] = NSNumber(value: Double(min(max(rounded, 6), 72)))
        }
        let base = CTFontDescriptorCreateWithNameAndSize(name as CFString, rounded)
        let attributes = [kCTFontVariationAttribute: variation] as CFDictionary
        let descriptor = CTFontDescriptorCreateCopyWithAttributes(base, attributes)
        let font = CTFontCreateWithFontDescriptor(descriptor, rounded, nil) as UIFont
        fonts[key] = font
        return font
    }
}

extension UIContentSizeCategory {
    init(_ size: DynamicTypeSize) {
        switch size {
        case .xSmall: self = .extraSmall
        case .small: self = .small
        case .medium: self = .medium
        case .large: self = .large
        case .xLarge: self = .extraLarge
        case .xxLarge: self = .extraExtraLarge
        case .xxxLarge: self = .extraExtraExtraLarge
        case .accessibility1: self = .accessibilityMedium
        case .accessibility2: self = .accessibilityLarge
        case .accessibility3: self = .accessibilityExtraLarge
        case .accessibility4: self = .accessibilityExtraExtraLarge
        case .accessibility5: self = .accessibilityExtraExtraExtraLarge
        @unknown default: self = .large
        }
    }
}

/// Sets a role's font, tracking and line height, following Dynamic Type.
struct TypeRoleModifier: ViewModifier {
    let role: Typography.Role
    let cap: DynamicTypeSize?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    func body(content: Content) -> some View {
        let font = Typography.uiFont(role, dynamicTypeSize, cap: cap)
        let spacing = role.lineHeight.map { max(0, $0 * font.pointSize - font.lineHeight) } ?? 0
        content
            .font(Font(font as CTFont))
            .tracking(role.tracking * font.pointSize)
            .lineSpacing(spacing)
    }
}

extension View {
    /// `cap` stops growth at a text size, for the few places round 12 must keep on one row at every
    /// size (the recording bar: accessibility audit F9). Capped text is still larger than default.
    func type(_ role: Typography.Role, cap: DynamicTypeSize? = nil) -> some View {
        modifier(TypeRoleModifier(role: role, cap: cap))
    }
}
