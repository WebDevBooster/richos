import SwiftUI

/// Round 12.1 values that a screen draws and a headless check proves (`native-ios-ui.test.sh`),
/// each with the mockup rule it comes from. A view reads these; it does not restate them.
enum RoundSpec {
    // MARK: conv-empty, the CEO's how-to paragraph (Urban's audit G7)
    // `app.css` `.beginning .mic-how { max-width: 300px; margin: 22px auto 0; padding-top: 20px;
    // border-top: 1px solid var(--line-faint); color: var(--ink); line-height: 1.55 }`, and NOTES
    // "his paragraph ... below a hairline: 16px, full ink, centered, 300px measure".

    /// The paragraph's measure.
    static let howToMeasure: CGFloat = 300
    /// Space above the hairline.
    static let howToRuleGap: CGFloat = 22
    /// Space between the hairline and the paragraph.
    static let howToTextGap: CGFloat = 20
    static let howToLineHeight: CGFloat = 1.55
    /// Full ink, not the soft ink of the line above it.
    static func howToInk(_ p: Palette) -> Color { p.ink }
    static func howToRule(_ p: Palette) -> Color { p.lineFaint }

    // MARK: comp-disabled, the orb (Urban's audit G13)
    // `app.js` `setDisabled`: `orb.style.opacity = ".45"`: the gold orb, dimmed, with its glyph.

    static let disabledOrbOpacity = 0.45
    static func disabledOrbFill(_ p: Palette) -> Color { p.signal }
    // DECLARED EXEMPTION (WCAG 1.4.11 exempts inactive components): the dimmed orb measures about
    // 2.56:1 in the mockup; it is an inactive control, and the line beside it says why sending is off.
}
