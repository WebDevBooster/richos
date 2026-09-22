package dev.richos.android.platform

import com.sun.net.httpserver.HttpServer
import dev.richos.android.core.protocol.HttpRequest
import dev.richos.android.core.protocol.Signing
import dev.richos.android.core.protocol.SseItem
import dev.richos.android.core.protocol.SseParser
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import java.io.IOException
import java.math.BigInteger
import java.net.InetSocketAddress
import java.security.KeyFactory
import java.security.KeyPairGenerator
import java.security.PrivateKey
import java.security.Signature
import java.security.interfaces.ECPublicKey
import java.security.spec.ECGenParameterSpec
import java.security.spec.ECPoint
import java.security.spec.ECPublicKeySpec

/** The HTTPS wire's refusals, and its request and stream mechanics against a local server. */
class WireTest {
    @Test
    fun `the wire refuses plain HTTP and address literals before connecting`() = runBlocking {
        for (url in listOf("http://mac.example/api/pair", "https://127.0.0.1:8443/api/pair", "https://[::1]:8443/api/pair")) {
            try {
                HttpsMac().send(HttpRequest("GET", url, emptyMap(), null))
                fail("$url was not refused")
            } catch (e: IOException) {
                assertTrue(e.message, e.message!!.startsWith("refusing"))
            }
        }
    }

    private var server: HttpServer? = null

    @After
    fun stop() {
        server?.stop(0)
    }

    private fun serve(handler: com.sun.net.httpserver.HttpHandler): String {
        val s = HttpServer.create(InetSocketAddress("127.0.0.1", 0), 0)
        s.createContext("/", handler)
        s.start()
        server = s
        return "http://127.0.0.1:${s.address.port}"
    }

    @Test
    fun `a request carries its headers and body, and the answer's headers come back lowercase`() = runBlocking {
        var seenBody = ""
        var seenAuth = ""
        val base = serve { ex ->
            seenBody = String(ex.requestBody.readBytes())
            seenAuth = ex.requestHeaders.getFirst("Authorization").orEmpty()
            ex.responseHeaders.add("X-RichOS-Challenge", "fresh")
            val reply = """{"ok":true}""".toByteArray()
            ex.sendResponseHeaders(200, reply.size.toLong())
            ex.responseBody.use { it.write(reply) }
        }
        val r = HttpsMac(allowPlainHttpForTests = true).send(HttpRequest("POST", "$base/api/pair", mapOf("Authorization" to "RichOS-Device d.c.s", "Content-Type" to "application/json"), "{}".toByteArray()))
        assertEquals(200, r.status)
        assertEquals("fresh", r.headers["x-richos-challenge"])
        assertEquals("{}", seenBody)
        assertEquals("RichOS-Device d.c.s", seenAuth)
    }

    @Test
    fun `a refusal's empty body and header are read, not thrown`() = runBlocking {
        val base = serve { ex ->
            ex.responseHeaders.add("X-RichOS-Challenge", "c404")
            ex.sendResponseHeaders(404, -1)
            ex.close()
        }
        val r = HttpsMac(allowPlainHttpForTests = true).send(HttpRequest("GET", "$base/api/challenge", emptyMap(), null))
        assertEquals(404, r.status)
        assertEquals("c404", r.headers["x-richos-challenge"])
    }

    @Test
    fun `the event stream hands every chunk over as it arrives and reports the status first`() = runBlocking {
        val base = serve { ex ->
            ex.responseHeaders.add("Content-Type", "text/event-stream")
            ex.sendResponseHeaders(200, 0)
            ex.responseBody.use { out ->
                out.write("id: 1\nevent: hello\nda".toByteArray()); out.flush()
                out.write("ta: {\"messages\":[]}\n\n: keep-alive 15000\n\n".toByteArray()); out.flush()
            }
        }
        val parser = SseParser()
        val items = mutableListOf<SseItem>()
        var status = 0
        HttpsMac(allowPlainHttpForTests = true).open(
            HttpRequest("GET", "$base/api/events?thread_id=t&auth=x", mapOf("Accept" to "text/event-stream"), null),
            onOpen = { status = it },
            onBytes = { items += parser.feed(it) },
        )
        assertEquals(200, status)
        assertEquals("hello", (items[0] as SseItem.Frame).frame.event)
        assertEquals(SseItem.KeepAlive, items[1])
    }
}
