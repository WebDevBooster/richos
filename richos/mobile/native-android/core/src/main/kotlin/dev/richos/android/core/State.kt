package dev.richos.android.core

import kotlinx.serialization.EncodeDefault
import kotlinx.serialization.ExperimentalSerializationApi
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

// The semantic state, field for field the shape the preserved phone core already prints
// (`richos/mobile/core/app.js` `state()` = session fields + `outbox`, `dueInMs`, `lastSend`),
// so a headless trace from this core and one from the JavaScript core read the same.
// Names are shared with the native iOS core (build plan §3.3: "the same type and action
// names so a reviewer can compare them side by side").

@Serializable
data class ConversationThread(val id: String, val title: String)

/** Dark "Sovereign" is what a new install opens in; light "Daybreak" is a choice (ceo-decisions §15). */
@Serializable
enum class Theme {
    @SerialName("dark") DARK,
    @SerialName("light") LIGHT,
}

/** What the user owns on this phone and what survives a restart. `app.js`'s `model`, plus `theme`. */
@Serializable
data class Session(
    val threads: List<ConversationThread> = emptyList(),
    val selectedThreadId: String? = null,
    val draft: String = "",
    val online: Boolean = false,
    val paired: Boolean = false,
    val theme: Theme = Theme.DARK,
)

@Serializable
enum class OutboxState {
    @SerialName("waiting") WAITING,
    @SerialName("sending") SENDING,

    /** The Mac gave a final answer; this needs the user, not a retry (`queue.js` BLOCKED). */
    @SerialName("blocked") BLOCKED,
}

/**
 * One message the user has sent that the Mac has not yet acknowledged (`queue.js` item).
 * The last two fields exist only once set, as in `queue.js`, so they are omitted while null.
 */
@OptIn(ExperimentalSerializationApi::class)
@Serializable
data class OutboxItem(
    val clientId: String,
    val threadId: String,
    val kind: String,
    val text: String,
    val state: OutboxState = OutboxState.WAITING,
    val attempts: Int = 0,
    val queuedAt: String,
    val lastReason: String? = null,
    @EncodeDefault(EncodeDefault.Mode.NEVER) val notBefore: Long? = null,
    @EncodeDefault(EncodeDefault.Mode.NEVER) val resumedAfterInterruptedSend: Boolean? = null,
)

/** What one pass over the outbox did, as data (`queue.js` `flush` result). */
@Serializable
data class SendReport(
    val sent: Int = 0,
    val waiting: Int = 0,
    val blocked: Int = 0,
    val reason: String? = null,
    val duplicates: Int = 0,
)

@Serializable
data class AppState(
    val threads: List<ConversationThread>,
    val selectedThreadId: String?,
    val draft: String,
    val online: Boolean,
    val paired: Boolean,
    val theme: Theme,
    val outbox: List<OutboxItem>,
    val dueInMs: Long?,
    val lastSend: SendReport?,
) {
    /**
     * What the gold circle in the composer shows: the microphone becomes the send arrow
     * "the moment there is a draft" (round-12 `comp-typing`). A draft of only whitespace
     * keeps the microphone, because `send` refuses it (`Message is empty`, `app.js`).
     */
    val composerAction: ComposerAction
        get() = if (draft.isBlank()) ComposerAction.RECORD else ComposerAction.SEND

    companion object {
        fun of(session: Session, outbox: List<OutboxItem>, dueInMs: Long?, lastSend: SendReport?) = AppState(
            threads = session.threads,
            selectedThreadId = session.selectedThreadId,
            draft = session.draft,
            online = session.online,
            paired = session.paired,
            theme = session.theme,
            outbox = outbox,
            dueInMs = dueInMs,
            lastSend = lastSend,
        )
    }
}

enum class ComposerAction { RECORD, SEND }
