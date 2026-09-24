package dev.richos.android.platform

import android.Manifest
import android.app.Notification
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
import dev.richos.android.core.AppState
import dev.richos.android.core.AppLinks
import dev.richos.android.core.NotificationStatus
import dev.richos.android.core.Platform
import dev.richos.android.core.protocol.NotificationPreview
import dev.richos.android.core.protocol.Signing
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.filterNotNull
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.flow.distinctUntilChangedBy
import kotlinx.coroutines.launch
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import java.io.File
import java.util.concurrent.atomic.AtomicLong
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
        if (isVisible()) reconcileNow(status, previews, isVisible)
    }

    /** A restored foreground connection can finish a failed setup, without a retry timer. */
    suspend fun reconcileOnConnection(states: Flow<AppState>, isVisible: () -> Boolean) {
        states.distinctUntilChangedBy { it.online }.collect { state ->
            if (state.online && state.notifications.status == NotificationStatus.SERVICE_UNAVAILABLE) {
                reconcile(state.notifications.status, state.notifications.previews, isVisible)
            }
        }
    }

    /** Launch and each return to the foreground both reconcile; one at a time, so a change registers once. */
    private val reconciling = Mutex()

    private suspend fun reconcileNow(status: NotificationStatus, previews: Boolean, isVisible: () -> Boolean) {
        // A Forget made offline finishes now: one attempt per launch or return, never a timer.
        if (pendingForget.isFile) forgetInstallation()
        if (!isVisible()) return
        // The way back: allowed again in Android Settings after a denial, the phone registers
        // again (no prompt: the OS already said yes) instead of staying "off" for good.
        if (status !in setOf(NotificationStatus.ON, NotificationStatus.DENIED, NotificationStatus.SERVICE_UNAVAILABLE)) return
        if (!granted()) {
            if (status != NotificationStatus.DENIED) dispatch(Action.NotificationsResult(NotificationStatus.DENIED))
            return
        }
        if (!firebaseReady()) return
        val token = firebaseLane.withLock {
            if (isVisible()) runCatching { fetchToken() }.getOrNull() else null
        }
        if (!isVisible() || token.isNullOrBlank() || (status == NotificationStatus.ON && ledger.matches(token))) return
        val key = if (previews) withContext(Dispatchers.IO) {
            runCatching { if (status == NotificationStatus.DENIED) previewKeys.key() else previewKeys.existing() }.getOrNull()
        } else withContext(Dispatchers.IO) { previewKeys.discard(); null }
        if (!isVisible()) return
        ledger.record(token)
        dispatch(Action.PushToken(token, key?.let(Signing::base64url)))
    }

    override suspend fun unregisterNotifications() {
        // D04: off means off. A reply already in the shade goes too, not only the ones to come.
        Replies.withdrawAll(context)
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
        // D04: the Mac is forgotten, so nothing it sent stays in the shade (its taps open nothing now).
        Replies.withdrawAll(context)
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
        val open = openIntent(context, target)
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
            // Which reply this is, so the app can withdraw it once that reply has been read (D04).
            // The Mac's references only, as the tap carries them: never an id, never the words.
            .apply { target?.let { addExtras(it.extras()) } }
            .build()
        val manager = NotificationManagerCompat.from(context)
        // A repeat delivery of the same event replaces, never stacks.
        manager.notify(notificationId(collapse), notification)
        // The group's own summary, which Android shows when it collapses the replies ("RichConnect ·
        // 2"). Left to Android, the automatic bundle's tap carried no reply, so the app opened with
        // nothing focused. This summary's tap targets the reply just posted, the newest, so tapping
        // the collapsed group opens the conversation at that reply with the single gold glow, as a
        // normal tap does (Urban's 2026-09-24 audit G5, §4.3). The replies still sound; the summary
        // never does (GROUP_ALERT_CHILDREN).
        manager.notify(SUMMARY_ID, summary(context, text, open))
        posted.incrementAndGet()
    }

    /** The id a reply's notification is posted under: its event reference, hashed, never the summary's. */
    private fun notificationId(collapse: String?): Int {
        val id = collapse?.hashCode() ?: 0
        return if (id == SUMMARY_ID) id + 1 else id
    }

    /** What a tap opens: the app, carrying the reply's references when there are any. */
    private fun openIntent(context: Context, target: NotificationTarget?): Intent? =
        context.packageManager.getLaunchIntentForPackage(context.packageName)
            ?.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP)
            ?.let { target?.into(it) ?: it }

    /** The group's summary, whose tap opens [open] (the newest reply still posted). */
    private fun summary(context: Context, text: CharSequence, open: Intent?): Notification {
        // Its own copy of the intent: the reply's pending intent must never share (and so change with) it.
        val summaryTap = open?.let { PendingIntent.getActivity(context, SUMMARY_ID, Intent(it), PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT) }
        return NotificationCompat.Builder(context, CHANNEL)
            .setSmallIcon(SMALL_ICON)
            .setColor(ACCENT)
            .setContentTitle("Rich")
            .setContentText(text)
            .setCategory(NotificationCompat.CATEGORY_MESSAGE)
            .setGroup(GROUP)
            .setGroupSummary(true)
            .setGroupAlertBehavior(NotificationCompat.GROUP_ALERT_CHILDREN)
            // Re-pointed when a reply is read (D04): an update, and never a second sound.
            .setOnlyAlertOnce(true)
            .setAutoCancel(true)
            .setContentIntent(summaryTap)
            .build()
    }

    /**
     * Whether a reply of ours may be in the shade, so a conversation on screen asks Android only when
     * there can be something to withdraw. Unknown when the process starts (an earlier process may have
     * posted); known empty once a pass leaves nothing, until the next post. A post racing a pass
     * moves [posted] past the generation the pass read, so it is never forgotten.
     */
    private val posted = AtomicLong(1)
    private val clearedAt = AtomicLong(0)

    /**
     * D04: the replies the person has read in the conversation on screen leave the shade, and the
     * group's summary with the last of them. A reply still posted keeps its notification, and the
     * collapsed group's tap is re-pointed at the newest of those, never at a reply just read.
     * Read-only when nothing matches: no notification is re-posted, so the shade never flickers.
     */
    fun withdrawRead(context: Context, read: ReadReplies.Read) {
        if (posted.get() == clearedAt.get()) return
        val generation = posted.get()
        val manager = context.getSystemService(NotificationManager::class.java) ?: return
        val active = runCatching { manager.activeNotifications.toList() }.getOrNull() ?: return
        val summaryPosted = active.any { it.id == SUMMARY_ID }
        val replies = active.filter { it.id != SUMMARY_ID && it.notification.group == GROUP }
        val thread = NotificationTarget.reference(read.threadId)
        val events = read.replyIds.mapTo(HashSet(), NotificationTarget::reference)
        val ids = events.mapTo(HashSet(), ::notificationId)
        val (gone, left) = replies.partition { sbn ->
            when (val target = NotificationTarget.fromExtras(sbn.notification.extras)) {
                // Posted before replies carried their references (builds up to e768c515, the D04
                // build): the notification id is the reply's reference, hashed, which names it.
                null -> sbn.id in ids
                else -> target.thread == thread && target.event in events
            }
        }
        val newest = left.maxWithOrNull(compareBy({ it.postTime }, { it.notification.`when` }))
        if (newest == null) {
            gone.forEach { manager.cancel(it.tag, it.id) }
            if (summaryPosted) manager.cancel(SUMMARY_ID)
            clearedAt.accumulateAndGet(generation, ::maxOf)
            return
        }
        // The summary is re-pointed BEFORE the read replies go, so at no moment does the collapsed
        // group open a reply already withdrawn: withdrawn first, there was a window (a stall here,
        // or the process ending) in which its tap still opened the reply just read.
        if (gone.isNotEmpty() && summaryPosted) {
            val extras = newest.notification.extras
            val text = extras.getCharSequence(Notification.EXTRA_TEXT) ?: NotificationPreview.GENERIC
            manager.notify(SUMMARY_ID, summary(context, text, openIntent(context, NotificationTarget.fromExtras(extras))))
        }
        gone.forEach { manager.cancel(it.tag, it.id) }
    }

    /** Every reply and the summary leave the shade: notifications turned off, or the Mac forgotten (D04). */
    fun withdrawAll(context: Context) {
        val generation = posted.get()
        val manager = context.getSystemService(NotificationManager::class.java) ?: return
        val active = runCatching { manager.activeNotifications.toList() }.getOrNull() ?: return
        active.filter { it.id == SUMMARY_ID || it.notification.group == GROUP }.forEach { manager.cancel(it.tag, it.id) }
        clearedAt.accumulateAndGet(generation, ::maxOf)
    }

    /** The one group every reply notification belongs to, owned by the app (not Android's auto-bundle). */
    const val GROUP = "dev.richos.connect.replies"

    /** The group summary's notification id and its tap's request code; a reply never takes it. */
    const val SUMMARY_ID = 0x52434E53
}
