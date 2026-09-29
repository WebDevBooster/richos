package dev.richos.android.design

import android.graphics.Bitmap
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.drawWithCache
import androidx.compose.ui.graphics.FilterQuality
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.IntSize
import dev.richos.android.core.Theme
import java.util.concurrent.Callable
import java.util.concurrent.FutureTask
import kotlin.math.roundToInt

/**
 * THE SPECKLED GROUND, the phone's `mobile` background in both themes.
 *
 * The CEO, 2026-09-29: *"add this speckled background design for dark theme (round-15/v6) and this
 * for light theme (round-15/v6-light-2) to our DESIGN SYSTEM so that those background designs can
 * always be easily and reliably integrated in our desktop and mobile apps. And add the following
 * rule: The splash screens on desktop and mobile apps as well as the desktop app home screen should
 * never have that speckled background design."* Then: *"After the design system addition lands, get
 * it integrated in desktop and mobile apps."*
 *
 * This is richos-hq `design/system/speckle.js` (landed at richos-hq `8b85de45`), its engine and its
 * two `mobile` presets, ported value for value and operation for operation: the same seed, the same
 * per-device-pixel hash, the same coverage grid, the same caps solved by the same bisection, the
 * same `Math.floor` on every alpha. `SpeckleTest` holds the port to the design system's own output,
 * computed by running that file (`bin/speckle-golden.mjs`): the solved caps to the last bit and the
 * whole point field, byte for byte, at three phone sizes. Anything that differs is a defect here.
 *
 * WHAT IT IS: single device-pixel points at a low alpha, whose coverage follows a lamp pooled at the
 * top center of the screen and thinning toward the bottom. Dark: cool rgb(214,226,250) 85% and gold
 * rgb(240,208,140) 15% on #0C1322. Light: champagne gold, rose and aqua on #EAE6DD, the brighter
 * points carrying a white lit side one device pixel away. Deterministic: the same phone shows the
 * same speckle on every launch. Still: nothing moves (`shape: null` in both presets).
 *
 * CONTRAST, BY CONSTRUCTION: every point's alpha is at or under a cap solved so that every color
 * this app draws DIRECTLY on the ground keeps 4.55:1 (WCAG AA 4.5:1 plus a margin for 8-bit
 * rounding) against a point at its strongest. The preset lists the colors round 15 draws there;
 * [EXTRA_DARK] adds the one this app draws there that the dark preset does not list (danger: "Not
 * sent", the Forget row), as the design system's NOTES require. It does not bind: the caps are the
 * design system's own (dark cool 0.1132, gold 0.1241; light gold 0.85, rose 0.4846, aqua 0.64).
 * Non-text indicators on the ground (3:1) are checked against the same worst point in `SpeckleTest`.
 *
 * WHERE: [Modifier.speckle] goes on a WHOLE-SCREEN ground plane, between its ground fill and its
 * lamp (`background(ground).speckle().lamp()`: the design system paints the ground, the points over
 * it, and the lamp over both, as round 15's phone does). Today: the app's root, every takeover
 * screen, and the veil the thread fades under beneath the header. Never on a raised plane: sheets,
 * dialogs, cards, bubbles and the composer stay opaque and plain. The field is anchored to the
 * window's top-left (`space: "fixed"`), so it belongs only on planes that start there.
 *
 * THE RULE (his words above): the splash screen never carries it. On this phone the splash is the
 * system's launch window (`Theme.RichOS`'s `windowBackground`, a flat `@color/launch_ground`) and
 * the bare ground `MainActivity.AppRoot` shows until the saved state is read; neither uses this, and
 * `SpeckleTest` fails if the launch window's background stops being a flat color. There is no
 * splash surface here to ask for, by construction: [Surface] has one member.
 *
 * BATTERY (CEO ruling §81): one bounded computation per screen size and theme (about 2.6 million
 * pixels on a 1080 x 2400 phone), run once on a background thread at launch ([prewarm]) and kept;
 * then one bitmap drawn per frame the app already draws. No timer, no animation, no frame is ever
 * requested by it: an idle screen stays at 0 frames per second.
 */
