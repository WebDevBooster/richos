package dev.richos.android.platform

import android.app.Application
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import androidx.test.core.app.ApplicationProvider
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.shadows.ShadowNetwork
import org.robolectric.shadows.ShadowNetworkCapabilities

/** The network coming back wakes the connection at once, instead of waiting out a back-off. */
@RunWith(RobolectricTestRunner::class)
class NetworkWakeTest {
    private val app: Application = ApplicationProvider.getApplicationContext()

    private fun capabilities(vararg transports: Int): NetworkCapabilities =
        ShadowNetworkCapabilities.newInstance().also { caps -> transports.forEach { shadowOf(caps).addTransportType(it) } }

    @Test
    fun `a returning default network wakes the connection`() {
        val events = mutableListOf<Boolean>()
        assertTrue(NetworkWake.register(app, { events += it }))
        val callbacks = shadowOf(app.getSystemService(ConnectivityManager::class.java)).networkCallbacks
        assertEquals(1, callbacks.size)
        callbacks.single().onAvailable(ShadowNetwork.newInstance(7))
        assertEquals(true, events.last())
        callbacks.single().onLost(ShadowNetwork.newInstance(7))
        assertEquals(false, events.last())
    }

    /**
     * D05: whether the default network runs through a VPN is the OS's own report, read from the
     * callback it already makes (never polled). On Android, Tailscale is a VPN: a Wi-Fi default
     * with no VPN transport is the phone with Tailscale off.
     */
    @Test
    fun `the default network's VPN transport is reported as the OS reports it, and only for the default network`() {
        val tunnel = mutableListOf<Boolean>()
        assertTrue(NetworkWake.register(app, {}, { tunnel += it }))
        val callback = shadowOf(app.getSystemService(ConnectivityManager::class.java)).networkCallbacks.single()
        val vpn = ShadowNetwork.newInstance(11)
        val wifi = ShadowNetwork.newInstance(12)
        callback.onAvailable(vpn)
        callback.onCapabilitiesChanged(vpn, capabilities(NetworkCapabilities.TRANSPORT_VPN, NetworkCapabilities.TRANSPORT_WIFI))
        assertEquals(true, tunnel.last())
        // Tailscale switched off: the default moves to plain Wi-Fi.
        callback.onAvailable(wifi)
        callback.onCapabilitiesChanged(wifi, capabilities(NetworkCapabilities.TRANSPORT_WIFI))
        assertEquals(false, tunnel.last())
        // A late report about the network that is no longer the default changes nothing.
        callback.onCapabilitiesChanged(vpn, capabilities(NetworkCapabilities.TRANSPORT_VPN))
        assertEquals(false, tunnel.last())
    }
}
