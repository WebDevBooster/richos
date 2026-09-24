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
import com.google.android.gms.tasks.Task
import com.google.firebase.installations.FirebaseInstallations
import com.google.firebase.messaging.FirebaseMessaging
import com.google.firebase.messaging.FirebaseMessagingService
import com.google.firebase.messaging.RemoteMessage
import dev.richos.android.BuildConfig
import dev.richos.android.app.AppStore
import dev.richos.android.app.RichApplication
import dev.richos.android.core.Action
import dev.richos.android.core.AppLinks
import dev.richos.android.core.NotificationStatus
import dev.richos.android.core.Platform
import dev.richos.android.core.protocol.NotificationPreview
import dev.richos.android.core.protocol.Signing
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.filterNotNull
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import java.io.File
import java.security.KeyStore
import java.security.SecureRandom
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

/**
 * The phone's preview key (contract §7.2): 32 random bytes the Mac seals previews with, sent once
 * at registration. At rest it is wrapped by a non-exportable AES key ([wrapper]), so the file alone
 * opens nothing (build plan §3.3 "stored wrapped by a Keystore AES key").
 */
class PreviewKeys(private val file: File, private val wrapper: () -> SecretKey) {
    fun key(): ByteArray = read() ?: ByteArray(32).also { SecureRandom().nextBytes(it); write(it) }

    fun existing(): ByteArray? = runCatching { read() }.getOrNull()

