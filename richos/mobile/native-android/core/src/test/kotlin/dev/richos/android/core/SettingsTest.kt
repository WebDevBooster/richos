package dev.richos.android.core

import dev.richos.android.core.dev.DevRequest
import dev.richos.android.core.dev.DevRuntime
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/** Notifications, settings and update notices (round-12 groups 8, 9, 10). */
class SettingsTest {
    private suspend fun online() = DevRuntime.create().also { it.execute(DevRequest.Fixture("online")) }

    @Test
    fun `the settings scenarios pass`() = runTest {
        for (name in listOf("settings-forget", "update-policy")) {
            assertEquals(name, DevRuntime.create().execute(DevRequest.Scenario(name)).jsonObject["name"]!!.jsonPrimitive.content)
        }
    }

    @Test
    fun `notifications are asked only when paired, and turning off unregisters`() = runTest {
        val unpaired = DevRuntime.create().also { it.execute(DevRequest.Fixture("unpaired")) }
        assertEquals(NotificationStatus.NOT_ASKED, unpaired.core.dispatch(Action.TurnOnNotifications).notifications.status)
        val runtime = online()
        runtime.core.dispatch(Action.TurnOnNotifications)
        runtime.core.dispatch(Action.NotificationsResult(NotificationStatus.ON))
        assertEquals(NotificationStatus.OFF, runtime.core.dispatch(Action.TurnOffNotifications).notifications.status)
        assertEquals(listOf("register:previews", "unregister"), runtime.export().platform)
    }

    @Test
    fun `changing previews while on registers again with the new choice`() = runTest {
        val runtime = online()
        runtime.core.dispatch(Action.TurnOnNotifications)
        runtime.core.dispatch(Action.NotificationsResult(NotificationStatus.ON))
        assertFalse(runtime.core.dispatch(Action.SetPreviews(false)).notifications.previews)
        assertEquals("register:no-previews", runtime.export().platform.last())
    }

    @Test
    fun `a denied answer is kept as a status, and Not now is remembered`() = runTest {
        val runtime = online()
        runtime.core.dispatch(Action.TurnOnNotifications)
        assertEquals(NotificationStatus.DENIED, runtime.core.dispatch(Action.NotificationsResult(NotificationStatus.DENIED)).notifications.status)
        assertTrue(runtime.core.dispatch(Action.DismissNotificationOffer).notifications.offerDismissed)
        runtime.execute(DevRequest.Restart)
        assertTrue(runtime.core.state.notifications.offerDismissed)
    }

    @Test
    fun `opening a notification selects its conversation and focuses its reply until cleared`() = runTest {
        val core = online().core
        var s = core.dispatch(Action.OpenedFromNotification("turn_9:text:0", "planning"))
        assertEquals("planning", s.selectedThreadId)
        assertEquals("turn_9:text:0", s.focusMessageId)
        s = core.dispatch(Action.ClearFocus)
        assertEquals(null, s.focusMessageId)
    }

    @Test
    fun `forget keeps what was never sent, and the theme`() = runTest {
        val runtime = online()
        runtime.core.dispatch(Action.SetTheme(Theme.LIGHT))
        runtime.core.dispatch(Action.MicrophonePermission(Microphone.GRANTED))
        runtime.core.dispatch(Action.VoicePress("k", 386.0, runtime.export().now))
        runtime.execute(DevRequest.Advance(2_000))
        runtime.core.dispatch(Action.VoiceInterrupted(runtime.export().now))
        runtime.core.dispatch(Action.ForgetPairing)
        val s = runtime.core.dispatch(Action.ConfirmForget)
        assertEquals(PairingPhase.UNPAIRED, s.pairing.phase)
        assertEquals(listOf("k"), s.keptRecordings.map { it.id })
        assertEquals(Theme.LIGHT, s.theme)
    }

    @Test
    fun `forget removes the push provider's installation, whether or not notifications were ever on`() = runTest {
        val on = online()
        on.core.dispatch(Action.TurnOnNotifications)
        on.core.dispatch(Action.NotificationsResult(NotificationStatus.ON))
        on.core.dispatch(Action.ForgetPairing)
        on.core.dispatch(Action.ConfirmForget)
        assertEquals(listOf("register:previews", "unregister", "forget-installation"), on.export().platform)

        val never = online()
        never.core.dispatch(Action.ForgetPairing)
        never.core.dispatch(Action.ConfirmForget)
        assertEquals(listOf("forget-installation"), never.export().platform)
    }

    @Test
    fun `the platform screens are asked for, not opened by the core`() = runTest {
        val runtime = online()
        runtime.core.dispatch(Action.OpenSystemSettings)
        runtime.core.dispatch(Action.OpenAppStore)
        runtime.core.dispatch(Action.OpenSupport)
        assertEquals(listOf("open:system-settings", "open:app-store", "open:support"), runtime.export().platform)
    }

    @Test
    fun `check for updates opens the Play listing, and the privacy policy is one tap from Settings`() = runTest {
        val runtime = online()
        runtime.core.dispatch(Action.CheckForUpdates)
        runtime.core.dispatch(Action.OpenPrivacyPolicy)
        assertEquals(listOf("open:app-store", "open:privacy-policy"), runtime.export().platform)
        // Unpaired too: the policy must be reachable before anyone pairs (store review starts there).
        val unpaired = DevRuntime.create().also { it.execute(DevRequest.Fixture("unpaired")) }
        unpaired.core.dispatch(Action.OpenPrivacyPolicy)
        assertEquals(listOf("open:privacy-policy"), unpaired.export().platform)
    }

    @Test
    fun `every outside address lives in AppLinks, and the placeholders are named for the CEO`() {
        assertEquals(listOf("privacyPolicy", "support"), AppLinks.placeholders)
        for (url in listOf(AppLinks.privacyPolicy, AppLinks.support)) assertTrue(url.startsWith("https://"), url)
        assertEquals("market://details?id=dev.richos.connect", AppLinks.playStore("dev.richos.connect"))
        assertEquals("https://play.google.com/store/apps/details?id=dev.richos.connect", AppLinks.playStoreWeb("dev.richos.connect"))
    }
}
