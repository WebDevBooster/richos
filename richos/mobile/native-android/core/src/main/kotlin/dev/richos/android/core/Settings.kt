package dev.richos.android.core

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

// Notifications, Settings and update notices (round-12 groups 8, 9, 10), as the native iOS core
// has them (`SettingsReducer`, `UpdateReducer`): same statuses, same sheets, same action names.

@Serializable
enum class NotificationStatus {
    @SerialName("not-asked") NOT_ASKED,
    @SerialName("turning-on") TURNING_ON,
    @SerialName("on") ON,
    @SerialName("off") OFF,

    /** Refused in the phone's settings. */
    @SerialName("denied") DENIED,
    @SerialName("unsupported") UNSUPPORTED,

    /** The platform's push service could not be reached (FCM on Android, APNs on iOS). */
    @SerialName("platform-unavailable") PLATFORM_UNAVAILABLE,
    @SerialName("service-unavailable") SERVICE_UNAVAILABLE,
}

/** Opt-in, asked once in a card with a real "Not now" (`notif-offer`); every status is a sentence in Settings. */
@Serializable
data class Notifications(
    val status: NotificationStatus = NotificationStatus.NOT_ASKED,
    /** `notif-offer` was answered "Not now"; it is asked once. */
    val offerDismissed: Boolean = false,
    /** Lock-screen previews of Rich's reply, decrypted on the phone. On by default. */
    val previews: Boolean = true,
)

@Serializable
enum class Sheet {
    @SerialName("settings") SETTINGS,

    /** `settings-forget` */
    @SerialName("forget") FORGET,

    /** `settings-forget-blocked` */
    @SerialName("forget-blocked") FORGET_BLOCKED,

    /** Settings, "Where your messages go" (the consent text, again). */
    @SerialName("where-messages-go") WHERE_MESSAGES_GO,

    /** Paste a pairing link instead of scanning. */
    @SerialName("pairing-link") PAIRING_LINK,
}

/** A hosted update policy's notice (contract §5.10; round-12 group 10). */
@Serializable
data class UpdateNotice(val prominence: Prominence, val version: String, val message: String) {
    @Serializable
    enum class Prominence {
        /** `upd-banner` */
        @SerialName("banner") BANNER,

        /** `upd-dialog` */
        @SerialName("dialog") DIALOG,

        /** `upd-blocking`: cannot be dismissed; Support and the reassurance stay. */
        @SerialName("required") REQUIRED,
    }
}

/** The platform's half of settings: the OS prompts and screens the core only asks for. Defaults do nothing. */
interface Platform {
    /** Register for push (and ask the OS once); the answer returns as `notifications-result`. */
    suspend fun requestNotifications(previews: Boolean) {}

    suspend fun unregisterNotifications() {}

    /**
     * Forget: remove what the push provider keeps about this phone (on Android, Firebase's
     * installation ID, on this phone and at Firebase), whether or not notifications were ever on.
     */
    suspend fun forgetInstallation() {}

    suspend fun openSystemSettings() {}

    suspend fun openAppStore() {}

    suspend fun openSupport() {}

    suspend fun openPrivacyPolicy() {}

    companion object {
        val NONE: Platform = object : Platform {}
    }
}
