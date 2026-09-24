package dev.richos.android.ui.overlays

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.defaultMinSize
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicText
import androidx.compose.foundation.verticalScroll
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.em
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.testTag
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.Hyphens
import androidx.compose.ui.text.style.LineBreak
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.dp
import dev.richos.android.design.ButtonKind
import dev.richos.android.design.Mark
import dev.richos.android.design.Rich
import dev.richos.android.design.RichButton
import dev.richos.android.design.RichIcon
import dev.richos.android.design.RichIcons
import dev.richos.android.design.Spinner
import dev.richos.android.design.lamp
import dev.richos.android.design.plane
import dev.richos.android.ui.UiEvent

/**
 * Headings and eyebrows break at word boundaries, balanced, and are never hyphenated: round 12.1
 * never hyphenates, and an automatic hyphen split the product name ("RichCon-nect", Urban's
 * 2026-09-24 audit G6). A word breaks only when it alone is wider than the line (iOS audit F10).
 */
private val wrapping = LineBreak.Paragraph.copy(strategy = LineBreak.Strategy.Balanced)

/**
 * `.takeover`: a full screen on the ground with the lamp. Its content scrolls when the text is
 * large; its buttons stay on screen underneath (iOS audit O2, F1: the actions never leave).
 */
@Composable
fun TakeoverFrame(tag: String, buttons: @Composable ColumnScope.() -> Unit = {}, content: @Composable ColumnScope.() -> Unit) {
    val c = Rich.colors
    Column(
        Modifier.fillMaxSize().background(c.ground).lamp()
            .windowInsetsPadding(WindowInsets.safeDrawing)
            .padding(start = 26.dp, end = 26.dp, top = 28.dp, bottom = 20.dp)
            .semantics { testTag = tag },
    ) {
        Column(Modifier.weight(1f).fillMaxWidth().verticalScroll(rememberScrollState()), content = content)
        Column(Modifier.fillMaxWidth().padding(top = 12.dp), verticalArrangement = Arrangement.spacedBy(10.dp), content = buttons)
    }
}

@Composable
fun Eyebrow(text: String, modifier: Modifier = Modifier) {
    val c = Rich.colors
    val t = Rich.type
    // DECLARED SKIPPABLE (design system's eyebrow class): 14 sp all-caps; signal 7.68:1 dark, ink 14.90:1 light.
    BasicText(
        text.uppercase(),
        style = t.eyebrow.copy(color = if (c.isDark) c.signal else c.ink, lineBreak = wrapping, hyphens = Hyphens.None),
        modifier = modifier,
    )
}

@Composable
fun DisplayHeading(text: String, modifier: Modifier = Modifier) {
    val c = Rich.colors
    val t = Rich.type
    val small = LocalConfiguration.current.screenWidthDp < 380
    BasicText(
        text,
        style = (if (small) t.displaySmall else t.display).copy(color = c.ink, lineBreak = wrapping, hyphens = Hyphens.None),
        modifier = modifier.padding(top = 14.dp).semantics { heading() },
    )
}

@Composable
fun Lede(text: String, modifier: Modifier = Modifier) {
    val c = Rich.colors
    val t = Rich.type
    BasicText(text, style = t.answer.copy(color = c.ink), modifier = modifier.padding(top = 16.dp))
}

@Composable
private fun BigMark() = Mark(64.dp, Modifier.padding(bottom = 18.dp))

/** An honest card inside a takeover (`.errcard`): what happened, and that nothing was lost. */
@Composable
private fun ErrorCard(title: String, body: String) {
    val c = Rich.colors
    val t = Rich.type
    Row(
        Modifier.padding(top = 18.dp).fillMaxWidth().plane(RoundedCornerShape(16.dp)).padding(horizontal = 16.dp, vertical = 14.dp),
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        RichIcon(RichIcons.Alert, c.danger, 22.dp, Modifier.padding(top = 2.dp))
        Column {
            BasicText(title, style = t.readStrong.copy(color = c.ink))
            BasicText(body, style = t.read.copy(color = c.inkSoft), modifier = Modifier.padding(top = 2.dp))
        }
    }
}

/**
 * What an unsuccessful pairing says, from core's problem code. `refused` is round 12's card; the
 * other three follow its pattern (what happened, that nothing was paired, what to do) and are
 * additions, declared: round 12 draws only the refusal.
 */
fun pairingProblemCard(problem: String?): Pair<String, String>? = when (problem) {
    null -> null
    "refused" -> "Your Mac did not accept this code" to "Stopped, and nothing was paired. Ask your Mac for a fresh code and scan again."
    "rate-limited" -> "Too many tries for now" to "Nothing was paired. Wait a minute, then scan the code again."
    "unreachable" -> "Your Mac could not be reached" to "Nothing was paired. Keep the Mac awake with RichOS running, then scan again."
    else -> "Pairing did not finish" to "Nothing was paired. Ask your Mac for a fresh code and scan again."
}