    /**
     * A-4 (security review 2026-09-23): previews off, or notifications off (which Forget does
     * first), leaves nothing on the phone that opens a preview. Turning previews on again makes a
     * fresh key, which the registration hands the Mac, so this is also how the key rotates.
     */
    fun discard() {
        runCatching { AtomicFile(file).delete() }
    }

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
    private val ledger: TokenLedger = TokenLedger.forApp(context),
    /** Deletes the FCM token, then Firebase's installation ID; a test substitutes a recorder. */
    private val deleteInstallation: suspend () -> Unit = ::defaultDeleteInstallation,
    /** Present while a Forget's deletion has not reached Firebase yet (offline); retried at the next launch. */
    private val pendingForget: File = File(context.filesDir, "push/forget-installation.pending"),
) : Platform {
    /** One Firebase conversation at a time: a token is never fetched while Forget deletes the installation. */
    private val firebaseLane = Mutex()

    override suspend fun requestNotifications(previews: Boolean) {
        if (!firebaseReady()) {
            dispatch(Action.NotificationsResult(NotificationStatus.PLATFORM_UNAVAILABLE))
            return
        }
        if (!notificationPermission()) {
            dispatch(Action.NotificationsResult(NotificationStatus.DENIED))
            return
        }
        val token = firebaseLane.withLock { runCatching { fetchToken() }.getOrNull() }
        if (token.isNullOrBlank()) {
            dispatch(Action.NotificationsResult(NotificationStatus.PLATFORM_UNAVAILABLE))
            return
        }
        val key = withContext(Dispatchers.IO) {
            if (previews) runCatching { previewKeys.key() }.getOrNull() else null.also { previewKeys.discard() }
        }
        ledger.record(token)
        dispatch(Action.PushToken(token, key?.let(Signing::base64url)))
    }

    /**
     * At launch, with notifications on: if Firebase's token is not the one this phone last handed
     * the Mac, hand it over now. A refresh can happen while nothing is listening (the process was
     * killed before [RichMessagingService.onNewToken] finished), and an old token fails only at
     * Google, silently, when the next reply is sent. Asks the OS nothing.
     *
     * Notifications switched off for RichConnect in Android Settings (which also ends the process)
     * are mirrored as DENIED, so Settings in the app says so and offers the way back, rather than
     * showing a switch that is on while nothing can be shown.
     */
    suspend fun reconcile(status: NotificationStatus, previews: Boolean, isVisible: () -> Boolean) = reconciling.withLock {
        // A received notification can create a process with no activity. It does not need a
        // routine token fetch or a retry of earlier maintenance. Recheck after waiting for the
        // lane so queued foreground callbacks cannot start that work after the app is hidden.
        // Actual onNewToken events still use TokenRefresh's separate hand-over path.
        if (isVisible()) reconcileNow(status, previews)
    }

    /** Launch and each return to the foreground both reconcile; one at a time, so a change registers once. */
    private val reconciling = Mutex()

    private suspend fun reconcileNow(status: NotificationStatus, previews: Boolean) {
        // A Forget made offline finishes now: one attempt per launch or return, never a timer.
        if (pendingForget.isFile) forgetInstallation()
        // The way back: allowed again in Android Settings after a denial, the phone registers
        // again (no prompt: the OS already said yes) instead of staying "off" for good.
        if (status == NotificationStatus.DENIED && granted()) return requestNotifications(previews)
        if (status != NotificationStatus.ON) return
        if (!granted()) {
            dispatch(Action.NotificationsResult(NotificationStatus.DENIED))
            return
        }
        if (!firebaseReady()) return
        val token = firebaseLane.withLock { runCatching { fetchToken() }.getOrNull() }
        if (token.isNullOrBlank() || ledger.matches(token)) return
        val key = if (previews) withContext(Dispatchers.IO) { runCatching { previewKeys.existing() }.getOrNull() } else null
        ledger.record(token)
        dispatch(Action.PushToken(token, key?.let(Signing::base64url)))
    }

    override suspend fun unregisterNotifications() {
        ledger.clear()
        withContext(Dispatchers.IO) { previewKeys.discard() }
        if (FirebaseApp.getApps(context).isNotEmpty()) runCatching { FirebaseMessaging.getInstance().deleteToken() }
    }

    /**
     * Privacy evidence E5: Forget removes Firebase's installation ID, on this phone and at Firebase,
     * which keeps it "until the Firebase customer makes an API call to delete the ID". The FCM token
     * goes first, then the installation. Starting Firebase for this makes nothing new: FCM auto-init
     * is off in the manifest, so a token or an ID exists only after the person turned notifications
     * on. Bounded; if it cannot reach Firebase now, the next launch finishes it ([reconcile]).
     */
    override suspend fun forgetInstallation() {
        if (!firebaseReady()) return
        withContext(Dispatchers.IO) { runCatching { pendingForget.parentFile?.mkdirs(); pendingForget.createNewFile() } }
        val done = firebaseLane.withLock { withTimeoutOrNull(FORGET_PATIENCE_MS) { runCatching { deleteInstallation() }.isSuccess } }
        if (done == true) withContext(Dispatchers.IO) { runCatching { AtomicFile(pendingForget).delete() } }
    }

    private fun granted() = Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU ||
        ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED

    override suspend fun openSystemSettings() = start(
        Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.fromParts("package", context.packageName, null)),
    )

    /** This app's Google Play listing: in the Play Store app, or on the web on a phone without it. */
    override suspend fun openAppStore() = view(AppLinks.playStore(context.packageName), AppLinks.playStoreWeb(context.packageName))

    override suspend fun openSupport() = view(AppLinks.support)

    override suspend fun openPrivacyPolicy() = view(AppLinks.privacyPolicy)

    /** Opens the first of [urls] something on this phone can open. With none, nothing happens and nothing fails. */
    private suspend fun view(vararg urls: String) = withContext(main) {
        for (url in urls) {
            val opened = runCatching { context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(url)).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)) }
            if (opened.isSuccess) break
        }
    }

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
        const val FORGET_PATIENCE_MS = 10_000L

        private suspend fun defaultToken(): String? = suspendCancellableCoroutine { done ->
            FirebaseMessaging.getInstance().token
                .addOnSuccessListener { if (done.isActive) done.resume(it) }
                .addOnFailureListener { if (done.isActive) done.resume(null) }
        }

        private suspend fun defaultDeleteInstallation() {
            FirebaseMessaging.getInstance().deleteToken().awaitDone()
            FirebaseInstallations.getInstance().delete().awaitDone()
        }

        /** Waits for a Play services task; its failure is thrown. */
        private suspend fun Task<*>.awaitDone(): Unit = suspendCancellableCoroutine { done ->
            addOnSuccessListener { if (done.isActive) done.resume(Unit) }
            addOnFailureListener { e -> if (done.isActive) done.resumeWithException(e) }
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
    /**
     * A new token goes to the Mac while notifications are on. This service can be the first thing
     * to run in a fresh process, before the store has read its saved state, so the hand-over waits
     * for that (bounded) instead of reading "no state yet" as "notifications off" and dropping it.
     */
    override fun onNewToken(token: String) {
        val app = applicationContext as? RichApplication ?: return
        val keys = keysFor(this)
        val ledger = ledgerFor(this)
        app.appScope.launch { TokenRefresh.handOver(app.store, token, keys, ledger) }
    }

    override fun onMessageReceived(message: RemoteMessage) {
        val data = message.data
        if (data["v"] != "1") return
        val text = NotificationPreview.textOrGeneric(keysFor(this).existing(), data["thread"], data["event"], data["preview"])
        Replies.post(this, text, NotificationTarget.fromData(data), collapse = data["event"])
    }

    companion object {
        /** Where the service finds the preview key; a test substitutes a JVM-wrapped one. */
        internal var keysFor: (Context) -> PreviewKeys = PreviewKeys::forApp
        internal var ledgerFor: (Context) -> TokenLedger = TokenLedger::forApp
    }
}