object Speckle {
    /** The design system's surfaces are `desktop` and `mobile`; the phone has one. */
    enum class Surface { MOBILE }

    /** The engine's tile, in css px (dp here): the coverage grid restarts at each tile's origin. */
    const val TILE = 256
    /** The engine caps the device pixel ratio at 3; a denser screen draws the 3x field scaled up. */
    const val MAX_DPR = 3.0

    class TextPair(val rgb: DoubleArray, val a: Double, val name: String)
    class Facet(val p: Double, val vMin: Double, val shadow: Int, val min: Double)
    class Tint(
        val name: String,
        val rgb: IntArray,
        val w: Double,
        val max: Double? = null,
        val curveMin: Double? = null,
        val curveK: Double? = null,
        val facet: Facet? = null,
    )

    class Preset(
        val seed: Int,
        /** Every ground a point can land on; the lowest cap wins. */
        val grounds: List<DoubleArray>,
        val floor: Double,
        val pairs: List<TextPair>,
        val tints: List<Tint>,
        val facetDX: Int,
        val facetDY: Int,
        val alphaMin: Double,
        val alphaK: Double,
        /** The lamp's peak coverage: 30% of pixels in dark, 24% in light. */
        val peak: Double,
    )

    // ---- the presets, from design/system/speckle.js, value for value -------------------------
    private val GROUND_DARK = doubleArrayOf(12.0, 19.0, 34.0)   // #0C1322
    private val PAPER = doubleArrayOf(234.0, 230.0, 221.0)      // #EAE6DD, unlit
    private val INK_DARK = doubleArrayOf(223.0, 228.0, 238.0)
    private val INK_LIGHT = doubleArrayOf(12.0, 19.0, 34.0)

    private val PAIRS_DARK = listOf(
        TextPair(INK_DARK, 1.0, "ink"), TextPair(INK_DARK, 0.72, "ink-soft"), TextPair(INK_DARK, 0.62, "ink-faint"),
        TextPair(doubleArrayOf(126.0, 146.0, 184.0), 1.0, "trim-text"), TextPair(doubleArrayOf(194.0, 163.0, 92.0), 1.0, "gold"),
        TextPair(doubleArrayOf(143.0, 149.0, 160.0), 1.0, "rich-name"), TextPair(doubleArrayOf(164.0, 169.0, 181.0), 1.0, "your-team"),
    )
    private val PAIRS_LIGHT_MOBILE = listOf(
        TextPair(INK_LIGHT, 1.0, "ink"), TextPair(INK_LIGHT, 0.72, "ink-soft"), TextPair(doubleArrayOf(138.0, 47.0, 40.0), 1.0, "danger"),
    )

    /**
     * `extraTextPairs`: what this app draws directly on the ground that the preset does not list.
     * Dark: danger #E8837C ("Not sent", the Forget row; ContrastPairings "danger on ground").
     * Light: none (its danger #8A2F28, ink and ink-soft are the preset's own).
     */
    val EXTRA_DARK = listOf(TextPair(doubleArrayOf(232.0, 131.0, 124.0), 1.0, "danger"))
    val EXTRA_LIGHT = emptyList<TextPair>()

    private fun tintsDark() = listOf(
        Tint("cool", intArrayOf(214, 226, 250), 85.0),
        Tint("gold", intArrayOf(240, 208, 140), 15.0),
    )

    private fun spark(name: String, rgb: IntArray, w: Double, max: Double, k: Double) =
        Tint(name, rgb, w, max = max, curveMin = 0.12, curveK = k, facet = Facet(p = 0.7, vMin = 0.55, shadow = 3, min = 0.55))

