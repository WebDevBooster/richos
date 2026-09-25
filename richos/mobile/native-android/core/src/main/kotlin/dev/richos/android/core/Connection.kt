package dev.richos.android.core

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

/**
 * Why the phone is or is not talking to the Mac. The port of the preserved phone's rules
 * (`richos/web/web-app/lib/connection.js` `classify`, and `richos/mobile/core/client.js`'s
 * notice timing), so every client shows the same state for the same evidence:
 *
 *  - revoked beats everything (terminal until paired again), then incompatible, then connected;
 *  - otherwise the phone's own network, then the managed service's health, then the Mac;
 *  - a healthy relay does not prove the Mac is asleep, so "Mac unreachable" from a health probe
 *    is shown as reconnecting, never as a verdict about the Mac.
 */
@Serializable
enum class ConnectionReason {
    @SerialName("connecting") CONNECTING,
    @SerialName("connected") CONNECTED,
    @SerialName("reconnecting") RECONNECTING,
    @SerialName("phone-offline") PHONE_OFFLINE,
    @SerialName("service-unavailable") SERVICE_UNAVAILABLE,
    @SerialName("mac-unreachable") MAC_UNREACHABLE,
    @SerialName("revoked") REVOKED,
    @SerialName("incompatible") INCOMPATIBLE,
    /** Paired over Tailscale, and the OS reports no VPN on this phone's default network (D05). */
    @SerialName("tailscale-off") TAILSCALE_OFF,
}

/**
 * What a screen shows about the connection. [notice] is the reason a user should SEE, or null:
 * brief recovery is invisible, and connecting/reconnecting earn a notice only after
 * [NOTICE_AFTER_MS] of continuous trouble (round-12 `conn-reconnecting`: "Shown only after 3 s of
 * trouble"). [noticeDueInMs] tells the app's one timer when the notice would appear.
 */
@Serializable
data class ConnectionState(
    val reason: ConnectionReason = ConnectionReason.CONNECTING,
    val notice: ConnectionReason? = null,
    val noticeDueInMs: Long? = null,
    val hasConnected: Boolean = false,
    val troubleSince: Long? = null,
) {
    companion object {
        const val NOTICE_AFTER_MS = 3_000L
    }
}

/** The stream owner's view of its socket (the preserved link's `onState`). */
@Serializable
enum class LinkStatus {
    @SerialName("opening") OPENING,
    @SerialName("open") OPEN,
    @SerialName("away") AWAY,
}

/** The service health probe's verdict on the managed route (`connection.js` `probe`). */
@Serializable
enum class ServiceState {
    @SerialName("available") AVAILABLE,
    @SerialName("unavailable") UNAVAILABLE,
    @SerialName("unknown") UNKNOWN,
}

object Connections {
    /** A RichOS Connect origin (`connection.js` `managed`): only there is the service probed. */
    fun managed(origin: String?): Boolean = origin != null && Regex("^https://c-[a-f0-9]{32}-g[1-9][0-9]*\\.richos\\.ceo$").matches(origin)

    fun classify(connected: Boolean, revoked: Boolean, unsupported: Boolean, phoneOnline: Boolean?, service: ServiceState?): ConnectionReason = when {
        revoked -> ConnectionReason.REVOKED
        unsupported -> ConnectionReason.INCOMPATIBLE
        connected -> ConnectionReason.CONNECTED
        phoneOnline == false -> ConnectionReason.PHONE_OFFLINE
        service == ServiceState.UNAVAILABLE -> ConnectionReason.SERVICE_UNAVAILABLE
        else -> ConnectionReason.MAC_UNREACHABLE
    }

    /**
     * **D05: WHAT THE PHONE CAN SAY ABOUT TAILSCALE, FROM THE OS'S OWN WORD.** Paired over the
     * Tailscale route (`*.ts.net`, contract §1.1), with the OS reporting that the default network
     * runs through no VPN ([vpn] false; Tailscale on Android is a VPN), a phone that is merely
     * away cannot reconnect by itself: "Reconnecting…" would not be true, and the fix is the
     * person's to make. Only the quiet reasons are refined; offline, the service, revoked and
     * incompatible say what they say. An unknown [vpn] (no report yet) is never guessed.
     */
    fun cause(reason: ConnectionReason, route: Route?, paired: Boolean, vpn: Boolean?): ConnectionReason =
        if (paired && route == Route.TAILNET && vpn == false && reason in REFINABLE) ConnectionReason.TAILSCALE_OFF else reason

    private val REFINABLE = setOf(ConnectionReason.CONNECTING, ConnectionReason.RECONNECTING, ConnectionReason.MAC_UNREACHABLE)

    /**
     * The published view at [now]: the notice rule applied to the raw [state]. [ConnectionReason.TAILSCALE_OFF]
     * keeps the same quiet 3 s as reconnecting (a Tailscale that is coming up by itself is never
     * announced), then names the fix, once: no timer after it (D05).
     */
    fun view(state: ConnectionState, now: Long): ConnectionState {
        val quietWhile = state.reason == ConnectionReason.CONNECTING || state.reason == ConnectionReason.RECONNECTING ||
            state.reason == ConnectionReason.TAILSCALE_OFF
        return when {
            state.reason == ConnectionReason.CONNECTED -> state.copy(notice = null, noticeDueInMs = null)
            !quietWhile -> state.copy(notice = state.reason, noticeDueInMs = null)
            // No trouble has started (the link has not reported yet): nothing to say, nothing due.
            state.troubleSince == null -> state.copy(notice = null, noticeDueInMs = null)
            else -> {
                val waited = now - state.troubleSince
                val persistent = if (state.reason == ConnectionReason.TAILSCALE_OFF) ConnectionReason.TAILSCALE_OFF else ConnectionReason.RECONNECTING
                if (waited >= ConnectionState.NOTICE_AFTER_MS) state.copy(notice = persistent, noticeDueInMs = null)
                else state.copy(notice = null, noticeDueInMs = ConnectionState.NOTICE_AFTER_MS - waited)
            }
        }
    }
}
