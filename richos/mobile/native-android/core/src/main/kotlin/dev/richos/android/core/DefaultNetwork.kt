package dev.richos.android.core

/**
 * The OS's default network as its callback reports it (Android's `registerDefaultNetworkCallback`,
 * read by `platform/NetworkWake.kt`): whether there is one, and when it MOVES to another. The
 * networks are opaque keys (`android.net.Network` in the app), so the rule is plain Kotlin and is
 * proven on the JVM.
 *
 * - The first default network after none: [online] true (the connection owner connects).
 * - A new default while the old one was never reported lost (Wi-Fi to cellular, a VPN coming up or
 *   going down: Android reports the new default with `onAvailable` and may never say the old one
 *   went): [online] true, which changes nothing, AND [switched], because the open stream's socket
 *   is bound to the old route and may never fail on its own.
 * - The default reported lost: [online] false. A late report about a network that is no longer the
 *   default changes nothing.
 *
 * Only OS callbacks drive it: never a probe, never a timer.
 */
class DefaultNetwork(private val online: (Boolean) -> Unit, private val switched: () -> Unit) {
    /** The current default network, or null when there is none. */
    var current: Any? = null
        private set

    fun available(network: Any) {
        val previous = current
        current = network
        online(true)
        if (previous != null && previous != network) switched()
    }

    fun lost(network: Any) {
        if (current == null || current == network) {
            current = null
            online(false)
        }
    }

    /**
     * A capabilities report: true when it is about the default network (and adopts it as the
     * default when none is known yet), false when it is about some other network.
     */
    fun reports(network: Any): Boolean {
        if (current != null && current != network) return false
        current = network
        return true
    }
}