    private fun tintsLight() = listOf(
        spark("gold", intArrayOf(255, 186, 30), 62.0, 0.85, 2.4),
        spark("rose", intArrayOf(255, 110, 150), 19.0, 0.6, 2.6),
        spark("aqua", intArrayOf(40, 200, 235), 19.0, 0.64, 2.6),
        Tint("lit side", intArrayOf(255, 255, 255), 0.0, max = 0.95),
    )

    fun preset(surface: Surface, theme: Theme): Preset = when (surface) {
        Surface.MOBILE -> if (theme == Theme.DARK) {
            Preset(15062, listOf(GROUND_DARK), 4.55, PAIRS_DARK + EXTRA_DARK, tintsDark(), 1, 1, 0.12, 3.0, 0.3)
        } else {
            Preset(15162, listOf(PAPER), 4.55, PAIRS_LIGHT_MOBILE + EXTRA_LIGHT, tintsLight(), -1, -1, 0.12, 2.6, 0.24)
        }
    }

    // ---- color, in sRGB, the way the browser composites (speckle.js lin/lum/ratio/over) --------
    private fun lin(c0: Double): Double {
        val c = c0 / 255
        return if (c <= 0.04045) c / 12.92 else StrictMath.pow((c + 0.055) / 1.055, 2.4)
    }

    fun lum(rgb: DoubleArray): Double = 0.2126 * lin(rgb[0]) + 0.7152 * lin(rgb[1]) + 0.0722 * lin(rgb[2])

    fun ratio(a: DoubleArray, b: DoubleArray): Double {
        val la = lum(a) + 0.05
        val lb = lum(b) + 0.05
        return if (la > lb) la / lb else lb / la
    }

    fun over(fg: DoubleArray, a: Double, bg: DoubleArray): DoubleArray =
        doubleArrayOf(fg[0] * a + bg[0] * (1 - a), fg[1] * a + bg[1] * (1 - a), fg[2] * a + bg[2] * (1 - a))

    /** The worst text pair with [tint] at alpha [a] over [ground]: its ratio, and the point's color. */
    fun worstAt(tint: DoubleArray, a: Double, ground: DoubleArray, pairs: List<TextPair>): Pair<Double, DoubleArray> {
        val bg = over(tint, a, ground)
        var worst = Double.POSITIVE_INFINITY
        for (p in pairs) {
            val r = ratio(over(p.rgb, p.a, bg), bg)
            if (r < worst) worst = r
        }
        return worst to bg
    }

    /** The largest alpha of [tint] over [ground] at which every pair still meets [floor]; bisection. */
    fun capAlpha(tint: DoubleArray, ground: DoubleArray, pairs: List<TextPair>, floor: Double): Double {
        if (worstAt(tint, 0.0, ground, pairs).first < floor) return 0.0
        var lo = 0.0
        var hi = 1.0
        repeat(48) {
            val m = (lo + hi) / 2
            if (worstAt(tint, m, ground, pairs).first >= floor) lo = m else hi = m
        }
        return lo
    }

    /** Each tint's solved cap, under its design ceiling `max` where it has one. */
    fun caps(p: Preset): DoubleArray = DoubleArray(p.tints.size) { i ->
        val t = p.tints[i]
        val rgb = DoubleArray(3) { t.rgb[it].toDouble() }
        var c = 1.0
        for (g in p.grounds) c = minOf(c, capAlpha(rgb, g, p.pairs, p.floor))
        t.max?.let { minOf(c, it) } ?: c
    }

    // ---- the field --------------------------------------------------------------------------
    /** A fast integer hash to [0, 1) per pixel (speckle.js `h3`). */
    fun h3(seed: Int, x: Int, y: Int): Double {
        var h = seed xor (x * 0x85EBCA6B.toInt()) xor (y * 0xC2B2AE35.toInt())
        h = h xor (h ushr 15); h *= 0x2C1B3C6D; h = h xor (h ushr 12); h *= 0x297A2D39; h = h xor (h ushr 15)
        return (h.toLong() and 0xFFFFFFFFL).toDouble() / 4294967296.0
    }

