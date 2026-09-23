package dev.richos.android.ui.pairing

import android.Manifest
import android.content.pm.PackageManager
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performTextInput
import dev.richos.android.app.MainActivity
import dev.richos.android.app.richStore
import dev.richos.android.core.PairingPhase
import dev.richos.android.core.Sheet
import dev.richos.android.ui.model.PairingSurface
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config

/**
 * The real activity, its real store and the production core, headless (Robolectric): the intro's
 * buttons now do what they say. Scan asks for the camera and a no shows the camera-off dialog; a
 * phone with no camera gets the scanner saying so; the link sheet opens from the scanner, core
 * refuses a bad link with its sentence under the field, and Back closes the sheet.
 */
@RunWith(RobolectricTestRunner::class)
@Config(qualifiers = "w412dp-h915dp-xhdpi")
class PairingWiringTest {
    @get:Rule
    val compose = createAndroidComposeRule<MainActivity>()

    private fun unpairedIntro() {
        compose.waitUntil(5_000) { compose.activity.richStore.states.value != null }
        assertEquals(PairingPhase.UNPAIRED, compose.activity.richStore.states.value!!.pairing.phase)
        compose.onNodeWithTag("pairing-intro").assertIsDisplayed()
    }

    private fun cameraHardware(present: Boolean) {
        shadowOf(compose.activity.packageManager).setSystemFeature(PackageManager.FEATURE_CAMERA_ANY, present)
    }

    @Test
    fun `Scan asks for the camera only when tapped, and a no shows the camera-off dialog`() {
        unpairedIntro()
        cameraHardware(true)
        val shadow = shadowOf(compose.activity)
        assertNull("nothing asked at launch", shadow.lastRequestedPermission)
        compose.onNodeWithText("Scan your Mac’s code").performClick()
        compose.waitForIdle()
        val request = shadow.lastRequestedPermission
        assertEquals(listOf(Manifest.permission.CAMERA), request.requestedPermissions.toList())
        compose.runOnUiThread {
            compose.activity.onRequestPermissionsResult(request.requestCode, request.requestedPermissions, intArrayOf(PackageManager.PERMISSION_DENIED))
        }
        compose.waitForIdle()
        assertEquals(PairingSurface.CAMERA_DENIED, compose.activity.pairingEntry.states.value.surface)
        compose.onNodeWithTag("camera-off-dialog").assertIsDisplayed()
        // The way out to the link: the dialog closes and core opens the sheet.
        compose.onNodeWithText("Use a pairing link").performClick()
        compose.waitUntil(5_000) { compose.activity.richStore.states.value?.sheet == Sheet.PAIRING_LINK }
        compose.onNodeWithTag("pairing-link-sheet").assertIsDisplayed()
        assertNull(compose.activity.pairingEntry.states.value.surface)
    }

    @Test
    fun `no camera - the scanner says so, the link sheet opens from it, core refuses a bad link, Back closes it`() {
        unpairedIntro()
        cameraHardware(false)
        compose.onNodeWithText("Scan your Mac’s code").performClick()
        compose.waitForIdle()
        compose.onNodeWithTag("scanner").assertIsDisplayed()
        compose.onNodeWithText("The camera is not available").assertIsDisplayed()

        compose.onNodeWithText("Use a pairing link instead").performClick()
        compose.waitUntil(5_000) { compose.activity.richStore.states.value?.sheet == Sheet.PAIRING_LINK }
        compose.onNodeWithTag("pairing-link-sheet").assertIsDisplayed()

        compose.onNodeWithTag("pairlink-field").performTextInput("http://mac.example/#pair=abc")
        compose.onNodeWithText("Pair with this link").performClick()
        compose.waitUntil(5_000) { compose.activity.richStore.lastRefusal.value != null }
        compose.onNodeWithText("Pairing requires an HTTPS origin").assertIsDisplayed()
        assertEquals(Sheet.PAIRING_LINK, compose.activity.richStore.states.value?.sheet)

        compose.runOnUiThread { compose.activity.onBackPressedDispatcher.onBackPressed() }
        compose.waitUntil(5_000) { compose.activity.richStore.states.value?.sheet == null }
        compose.onNodeWithTag("pairing-intro").assertIsDisplayed()
    }
}
