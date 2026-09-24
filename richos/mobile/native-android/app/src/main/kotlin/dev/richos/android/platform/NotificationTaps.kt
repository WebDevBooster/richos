package dev.richos.android.platform

import android.content.Intent
import android.os.Bundle
import dev.richos.android.app.AppStore
import dev.richos.android.core.Action
import dev.richos.android.core.AppState
import dev.richos.android.core.ConnectionReason
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.filterNotNull
import kotlinx.coroutines.launch
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.withTimeoutOrNull
import java.security.MessageDigest

/**
 * Where a reply notification points (contract §7.3): the Mac's SHA-256 references to the
 * conversation and the reply, never their ids, so Google and the relay never see them. The port of
 * the native iPhone's `NotificationTarget` (`native-ios/App/Platform/Shared/NotificationTarget.swift`),
 * rule for rule: strict shapes, and anything else is not a RichConnect notification and opens nothing.
 */
data class NotificationTarget(val host: String?, val thread: String, val event: String) {
    /** The conversation this points at, once the app has its list. */
    fun threadId(state: AppState): String? = state.threads.firstOrNull { reference(it.id) == thread }?.id

    /** The reply this points at, when it is loaded in the selected conversation. */
    fun messageId(state: AppState): String? = state.messages.lastOrNull { it.role == "rich" && reference(it.id) == event }?.id

    /** The references ride on the tap's intent; nothing else from the message does. */
    fun into(intent: Intent): Intent = intent.apply {
        putExtra(EXTRA_THREAD, thread)
        putExtra(EXTRA_EVENT, event)
        host?.let { putExtra(EXTRA_HOST, it) }
    }

    /** The same references as notification extras, so a posted reply says which reply it is (D04). */
    fun extras(): Bundle = Bundle().apply {
        putString(EXTRA_THREAD, thread)
        putString(EXTRA_EVENT, event)
        host?.let { putString(EXTRA_HOST, it) }
    }

    companion object {
        const val EXTRA_HOST = "dev.richos.connect.reply.host"
        const val EXTRA_THREAD = "dev.richos.connect.reply.thread"
        const val EXTRA_EVENT = "dev.richos.connect.reply.event"

        private val hex32 = Regex("^[a-f0-9]{32}$")
        private val hex64 = Regex("^[a-f0-9]{64}$")

        /** From an FCM data message (Worker schema 3): `v` "1", a 64-hex `thread` and `event`, an optional 32-hex `host`. */
        fun fromData(data: Map<String, String>): NotificationTarget? {
            if (data["v"] != "1") return null
            return of(data["host"], data["thread"], data["event"])
        }

        /** From the tapped notification's intent; null for an ordinary launch. */
        fun fromIntent(intent: Intent?): NotificationTarget? {
            if (intent == null) return null
            return of(intent.getStringExtra(EXTRA_HOST), intent.getStringExtra(EXTRA_THREAD) ?: return null, intent.getStringExtra(EXTRA_EVENT))
        }

        /** From a posted notification's extras ([extras]); null for one that carries no reply. */
        fun fromExtras(extras: Bundle?): NotificationTarget? {
            if (extras == null) return null
            return of(extras.getString(EXTRA_HOST), extras.getString(EXTRA_THREAD), extras.getString(EXTRA_EVENT))
        }

        private fun of(host: String?, thread: String?, event: String?): NotificationTarget? {
            if (thread == null || event == null || !hex64.matches(thread) || !hex64.matches(event)) return null
            if (host != null && !hex32.matches(host)) return null
            return NotificationTarget(host, thread, event)
        }

        /** `hex(SHA-256(utf8 id))`, the Mac's reference for a conversation or a message id. */
        fun reference(id: String): String =
            MessageDigest.getInstance("SHA-256").digest(id.toByteArray(Charsets.UTF_8)).joinToString("") { "%02x".format(it) }
    }
}

/**
 * A tapped reply opens its conversation with that reply glowing once (`conv-focused`). The app may
 * be cold-starting and the reply not yet loaded, so this follows the store until it can act, asks
 * for older history a bounded number of times if the reply is further back, and gives up quietly
 * after [PATIENCE_MS]: the conversation is open either way.
 */
object NotificationTaps {
    const val PATIENCE_MS = 30_000L
    const val OLDER_CHUNKS = 5

    /** What a tap needs next, decided from one state. Pure, so it is tested without a device. */
    sealed interface Step {
        data object Wait : Step
        data class Select(val threadId: String) : Step
        data object LoadOlder : Step
        data class Open(val messageId: String, val threadId: String) : Step
    }

    /**
     * The activity's entry: a launch or new intent carrying a reply's references starts [route] on
     * [scope], once. The references are removed from the intent, so a later re-creation (rotation,
     * a return from Recents) does not open the same reply again.
     */
    fun handle(intent: Intent?, store: AppStore, scope: CoroutineScope): Job? {
        if (intent == null || intent.flags and Intent.FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY != 0) return null
        val target = NotificationTarget.fromIntent(intent) ?: return null
        intent.removeExtra(NotificationTarget.EXTRA_HOST)
        intent.removeExtra(NotificationTarget.EXTRA_THREAD)
        intent.removeExtra(NotificationTarget.EXTRA_EVENT)
        return scope.launch { route(store, target) }
    }

    fun step(state: AppState, target: NotificationTarget, olderAsked: Int): Step {
        val threadId = target.threadId(state) ?: return Step.Wait
        if (state.selectedThreadId != threadId) return Step.Select(threadId)
        target.messageId(state)?.let { return Step.Open(it, threadId) }
        // Only once the live stream has delivered the newest rows is "not loaded" a reason to look back.
        val live = state.connection.reason == ConnectionReason.CONNECTED
        return if (live && state.olderAvailable && !state.loadingOlder && olderAsked < OLDER_CHUNKS) Step.LoadOlder else Step.Wait
    }

    /** Follows [store] until the reply is focused (true) or patience runs out (false). */
    suspend fun route(store: AppStore, target: NotificationTarget, patienceMs: Long = PATIENCE_MS): Boolean =
        withTimeoutOrNull(patienceMs) {
            var olderAsked = 0
            var selected: String? = null
            var lastOlderAt: Int? = null
            store.states.filterNotNull().first { state ->
                when (val next = step(state, target, olderAsked)) {
                    Step.Wait -> false
                    is Step.Select -> {
                        if (selected != next.threadId) { selected = next.threadId; store.dispatch(Action.SelectThread(next.threadId)) }
                        false
                    }
                    Step.LoadOlder -> {
                        // One request per chunk: wait for the answer before asking again.
                        if (lastOlderAt != state.messages.size) { lastOlderAt = state.messages.size; olderAsked++; store.dispatch(Action.LoadOlder) }
                        false
                    }
                    is Step.Open -> {
                        store.dispatch(Action.OpenedFromNotification(next.messageId, next.threadId))
                        true
                    }
                }
            }
            true
        } ?: false
}
