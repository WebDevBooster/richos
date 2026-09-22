package dev.richos.android.platform

import android.Manifest
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.AtomicFile
import androidx.activity.ComponentActivity
import androidx.activity.result.ActivityResultLauncher
import androidx.activity.result.contract.ActivityResultContracts
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import com.google.firebase.FirebaseApp
import com.google.firebase.FirebaseOptions
import com.google.firebase.messaging.FirebaseMessaging
import com.google.firebase.messaging.FirebaseMessagingService
import com.google.firebase.messaging.RemoteMessage
import dev.richos.android.BuildConfig
import dev.richos.android.app.richStore
import dev.richos.android.core.Action
import dev.richos.android.core.NotificationStatus
import dev.richos.android.core.Platform
import dev.richos.android.core.protocol.NotificationPreview
import dev.richos.android.core.protocol.Signing
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import java.io.File
import java.security.KeyStore
import java.security.SecureRandom
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec
import kotlin.coroutines.resume

/**
 * The phone's preview key (contract §7.2): 32 random bytes the Mac seals previews with, sent once
 * at registration. At rest it is wrapped by a non-exportable AES key ([wrapper]), so the file alone
 * opens nothing (build plan §3.3 "stored wrapped by a Keystore AES key").
 */
class PreviewKeys(private val file: File, private val wrapper: () -> SecretKey) {
    fun key(): ByteArray = read() ?: ByteArray(32).also { SecureRandom().nextBytes(it); write(it) }

    fun existing(): ByteArray? = runCatching { read() }.getOrNull()

    /** Tests only: store a known key. */
    internal fun adopt(key: ByteArray) = write(key)

    private fun read(): ByteArray? {
        if (!file.isFile) return null
        val stored = AtomicFile(file).readFully()
        if (stored.size < 13) return null
        val iv = stored.copyOfRange(0, 12)
        return Cipher.getInstance("AES/GCM/NoPadding").run {
            init(Cipher.DECRYPT_MODE, wrapper(), GCMParameterSpec(128, iv))
            doFinal(stored.copyOfRange(12, stored.size))
        }
    }

    private fun write(key: ByteArray) {
        file.parentFile?.mkdirs()
        val cipher = Cipher.getInstance("AES/GCM/NoPadding").apply { init(Cipher.ENCRYPT_MODE, wrapper()) }
        val sealed = cipher.iv + cipher.doFinal(key)
        val atomic = AtomicFile(file)
        val out = atomic.startWrite()
        try {
            out.write(sealed)
            atomic.finishWrite(out)
        } catch (e: Exception) {
            atomic.failWrite(out)
            throw e
        }
    }

    companion object {
        private const val ALIAS = "dev.richos.native.android.preview-wrap"

        /** The Android Keystore AES key that wraps the preview key; created on first use. */
        fun keystoreWrapper(): SecretKey {
            val store = KeyStore.getInstance(AndroidKeystoreVault.PROVIDER).apply { load(null) }
            (store.getKey(ALIAS, null) as? SecretKey)?.let { return it }
            return KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, AndroidKeystoreVault.PROVIDER).run {
                init(
                    KeyGenParameterSpec.Builder(ALIAS, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                        .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                        .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                        .setKeySize(256)
                        .build(),
                )
                generateKey()
            }
        }

        fun forApp(context: Context) = PreviewKeys(File(context.filesDir, "push/preview.key"), ::keystoreWrapper)
    }
}

/** Firebase's four public identifiers from the build; null when this build has none. */
object FirebaseConfig {
    fun options(): FirebaseOptions? {
        if (BuildConfig.FIREBASE_APP_ID.isBlank() || BuildConfig.FIREBASE_PROJECT_ID.isBlank() || BuildConfig.FIREBASE_API_KEY.isBlank()) return null
        return FirebaseOptions.Builder()
            .setApplicationId(BuildConfig.FIREBASE_APP_ID)
            .setProjectId(BuildConfig.FIREBASE_PROJECT_ID)
            .setApiKey(BuildConfig.FIREBASE_API_KEY)
            .setGcmSenderId(BuildConfig.FIREBASE_SENDER_ID)
            .build()
    }

    /** Initializes Firebase once, in code (no google-services plugin); false when unconfigured. */
    fun ensure(context: Context): Boolean {
        if (FirebaseApp.getApps(context).isNotEmpty()) return true
        val options = options() ?: return false
        FirebaseApp.initializeApp(context, options)
        return true
    }
}

/**
 * Core's [Platform] port on Android: push through FCM, and the OS screens the core asks for. The
 * core decides WHEN to register and what the status means; this asks the OS (POST_NOTIFICATIONS on
 * Android 13+), fetches the FCM token and hands it back as `push-token`. A build without the
 * Firebase configuration reports `platform-unavailable` rather than failing.
 */
