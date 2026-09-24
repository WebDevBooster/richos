package dev.richos.android.platform

import dev.richos.android.core.EventStream
import dev.richos.android.core.protocol.Http
import dev.richos.android.core.protocol.HttpRequest
import dev.richos.android.core.protocol.HttpResponse
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.launch
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.withContext
import java.io.IOException
import java.io.InputStream
import java.net.HttpURLConnection
import java.net.URL

/**
 * The wire to the Mac (phone protocol contract §1.1): HTTPS only, by host name only so SNI carries
 * the name, on the platform's DEFAULT trust store with NOTHING pinned. The Tailscale route presents
 * a publicly trusted chain for the tailnet name and the Connect route is terminated by Cloudflare;
 * the Mac's own authority is used only for the six words. HTTP/1.1, as the Mac speaks.
 *
 * [open] is how a connection is made; the app uses the default, a JVM test injects a plain local
 * server behind the same checks, so the request and stream mechanics are proven without a device.
 */
class HttpsMac(
    private val open: (URL) -> HttpURLConnection = { it.openConnection() as HttpURLConnection },
    private val allowPlainHttpForTests: Boolean = false,
) : Http, EventStream {

    private fun connect(request: HttpRequest, readTimeoutMs: Int): HttpURLConnection {
        val url = URL(request.url)
        val secure = url.protocol == "https"
        if (!secure && !allowPlainHttpForTests) throw IOException("refusing ${url.protocol}: the Mac is reached over HTTPS only")
        if (isAddressLiteral(url.host) && !allowPlainHttpForTests) throw IOException("refusing an address: connect by host name so SNI carries it")
        return open(url).apply {
            requestMethod = request.method
            connectTimeout = CONNECT_TIMEOUT_MS
            readTimeout = readTimeoutMs
            instanceFollowRedirects = false
            useCaches = false
            for ((k, v) in request.headers) setRequestProperty(k, v)
            request.body?.let { body ->
                doOutput = true
                setFixedLengthStreamingMode(body.size)
            }
        }
    }

    private fun HttpURLConnection.lowercaseHeaders(): Map<String, String> =
        headerFields.orEmpty().filterKeys { it != null }.map { (k, v) -> k.lowercase() to v.lastOrNull().orEmpty() }.toMap()

    private fun HttpURLConnection.bodyStream(): InputStream? = if (responseCode >= 400) errorStream else inputStream

    override suspend fun send(request: HttpRequest): HttpResponse = withContext(Dispatchers.IO) { coroutineScope {
        val c = connect(request, REQUEST_READ_TIMEOUT_MS)
        val closer = launch(start = CoroutineStart.UNDISPATCHED) {
            try { awaitCancellation() } finally { c.disconnect() }
        }
        try {
            request.body?.let { body -> c.outputStream.use { it.write(body) } }
            val status = c.responseCode
            val body = c.bodyStream()?.use { it.readBytes() } ?: ByteArray(0)
            HttpResponse(status, c.lowercaseHeaders(), body)
        } catch (failure: IOException) {
            coroutineContext.ensureActive()
            throw failure
        } finally {
            closer.cancel()
            c.disconnect()
        }
    } }

    override suspend fun open(request: HttpRequest, onOpen: suspend (Int) -> Unit, onBytes: suspend (ByteArray) -> Unit) {
        withContext(Dispatchers.IO) { coroutineScope {
            // The Mac sends a keep-alive comment every 15 s; three missed means the socket is dead.
            val c = connect(request, STREAM_READ_TIMEOUT_MS)
            // A blocked read does not notice cancellation; closing the socket does.
            val closer = launch(start = CoroutineStart.UNDISPATCHED) {
                try { awaitCancellation() } finally { c.disconnect() }
            }
            try {
                val status = c.responseCode
                onOpen(status)
                if (status != 200) return@coroutineScope
                c.inputStream.use { input ->
                    val buffer = ByteArray(8 * 1024)
                    while (true) {
                        coroutineContext.ensureActive()
                        val n = input.read(buffer)
                        if (n < 0) break
                        if (n > 0) onBytes(buffer.copyOf(n))
                    }
                }
            } catch (failure: IOException) {
                coroutineContext.ensureActive()
                throw failure
            } finally {
                closer.cancel()
                c.disconnect()
            }
        } }
    }

    companion object {
        const val CONNECT_TIMEOUT_MS = 10_000
        const val REQUEST_READ_TIMEOUT_MS = 30_000
        const val STREAM_READ_TIMEOUT_MS = 45_000

        /** IPv4 dotted quads and bracketed or bare IPv6 literals. */
        fun isAddressLiteral(host: String): Boolean =
            Regex("^\\d{1,3}(\\.\\d{1,3}){3}$").matches(host) || host.startsWith("[") || host.contains(':')
    }
}
