package dev.richos.android.core

/**
 * Every address outside the app that RichConnect opens, in ONE place: the privacy policy, support,
 * and this app's Google Play listing (Settings rows, the update notices, `pair-stale`). The names are
 * the iPhone's (`native-ios/Core/Sources/RichOSCore/Settings/AppLinks.swift`), so one list serves both.
 *
 * **PLACEHOLDERS: the CEO fills these before submission.** Neither page is hosted yet (App Store
 * listing drafts, blockers 2 and 3). Each value below is a stand-in; [placeholders] names the ones
 * still unset, so a release check can refuse a build that ships them.
 */
object AppLinks {
    /** PLACEHOLDER(CEO): the hosted privacy policy. Google Play and Apple both require a link inside the app. */
    const val privacyPolicy = "https://richos.ceo/privacy"

    /** PLACEHOLDER(CEO): the support page, with the contact details the stores require. */
    const val support = "https://richos.ceo/support"

    /**
     * This app's Google Play listing, opened in the Play Store app. NOT a placeholder: the
     * application ID `dev.richos.connect` is permanent (the CEO approved it on 2026-09-23).
     */
    fun playStore(applicationId: String) = "market://details?id=$applicationId"

    /** The same listing on the web, for a phone with no Play Store app. */
    fun playStoreWeb(applicationId: String) = "https://play.google.com/store/apps/details?id=$applicationId"

    /** The constants above still holding a stand-in. Empty once the CEO has filled both. */
    val placeholders: List<String> = listOf("privacyPolicy", "support")
}
