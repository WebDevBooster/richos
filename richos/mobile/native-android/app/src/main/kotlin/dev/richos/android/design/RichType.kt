package dev.richos.android.design

import androidx.compose.runtime.Immutable
import androidx.compose.ui.text.ExperimentalTextApi
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.Font
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.font.FontVariation
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.LineHeightStyle
import androidx.compose.ui.unit.TextUnit
import androidx.compose.ui.unit.em
import androidx.compose.ui.unit.sp
import dev.richos.android.R

/**
 * The faces and the type scale (round-12 NOTES "Type"; ceo-decisions §15 floors).
 *
 * Inter throughout; Newsreader for the serif headings of takeovers, sheets and the six words.
 * The files are the design system's own (`design/system/fonts/`, SIL OFL 1.1, licenses shipped in
 * `assets/licenses/`), converted from WOFF2 to TrueType byte-for-byte in outline because Android
 * font resources do not read WOFF2.
 *
 * Every size is in sp, so the whole scale follows the phone's font size. The floors:
 * **18 sp** Rich's answers; **17 sp** your messages, the timer, Cancel, controls and settings rows;
 * **16 sp** placeholder, hints, secondary lines, captions, card bodies, buttons (the readable floor);
 * **14 sp, declared skippable:** timestamps inside bubbles and the all-caps eyebrows, per the design
 * system's declared class. Nothing readable is below 16 sp and nothing at all below 14 sp.
 */
@OptIn(ExperimentalTextApi::class)
object RichFonts {
    private fun inter(weight: FontWeight) = Font(
        R.font.inter_variable,
        weight = weight,
        variationSettings = FontVariation.Settings(FontVariation.weight(weight.weight)),
    )

    val Inter: FontFamily = FontFamily(
        inter(FontWeight.Normal),
        inter(FontWeight.Medium),
        inter(FontWeight.SemiBold),
        inter(FontWeight.Bold),
        Font(R.font.inter_italic, FontWeight.Normal, FontStyle.Italic),
    )

    val Newsreader: FontFamily = FontFamily(
        Font(R.font.newsreader_regular, FontWeight.Normal),
        Font(R.font.newsreader_italic, FontWeight.Normal, FontStyle.Italic),
    )
}

/** The size tiers, in sp. Everything that draws text takes one of these. */
object TypeSize {
    val Answer: TextUnit = 18.sp
    val Body: TextUnit = 17.sp
    val Read: TextUnit = 16.sp
    /** DECLARED SKIPPABLE ONLY: timestamps inside bubbles, eyebrows. */
    val Skippable: TextUnit = 14.sp
    /** Takeover heading (2.375 rem); 34 sp on the small phone. */
    val Display: TextUnit = 38.sp
    val DisplaySmall: TextUnit = 34.sp
    /** Update-required heading (2.25 rem). */
    val DisplayBlocking: TextUnit = 36.sp
    /** Sheet title (1.75 rem) and the six words (1.75 rem; 1.5 rem small). */
    val Sheet: TextUnit = 28.sp
    val Word: TextUnit = 28.sp
    val WordSmall: TextUnit = 24.sp
    /** Dialog title (1.625 rem). */
    val Dialog: TextUnit = 26.sp
    /** Empty-conversation line (1.5 rem). */
    val Welcome: TextUnit = 24.sp
}

@Immutable
data class RichTypography(
    /** Rich's bubbles, takeover ledes: 18 sp, prose leading 1.5. */
    val answer: TextStyle,
    /** Your bubbles, controls, settings rows, card titles: 17 sp. */
    val body: TextStyle,
    val bodyStrong: TextStyle,
    /** Readable floor: hints, secondary lines, card bodies, buttons: 16 sp. */
    val read: TextStyle,
    val readStrong: TextStyle,
    /** DECLARED SKIPPABLE: timestamps (tabular), 14 sp. */
    val stamp: TextStyle,
    /** DECLARED SKIPPABLE: all-caps eyebrow micro-labels, 14 sp, tracked. */
    val eyebrow: TextStyle,
    /** Serif headings. */
    val display: TextStyle,
    val displaySmall: TextStyle,
    val displayBlocking: TextStyle,
    val sheetTitle: TextStyle,
    val dialogTitle: TextStyle,
    val word: TextStyle,
    val wordSmall: TextStyle,
    val welcome: TextStyle,
    /** The recording timer: 17 sp medium, tabular figures. */
    val timer: TextStyle,
) {
    companion object {
        private val tight = LineHeightStyle(LineHeightStyle.Alignment.Center, LineHeightStyle.Trim.None)

        fun standard(): RichTypography {
            val sans = TextStyle(fontFamily = RichFonts.Inter, lineHeightStyle = tight)
            val serif = TextStyle(fontFamily = RichFonts.Newsreader, fontWeight = FontWeight.Normal, lineHeightStyle = tight)
            return RichTypography(
                answer = sans.copy(fontSize = TypeSize.Answer, lineHeight = 1.5.em, letterSpacing = (-0.005).em),
                body = sans.copy(fontSize = TypeSize.Body, lineHeight = 1.35.em),
                bodyStrong = sans.copy(fontSize = TypeSize.Body, lineHeight = 1.35.em, fontWeight = FontWeight.SemiBold),
                read = sans.copy(fontSize = TypeSize.Read, lineHeight = 1.35.em),
                readStrong = sans.copy(fontSize = TypeSize.Read, lineHeight = 1.35.em, fontWeight = FontWeight.SemiBold),
                stamp = sans.copy(fontSize = TypeSize.Skippable, lineHeight = 1.2.em, fontWeight = FontWeight.Medium, fontFeatureSettings = "tnum"),
                eyebrow = sans.copy(fontSize = TypeSize.Skippable, lineHeight = 1.3.em, fontWeight = FontWeight.SemiBold, letterSpacing = 0.14.em),
                display = serif.copy(fontSize = TypeSize.Display, lineHeight = 1.08.em, letterSpacing = (-0.01).em),
                displaySmall = serif.copy(fontSize = TypeSize.DisplaySmall, lineHeight = 1.08.em, letterSpacing = (-0.01).em),
                displayBlocking = serif.copy(fontSize = TypeSize.DisplayBlocking, lineHeight = 1.1.em),
                sheetTitle = serif.copy(fontSize = TypeSize.Sheet, lineHeight = 1.15.em, letterSpacing = (-0.01).em),
                dialogTitle = serif.copy(fontSize = TypeSize.Dialog, lineHeight = 1.15.em, letterSpacing = (-0.01).em),
                word = serif.copy(fontSize = TypeSize.Word, lineHeight = 1.1.em),
                wordSmall = serif.copy(fontSize = TypeSize.WordSmall, lineHeight = 1.1.em),
                welcome = serif.copy(fontSize = TypeSize.Welcome, lineHeight = 1.2.em),
                timer = sans.copy(fontSize = TypeSize.Body, lineHeight = 1.3.em, fontWeight = FontWeight.Medium, fontFeatureSettings = "tnum", letterSpacing = 0.01.em),
            )
        }
    }
}
