package dev.richos.android.design

import dev.richos.android.core.Theme
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File
import java.io.RandomAccessFile

/**
 * Cold start: the speckled ground is computed once per install, theme and screen size, and every
 * later launch reads it back (design/Speckle.kt FieldStore).
 *
 * Measured 2026-10-02 on the Android test phone: computing the field on every cold launch took
 * half a second of wall time and 220 ms of CPU, and the first useful frame waited 94 ms for it,
 * raising the launch's median from 755 to 839 ms. These cases hold the fix: a launch that finds the
 * field kept computes nothing, reads back exactly the design system's field, and never draws a
 * field kept by another build or a damaged file.
 */
class SpeckleStoreTest {
    @get:Rule
    val tmp = TemporaryFolder()

    // A small screen keeps the computation quick; the store does not care about the size.
    private val w = 200
    private val h = 400
    private val density = 2f

    private fun launch(store: FieldStore, theme: Theme = Theme.LIGHT): Pair<Speckle.Field, Int> {
        var computed = 0
        val f = Speckle.fieldFor(theme, w, h, density, store) { computed++; store.write(theme, w, h, density, it) }
        return f to computed
    }

    @Test
    fun `a later launch of the same build computes nothing and draws the same field`() {
        val dir = tmp.newFolder("speckle")
        val (first, firstComputed) = launch(FieldStore(dir, "build-1"))
        assertEquals("the first launch computes the field", 1, firstComputed)
        // A new process: a new store over the same directory.
        val (second, secondComputed) = launch(FieldStore(dir, "build-1"))
        assertEquals("a later launch reads the kept field and computes nothing", 0, secondComputed)
        assertEquals(first.width, second.width)
        assertEquals(first.height, second.height)
        assertArrayEquals("the kept field is the design system's, byte for byte", first.argb, second.argb)
        val fresh = Speckle.field(Speckle.Surface.MOBILE, Theme.LIGHT, w / density.toDouble(), h / density.toDouble(), density.toDouble())
        assertArrayEquals(fresh.argb, second.argb)
    }

    @Test
    fun `each theme is kept on its own`() {
        val dir = tmp.newFolder("speckle")
        val store = FieldStore(dir, "build-1")
        launch(store, Theme.LIGHT)
        val (dark, computed) = launch(store, Theme.DARK)
        assertEquals("the other theme is computed, never the light one drawn in its place", 1, computed)
        val expected = Speckle.field(Speckle.Surface.MOBILE, Theme.DARK, w / density.toDouble(), h / density.toDouble(), density.toDouble())
        assertArrayEquals(expected.argb, dark.argb)
        assertEquals(0, launch(FieldStore(dir, "build-1"), Theme.DARK).second)
        assertEquals(0, launch(FieldStore(dir, "build-1"), Theme.LIGHT).second)
    }

    @Test
    fun `a new build computes afresh and removes the old build's files`() {
        val dir = tmp.newFolder("speckle")
        launch(FieldStore(dir, "build-1"))
        val old = dir.listFiles()!!.toList()
        assertEquals(1, old.size)
        assertNull("another build's field is never read", FieldStore(dir, "build-2").read(Theme.LIGHT, w, h, density))
        assertEquals(1, launch(FieldStore(dir, "build-2")).second)
        assertFalse("the old build's file is gone", old.single().exists())
        assertEquals(1, dir.listFiles()!!.size)
    }

    @Test
    fun `a damaged or cut-off file is computed again, never drawn`() {
        val dir = tmp.newFolder("speckle")
        val store = FieldStore(dir, "build-1")
        launch(store)
        val kept: File = dir.listFiles()!!.single()
        // Cut off halfway: a write the phone lost power during.
        RandomAccessFile(kept, "rw").use { it.setLength(it.length() / 2) }
        assertNull(store.read(Theme.LIGHT, w, h, density))
        assertEquals(1, launch(store).second)
        assertNotNull(store.read(Theme.LIGHT, w, h, density))
        // Bytes changed inside the compressed field.
        RandomAccessFile(kept, "rw").use { f -> f.seek(f.length() - 40); f.write(ByteArray(16) { 0x5A }) }
        assertNull(store.read(Theme.LIGHT, w, h, density))
        assertEquals(1, launch(store).second)
        // Not a field at all.
        kept.writeText("not a field")
        assertNull(store.read(Theme.LIGHT, w, h, density))
    }

    @Test
    fun `without a store the field is computed as before`() {
        var computed = 0
        val f = Speckle.fieldFor(Theme.DARK, w, h, density, null) { computed++ }
        assertEquals(1, computed)
        assertTrue(f.argb.any { it != 0 })
    }
}
