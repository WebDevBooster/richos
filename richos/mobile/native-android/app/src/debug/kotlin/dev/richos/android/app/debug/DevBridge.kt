package dev.richos.android.app.debug

import android.content.BroadcastReceiver
import android.content.ContentProvider
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.util.AtomicFile
import android.util.Base64
import dev.richos.android.app.DevHook
import dev.richos.android.app.richStore
import dev.richos.android.core.CoreError
import dev.richos.android.core.dev.DevRequest
import dev.richos.android.core.dev.DevRuntime
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.serialization.SerializationException
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import java.io.File
import dev.richos.android.core.protocol.Signing
import dev.richos.android.platform.AndroidKeystoreVault
import dev.richos.android.platform.KeystoreKeys
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import java.math.BigInteger
import java.security.KeyFactory
import java.security.KeyPairGenerator
import java.security.KeyStore
import java.security.Signature
import java.security.interfaces.ECPublicKey
import java.security.spec.ECGenParameterSpec
import java.security.spec.ECPoint
import java.security.spec.ECPublicKeySpec

/**
 * DEBUG ONLY. Runs development commands against the SAME [DevRuntime] the headless CLI runs,
 * inside the app, and installs that runtime's core into the app's store so the screen shows
 * what the command did. The document lives in the app's private files, so it survives a
 * process restart exactly as the headless session file does.
 */
object DevBridge {
    private val lock = Mutex()
    private var runtime: DevRuntime? = null
    private var owner: Context? = null

    fun docFile(context: Context) = File(context.filesDir, "dev/headless.json")

    /** Tests only: drop the cached runtime so the next command reopens from the file. */
    internal fun forget() {
        runtime = null
        owner = null
    }

    private suspend fun runtime(context: Context): DevRuntime {
        val app = context.applicationContext
        // One runtime per application instance: a runtime bound to another instance's files and
        // store (a test runner's previous application) is never reused.
        if (owner === app) runtime?.let { return it }
        owner = app
        val file = docFile(app)
        val atomic = AtomicFile(file)
        val initial = withContext(Dispatchers.IO) {
            if (file.exists()) DevRuntime.decodeDoc(String(atomic.readFully(), Charsets.UTF_8)) else null
        }
        return DevRuntime.create(
            initial = initial,
            save = { doc ->
                withContext(Dispatchers.IO) {
                    file.parentFile?.mkdirs()
                    val stream = atomic.startWrite()
                    try {
                        stream.write(DevRuntime.encodeDoc(doc).toByteArray(Charsets.UTF_8))
                        atomic.finishWrite(stream)
                    } catch (e: Exception) {
                        atomic.failWrite(stream)
                        throw e
                    }
                }
            },
            onCore = { core -> app.richStore.install(core) },
        ).also { runtime = it }
    }

    /** The core a debug process opens on when a development world exists. */
    suspend fun core(context: Context) = lock.withLock { runtime(context).core }

    /** One command, as the headless CLI's envelope: `{"ok","mode","command","elapsedMs","result"}`. */
    suspend fun execute(context: Context, command: String?, arg: String?): Pair<Boolean, JsonObject> = lock.withLock {
        val start = System.nanoTime()
        fun elapsed() = JsonPrimitive(Math.round((System.nanoTime() - start) / 10_000.0) / 100.0)
        try {
            if (command == "identity-check") {
                return@withLock true to envelope(command, elapsed(), identityCheck())
            }
            val request = DevRequest.parse(command, arg)
            val result = runtime(context).execute(request)
            true to JsonObject(
                linkedMapOf<String, JsonElement>(
                    "ok" to JsonPrimitive(true),
                    "mode" to JsonPrimitive("emu"),
                    "command" to JsonPrimitive(command),
                    "elapsedMs" to elapsed(),
                    "result" to result,
                ),
            )
        } catch (e: CoreError) {
            false to failure(e.message, elapsed())
        } catch (e: SerializationException) {
            false to failure("The development document is unreadable: ${e.message?.lineSequence()?.firstOrNull()}", elapsed())
        }
    }

