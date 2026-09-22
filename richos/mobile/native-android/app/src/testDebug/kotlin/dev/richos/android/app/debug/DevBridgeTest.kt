package dev.richos.android.app.debug

import android.app.Activity
import android.content.BroadcastReceiver
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.util.Base64
import androidx.test.core.app.ApplicationProvider
import dev.richos.android.app.RichApplication
import dev.richos.android.core.dev.DevRequest
import dev.richos.android.core.dev.DevRuntime
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import android.os.Looper

/**
 * The debug bridge returns the same semantic state as the headless CLI, because it runs the
 * same runtime — checked here on the JVM for every step of the foundation scenario, and on a
 * real emulator by `randroid emu parity`.
 */
@RunWith(RobolectricTestRunner::class)
class DevBridgeTest {
    private val app: RichApplication = ApplicationProvider.getApplicationContext()

    @Before
    fun clean() {
        DevBridge.forget()
        DevBridge.docFile(app).parentFile?.deleteRecursively()
    }

    private val steps = listOf(
        "fixture" to "offline",
        "action" to """{"type":"compose","text":"Hello Rich"}""",
        "action" to """{"type":"theme","theme":"light"}""",
        "state" to null,
    )

    @Test
    fun `every step returns the state the headless runtime returns`() = runBlocking {
        val headless = DevRuntime.create()
        for ((command, arg) in steps) {
            val (ok, body) = DevBridge.execute(app, command, arg)
            assertTrue("$command failed: $body", ok)
            val expected = headless.execute(DevRequest.parse(command, arg)).jsonObject["state"]
            assertEquals("$command $arg", expected, body["result"]!!.jsonObject["state"])
        }
    }

    @Test
    fun `the bridge installs its core into the app's store, so the screen follows it`() = runBlocking {
        DevBridge.execute(app, "action", """{"type":"compose","text":"on screen"}""")
        shadowOf(Looper.getMainLooper()).idle()
        assertEquals("on screen", app.store.states.value?.draft)
    }

    @Test
    fun `a refused command answers with the error envelope`() = runBlocking {
        val (ok, body) = DevBridge.execute(app, "action", """{"type":"select-thread","threadId":"nope"}""")
        assertFalse(ok)
        assertEquals("Unknown conversation", body["error"]!!.jsonPrimitive.content)
    }

    @Test
    fun `the receiver answers an ordered broadcast with the base64 envelope`() {
        val arg = Base64.encodeToString("""{"type":"compose","text":"via broadcast"}""".toByteArray(), Base64.NO_WRAP)
        val intent = Intent()
            .setComponent(ComponentName(app, DevBridgeReceiver::class.java))
            .putExtra("command", "action")
            .putExtra("arg64", arg)
        var code = -1
        var data: String? = null
        app.sendOrderedBroadcast(intent, null, object : BroadcastReceiver() {
            override fun onReceive(context: Context, intent: Intent) {
                code = resultCode
                data = resultData
            }
        }, null, Activity.RESULT_CANCELED, null, null)
        val deadline = System.currentTimeMillis() + 5_000
        while (data == null && System.currentTimeMillis() < deadline) shadowOf(Looper.getMainLooper()).idle()
        assertEquals(0, code)
        val body = Json.parseToJsonElement(String(Base64.decode(data, Base64.DEFAULT))) as JsonObject
        assertEquals("via broadcast", (body["result"] as JsonObject)["state"]!!.jsonObject["draft"]!!.jsonPrimitive.content)
        assertTrue(DevBridge.docFile(app).isFile)
    }
}