class FcmPlatform(
    private val context: Context,
    private val previewKeys: PreviewKeys,
    private val dispatch: (Action) -> Unit,
    private val foreground: () -> ComponentActivity?,
    private val firebaseReady: () -> Boolean = { FirebaseConfig.ensure(context) },
    private val fetchToken: suspend () -> String? = ::defaultToken,
    /** Where the OS prompts run; a test substitutes one that does not need a running looper. */
    private val main: kotlinx.coroutines.CoroutineDispatcher = Dispatchers.Main,
) : Platform {
    override suspend fun requestNotifications(previews: Boolean) {
        if (!firebaseReady()) {
            dispatch(Action.NotificationsResult(NotificationStatus.PLATFORM_UNAVAILABLE))
            return
        }
        if (!notificationPermission()) {
            dispatch(Action.NotificationsResult(NotificationStatus.DENIED))
            return
        }
        val token = runCatching { fetchToken() }.getOrNull()
        if (token.isNullOrBlank()) {
            dispatch(Action.NotificationsResult(NotificationStatus.PLATFORM_UNAVAILABLE))
            return
        }
        val key = if (previews) withContext(Dispatchers.IO) { runCatching { previewKeys.key() }.getOrNull() } else null
        dispatch(Action.PushToken(token, key?.let(Signing::base64url)))
    }

    override suspend fun unregisterNotifications() {
        if (FirebaseApp.getApps(context).isNotEmpty()) runCatching { FirebaseMessaging.getInstance().deleteToken() }
    }

    override suspend fun openSystemSettings() = start(
        Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.fromParts("package", context.packageName, null)),
    )

    override suspend fun openAppStore() = start(Intent(Intent.ACTION_VIEW, Uri.parse("market://details?id=${context.packageName}")))

    private suspend fun start(intent: Intent) = withContext(main) {
        runCatching { context.startActivity(intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)) }
        Unit
    }

    /** Android 13+ asks; older versions grant notifications at install. */
    private suspend fun notificationPermission(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return true
        if (ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED) return true
        return withContext(main) {
            val activity = foreground() ?: return@withContext false
            suspendCancellableCoroutine { done ->
                var launcher: ActivityResultLauncher<String>? = null
                launcher = activity.activityResultRegistry.register("richos-notifications-${System.nanoTime()}", ActivityResultContracts.RequestPermission()) { ok ->
                    launcher?.unregister()
                    if (done.isActive) done.resume(ok)
                }
                launcher.launch(Manifest.permission.POST_NOTIFICATIONS)
            }
        }
    }

    companion object {
        private suspend fun defaultToken(): String? = suspendCancellableCoroutine { done ->
            FirebaseMessaging.getInstance().token
                .addOnSuccessListener { if (done.isActive) done.resume(it) }
                .addOnFailureListener { if (done.isActive) done.resume(null) }
        }
    }
}

/**
 * FCM's entry into the app (Worker schema 3): a high-priority DATA message carrying only strings —
 * `v`, `host`, `thread`, `event` and, with previews on, `preview` (the Mac's sealed envelope). The
 * app decrypts on the phone and ALWAYS posts a visible notification: the reply's words when they
 * open, "Rich has replied." otherwise (Android deprioritizes high-priority messages that show nothing).
 */
class RichMessagingService : FirebaseMessagingService() {
    override fun onNewToken(token: String) {
        // Registered with the Mac only while notifications are on; the core decides.
        val store = applicationContext.richStore
        if (store.states.value?.notifications?.status == NotificationStatus.ON) {
            val previews = store.states.value?.notifications?.previews == true
            val key = if (previews) keysFor(this).existing() else null
            store.dispatch(Action.PushToken(token, key?.let(Signing::base64url)))
        }
    }

    override fun onMessageReceived(message: RemoteMessage) {
        val data = message.data
        if (data["v"] != "1") return
        val text = NotificationPreview.textOrGeneric(keysFor(this).existing(), data["thread"], data["event"], data["preview"])
        Replies.post(this, text, collapse = data["event"])
    }

    companion object {
        /** Where the service finds the preview key; a test substitutes a JVM-wrapped one. */
        internal var keysFor: (Context) -> PreviewKeys = PreviewKeys::forApp
    }
}

/** The replies channel and the one notification a reply gets. */
object Replies {
    const val CHANNEL = "replies"

    fun ensureChannel(context: Context) {
        val manager = context.getSystemService(NotificationManager::class.java) ?: return
        if (manager.getNotificationChannel(CHANNEL) == null) {
            manager.createNotificationChannel(NotificationChannel(CHANNEL, "Rich's replies", NotificationManager.IMPORTANCE_HIGH))
        }
    }

    fun post(context: Context, text: String, collapse: String?) {
        ensureChannel(context)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
        ) {
            return
        }
        val open = context.packageManager.getLaunchIntentForPackage(context.packageName)?.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
        val tap = open?.let { PendingIntent.getActivity(context, 0, it, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT) }
        val notification = NotificationCompat.Builder(context, CHANNEL)
            .setSmallIcon(android.R.drawable.stat_notify_chat)
            .setContentTitle("Rich")
            .setContentText(text)
            .setStyle(NotificationCompat.BigTextStyle().bigText(text))
            .setAutoCancel(true)
            .setContentIntent(tap)
            .build()
        // One notification per event: a repeat delivery of the same event replaces, never stacks.
        NotificationManagerCompat.from(context).notify(collapse?.hashCode() ?: 0, notification)
    }
}