    private fun envelope(command: String, elapsed: JsonPrimitive, result: JsonElement) = JsonObject(
        linkedMapOf(
            "ok" to JsonPrimitive(true),
            "mode" to JsonPrimitive("emu"),
            "command" to JsonPrimitive(command),
            "elapsedMs" to elapsed,
            "result" to result,
        ),
    )

    /**
     * The real Android Keystore, on this device: create a throwaway identity, sign, convert the
     * platform's DER to the raw form the Mac verifies, verify it against the exported point, then
     * delete it. The one thing about the identity a JVM test cannot prove.
     */
    private suspend fun identityCheck(): JsonElement {
        val origin = "https://identity-check.invalid"
        val keys = KeystoreKeys(AndroidKeystoreVault())
        try {
            val point = keys.publicPoint(origin)
            val data = "challenge\nPOST\n/api/messages\nidentity-check".toByteArray()
            val raw = Signing.derToRaw(keys.sign(origin, data))
            val params = (KeyPairGenerator.getInstance("EC").apply { initialize(ECGenParameterSpec("secp256r1")) }.generateKeyPair().public as ECPublicKey).params
            val public = KeyFactory.getInstance("EC").generatePublic(
                ECPublicKeySpec(ECPoint(BigInteger(1, point.copyOfRange(1, 33)), BigInteger(1, point.copyOfRange(33, 65))), params),
            )
            val verified = Signature.getInstance("SHA256withECDSA").run { initVerify(public); update(data); verify(Signing.rawToDer(raw)) }
            val exportable = runCatching { (KeyStore.getInstance("AndroidKeyStore").apply { load(null) }.getKey(KeystoreKeys.aliasFor(origin), null))?.encoded }.getOrNull()
            return buildJsonObject {
                put("pointBytes", point.size)
                put("rawSignatureBytes", raw.size)
                put("verified", verified)
                put("deviceId", Signing.deviceId(point))
                put("privateKeyExported", exportable != null)
            }
        } finally {
            keys.delete(origin)
        }
    }

    private fun failure(message: String?, elapsed: JsonPrimitive) = JsonObject(
        linkedMapOf<String, JsonElement>(
            "ok" to JsonPrimitive(false),
            "error" to JsonPrimitive(message ?: "failed"),
            "elapsedMs" to elapsed,
        ),
    )
}

/**
 * `adb shell am broadcast -n <app>/dev.richos.android.app.debug.DevBridgeReceiver
 *    --es command <verb> [--es arg64 <base64 of the argument>]`.
 * The argument is base64 so a JSON action survives the device shell's quoting untouched.
 * The reply is the result data of the ordered broadcast — base64 of the JSON envelope, result
 * code 0 or 1 — which `am broadcast` prints, so one adb call is one round trip.
 */
class DevBridgeReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val pending = goAsync()
        val command = intent.getStringExtra("command")
        val arg = intent.getStringExtra("arg64")?.let { String(Base64.decode(it, Base64.DEFAULT), Charsets.UTF_8) }
        CoroutineScope(Dispatchers.Main.immediate).launch {
            try {
                val (ok, body) = DevBridge.execute(context, command, arg)
                pending.resultCode = if (ok) 0 else 1
                pending.resultData = Base64.encodeToString(body.toString().toByteArray(Charsets.UTF_8), Base64.NO_WRAP)
            } finally {
                pending.finish()
            }
        }
    }
}

/** Opens the app on the development world when the CLI has prepared one. */
class DevBridgeInit : ContentProvider() {
    override fun onCreate(): Boolean {
        val context = context ?: return false
        // Always assigned, never left over: the hook is process-wide, and a stale factory from an
        // earlier application instance (a test runner reuses the process) must not survive.
        DevHook.coreFactory = if (DevBridge.docFile(context).exists()) ({ DevBridge.core(context) }) else null
        return true
    }

    override fun query(uri: Uri, projection: Array<out String>?, selection: String?, selectionArgs: Array<out String>?, sortOrder: String?) = null

    override fun getType(uri: Uri): String? = null

    override fun insert(uri: Uri, values: ContentValues?): Uri? = null

    override fun delete(uri: Uri, selection: String?, selectionArgs: Array<out String>?) = 0

    override fun update(uri: Uri, values: ContentValues?, selection: String?, selectionArgs: Array<out String>?) = 0
}
