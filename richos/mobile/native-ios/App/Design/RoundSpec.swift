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

}
