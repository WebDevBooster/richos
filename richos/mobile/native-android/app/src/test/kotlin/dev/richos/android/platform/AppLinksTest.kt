package dev.richos.android.platform

import android.app.Application
import android.content.ComponentName
import android.content.Intent
import android.content.IntentFilter
import androidx.test.core.app.ApplicationProvider
import dev.richos.android.core.AppLinks
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import java.io.File
import javax.crypto.KeyGenerator

/**
 * Settings' three ways out of the app (privacy evidence E1, E8, E9): the privacy policy, support and
 * the Google Play listing open the addresses in [AppLinks], and a phone without the Play Store app
 * still reaches the listing on the web.
 */
@RunWith(RobolectricTestRunner::class)
class AppLinksTest {
    private val app: Application = ApplicationProvider.getApplicationContext()
    private val wrap = KeyGenerator.getInstance("AES").apply { init(256) }.generateKey()

    private fun platform() = FcmPlatform(
        app, PreviewKeys(File(app.cacheDir, "links-test/preview.key"), { wrap }), { }, { null },
        firebaseReady = { false }, main = Dispatchers.Unconfined, ledger = TokenLedger(File(app.cacheDir, "links-test/ledger")),
    )

    private fun opened(): String? = shadowOf(app).nextStartedActivity?.data?.toString()

    /** Something on the phone opens [scheme] links; with `checkActivities` on, nothing else does. */
    private fun handles(scheme: String) {
        val viewer = ComponentName("viewer.$scheme", "viewer.$scheme.Viewer")
        shadowOf(app.packageManager).addActivityIfNotPresent(viewer)
        shadowOf(app.packageManager).addIntentFilterForActivity(
            viewer,
            IntentFilter(Intent.ACTION_VIEW).apply { addCategory(Intent.CATEGORY_DEFAULT); addDataScheme(scheme) },
        )
    }

    @Test
    fun `support and the privacy policy open their pages`() = runBlocking {
        val p = platform()
        p.openPrivacyPolicy()
        assertEquals(AppLinks.privacyPolicy, opened())
        p.openSupport()
        assertEquals(AppLinks.support, opened())
    }

    @Test
    fun `the Play listing opens in the Play Store app, for the permanent application ID`() = runBlocking {
        platform().openAppStore()
        assertEquals("market://details?id=dev.richos.connect", opened())
    }

    @Test
    fun `without the Play Store app the listing opens on the web, and with nothing at all nothing fails`() = runBlocking {
        shadowOf(app).checkActivities(true)
        platform().openAppStore()
        assertNull("nothing on this phone opens either address", opened())
        handles("https")
        platform().openAppStore()
        assertEquals("https://play.google.com/store/apps/details?id=dev.richos.connect", opened())
    }
}
