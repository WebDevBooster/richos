package dev.richos.android.core

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

/**
 * Everything that can change [AppState]. The UI, the headless CLI and the emulator bridge
 * all produce these and all go through [RichCore.dispatch]; there is no second path.
 *
 * The JSON form is the preserved phone core's (`richos/mobile/core/app.js`), discriminated
 * by `type`: `{"type":"compose","text":"Hello"}`, `{"type":"send"}`, … so a scenario written
 * for one client reads the same on every client. `theme` is the one addition.
 */
@Serializable
sealed interface Action {
    @Serializable @SerialName("select-thread")
    data class SelectThread(val threadId: String) : Action

    @Serializable @SerialName("compose")
    data class Compose(val text: String) : Action

    @Serializable @SerialName("send")
    data object Send : Action

    @Serializable @SerialName("send-voice")
    data class SendVoice(val recording: Recording, val clientId: String? = null, val threadId: String? = null) : Action

    @Serializable @SerialName("network")
    data class Network(val online: Boolean) : Action

    @Serializable @SerialName("retry")
    data object Retry : Action

    @Serializable @SerialName("sync")
    data object Sync : Action

    @Serializable @SerialName("discard")
    data class Discard(val clientId: String) : Action

    @Serializable @SerialName("theme")
    data class SetTheme(val theme: Theme) : Action
}

@Serializable
data class Recording(val id: String, val seconds: Double)

/** A refused action or command. The message is a sentence a person can act on. */
class CoreError(message: String) : IllegalArgumentException(message)
