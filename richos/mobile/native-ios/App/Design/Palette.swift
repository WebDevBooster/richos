import SwiftUI
import RichOSCore

/// The two ruled palettes, as round 12 uses them (`design/mockups/rounds/round-12/shared/app.css`,
/// lines 27–77). Every value is a ruled token from `design/system/tokens.css` (§14 dark "Sovereign",
/// §15 light "Daybreak") or one of round 12's DECLARED gap values (`round-12/NOTES.md` "Gaps"). There
/// is no other color in the app: a screen that needs one it cannot find here needs a design decision,
/// not a literal.
///
/// The app follows its own appearance setting (`AppState.appearance`), not the system's: a new
/// install opens dark (ceo-decisions §15), and the choice is the person's.
struct Palette: Equatable, Sendable {
    let appearance: Appearance

    // Ruled tokens.
    let ground: Color
    let surface: Color
    let ink: Color
    let signal: Color
    let trim: Color
    let onSignal: Color

    // Declared gap values (round-12 NOTES.md "Gaps").
    /// GAP 5: your own bubble, the ground washed with `signal`.
    let mine: Color
    /// GAP 4: danger, reused from the live app. Only the recording dot, the bin, "Not sent", Forget.
    let danger: Color
    /// Drawn system keyboard and lock screen are not RichOS surfaces; they are not in this palette.
    let scrim: Color

    // Alpha derivations, composited over whatever is behind them exactly as the CSS does.
    /// GAP 3: the secondary tone is `ink` at 72% (worst measured 6.31:1, NOTES "Contrast").
    var inkSoft: Color { ink.opacity(0.72) }
    /// GAP 1: a line is the ruled `trim` at its ruled value (declared 2.94:1 on the dark ground; no
    /// control is identified by a line alone).
    var line: Color { trim }
    var lineFaint: Color { trim.opacity(appearance == .dark ? 0.38 : 0.34) }
    var signalWash: Color { signal.opacity(appearance == .dark ? 0.13 : 0.12) }
    var signalHalo: Color { signal.opacity(0.22) }

    /// Accent glyphs that sit on the ground or a surface: gold in the dark, ink in the light, where
    /// light-mode gold on the ground would be 3.15:1 (round-12 `app.css` `.eyebrow`, `.consent-rows .ic`,
    /// `.banner .ic`, `.vdur.playing` all switch to ink in light for this reason).
    var accentGlyph: Color { appearance == .dark ? signal : ink }

    /// The gold play button on YOUR bubble in the light theme is 2.80:1 against the gold-washed plane
    /// (computed by `native-ios-ui.test.sh`), under the 3:1 floor for a control; it gets a 1 pt ink
    /// edge there. Dark needs none. A deviation from round 12, which did not measure this pairing.
    var playEdgeOnMine: Color? { appearance == .dark ? nil : ink }

    /// The drop shadow every floating element wears (`--sh-float`). SwiftUI shadows have no spread, so
    /// the CSS's negative spread is approximated by a smaller radius; it is decoration, not information.
    var floatShadow: Color { appearance == .dark ? Color.black.opacity(0.55) : Color(hex: 0x2E2816).opacity(0.22) }
    var floatShadowNear: Color { appearance == .dark ? Color.black.opacity(0.4) : Color(hex: 0x2E2816).opacity(0.12) }
    var orbShadow: Color { signal.opacity(appearance == .dark ? 0.5 : 0.45) }
    /// The lamp: a whisper of light at the top of the ground (`--lamp`).
    var lamp: Color { appearance == .dark ? trim.opacity(0.22) : Color.white.opacity(0.55) }

    var colorScheme: ColorScheme { appearance == .dark ? .dark : .light }

    static let sovereign = Palette(
        appearance: .dark,
        ground: Color(hex: 0x0C1322), surface: Color(hex: 0x141E34), ink: Color(hex: 0xDFE4EE),
        signal: Color(hex: 0xC2A35C), trim: Color(hex: 0x4C6087), onSignal: Color(hex: 0x0C1322),
        mine: Color(hex: 0x242629), danger: Color(hex: 0xE8837C),
        scrim: Color(red: 3 / 255, green: 7 / 255, blue: 15 / 255).opacity(0.66))

    static let daybreak = Palette(
        appearance: .light,
        ground: Color(hex: 0xEAE6DD), surface: Color(hex: 0xF7F5EF), ink: Color(hex: 0x0C1322),
        signal: Color(hex: 0x9C7C34), trim: Color(hex: 0x4C6087), onSignal: Color(hex: 0x0C1322),
        mine: Color(hex: 0xE1D9C9), danger: Color(hex: 0x8A2F28),
        scrim: Color(red: 43 / 255, green: 37 / 255, blue: 22 / 255).opacity(0.42))

    static func `for`(_ appearance: Appearance) -> Palette {
        appearance == .dark ? .sovereign : .daybreak
    }
}

extension Color {
    /// `0xRRGGBB`, sRGB.
    init(hex: UInt32) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: 1)
    }
}

private struct PaletteKey: EnvironmentKey {
    static let defaultValue = Palette.sovereign
}

extension EnvironmentValues {
    var palette: Palette {
        get { self[PaletteKey.self] }
        set { self[PaletteKey.self] = newValue }
    }
}

extension View {
    /// Puts a palette in the environment and tells the system which appearance the app is in, so the
    /// keyboard, the status bar and system alerts match the ground they sit on.
    func palette(_ palette: Palette) -> some View {
        environment(\.palette, palette)
            .preferredColorScheme(palette.colorScheme)
    }
}