    /** The lamp for the phone: centered, a little wide, thinning toward the bottom (`lampMobile`). */
    private fun coverage(peak: Double, x: Double, y: Double, w: Double, h: Double): Double {
        val dx = (x - 0.5 * w) / (0.8 * w)
        val dy = (y + 0.05 * h) / (0.6 * h)
        return peak * StrictMath.exp(-(dx * dx + dy * dy))
    }

    private fun jsRound(v: Double): Int = StrictMath.floor(v + 0.5).toInt()

    /** The point field: [width] x [height] device pixels, unpremultiplied ARGB, 0 where no point is. */
    class Field(val width: Int, val height: Int, val argb: IntArray)

    /**
     * The field for a screen [widthDp] x [heightDp] at [density], exactly as speckle.js's tiles
     * write it (before compositing). The canvas is `round(size x min(density, 3))` pixels.
     */
    fun field(surface: Surface, theme: Theme, widthDp: Double, heightDp: Double, density: Double): Field {
        val p = preset(surface, theme)
        val caps = caps(p)
        val dpr = minOf(density, MAX_DPR)
        val cw = jsRound(widthDp * dpr)
        val ch = jsRound(heightDp * dpr)
        val out = IntArray(maxOf(cw, 0) * maxOf(ch, 0))
        if (cw <= 0 || ch <= 0) return Field(maxOf(cw, 0), maxOf(ch, 0), out)
        val tints = p.tints
        val nt = tints.size
        var totalW = 0.0
        for (t in tints) totalW += t.w
        val cum = DoubleArray(nt)
        var acc = 0.0
        for (i in 0 until nt) { acc += tints[i].w / totalW; cum[i] = acc }
        fun pick(w: Double): Int { var ti = 0; while (ti < nt - 1 && w > cum[ti]) ti++; return ti }
        val curveKs = DoubleArray(nt) { tints[it].curveK ?: p.alphaK }
        val curveMins = DoubleArray(nt) { tints[it].curveMin ?: p.alphaMin }
        val hasFacet = tints.any { it.facet != null }
        val seed = p.seed
        val wpx = jsRound(TILE * dpr)
        val step = 8
        val cols = wpx / step + 2
        val rows = cols
        val cov = FloatArray(cols * rows)
        var ty = 0
        while (ty * TILE < heightDp) {
            var tx = 0
            while (tx * TILE < widthDp) {
                val ox = tx * wpx
                val oy = ty * wpx
                for (j in 0 until rows) for (i in 0 until cols) {
                    cov[j * cols + i] = coverage(p.peak, (ox + i * step) / dpr, (oy + j * step) / dpr, widthDp, heightDp).toFloat()
                }
                for (py in 0 until wpx) {
                    val yCanvas = oy + py
                    if (yCanvas >= ch) break
                    val gy = py.toDouble() / step
                    val j0 = StrictMath.floor(gy).toInt()
                    val fy = gy - j0
                    for (px in 0 until wpx) {
                        val xCanvas = ox + px
                        if (xCanvas >= cw) break
                        val gx = px.toDouble() / step
                        val i0 = StrictMath.floor(gx).toInt()
                        val fx = gx - i0
                        val c00 = cov[j0 * cols + i0].toDouble()
                        val c10 = cov[j0 * cols + i0 + 1].toDouble()
                        val c01 = cov[(j0 + 1) * cols + i0].toDouble()
                        val c11 = cov[(j0 + 1) * cols + i0 + 1].toDouble()
                        val cv = (c00 * (1 - fx) + c10 * fx) * (1 - fy) + (c01 * (1 - fx) + c11 * fx) * fy
                        if (cv <= 0) continue
                        val x = xCanvas
                        val y = yCanvas
                        val u = h3(seed, x, y)
                        val a: Double
                        val t: IntArray
                        if (u >= cv) {
                            // Light only: the lit side of a brighter point one device pixel away.
                            if (!hasFacet) continue
                            val fxp = x - p.facetDX
                            val fyp = y - p.facetDY
                            if (h3(seed, fxp, fyp) >= cv) continue
                            val fti = pick(h3(seed + 104729, fxp, fyp))
                            val fc = tints[fti].facet ?: continue
                            if (h3(seed + 31337, fxp, fyp) >= fc.p) continue
                            val fv = h3(seed + 7919, fxp, fyp)
                            if (fv < fc.vMin) continue
                            val fq = (fv - fc.vMin) / (1 - fc.vMin)
                            a = caps[fc.shadow] * (fc.min + (1 - fc.min) * fq)
                            t = tints[fc.shadow].rgb
                        } else {
                            val v = h3(seed + 7919, x, y)
                            val ti = pick(h3(seed + 104729, x, y))
                            a = caps[ti] * (curveMins[ti] + (1 - curveMins[ti]) * StrictMath.pow(v, curveKs[ti]))
                            t = tints[ti].rgb
                        }
                        // floor: never above the cap.
                        val alpha = StrictMath.floor(a * 255).toInt().coerceIn(0, 255)
                        out[y * cw + x] = (alpha shl 24) or (t[0] shl 16) or (t[1] shl 8) or t[2]
                    }
                }
                tx++
            }
            ty++
        }
        return Field(cw, ch, out)
    }

