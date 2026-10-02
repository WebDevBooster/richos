package dev.richos.android.ui

import android.app.Application
import androidx.compose.foundation.ScrollState
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.ui.Modifier
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.test.captureToImage
import androidx.compose.ui.test.junit4.v2.createComposeRule
import androidx.compose.ui.test.onAllNodesWithTag
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.dp
import dev.richos.android.core.Microphone
import dev.richos.android.core.Theme
import dev.richos.android.design.EdgeCuedRegion
import dev.richos.android.design.EdgeGuards
import dev.richos.android.design.EdgeWindow
import dev.richos.android.design.Rich
import dev.richos.android.design.RichColors
import dev.richos.android.design.RichTheme
import dev.richos.android.ui.catalog.ScreenCatalog
import dev.richos.android.ui.composer.ComposerCardView
import dev.richos.android.ui.composer.NotificationOfferCard
import dev.richos.android.ui.composer.WaitingToSendCard
import dev.richos.android.ui.model.ComposerCard
import dev.richos.android.ui.model.ScreenModel
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.launch
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

/**
 * iPhone parity (isaac-opus-r3floor1 `343be3ad2`, `61140a2ca`): at its 80 dp floor the cards' region
 * keeps a 16 dp strip for its "more above / more below" arrow and nothing else, shows whole lines and
 * controls between the strips, and comes to rest with a line or control at the top of that room: after
 * a drag, and after a card the app raises itself. Measured from the drawn pixels, not from the model.
 */
