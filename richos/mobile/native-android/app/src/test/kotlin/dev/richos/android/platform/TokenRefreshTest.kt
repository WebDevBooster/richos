package dev.richos.android.platform

import android.os.Looper
import androidx.test.core.app.ApplicationProvider
import dev.richos.android.app.AppPorts
import dev.richos.android.app.AppStore
import dev.richos.android.app.RichApplication
import dev.richos.android.core.Notifications
import dev.richos.android.core.NotificationStatus
import dev.richos.android.core.Ports
import dev.richos.android.core.RichCore
import dev.richos.android.core.Session
import dev.richos.android.core.SessionStore
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.async
import org.junit.After
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import java.io.File
import java.time.Duration
import javax.crypto.KeyGenerator

/**
 * A refreshed FCM token reaches the Mac even when the refresh is the first thing a fresh process
 * does. Before the fix the service read the store's state at once, found nothing yet, and dropped
 * the token: pushes then failed at Google with nobody told.
 */
@RunWith(RobolectricTestRunner::class)
class TokenRefreshTest {
    private val app: RichApplication = ApplicationProvider.getApplicationContext()
    private val dir = File(app.cacheDir, "token-refresh-test")
    private val wrap = KeyGenerator.getInstance("AES").apply { init(256) }.generateKey()
    private val keys = PreviewKeys(File(dir, "preview.key")) { wrap }
    private val token = "fcm:new-" + "t".repeat(60)

    @After
    fun clean() {
        dir.deleteRecursively()
    }

    @Test
    fun `a refresh that arrives before the store opens is handed over once it opens`() {
        val ledger = TokenLedger(File(dir, "ledger"))
        val store = AppStore(app.appScope)
        val handed = handOver(store, ledger)
        turn(300)
        assertFalse("nothing to hand over to yet", handed.isCompleted)
        store.open { RichCore.open(ports(Notifications(status = NotificationStatus.ON))) }
        turnUntil { handed.isCompleted }
        assertTrue(ledger.matches(token))
    }

    @Test
    fun `with notifications off a refresh is not handed to the Mac`() {
        val ledger = TokenLedger(File(dir, "ledger"))
        val store = AppStore(app.appScope)
        store.open { RichCore.open(ports(Notifications(status = NotificationStatus.OFF))) }
        val handed = handOver(store, ledger)
        turnUntil { handed.isCompleted }
        assertFalse(ledger.matches(token))
    }

    @OptIn(ExperimentalCoroutinesApi::class)
    private fun handOver(store: AppStore, ledger: TokenLedger) = app.appScope.async { TokenRefresh.handOver(store, token, keys, ledger, patienceMs = 5_000) }

    private fun ports(notifications: Notifications): Ports {
        val base = AppPorts.create(app)
        var saved = Session(notifications = notifications)
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

    private fun turn(ms: Long) = shadowOf(Looper.getMainLooper()).idleFor(Duration.ofMillis(ms))

    private fun turnUntil(done: () -> Boolean) {
        val deadline = System.currentTimeMillis() + 10_000
        while (!done() && System.currentTimeMillis() < deadline) turn(10)
        if (!done()) fail("not reached within 10 s of turning the main looper")
    }
}
