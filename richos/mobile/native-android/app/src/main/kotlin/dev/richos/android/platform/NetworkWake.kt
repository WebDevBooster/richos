package dev.richos.android.platform

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network

/**
 * The network came back: reconnect now instead of at the end of a back-off (up to 30 s). The port
 * of the web app's `online` wakeup (`web-app/app.js`: "a wakeup fires what is already owed rather
 * than adding an attempt"). [wake] is `ConnectionOwner.wake()`; the reopened link then drains the
 * outbox (andy-opus-comp1's drain, `Action.Sync` on link open and on the outbox's due time).
 *
 * Seen on emulator-5580 without it: a photo shared offline was still waiting two minutes after the
 * network returned, until "Try now" was pressed.
 */
class NetworkWake(private val wake: () -> Unit) : ConnectivityManager.NetworkCallback() {
    /** A default network appeared (Wi-Fi or mobile data back, airplane mode off). */
    override fun onAvailable(network: Network) = wake()

    companion object {
        /** Watches the default network for the life of the process; false if the OS refused. */
        fun register(context: Context, wake: () -> Unit): Boolean = runCatching {
            val manager = context.getSystemService(ConnectivityManager::class.java) ?: return false
            manager.registerDefaultNetworkCallback(NetworkWake(wake))
            true
        }.getOrDefault(false)
    }
}
