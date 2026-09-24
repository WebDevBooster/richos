package dev.richos.android.app

import android.os.Trace

/** Release-safe trace events. Names only: no content, credentials, IDs or telemetry uploads. */
object PerformanceMarks {
    fun mark(name: String) {
        Trace.beginSection("richconnect:$name")
        Trace.endSection()
    }
}