@RunWith(RobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(sdk = [35], application = Application::class, qualifiers = "w360dp-h640dp-xhdpi")
class CardsRegionRestsOnWholeLinesTest {
    @get:Rule
    val compose = createComposeRule()

    private val guards = EdgeGuards()
    private lateinit var scroll: ScrollState
    private lateinit var scope: CoroutineScope

    /** The real cards a phone raises, in a region at the 80 dp floor, on the theme's own ground. */
    private fun showCards(theme: Theme) {
        compose.setContent {
            RichTheme(theme) {
                scroll = rememberScrollState()
                scope = rememberCoroutineScope()
                Box(Modifier.width(360.dp).background(Rich.colors.ground)) {
                    EdgeCuedRegion(80.dp, scroll = scroll, guards = guards, contentPadding = PaddingValues(2.dp)) {
                        WaitingToSendCard(2) {}
                        ComposerCardView(ComposerCard.MicrophoneOff(canAsk = true)) {}
                        NotificationOfferCard {}
                    }
                }
            }
        }
        compose.waitForIdle()
    }

    private fun groundOf(theme: Theme) = (if (theme == Theme.LIGHT) RichColors.Light else RichColors.Dark).ground.toArgb()

    private fun px(dp: Float) = dp * compose.density.density

    /** Every pixel row of the region's strips holds only background, except the arrow in the middle. */
    private fun assertStripsHoldOnlyTheCue(theme: Theme, what: String) {
        val node = compose.onNodeWithTag("edge-cued-region")
        val image = node.captureToImage().asAndroidBitmap()
        val ground = groundOf(theme)
        val band = px(EdgeWindow.BandDp).toInt()
        val above = scroll.value > 1
        val below = scroll.value < scroll.maxValue - 1
        val strips = buildList {
            if (above) add(0 until band)
            if (below) add((image.height - band) until image.height)
        }
        val cue = (image.width / 2 - px(14f).toInt())..(image.width / 2 + px(14f).toInt())
        for (rows in strips) for (y in rows) for (x in 0 until image.width) {
            if (x in cue) continue
            val p = image.getPixel(x, y)
            assertEquals("$what: drawn content in a cue strip at ($x, $y), scroll ${scroll.value}/${scroll.maxValue}", ground, p)
        }
    }

    /** At rest, between the strips: a line or control starts the room (or the region is at an end). */
    private fun assertRoomStartsOnAWholeLine(what: String) {
        val viewport = compose.onNodeWithTag("edge-cued-region").fetchSemanticsNode().size.height.toFloat()
        val offset = scroll.value.toFloat()
        val above = offset > 1
        val below = offset < scroll.maxValue - 1
        val all = guards.all()
        assertTrue("$what: no lines registered", all.isNotEmpty())
        val window = EdgeWindow.shown(offset, viewport, above, below, all, px(EdgeWindow.BandDp)) ?: return
        val a = offset + window.start
        val b = offset + window.endInclusive
        // One line or control taller than the room: the room itself shows (the iPhone rule), cut or not.
        val plain = window.start == px(EdgeWindow.BandDp) && window.endInclusive == viewport - px(EdgeWindow.BandDp)
        val where = "$what: room $window of $viewport at $offset, lines $all"
        if (!plain) {
            assertTrue("$where: a line is cut at the top of the room", all.none { it.start + 0.01f < a && a < it.endInclusive - 0.01f })
            assertTrue("$where: a line is cut at the bottom of the room", all.none { it.start + 0.01f < b && b < it.endInclusive - 0.01f })
            assertTrue("$where: the room shows no whole line or control", all.any { it.start >= a - 0.5f && it.endInclusive <= b + 0.5f })
        }
        if (above && below) {
            val first = all.filter { it.start >= a - 0.5f }.minOf { it.start }
            assertTrue("$what: the room starts on bare surface ($first vs $a)", first - a <= px(2.5f))
        }
    }

    private fun dragTo(value: Int) {
        compose.runOnIdle { scope.launch { scroll.scrollTo(value) } }
        compose.waitForIdle()
        compose.mainClock.advanceTimeBy(1000)
        compose.waitForIdle()
    }

    private fun assertEveryRestingPlace(theme: Theme) {
        showCards(theme)
        val name = theme.name.lowercase()
        assertTrue("$name: the cards must overflow 80 dp", scroll.maxValue > 0)
        val max = scroll.maxValue
        val places = (0..12).map { max * it / 12 } + listOf(1, 7, max - 3)
        for (v in places) {
            dragTo(v)
            val what = "$name drag to $v of $max"
            assertStripsHoldOnlyTheCue(theme, what)
            assertRoomStartsOnAWholeLine(what)
        }
    }

    @Test
    fun `light - no text in a cue strip and the room starts on a whole line at every resting place`() = assertEveryRestingPlace(Theme.LIGHT)

    @Test
    fun `dark - no text in a cue strip and the room starts on a whole line at every resting place`() = assertEveryRestingPlace(Theme.DARK)

    @Test
    fun `the cues are present only for the edge that hides more`() {
        showCards(Theme.LIGHT)
        compose.onNodeWithTag("edge-more-below").assertExists()
        compose.onNodeWithTag("edge-more-above").assertDoesNotExist()
        dragTo(scroll.maxValue)
        compose.onNodeWithTag("edge-more-above").assertExists()
        compose.onNodeWithTag("edge-more-below").assertDoesNotExist()
    }

    // ---- a card the app raises itself ----

    private fun show(model: ScreenModel, theme: Theme): (ScreenModel) -> Unit {
        var current by mutableStateOf(model)
        compose.setContent {
            val base = LocalDensity.current
            CompositionLocalProvider(LocalDensity provides Density(base.density, 1f)) {
                RichApp(current, onEvent = {})
            }
        }
        compose.waitForIdle()
        return { current = it }
    }

    /** The floor pose of the physical-phone finding: keyboard up, "Waiting to send", then the microphone card raised. */
    private fun assertRaisedCardRestsOnAWholeLine(theme: Theme) {
        val retry = ScreenCatalog.model("conv-retry", theme, 360f).let { it.copy(keyboardDrawn = true) }
        val set = show(retry, theme)
        compose.onNodeWithText("Try now").assertExists()
        compose.runOnIdle {
            set(retry.copy(app = retry.app.copy(microphone = Microphone.DENIED, microphoneCard = true, microphoneCanAsk = false)))
        }
        compose.waitForIdle()
        compose.mainClock.advanceTimeBy(1000)
        compose.waitForIdle()
        val region = compose.onNodeWithTag("edge-cued-region").fetchSemanticsNode().boundsInRoot
        val band = px(EdgeWindow.BandDp)
        val title = compose.onNodeWithText("The microphone is off for RichConnect").fetchSemanticsNode().boundsInRoot
        assertTrue(
            "${theme.name}: the raised card's title ($title) is not whole in the room between the strips of $region",
            title.top >= region.top + band - 1f && title.bottom <= region.bottom - band + 1f,
        )
        // Nothing drawn in a strip but the arrow: the same pixel rule as a drag.
        val image = compose.onNodeWithTag("edge-cued-region").captureToImage().asAndroidBitmap()
        val cue = (image.width / 2 - px(14f).toInt())..(image.width / 2 + px(14f).toInt())
        val topCue = compose.onAllCues("edge-more-above")
        val bottomCue = compose.onAllCues("edge-more-below")
        // The screen behind the region carries speckle, so "no text" is "no ink-colored pixel": a glyph's
        // core is the theme's ink, which no speckle or card surface comes near. The room holds plenty.
        val ink = (if (theme == Theme.LIGHT) RichColors.Light else RichColors.Dark).ink.toArgb()
        fun inkIn(rows: IntRange) = rows.sumOf { y -> (0 until image.width).count { x -> x !in cue && near(image.getPixel(x, y), ink) } }
        if (topCue) assertEquals("${theme.name}: text drawn in the top strip", 0, inkIn(0 until band.toInt()))
        if (bottomCue) assertEquals("${theme.name}: text drawn in the bottom strip", 0, inkIn((image.height - band.toInt()) until image.height))
        val room = inkIn((if (topCue) band.toInt() else 0) until (if (bottomCue) image.height - band.toInt() else image.height))
        assertTrue("${theme.name}: the room between the strips shows no text at all", room > 50)
    }

    private fun near(p: Int, q: Int) = listOf(16, 8, 0).all { kotlin.math.abs(((p shr it) and 0xFF) - ((q shr it) and 0xFF)) <= 40 }

    private fun androidx.compose.ui.test.junit4.ComposeContentTestRule.onAllCues(tag: String) =
        onAllNodesWithTag(tag).fetchSemanticsNodes().isNotEmpty()

    @Test
    fun `light - an app-raised card at the floor comes to rest on a whole line`() = assertRaisedCardRestsOnAWholeLine(Theme.LIGHT)

    @Test
    fun `dark - an app-raised card at the floor comes to rest on a whole line`() = assertRaisedCardRestsOnAWholeLine(Theme.DARK)
}
