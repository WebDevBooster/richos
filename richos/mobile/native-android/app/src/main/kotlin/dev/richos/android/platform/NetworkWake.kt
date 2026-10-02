package dev.richos.android.platform

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import dev.richos.android.core.DefaultNetwork

/**
 * OS default-route events gate the one connection owner. No polling or internet-validation
 * requirement. [tunnel] reports whether that default network runs through a VPN, from the
 * capabilities the OS already delivers with it (D05: Tailscale on Android is a VPN, so a default
 * network without one is this phone off Tailscale). Only the current default network counts.
 * [switched] reports a new default network while the old one was never reported lost (the rule is
 * core's [DefaultNetwork]): the open stream is bound to the old route and is reopened.
 */
class NetworkWake(
    changed: (Boolean) -> Unit,
    private val tunnel: (Boolean) -> Unit = {},
    switched: () -> Unit = {},
) : ConnectivityManager.NetworkCallback() {
    private val default = DefaultNetwork(changed, switched)

    override fun onAvailable(network: Network) = default.available(network)

    override fun onCapabilitiesChanged(network: Network, capabilities: NetworkCapabilities) {
        if (!default.reports(network)) return
        tunnel(capabilities.hasTransport(NetworkCapabilities.TRANSPORT_VPN))
    }

    override fun onLost(network: Network) = default.lost(network)

    companion object {
        fun register(context: Context, changed: (Boolean) -> Unit, tunnel: (Boolean) -> Unit = {}, switched: () -> Unit = {}): Boolean = runCatching {
            val manager = context.getSystemService(ConnectivityManager::class.java) ?: return false
            val active = manager.activeNetwork
            changed(active != null)
            active?.let { manager.getNetworkCapabilities(it) }?.let { tunnel(it.hasTransport(NetworkCapabilities.TRANSPORT_VPN)) }
            manager.registerDefaultNetworkCallback(NetworkWake(changed, tunnel, switched))
            true
        }.getOrDefault(false)
    }
}