/** 1 · Pairing intro — one calm screen, one primary action; a [problem] adds the honest card. */
@Composable
fun PairingIntro(problem: String?, onEvent: (UiEvent) -> Unit) {
    TakeoverFrame(
        "pairing-intro",
        buttons = {
            RichButton("Scan your Mac’s code", { onEvent(UiEvent.ScanCode) }, icon = RichIcons.Qr, tall = true, wide = true)
            RichButton("Use a pairing link instead", { onEvent(UiEvent.UsePairingLink) }, kind = ButtonKind.QUIET, wide = true)
        },
    ) {
        BigMark()
        Eyebrow("Your conversation, with you")
        DisplayHeading("Take Rich with you")
        Lede("Rich works on your Mac. Pair this phone once and your conversation comes along wherever you are.")
        pairingProblemCard(problem)?.let { (title, body) -> ErrorCard(title, body) }
        Column(Modifier.padding(top = 22.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) {
            Step(1, buildAnnotatedString {
                append("On your Mac, open ")
                withStyle(SpanStyle(fontWeight = FontWeight.SemiBold)) { append("Use Rich from your phone") }
                append(" and choose ")
                withStyle(SpanStyle(fontWeight = FontWeight.SemiBold)) { append("RichOS Connect") }
                append(".")
            })
            Step(2, buildAnnotatedString { append("Scan the code it shows you.") })
        }
    }
}

@Composable
private fun Step(n: Int, text: androidx.compose.ui.text.AnnotatedString) {
    val c = Rich.colors
    val t = Rich.type
    Row(horizontalArrangement = Arrangement.spacedBy(14.dp), verticalAlignment = Alignment.Top) {
        Box(
            Modifier.defaultMinSize(30.dp, 30.dp).background(c.surface, CircleShape).border(1.dp, c.lineFaint, CircleShape).padding(horizontal = 4.dp),
            contentAlignment = Alignment.Center,
        ) { BasicText(n.toString(), style = t.answer.copy(color = c.ink, fontFamily = dev.richos.android.design.RichFonts.Newsreader, lineHeight = 1.2.em)) }
        BasicText(text, style = t.body.copy(color = c.ink))
    }
}

/** 4 · Pairing in progress — brief and quiet: one line, one spinner, nothing to do. */
@Composable
fun PairingProgress() {
    val c = Rich.colors
    val t = Rich.type
    TakeoverFrame("pairing-progress") {
        BigMark()
        Eyebrow("Almost there")
        DisplayHeading("Pairing with your Mac")
        Row(Modifier.padding(top = 26.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            Spinner(16.dp)
            BasicText("Setting up a private connection…", style = t.body.copy(color = c.ink))
        }
    }
}

/** 5 · The six-word check — the trust moment. */
@Composable
fun SixWords(words: List<String>, onEvent: (UiEvent) -> Unit) {
    val c = Rich.colors
    val t = Rich.type
    val small = LocalConfiguration.current.screenWidthDp < 380
    TakeoverFrame(
        "pairing-words",
        buttons = {
            RichButton("They match", { onEvent(UiEvent.WordsMatch) }, icon = RichIcons.Check, tall = true, wide = true)
            RichButton("They do not match", { onEvent(UiEvent.WordsDoNotMatch) }, kind = ButtonKind.QUIET, wide = true)
        },
    ) {
        Eyebrow("Check these words")
        DisplayHeading("Do they match your Mac?")
        Lede("Your Mac shows the same six words. If they match, this connection is private to you.")
        val perRow = if (LocalDensity.current.fontScale > 1.3f) 1 else 2
        Column(Modifier.padding(top = 26.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            words.chunked(perRow).forEachIndexed { row, pair ->
                Row(horizontalArrangement = Arrangement.spacedBy(14.dp)) {
                    pair.forEachIndexed { i, w ->
                        Row(
                            Modifier.weight(1f).plane(RoundedCornerShape(14.dp))
                                .padding(horizontal = if (small) 14.dp else 16.dp, vertical = if (small) 11.dp else 14.dp),
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(10.dp),
                        ) {
                            // DECLARED SKIPPABLE: the word's ordinal, 14 sp; the word itself is 28 sp serif.
                            BasicText((row * perRow + i + 1).toString(), style = t.eyebrow.copy(color = c.inkSoft, letterSpacing = t.stamp.letterSpacing))
                            BasicText(w, style = (if (small) t.wordSmall else t.word).copy(color = c.ink))
                        }
                    }
                }
            }
        }
    }
}

/** 9 · This saved session needs a newer app. */
@Composable
fun NeedsNewerApp(onEvent: (UiEvent) -> Unit) {
    TakeoverFrame(
        "pairing-stale",
        buttons = {
            RichButton("Update in Google Play", { onEvent(UiEvent.UpdateInStore) }, icon = RichIcons.Download, tall = true, wide = true)
            RichButton("Support", { onEvent(UiEvent.Support) }, kind = ButtonKind.QUIET, wide = true)
        },
    ) {
        BigMark()
        Eyebrow("Newer app version needed")
        DisplayHeading("This saved session needs a newer app")
        Lede("Your data has been kept. Update this RichConnect app and everything picks up where it left off.")
    }
}

/** The consent screen before the first message (reachable later from Settings). */
@Composable
fun Consent(onEvent: (UiEvent) -> Unit) {
    TakeoverFrame(
        "pairing-consent",
        buttons = {
            RichButton("Continue", { onEvent(UiEvent.ConsentContinue) }, tall = true, wide = true)
            RichButton("Learn more", { onEvent(UiEvent.ConsentLearnMore) }, kind = ButtonKind.QUIET, wide = true)
        },
    ) {
        Eyebrow("Before your first message")
        DisplayHeading("Where your words go")
        Lede("One thing to know before you talk to Rich from this phone.")
        Column(Modifier.padding(top = 26.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) {
            ConsentRow(RichIcons.Mac, "What you type or say goes to your Mac.", "Your conversation lives there, not on our servers.")
            ConsentRow(RichIcons.Spark, "Rich (powered by your AI provider) writes the reply there.", "So, all the AI work happens on your Mac.")
            ConsentRow(RichIcons.Cloud, "Our connection service just moves the messages between your Mac and your phone.", "Encrypted on the way, stored nowhere.")
        }
    }
}

@Composable
private fun ConsentRow(icon: androidx.compose.ui.graphics.vector.ImageVector, title: String, body: String) {
    val c = Rich.colors
    val t = Rich.type
    Row(horizontalArrangement = Arrangement.spacedBy(14.dp), verticalAlignment = Alignment.Top) {
        Box(Modifier.size(40.dp).background(c.surface, CircleShape).border(1.dp, c.lineFaint, CircleShape), contentAlignment = Alignment.Center) {
            RichIcon(icon, if (c.isDark) c.signal else c.ink, 20.dp)
        }
        Column(Modifier.weight(1f)) {
            BasicText(title, style = t.bodyStrong.copy(color = c.ink))
            BasicText(body, style = t.read.copy(color = c.inkSoft), modifier = Modifier.padding(top = 2.dp))
        }
    }
}

/** 51 · Removed from the Mac — the one terminal takeover, until paired again. */
@Composable
fun RemovedFromMac(onEvent: (UiEvent) -> Unit) {
    TakeoverFrame(
        "removed-from-mac",
        buttons = { RichButton("Pair again", { onEvent(UiEvent.PairAgain) }, icon = RichIcons.Qr, tall = true, wide = true) },
    ) {
        BigMark()
        Eyebrow("Pairing ended")
        DisplayHeading("This phone was removed from your Mac")
        Lede("Someone chose “Forget this phone” on the Mac. Nothing here was lost, but Rich cannot be reached from this phone until you pair it again.")
    }
}

/** 63 · Update required — cannot be dismissed, but Support and the reassurance stay. */
@Composable
fun UpdateRequired(version: String, onEvent: (UiEvent) -> Unit) {
    val c = Rich.colors
    val t = Rich.type
    TakeoverFrame(
        "update-required",
        buttons = {
            RichButton("Update in Google Play", { onEvent(UiEvent.UpdateInStore) }, icon = RichIcons.Download, tall = true, wide = true)
            RichButton("Support", { onEvent(UiEvent.Support) }, kind = ButtonKind.QUIET, wide = true)
        },
    ) {
        Mark(64.dp, Modifier.padding(top = 12.dp, bottom = 18.dp))
        Eyebrow("Update required")
        BasicText(
            "This version of RichConnect can no longer send",
            style = t.displayBlocking.copy(color = c.ink, lineBreak = wrapping, hyphens = Hyphens.None),
            modifier = Modifier.padding(top = 14.dp).semantics { heading() },
        )
        Lede("Version $version is in Google Play now. Updating takes about a minute.")
        BasicText("Your drafts, queued messages and recordings stay on this phone.", style = t.read.copy(color = c.inkSoft), modifier = Modifier.padding(top = 10.dp))
    }
}
