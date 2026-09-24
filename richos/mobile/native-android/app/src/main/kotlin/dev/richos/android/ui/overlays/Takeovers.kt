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
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import dev.richos.android.core.RichCore
import dev.richos.android.design.ButtonKind
import dev.richos.android.design.Mark
import dev.richos.android.design.Rich
import dev.richos.android.design.RichButton
import dev.richos.android.design.RichIcon
import dev.richos.android.design.RichIcons
import dev.richos.android.design.ScrollEdgeFade
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
 * large; its buttons stay on screen underneath (iOS audit O2, F1: the actions never leave). While
 * more content lies below, a fade marks the scroll edge so the cut never looks like clipping
 * (Urban's 2026-09-24 audit G3). [top] and [buttonGap] are round 12.1's `.takeover` padding and
 * the air above the buttons; the consent screen tightens the first and widens the second.
 */
@Composable
fun TakeoverFrame(
    tag: String,
    buttons: @Composable ColumnScope.() -> Unit = {},
    top: Dp = 28.dp,
    buttonGap: Dp = 12.dp,
    content: @Composable ColumnScope.() -> Unit,
) {
    val c = Rich.colors
    val scroll = rememberScrollState()
    Column(
        Modifier.fillMaxSize().background(c.ground).lamp()
            .windowInsetsPadding(WindowInsets.safeDrawing)
            .padding(start = 26.dp, end = 26.dp, top = top, bottom = 20.dp)
            .semantics { testTag = tag },
    ) {
        Box(Modifier.weight(1f).fillMaxWidth()) {
            Column(Modifier.fillMaxSize().verticalScroll(scroll), content = content)
            ScrollEdgeFade(scroll, Modifier.align(Alignment.BottomCenter))
        }
        Column(Modifier.fillMaxWidth().padding(top = buttonGap), verticalArrangement = Arrangement.spacedBy(10.dp), content = buttons)
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
fun DisplayHeading(text: String, modifier: Modifier = Modifier, top: Dp = 14.dp) {
    val c = Rich.colors
    val t = Rich.type
    val small = LocalConfiguration.current.screenWidthDp < 380
    BasicText(
        text,
        style = (if (small) t.displaySmall else t.display).copy(color = c.ink, lineBreak = wrapping, hyphens = Hyphens.None),
        modifier = modifier.padding(top = top).semantics { heading() },
    )
}

@Composable
fun Lede(text: String, modifier: Modifier = Modifier, top: Dp = 16.dp) {
    val c = Rich.colors
    val t = Rich.type
    BasicText(text, style = t.answer.copy(color = c.ink), modifier = modifier.padding(top = top))
}

@Composable
fun Lede(text: androidx.compose.ui.text.AnnotatedString, modifier: Modifier = Modifier, top: Dp = 16.dp) {
    val c = Rich.colors
    val t = Rich.type
    BasicText(text, style = t.answer.copy(color = c.ink), modifier = modifier.padding(top = top))
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
 * What an unsuccessful pairing says, from core's problem code: what happened, and the one action,
 * "scan it again", which is the intro's first button (the same verb on the card and the button;
 * no second button and no "Pair again", Urban's review, question 1).
 *
 * The words are Urban's final text (richos-hq `docs/verification/2026-09-24-native-pair-v2/
 * urban-review.md`, states 4 to 9), which the PWA (`web/web-app/app.js`) and the iPhone carry too,
 * with "scan it again" for the PWA's "open it on this phone again". The update card's middle
 * sentence is Sage's (pair-v2 hypotheses review §3): an older Mac shows "Your phone said the six
 * words did not match" because this phone's refusal is the only way to make it forget the key. It
 * must NOT reassure: a relay that strips `pair-v2` from a current Mac produces the same two screens.
 */
fun pairingProblemCard(problem: String?): Pair<String, String>? = when (problem) {
    null -> null
    "refused" -> "Your Mac did not accept this code" to "Nothing was paired. Show a fresh code on your Mac and scan it again."
    "rate-limited" -> "Too many tries for now" to "Nothing was paired. Wait a minute, then scan the code again."
    "unreachable" -> "Your Mac could not be reached" to "Nothing was paired. Keep the Mac awake with RichOS running, then scan again."
    RichCore.PROBLEM_MAC_NEEDS_UPDATE -> "Your Mac needs an update" to
        "This phone cannot pair with the version of RichOS on it. Your Mac may say the six words did not match: it stopped because this phone did. Update RichOS on your Mac, then show a fresh code there and scan it again."
    RichCore.PROBLEM_MAC_DECLINED -> "Your Mac did not accept this phone" to
        "Nothing was paired. Either someone said the words did not match on your Mac, or pairing was stopped there. Show a fresh code on your Mac and scan it again."
    RichCore.PROBLEM_EXPIRED -> "Pairing timed out" to
        "This phone did not hear back from your Mac in time, so it stopped. Show a fresh code on your Mac and scan it again."
    RichCore.PROBLEM_WORDS_REJECTED -> "Stopped, and nothing was paired" to
        "If the words on this phone and your Mac were different, this phone was not talking to your Mac. Tell Rich on your Mac before you pair again."
    else -> "Pairing did not finish" to "Nothing was paired. Show a fresh code on your Mac and scan it again."
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
        val card = pairingProblemCard(problem)
        // Urban's review, acceptance check 3: at a large text size the card's title shows without
        // scrolling. The mark, the eyebrow and the pitch are for a first visit, and a person reading
        // a failure has already seen them, so with a card at large text they step aside. Urban
        // named the lede; the lede alone does not clear it at 2x on the 360 x 640 dp phone (the
        // update card's title measured 634-710 dp against a scroll edge at 367 dp), so the mark
        // and the eyebrow go too. InteractionTest measures every card.
        val compact = card != null && LocalDensity.current.fontScale >= 1.3f
        if (!compact) {
            BigMark()
            Eyebrow("Your conversation, with you")
        }
        DisplayHeading("Take Rich with you", top = if (compact) 0.dp else 14.dp)
        if (!compact) Lede("Rich works on your Mac. Pair this phone once and your conversation comes along wherever you are.")
        card?.let { (title, body) -> ErrorCard(title, body) }
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
    TakeoverFrame(
        "pairing-words",
        buttons = {
            RichButton("They match", { onEvent(UiEvent.WordsMatch) }, icon = RichIcons.Check, tall = true, wide = true)
            RichButton("They do not match", { onEvent(UiEvent.WordsDoNotMatch) }, kind = ButtonKind.QUIET, wide = true)
        },
    ) {
        Eyebrow("Check these words")
        DisplayHeading("Do they match your Mac?")
        // Never "the same six words": telling the answer before the check primes a skimmer to press
        // They match (Urban's review, state 2; the Mac's own "If they are the same six").
        Lede("Your Mac shows six words too. If they are the same six, this connection is private to you.")
        WordGrid(words)
    }
}

/** The six words, two to a row (one at a large text size), each on its own plane with its ordinal. */
@Composable
private fun WordGrid(words: List<String>) {
    val c = Rich.colors
    val t = Rich.type
    val small = LocalConfiguration.current.screenWidthDp < 380
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

/**
 * 5+ · Waiting for the press on the Mac (pairing v2, Sage F1). "They match" on the phone is
 * sent; the Mac lets this phone in only when the person presses They match there too. The screen
 * says which press is missing in the PWA's words (`web/web-app/app.js` `showWaitingForMac`),
 * keeps the words up so they can still be compared, and keeps "They do not match" as the way
 * out. Nothing moves on it: the wait is core's schedule, not an animation, so an idle screen draws
 * no frame (CEO ruling §81).
 */
@Composable
fun WaitingForMac(words: List<String>, onEvent: (UiEvent) -> Unit) {
    TakeoverFrame(
        "pairing-waiting-mac",
        buttons = {
            RichButton("They do not match", { onEvent(UiEvent.WordsDoNotMatch) }, kind = ButtonKind.QUIET, wide = true)
        },
    ) {
        Eyebrow("Almost there")
        DisplayHeading("Now press They match on your Mac")
        // Urban's review, state 3: "carries on by itself" is true however long the Mac takes to be
        // heard, "here or on your Mac" names both places, and the control's name is set in SemiBold,
        // the weight the intro's steps give control names.
        Lede(buildAnnotatedString {
            append("This phone carries on by itself once you do. If the words on your Mac are different, press ")
            withStyle(SpanStyle(fontWeight = FontWeight.SemiBold)) { append("They do not match") }
            append(", here or on your Mac.")
        })
        if (words.isNotEmpty()) WordGrid(words)
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

/**
 * The consent screen before the first message (reachable later from Settings). Its whole job is
 * to be read (Apple 5.1.2(i)): all three lines and their details sit above the buttons with 18 dp
 * of air (`.takeover:has(.consent-rows) .stack`), never cut. On the small phone the rhythm tightens
 * as round 12.1's does on its small phone (`.phone[data-device="small"] .consent-rows`); a phone
 * that is also short (the 360 × 640 dp one) tightens the same gaps further until the details fit
 * (Urban's 2026-09-24 audit G3). At a large text size it scrolls, with the scroll edge marked. The
 * words are never shortened to fit.
 */
@Composable
fun Consent(onEvent: (UiEvent) -> Unit) {
    val config = LocalConfiguration.current
    val r = ConsentRhythm.of(config.screenWidthDp, config.screenHeightDp)
    TakeoverFrame(
        "pairing-consent",
        top = r.top,
        buttonGap = 18.dp,
        buttons = {
            RichButton("Continue", { onEvent(UiEvent.ConsentContinue) }, tall = true, wide = true)
            RichButton("Learn more", { onEvent(UiEvent.ConsentLearnMore) }, kind = ButtonKind.QUIET, wide = true)
        },
    ) {
        Eyebrow("Before your first message")
        DisplayHeading("Where your words go", top = r.headingTop)
        Lede("One thing to know before you talk to Rich from this phone.", top = r.ledeTop)
        Column(Modifier.padding(top = r.rowsTop), verticalArrangement = Arrangement.spacedBy(r.rowGap)) {
            ConsentRow(RichIcons.Mac, "What you type or say goes to your Mac.", "Your conversation lives there, not on our servers.", r.detailTop)
            ConsentRow(RichIcons.Spark, "Rich (powered by your AI provider) writes the reply there.", "So, all the AI work happens on your Mac.", r.detailTop)
            ConsentRow(RichIcons.Cloud, "Our connection service just moves the messages between your Mac and your phone.", "Encrypted on the way, stored nowhere.", r.detailTop)
        }
    }
}

/**
 * The consent screen's vertical rhythm: round 12.1's regular phone (28 / 26 / 14), its small phone
 * (18 / 18 / 11), and, for a phone both narrow and short, the same gaps tightened until all three
 * details fit above the buttons at 100% text.
 */
private data class ConsentRhythm(val top: Dp, val headingTop: Dp, val ledeTop: Dp, val rowsTop: Dp, val rowGap: Dp, val detailTop: Dp) {
    companion object {
        private val regular = ConsentRhythm(top = 28.dp, headingTop = 14.dp, ledeTop = 16.dp, rowsTop = 26.dp, rowGap = 14.dp, detailTop = 2.dp)
        private val small = regular.copy(top = 18.dp, rowsTop = 18.dp, rowGap = 11.dp)
        private val smallAndShort = ConsentRhythm(top = 12.dp, headingTop = 10.dp, ledeTop = 12.dp, rowsTop = 12.dp, rowGap = 8.dp, detailTop = 0.dp)

        fun of(widthDp: Int, heightDp: Int): ConsentRhythm = when {
            widthDp < 380 && heightDp < 700 -> smallAndShort
            widthDp < 380 -> small
            else -> regular
        }
    }
}

@Composable
private fun ConsentRow(icon: androidx.compose.ui.graphics.vector.ImageVector, title: String, body: String, detailTop: Dp) {
    val c = Rich.colors
    val t = Rich.type
    Row(horizontalArrangement = Arrangement.spacedBy(14.dp), verticalAlignment = Alignment.Top) {
        Box(Modifier.size(40.dp).background(c.surface, CircleShape).border(1.dp, c.lineFaint, CircleShape), contentAlignment = Alignment.Center) {
            RichIcon(icon, if (c.isDark) c.signal else c.ink, 20.dp)
        }
        Column(Modifier.weight(1f)) {
            BasicText(title, style = t.bodyStrong.copy(color = c.ink))
            BasicText(body, style = t.read.copy(color = c.inkSoft), modifier = Modifier.padding(top = detailTop))
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
