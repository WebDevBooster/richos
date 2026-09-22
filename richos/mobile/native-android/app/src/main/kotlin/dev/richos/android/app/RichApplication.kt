package dev.richos.android.app

import android.app.Activity
import android.app.Application
import android.os.Bundle
import dev.richos.android.core.ConnectionOwner
import dev.richos.android.core.RichCore
import dev.richos.android.core.protocol.MacApi
import dev.richos.android.platform.HttpsMac
import kotlinx.coroutines.MainScope
import kotlinx.coroutines.launch

/**
 * The composition root: one [AppStore] for every activity and screen, the production ports, and
 * the one [ConnectionOwner] that keeps the Mac's stream open while the app runs. A debug build
 * that the CLI has put in a development world opens on that world instead, and no owner runs
 * (the scripted Mac is in-process; nothing should dial the fixture's host).
 */
class RichApplication : Application() {
    private val scope = MainScope()
    val store: AppStore by lazy { AppStore(scope) }

    /** The live connection's owner; null until the production core has opened, and in a dev world. */
    @Volatile
    var owner: ConnectionOwner? = null
        private set

    override fun onCreate() {
        super.onCreate()
        val dev = DevHook.coreFactory
        if (dev != null) {
            store.open(dev)
        } else {
            val wire = HttpsMac()
            val ports = AppPorts.create(this, wire)
            store.open {
                RichCore.open(ports).also { core ->
                    val connection = ConnectionOwner(core, MacApi(ports.http, ports.keys), wire)
                    owner = connection
                    scope.launch { connection.run() }
                }
            }
        }
        // Coming back to the foreground fires a pending reconnect at once (web/lib/link.js).
        registerActivityLifecycleCallbacks(
            object : ActivityLifecycleCallbacks {
                override fun onActivityStarted(activity: Activity) {
                    owner?.wake()
                }

                override fun onActivityCreated(activity: Activity, savedInstanceState: Bundle?) = Unit
                override fun onActivityResumed(activity: Activity) = Unit
                override fun onActivityPaused(activity: Activity) = Unit
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
