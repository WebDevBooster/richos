package dev.richos.android.platform

import android.app.Application
import android.net.ConnectivityManager
import androidx.test.core.app.ApplicationProvider
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.shadows.ShadowNetwork

/** The network coming back wakes the connection at once, instead of waiting out a back-off. */
@RunWith(RobolectricTestRunner::class)
class NetworkWakeTest {
    private val app: Application = ApplicationProvider.getApplicationContext()

    @Test
    fun `a returning default network wakes the connection`() {
        val events = mutableListOf<Boolean>()
        assertTrue(NetworkWake.register(app) { events += it })
        val callbacks = shadowOf(app.getSystemService(ConnectivityManager::class.java)).networkCallbacks
        assertEquals(1, callbacks.size)
        callbacks.single().onAvailable(ShadowNetwork.newInstance(7))
        assertEquals(true, events.last())
        callbacks.single().onLost(ShadowNetwork.newInstance(7))
        assertEquals(false, events.last())
    }
}
