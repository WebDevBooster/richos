package dev.richos.android.app

import android.app.Activity
import android.app.Application
import android.os.Bundle
import androidx.activity.ComponentActivity
import dev.richos.android.core.Action
import dev.richos.android.core.AttachmentLimits
import dev.richos.android.core.ConnectionOwner
import dev.richos.android.platform.AttachmentPicker
import dev.richos.android.platform.mirrored
import dev.richos.android.platform.FcmPlatform
import dev.richos.android.platform.NetworkWake
import dev.richos.android.platform.Stager
import dev.richos.android.platform.MicRecorder
import dev.richos.android.platform.PreviewKeys
import dev.richos.android.platform.Replies
import java.lang.ref.WeakReference
import dev.richos.android.core.RichCore
import dev.richos.android.core.protocol.MacApi
import dev.richos.android.platform.HttpsMac
import kotlinx.coroutines.MainScope
import kotlinx.coroutines.flow.filterNotNull
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch

/**
 * The composition root: one [AppStore] for every activity and screen, the production ports, and
 * the one [ConnectionOwner] that keeps the Mac's stream open while the app runs. A debug build
 * that the CLI has put in a development world opens on that world instead, and no owner runs
 * (the scripted Mac is in-process; nothing should dial the fixture's host).
 */
class RichApplication : Application() {
    private val scope = MainScope()

    /** The process's scope, for work that outlives an activity (a share finishing after it closed). */
    val appScope: kotlinx.coroutines.CoroutineScope get() = scope
    val store: AppStore by lazy { AppStore(scope) }

    @Volatile
    private var foreground: WeakReference<Activity>? = null

    /** The conversation is on screen right now (resumed), so a reply needs no notification. */
    val conversationOnScreen: Boolean get() = foreground?.get() is MainActivity

    /**
     * Photos and files: the core's picker port. The + menu's choice reaches the core as
     * `pick-attachments`; the core asks this to present a picker; what is picked returns as `attach`.
     */
    val attachments: AttachmentPicker by lazy {
        val stager = Stager(this, AppPorts.stagedDir(this)) { (store.states.value?.attachmentLimits ?: AttachmentLimits()).maxFileBytes }
        AttachmentPicker(stager, { store.dispatch(it) }, { foreground?.get() as? ComponentActivity }, scope, AttachmentPicker.capturesDir(this))
    }

    /**
     * Activities of this app started (on screen) right now. The stream to the Mac is open only
     * while this is above zero: in the background a reply arrives as a push, never over a socket
     * kept alive for it (the iPhone's rule; an Android phone flags an app that refreshes in the
     * background as "power-intensive").
     */
    private var started = 0

    /** The live connection's owner; null until the production core has opened, and in a dev world. */
    @Volatile
    var owner: ConnectionOwner? = null
        private set

    /** Push on this phone; null in a development world. */
    @Volatile
    private var push: FcmPlatform? = null

    /** The microphone; null in a development world. */
    @Volatile
    private var microphone: MicRecorder? = null