    // ---- the bitmap, computed once per screen size and theme ----------------------------------
    private data class Key(val theme: Theme, val widthPx: Int, val heightPx: Int, val density: Float)

    /** The last two fields (a theme switch and back costs nothing). */
    private val cache = LinkedHashMap<Key, FutureTask<ImageBitmap>>()

    private fun task(key: Key): Pair<FutureTask<ImageBitmap>, Boolean> = synchronized(cache) {
        cache[key]?.let { return it to false }
        val t = FutureTask(Callable {
            val f = field(Surface.MOBILE, key.theme, key.widthPx / key.density.toDouble(), key.heightPx / key.density.toDouble(), key.density.toDouble())
            Bitmap.createBitmap(f.argb, f.width, f.height, Bitmap.Config.ARGB_8888).asImageBitmap()
        })
        cache[key] = t
        while (cache.size > 2) cache.remove(cache.keys.first())
        t to true
    }

    /**
     * Starts the field for a screen [widthPx] x [heightPx] on one background thread, once, so the
     * first frame finds it drawn. Called from `MainActivity.onCreate` with the window's size.
     */
    fun prewarm(theme: Theme, widthPx: Int, heightPx: Int, density: Float) {
        if (widthPx <= 0 || heightPx <= 0) return
        val (t, fresh) = task(Key(theme, widthPx, heightPx, density))
        if (fresh) Thread(t, "richos-speckle").apply { priority = Thread.NORM_PRIORITY - 1 }.start()
    }

    /** The field's bitmap for this screen: the prewarmed one, or computed here once if none was started. */
    fun image(theme: Theme, widthPx: Int, heightPx: Int, density: Float): ImageBitmap? {
        if (widthPx <= 0 || heightPx <= 0) return null
        val (t, fresh) = task(Key(theme, widthPx, heightPx, density))
        if (fresh) t.run()
        return t.get()
    }
}

/**
 * The speckled ground on a whole-screen ground plane: `background(ground).speckle().lamp()`. See
 * [Speckle] for where it belongs and where it never goes (the splash screen, any raised plane).
 */
@Composable
fun Modifier.speckle(): Modifier {
    val theme = if (Rich.colors.isDark) Theme.DARK else Theme.LIGHT
    return drawWithCache {
        val w = size.width.roundToInt()
        val h = size.height.roundToInt()
        val image = Speckle.image(theme, w, h, density)
        onDrawBehind {
            if (image != null) {
                val exact = image.width == w && image.height == h
                drawImage(image, IntOffset.Zero, IntSize(image.width, image.height), IntOffset.Zero, IntSize(w, h),
                    filterQuality = if (exact) FilterQuality.None else FilterQuality.Low)
            }
        }
    }
}
