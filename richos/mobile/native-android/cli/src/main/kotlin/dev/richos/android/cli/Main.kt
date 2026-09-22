package dev.richos.android.cli

import dev.richos.android.core.CoreError
import dev.richos.android.core.dev.DevDoc
import dev.richos.android.core.dev.DevRequest
import dev.richos.android.core.dev.DevRuntime
import dev.richos.android.core.dev.Fixtures
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.ExperimentalSerializationApi
import kotlinx.serialization.SerializationException
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import java.io.File
import java.io.PrintStream
import java.nio.file.AtomicMoveNotSupportedException
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import kotlin.system.exitProcess

internal val USAGE = """Headless RichOS Android core (JSON output; nonzero exit on failure)
  randroid headless state|reset|restart
  randroid headless fixture ${Fixtures.names.joinToString("|")}
  randroid headless action '{"type":"compose","text":"Hello"}'
  randroid headless transport accept|unreachable|lose-ack|revoked
  randroid headless advance 1000
  randroid headless scenario ${DevRuntime.SCENARIOS.joinToString("|")}
The grammar and the result shape are the preserved phone CLI's (richos/mobile/cli/mobile.mjs).
State persists between calls in the session file named by RANDROID_SESSION."""

@OptIn(ExperimentalSerializationApi::class)
private val Pretty = Json {
    prettyPrint = true
    prettyPrintIndent = "  "
}

fun main(args: Array<String>) {
    exitProcess(run(args.toList(), System.getenv("RANDROID_SESSION"), System.out, System.err))
}

/**
 * One command against the session file. Exit 0 prints `{"ok":true,"mode","command",
 * "elapsedMs","result"}` on stdout; exit 1 prints `{"ok":false,"error","elapsedMs"}` on stderr —
 * the preserved CLI's two shapes, byte for byte in structure.
 */
fun run(argv: List<String>, sessionPath: String?, out: PrintStream, err: PrintStream): Int {
    val start = System.nanoTime()
    fun elapsed() = JsonPrimitive(Math.round((System.nanoTime() - start) / 10_000.0) / 100.0)
    val command = argv.getOrNull(0)
    if (command == null || command == "--help" || command == "-h") {
        out.println(USAGE)
        return 0
    }
    var lock: File? = null
    return try {
        if (argv.size > 2) throw CoreError("Too many arguments; quote a JSON action as one argument")
        val request = DevRequest.parse(command, argv.getOrNull(1))
        val session = File(sessionPath?.takeIf { it.isNotBlank() } ?: throw CoreError("RANDROID_SESSION is not set; bin/randroid sets it"))
        session.parentFile?.mkdirs()
        lock = File(session.path + ".lock").also {
            if (!it.mkdir()) throw CoreError("Another headless command owns ${it.path}. If it crashed, remove that directory.")
        }
        val initial: DevDoc? = if (session.isFile) DevRuntime.decodeDoc(session.readText()) else null
        val result = runBlocking {
            DevRuntime.create(initial, save = { doc -> writeAtomically(session, DevRuntime.encodeDoc(doc)) }).execute(request)
        }
        val envelope = JsonObject(
            linkedMapOf<String, JsonElement>(
                "ok" to JsonPrimitive(true),
                "mode" to JsonPrimitive("headless"),
                "command" to JsonPrimitive(command),
                "elapsedMs" to elapsed(),
                "result" to result,
            ),
        )
        out.println(Pretty.encodeToString(JsonElement.serializer(), envelope))
        0
    } catch (e: CoreError) {
        fail(err, e.message, elapsed())
    } catch (e: SerializationException) {
        fail(err, "The session file is unreadable: ${e.message?.lineSequence()?.firstOrNull()}", elapsed())
    } finally {
        lock?.delete()
    }
}

private fun fail(err: PrintStream, message: String?, elapsed: JsonPrimitive): Int {
    val body = JsonObject(
        linkedMapOf<String, JsonElement>(
            "ok" to JsonPrimitive(false),
            "error" to JsonPrimitive(message ?: "failed"),
            "elapsedMs" to elapsed,
        ),
    )
    err.println(body.toString())
    return 1
}

private fun writeAtomically(file: File, text: String) {
    val temp = File(file.path + ".new")
    temp.writeText(text)
    try {
        Files.move(temp.toPath(), file.toPath(), StandardCopyOption.ATOMIC_MOVE, StandardCopyOption.REPLACE_EXISTING)
    } catch (e: AtomicMoveNotSupportedException) {
        Files.move(temp.toPath(), file.toPath(), StandardCopyOption.REPLACE_EXISTING)
    }
}