    override fun onCreate() {
        super.onCreate()
        val dev = DevHook.coreFactory
        if (dev != null) {
            store.open(dev)
        } else {
            val wire = HttpsMac()
            val recorder = MicRecorder(
                context = this,
                dir = AppPorts.stagedDir(this),
                onLevel = { store.dispatch(Action.VoiceLevel(it)) },
                onPermission = { permission, canAsk -> store.dispatch(Action.MicrophonePermission(permission, canAsk)) },
                onPlaybackEnded = { store.dispatch(Action.PlaybackEnded(it)) },
                onInterrupted = { id -> scope.launch {
                    if (store.current?.state?.voice?.id == id) store.dispatch(Action.VoiceInterrupted(System.currentTimeMillis()))
                } },
                foreground = { foreground?.get() as? ComponentActivity },
            )
            Replies.ensureChannel(this)
            val platform = FcmPlatform(
                context = this,
                previewKeys = PreviewKeys.forApp(this),
                dispatch = { store.dispatch(it) },
                foreground = { foreground?.get() as? ComponentActivity },
            )
            val picker = object : dev.richos.android.core.AttachPicker {
                override suspend fun present(source: dev.richos.android.core.AttachSource, maxCount: Int) = attachments.present(source, maxCount)
            }
            val ports = AppPorts.create(this, wire, recorder, platform, picker)
            store.open {
                RichCore.open(ports).also { core ->
                    // The core mirrors the OS's microphone answer; a revoke in Settings is seen here.
                    // No activity yet, so whether Android would ask again is read when one starts.
                    mirrored(recorder.granted(), canAsk = false, core.state.microphone, core.state.microphoneCanAsk)?.let { (p, ask) ->
                        core.dispatch(Action.MicrophonePermission(p, ask))
                    }
                    // A process a push started has nothing on screen: no stream until an activity starts.
                    val connection = ConnectionOwner(core, MacApi(ports.http, ports.keys), wire, foreground = started > 0,
                        onStorageFailure = { store.reportStorageFailure() })
                    owner = connection
                    scope.launch { connection.run() }
                    scope.launch { platform.reconcileOnConnection(core.states) { started > 0 } }
                    // The network came back: reconnect now, not at the end of a back-off.
                    // And whether Tailscale's tunnel is up, from the same OS callback (D05).
                    NetworkWake.register(this, changed = { connection.networkChanged(it) }, tunnel = { connection.tunnelChanged(it) })
                }
            }
            push = platform
            microphone = recorder
            // A push token that changed while nothing was listening is handed to the Mac now, and
            // the OS's notification answer is mirrored (platform/Notifications.kt, reconcile).
            scope.launch {
                val opened = store.states.filterNotNull().first()
                platform.reconcile(opened.notifications.status, opened.notifications.previews) { started > 0 }
            }
        }
        registerActivityLifecycleCallbacks(
            object : ActivityLifecycleCallbacks {
                // Coming back to the foreground fires a pending reconnect at once (web/lib/link.js),
                // and picks up notifications, and the microphone, allowed again in Android Settings
                // meanwhile (the microphone-off card goes once it is allowed, D03).
                override fun onActivityStarted(activity: Activity) {
                    started++
                    owner?.foregrounded()
                    val now = store.states.value ?: return
                    microphone?.mirror(now.microphone, now.microphoneCanAsk, activity)
                    push?.let { p -> scope.launch { p.reconcile(now.notifications.status, now.notifications.previews) { started > 0 } } }
                }

                // The activity on screen, for the one OS question the recorder asks.
                override fun onActivityResumed(activity: Activity) {
                    foreground = WeakReference(activity)
                }

                override fun onActivityPaused(activity: Activity) {
                    if (foreground?.get() === activity) foreground = null
                }

                override fun onActivityCreated(activity: Activity, savedInstanceState: Bundle?) = Unit
                // The last activity left the screen: close the stream and stop retrying. A rotation
                // stops and restarts the activity at once; that is not leaving.
                override fun onActivityStopped(activity: Activity) {
                    started = (started - 1).coerceAtLeast(0)
                    if (started == 0 && !activity.isChangingConfigurations) owner?.backgrounded()
                }
                override fun onActivitySaveInstanceState(activity: Activity, outState: Bundle) = Unit
                override fun onActivityDestroyed(activity: Activity) = Unit
            },
        )
    }
}

/**
 * The one seam a debug build uses to run the development runtime instead of the production
 * ports. Main code only reads it; only `app/src/debug/` writes it, so in a release build it is
 * always null and the development runtime is unreachable.
 */
object DevHook {
    @Volatile
    var coreFactory: (suspend () -> RichCore)? = null
}

/** For code that has only a context. */
val android.content.Context.richStore: AppStore
    get() = (applicationContext as RichApplication).store
