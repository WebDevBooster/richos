package dev.richos.android.platform

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities

/**
 * OS default-route events gate the one connection owner. No polling or internet-validation
 * requirement. [tunnel] reports whether that default network runs through a VPN, from the
 * capabilities the OS already delivers with it (D05: Tailscale on Android is a VPN, so a default
 * network without one is this phone off Tailscale). Only the current default network counts.
 */
class NetworkWake(private val changed: (Boolean) -> Unit, private val tunnel: (Boolean) -> Unit = {}) : ConnectivityManager.NetworkCallback() {
    private var current: Network? = null
    override fun onAvailable(network: Network) {
        current = network
        changed(true)
    }
    override fun onCapabilitiesChanged(network: Network, capabilities: NetworkCapabilities) {
        if (current != null && current != network) return
        current = network
        tunnel(capabilities.hasTransport(NetworkCapabilities.TRANSPORT_VPN))
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
            val active = manager.activeNetwork
            changed(active != null)
            active?.let { manager.getNetworkCapabilities(it) }?.let { tunnel(it.hasTransport(NetworkCapabilities.TRANSPORT_VPN)) }
            manager.registerDefaultNetworkCallback(NetworkWake(changed, tunnel))
            true
        }.getOrDefault(false)
    }
}
