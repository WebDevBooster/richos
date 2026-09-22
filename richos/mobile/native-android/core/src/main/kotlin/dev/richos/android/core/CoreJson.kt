package dev.richos.android.core

import kotlinx.serialization.SerializationException
import kotlinx.serialization.json.Json

/**
 * The one JSON configuration. Every field is always printed, `null` included, because the
 * preserved phone core prints them that way and a trace is compared field by field.
 */
val CoreJson: Json = Json {
    encodeDefaults = true
    explicitNulls = true
    classDiscriminator = "type"
    ignoreUnknownKeys = false
}

/** Parses `{"type":"compose","text":"Hello"}` into an [Action], or explains what is wrong. */
fun parseAction(json: String): Action = try {
    CoreJson.decodeFromString(Action.serializer(), json)
} catch (e: SerializationException) {
    throw CoreError("Not a valid action: ${e.message?.lineSequence()?.firstOrNull() ?: "unreadable JSON"}")
} catch (e: IllegalArgumentException) {
    throw CoreError("Not a valid action: ${e.message?.lineSequence()?.firstOrNull() ?: "unreadable JSON"}")
}