/** The service's half of a token refresh, kept apart from the service so it is tested directly. */
object TokenRefresh {
    const val PATIENCE_MS = 10_000L

    suspend fun handOver(store: AppStore, token: String, keys: PreviewKeys, ledger: TokenLedger, patienceMs: Long = PATIENCE_MS) {
        val state = withTimeoutOrNull(patienceMs) { store.states.filterNotNull().first() } ?: return
        if (state.notifications.status != NotificationStatus.ON) return
        val key = if (state.notifications.previews) withContext(Dispatchers.IO) { keys.existing() } else null
        ledger.record(token)
        store.dispatch(Action.PushToken(token, key?.let(Signing::base64url)))
    }
}

/**
 * The SHA-256 of the last FCM token this phone handed the Mac, so a launch can tell a token that
 * changed while nothing was listening. Only the hash is kept; the token itself stays Firebase's.
 */
class TokenLedger(private val file: File) {
    fun matches(token: String): Boolean = runCatching { file.isFile && String(AtomicFile(file).readFully(), Charsets.UTF_8) == hash(token) }.getOrDefault(false)

    fun record(token: String) {
        runCatching {
            file.parentFile?.mkdirs()
            val atomic = AtomicFile(file)
            val out = atomic.startWrite()
            try {
                out.write(hash(token).toByteArray(Charsets.UTF_8))
                atomic.finishWrite(out)
            } catch (e: Exception) {
                atomic.failWrite(out)
                throw e
            }
        }
    }

    fun clear() {
        runCatching { AtomicFile(file).delete() }
    }

    private fun hash(token: String) = NotificationTarget.reference(token)

    companion object {
        fun forApp(context: Context) = TokenLedger(File(context.filesDir, "push/registered-token.sha256"))
    }
}

/** The replies channel and the one notification a reply gets. */
object Replies {
    const val CHANNEL = "replies"

    /**
     * The RichConnect mark as the small icon (round 12.1 `notif-lock-*`: the card carries the mark,
     * Urban's 2026-09-24 audit G4), generated from the icon source by `release/make-app-icon.cjs`.
     */
    val SMALL_ICON = dev.richos.android.R.drawable.ic_notification

    /**
     * The signal gold that tints it. The shade may be light or dark and the app cannot know which,
     * so it is the one gold that clears the 3:1 non-text floor on both: Daybreak's #9C7C34, 3.93:1 on
     * white and 4.10:1 on a dark shade (#202124) by contrast.py. Sovereign's #C2A35C is 2.42:1 on white.
     */
    const val ACCENT = 0xFF9C7C34.toInt()

