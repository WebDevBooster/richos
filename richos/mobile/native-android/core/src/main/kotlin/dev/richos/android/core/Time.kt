package dev.richos.android.core

import java.time.Instant
import java.time.ZoneOffset
import java.time.format.DateTimeFormatter

private val ISO_MILLIS: DateTimeFormatter = DateTimeFormatter.ofPattern("yyyy-MM-dd'T'HH:mm:ss.SSS'Z'").withZone(ZoneOffset.UTC)

/** JavaScript's `Date.prototype.toISOString`, which always prints milliseconds (`queue.js` `queuedAt`). */
fun isoMillis(epochMillis: Long): String = ISO_MILLIS.format(Instant.ofEpochMilli(epochMillis))
