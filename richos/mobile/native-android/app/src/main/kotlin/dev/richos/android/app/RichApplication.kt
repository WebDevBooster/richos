package dev.richos.android.app

import android.app.Application
import dev.richos.android.core.RichCore
import kotlinx.coroutines.MainScope

/** The process: one [AppStore], opened once, for every activity and every screen. */
class RichApplication : Application() {
    val store: AppStore by lazy { AppStore(MainScope()) }

    override fun onCreate() {
        super.onCreate()
        val factory = DevHook.coreFactory ?: { RichCore.open(AppPorts.create(this)) }
        store.open(factory)
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
