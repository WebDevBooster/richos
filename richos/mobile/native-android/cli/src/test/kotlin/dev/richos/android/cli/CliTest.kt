package dev.richos.android.cli

import java.io.ByteArrayOutputStream
import java.io.File
import java.io.PrintStream
import java.nio.file.Files
import kotlin.test.AfterTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class CliTest {
    private val dir: File = Files.createTempDirectory("randroid-cli").toFile()
    private val session = File(dir, "headless.json")

    @AfterTest
    fun cleanUp() {
        dir.deleteRecursively()
    }

    private data class Result(val code: Int, val out: String, val err: String)

    private fun cli(vararg argv: String, path: String? = session.path): Result {
        val out = ByteArrayOutputStream()
        val err = ByteArrayOutputStream()
        val code = run(argv.toList(), path, PrintStream(out, true, "UTF-8"), PrintStream(err, true, "UTF-8"))
        return Result(code, out.toString("UTF-8"), err.toString("UTF-8"))
    }

    @Test
    fun `a result carries the preserved envelope`() {
        val r = cli("state")
        assertEquals(0, r.code, r.err)
        for (key in listOf("\"ok\": true", "\"mode\": \"headless\"", "\"command\": \"state\"", "\"elapsedMs\":", "\"result\": {")) {
            assertTrue(r.out.contains(key), "missing $key in ${r.out}")
        }
    }

    @Test
    fun `state persists between separate invocations, as separate processes do`() {
        assertEquals(0, cli("action", """{"type":"compose","text":"Hello Rich"}""").code)
        assertEquals(0, cli("restart").code)
        assertTrue(cli("state").out.contains("\"draft\": \"Hello Rich\""))
        assertEquals(0, cli("reset").code)
        assertTrue(cli("state").out.contains("\"draft\": \"\""))
    }

    @Test
    fun `the foundation scenario runs end to end`() {
        val r = cli("scenario", "draft-survives-restart")
        assertEquals(0, r.code, r.err)
        assertTrue(r.out.contains("\"name\": \"draft-survives-restart\""))
    }

    @Test
    fun `a refused action exits 1 with the preserved error shape and changes nothing`() {
        cli("action", """{"type":"compose","text":"kept"}""")
        val r = cli("action", """{"type":"select-thread","threadId":"nope"}""")
        assertEquals(1, r.code)
        assertTrue(r.err.startsWith("{\"ok\":false,\"error\":\"Unknown conversation\",\"elapsedMs\":"), r.err)
        assertTrue(cli("state").out.contains("\"draft\": \"kept\""))
    }

    @Test
    fun `usage errors are errors, and no session file is a named error`() {
        assertEquals(1, cli("fly").code)
        assertEquals(1, cli("advance", "-5").code)
        val r = cli("state", path = null)
        assertEquals(1, r.code)
        assertTrue(r.err.contains("RANDROID_SESSION"), r.err)
    }

    @Test
    fun `a held lock refuses a second command instead of racing it, and the lock is released after`() {
        val lock = File(session.path + ".lock").apply { mkdirs() }
        val r = cli("state")
        assertEquals(1, r.code)
        assertTrue(r.err.contains("Another headless command"), r.err)
        lock.delete()
        assertEquals(0, cli("state").code)
        assertFalse(lock.exists())
    }
}