    fun ensureChannel(context: Context) {
        val manager = context.getSystemService(NotificationManager::class.java) ?: return
        if (manager.getNotificationChannel(CHANNEL) == null) {
            manager.createNotificationChannel(
                NotificationChannel(CHANNEL, "Rich's replies", NotificationManager.IMPORTANCE_HIGH).apply {
                    description = "Rich's answers while RichConnect is not on screen."
                },
            )
        }
    }

    /**
     * While the conversation is on screen the reply is already arriving in it, so no notification
     * covers it (the iPhone app suppresses foreground presentation the same way,
     * `mobile/service/notifications.md`). Anything less, including a locked phone with the app on
     * top, the share sheet over another app, or the moment after leaving, still notifies. Read from
     * the app's own resumed activity: the process importance it replaced lagged the Home press, and
     * on emulator-5580 two replies arriving after the person had left were swallowed by it.
     */
    internal val conversationVisible: (Context) -> Boolean = { (it.applicationContext as? RichApplication)?.conversationOnScreen == true }

    /** [conversationVisible]; a test substitutes a fixed answer. */
    internal var onScreen: (Context) -> Boolean = conversationVisible

    fun post(context: Context, text: String, target: NotificationTarget?, collapse: String?) {
        ensureChannel(context)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
        ) {
            return
        }
        if (onScreen(context)) return
        // One notification per event, so one pending intent per event: PendingIntent identity ignores
        // extras, and a shared request code made every notification open the newest reply's references.
        val id = collapse?.hashCode() ?: 0
        val open = context.packageManager.getLaunchIntentForPackage(context.packageName)
            ?.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP)
            ?.let { target?.into(it) ?: it }
        val tap = open?.let { PendingIntent.getActivity(context, id, it, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT) }
        val notification = NotificationCompat.Builder(context, CHANNEL)
            .setSmallIcon(SMALL_ICON)
            .setColor(ACCENT)
            .setContentTitle("Rich")
            .setContentText(text)
            .setStyle(NotificationCompat.BigTextStyle().bigText(text))
            .setCategory(NotificationCompat.CATEGORY_MESSAGE)
            .setGroup(GROUP)
            .setAutoCancel(true)
            .setContentIntent(tap)
            .build()
        val manager = NotificationManagerCompat.from(context)
        // A repeat delivery of the same event replaces, never stacks.
        manager.notify(if (id == SUMMARY_ID) id + 1 else id, notification)
        // The group's own summary, which Android shows when it collapses the replies ("RichConnect ·
        // 2"). Left to Android, the automatic bundle's tap carried no reply, so the app opened with
        // nothing focused. This summary's tap targets the reply just posted, the newest, so tapping
        // the collapsed group opens the conversation at that reply with the single gold glow, as a
        // normal tap does (Urban's 2026-09-24 audit G5, §4.3). The replies still sound; the summary
        // never does (GROUP_ALERT_CHILDREN).
        // Its own copy of the intent: the reply's pending intent must never share (and so change with) it.
        val summaryTap = open?.let { PendingIntent.getActivity(context, SUMMARY_ID, Intent(it), PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT) }
        val summary = NotificationCompat.Builder(context, CHANNEL)
            .setSmallIcon(SMALL_ICON)
            .setColor(ACCENT)
            .setContentTitle("Rich")
            .setContentText(text)
            .setCategory(NotificationCompat.CATEGORY_MESSAGE)
            .setGroup(GROUP)
            .setGroupSummary(true)
            .setGroupAlertBehavior(NotificationCompat.GROUP_ALERT_CHILDREN)
            .setAutoCancel(true)
            .setContentIntent(summaryTap)
            .build()
        manager.notify(SUMMARY_ID, summary)
    }

    /** The one group every reply notification belongs to, owned by the app (not Android's auto-bundle). */
    const val GROUP = "dev.richos.connect.replies"

    /** The group summary's notification id and its tap's request code; a reply never takes it. */
    const val SUMMARY_ID = 0x52434E53
}
