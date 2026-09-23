package dev.richos.android.app

import android.app.Activity
import android.app.Application
import android.os.Bundle
import androidx.activity.ComponentActivity
import dev.richos.android.core.Action
import dev.richos.android.core.ConnectionOwner
import dev.richos.android.core.Microphone
import dev.richos.android.platform.AttachmentPicker
import dev.richos.android.platform.FcmPlatform
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

    /**
     * Photos and files: the composer's attach control calls [AttachmentPicker.pickPhotos] or
     * [AttachmentPicker.pickFiles]; what is picked arrives in the core as `attach`.
     */
    val attachments: AttachmentPicker by lazy {
        AttachmentPicker(Stager(this, AppPorts.stagedDir(this)), { store.dispatch(it) }, { foreground?.get() as? ComponentActivity }, scope)
    }

    /** The live connection's owner; null until the production core has opened, and in a dev world. */
    @Volatile
    var owner: ConnectionOwner? = null
        private set

    /** Push on this phone; null in a development world. */
    @Volatile
    private var push: FcmPlatform? = null

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
                onPermission = { store.dispatch(Action.MicrophonePermission(it)) },
                foreground = { foreground?.get() as? ComponentActivity },
            )
            Replies.ensureChannel(this)
            val platform = FcmPlatform(
                context = this,
                previewKeys = PreviewKeys.forApp(this),
                dispatch = { store.dispatch(it) },
                foreground = { foreground?.get() as? ComponentActivity },
            )
            val ports = AppPorts.create(this, wire, recorder, platform)
            store.open {
                RichCore.open(ports).also { core ->
                    // The core mirrors the OS's microphone answer; a revoke in Settings is seen here.
                    val os = if (recorder.granted()) Microphone.GRANTED else Microphone.UNKNOWN
                    if (core.state.microphone != os && !(os == Microphone.UNKNOWN && core.state.microphone == Microphone.DENIED)) {
                        core.dispatch(Action.MicrophonePermission(os))
                    }
                    val connection = ConnectionOwner(core, MacApi(ports.http, ports.keys), wire)
                    owner = connection
                    scope.launch { connection.run() }
                }
            }
            push = platform
            // A push token that changed while nothing was listening is handed to the Mac now, and
            // the OS's notification answer is mirrored (platform/Notifications.kt, reconcile).
            scope.launch {
                val opened = store.states.filterNotNull().first()
                platform.reconcile(opened.notifications.status, opened.notifications.previews)
            }
        }
        registerActivityLifecycleCallbacks(
            object : ActivityLifecycleCallbacks {
                // Coming back to the foreground fires a pending reconnect at once (web/lib/link.js),
                // and picks up notifications allowed again in Android Settings meanwhile.
                override fun onActivityStarted(activity: Activity) {
                    owner?.wake()
                    val now = store.states.value ?: return
                    push?.let { p -> scope.launch { p.reconcile(now.notifications.status, now.notifications.previews) } }
                }

                // The activity on screen, for the one OS question the recorder asks.
                override fun onActivityResumed(activity: Activity) {
                    foreground = WeakReference(activity)
                }

                override fun onActivityPaused(activity: Activity) {
                    if (foreground?.get() === activity) foreground = null
                }

                override fun onActivityCreated(activity: Activity, savedInstanceState: Bundle?) = Unit
                override fun onActivityStopped(activity: Activity) = Unit
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
