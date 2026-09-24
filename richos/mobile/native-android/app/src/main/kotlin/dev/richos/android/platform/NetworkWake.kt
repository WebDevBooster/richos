package dev.richos.android.platform

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network

/** OS default-route events gate the one connection owner. No polling or internet-validation requirement. */
class NetworkWake(private val changed: (Boolean) -> Unit) : ConnectivityManager.NetworkCallback() {
    private var current: Network? = null
    override fun onAvailable(network: Network) {
        current = network
        changed(true)
    }
    override fun onLost(network: Network) {
        if (current == null || current == network) {
            current = null
            changed(false)
        }
    }

    companion object {
        fun register(context: Context, changed: (Boolean) -> Unit, tunnel: (Boolean) -> Unit = {}): Boolean = runCatching {
            val manager = context.getSystemService(ConnectivityManager::class.java) ?: return false
            changed(manager.activeNetwork != null)
            manager.registerDefaultNetworkCallback(NetworkWake(changed))
            true
        }.getOrDefault(false)
    }
}
