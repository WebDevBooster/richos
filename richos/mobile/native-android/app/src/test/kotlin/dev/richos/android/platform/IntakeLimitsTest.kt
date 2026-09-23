package dev.richos.android.platform

import android.net.Uri
import android.os.Looper
import androidx.test.core.app.ApplicationProvider
import dev.richos.android.app.AppPorts
import dev.richos.android.app.AppStore
import dev.richos.android.app.RichApplication
import dev.richos.android.core.Ports
import dev.richos.android.core.RichCore
import dev.richos.android.core.Session
import dev.richos.android.core.SessionStore
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.async
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import java.io.File
import java.io.InputStream
import java.time.Duration

/**
 * A-3 (security review 2026-09-23): what another app shares is bounded while it is read, a share of
 * more items than the Mac takes stages nothing, and a refused share leaves nothing on the phone.
 */
@RunWith(RobolectricTestRunner::class)
class IntakeLimitsTest {
    private val app: RichApplication = ApplicationProvider.getApplicationContext()
    private val dir = File(app.cacheDir, "intake-limits")
    private val mib = 1024L * 1024L

    @After
    fun clean() {
        dir.deleteRecursively()
    }

    /** Serves [size] bytes (or forever) without holding them anywhere; counts what was read. */
    private class Endless(private val size: Long = Long.MAX_VALUE) : InputStream() {
        var served = 0L
        override fun read(): Int = if (served >= size) -1 else 0.also { served++ }
        override fun read(b: ByteArray, off: Int, len: Int): Int {
            if (served >= size) return -1
            val n = minOf(len.toLong(), size - served).toInt()
            java.util.Arrays.fill(b, off, off + n, 7)
            served += n
            return n
        }
    }

    private fun serve(name: String, stream: InputStream): Uri =
        Uri.parse("content://com.example.sharer/$name").also { shadowOf(app.contentResolver).registerInputStream(it, stream) }

    private fun staged() = dir.listFiles()?.toList().orEmpty()

    @Test
    fun `a file over the Mac's 25 MiB limit is refused as it is read, and no copy is left`() = runBlocking {
        val big = Endless(26 * mib)
        val refused = runCatching { Stager(app, dir).stage(serve("big.pdf", big)) }.exceptionOrNull()
        assertTrue("expected TOO_LARGE, got $refused", (refused as? Stager.Refused)?.reason == Stager.Reason.TOO_LARGE)
        assertTrue("read ${big.served} bytes of a file already over the limit", big.served <= 25 * mib + 64 * 1024)
        assertEquals(emptyList<File>(), staged())
    }

    @Test
    fun `an endless stream is refused, never read to the end`() = runBlocking {
        val endless = Endless()
        val refused = runCatching { Stager(app, dir) { 1 * mib }.stage(serve("forever.pdf", endless)) }.exceptionOrNull()
        assertTrue((refused as? Stager.Refused)?.reason == Stager.Reason.TOO_LARGE)
        assertEquals(emptyList<File>(), staged())
    }

    @Test
    fun `a file within the limit is staged byte for byte with its hash`() = runBlocking {
        val bytes = ByteArray(300_000) { (it % 251).toByte() }
        val a = Stager(app, dir).stage(serve("plan.pdf", bytes.inputStream()))
        assertEquals(300_000L, a.size)
        assertTrue(File(dir, a.id).readBytes().contentEquals(bytes))
        assertEquals(dev.richos.android.core.protocol.Signing.hex(dev.richos.android.core.protocol.Signing.sha256(bytes)), a.sha256)
    }

    @Test
    fun `a share of more items than the Mac takes stages nothing`() = runBlocking {
        val uris = (1..11).map { serve("f$it.pdf", ByteArray(10).inputStream()) }
        val intake = ShareToRich.intake(Stager(app, dir), uris, maxFiles = 10)
        assertTrue(intake.tooMany)
        assertEquals(0, intake.files.size)
        assertEquals(emptyList<File>(), staged())
        val ten = ShareToRich.intake(Stager(app, dir), uris.take(10), maxFiles = 10)
        assertEquals(10, ten.files.size)
    }

    @Test
    fun `a share the core refuses leaves no staged copy behind`() {
        val stager = Stager(app, dir)
        val files = runBlocking { listOf(stager.stage(serve("a.pdf", ByteArray(10).inputStream()))) }
        assertEquals(1, staged().size)
        val store = AppStore(app.appScope)
        store.open { RichCore.open(ports(Session(paired = false))) }
        @OptIn(ExperimentalCoroutinesApi::class)
        val outcome = app.appScope.async { ShareToRich.share(store, "", files, discard = stager::discard) }
        val deadline = System.currentTimeMillis() + 10_000
        while (!outcome.isCompleted && System.currentTimeMillis() < deadline) shadowOf(Looper.getMainLooper()).idleFor(Duration.ofMillis(10))
        if (!outcome.isCompleted) fail("the share did not settle")
        @OptIn(ExperimentalCoroutinesApi::class)
        assertEquals(ShareOutcome.NOT_PAIRED, outcome.getCompleted())
        assertEquals(emptyList<File>(), staged())
    }

    private fun ports(session: Session): Ports {
        val base = AppPorts.create(app)
        var saved = session
        return Ports(
            storage = base.storage,
            session = object : SessionStore {
                override suspend fun read() = saved
                override suspend fun write(session: Session) { saved = session }
            },
            transport = null, clock = base.clock, ids = base.ids, http = base.http, keys = base.keys,
            applicationId = base.applicationId,
        )
    }
}
