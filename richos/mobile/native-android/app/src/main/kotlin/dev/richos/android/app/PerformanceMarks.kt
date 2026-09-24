package dev.richos.android.app

import android.os.Trace

/** Release-safe trace events. Names only: no content, credentials, IDs or telemetry uploads. */
object PerformanceMarks {
    fun mark(name: String) {
        Trace.beginSection("richconnect:$name")
        // FrameMetrics uses CLOCK_MONOTONIC; some OEM ftrace clocks use a different origin.
        // This timing-only counter lets the measurement tool join a draw to its presented frame.
        if (Trace.isEnabled()) Trace.setCounter("richconnect:monotonic-ns", System.nanoTime())
        Trace.endSection()
    }
}
