package dev.richos.android.app

import android.content.Context
import android.util.AtomicFile
import dev.richos.android.core.Clock
import dev.richos.android.core.CoreJson
import dev.richos.android.core.IdSource
import dev.richos.android.core.OutboxItem
import dev.richos.android.core.OutboxStorage
import dev.richos.android.core.Ports
import dev.richos.android.core.Receipt
import dev.richos.android.core.Session
import dev.richos.android.core.SessionStore
import dev.richos.android.core.Transport
import dev.richos.android.core.TransportFailure
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.KSerializer
import kotlinx.serialization.SerializationException
import kotlinx.serialization.builtins.ListSerializer
import java.io.File
import java.util.UUID

/**
 * The production ports: JSON files in app-private storage, each replaced atomically
 * (build plan §3.3 "JSON files in app-private storage with AtomicFile; no Room").
 * Transport arrives with pairing; until then every send is a final "not paired".
 */
object AppPorts {
    fun create(context: Context): Ports {
        val dir = File(context.filesDir, "core")
        val outboxFile = JsonFile(File(dir, "outbox.json"), ListSerializer(OutboxItem.serializer())) { emptyList() }
        val sessionFile = JsonFile(File(dir, "session.json"), Session.serializer()) { Session() }
        return Ports(
            storage = object : OutboxStorage {
                override suspend fun all(): List<OutboxItem> = outboxFile.read()
                override suspend fun put(item: OutboxItem) = outboxFile.write(outboxFile.read().filter { it.clientId != item.clientId } + item)
                override suspend fun remove(clientId: String) = outboxFile.write(outboxFile.read().filter { it.clientId != clientId })
            },
            session = object : SessionStore {
                override suspend fun read(): Session = sessionFile.read()
                override suspend fun write(session: Session) = sessionFile.write(session)
            },
            transport = object : Transport {
                override suspend fun sendText(item: OutboxItem): Receipt = throw TransportFailure("not-paired", retryable = false)
            },
            clock = Clock { System.currentTimeMillis() },
            ids = IdSource { "android-" + UUID.randomUUID() },
        )
    }
}

/**
 * One value in one file. A file this build cannot read is moved aside and never overwritten
 * (the outbox rule in the adoption ledger §2.8, C5); a missing file is the default value.
 */
class JsonFile<T>(private val file: File, private val serializer: KSerializer<T>, private val default: () -> T) {
    private val atomic = AtomicFile(file)

    suspend fun read(): T = withContext(Dispatchers.IO) {
        if (!file.exists()) return@withContext default()
        try {
            CoreJson.decodeFromString(serializer, String(atomic.readFully(), Charsets.UTF_8))
        } catch (e: SerializationException) {
            setAside()
        } catch (e: IllegalArgumentException) {
            setAside()
        }
    }

    suspend fun write(value: T) = withContext(Dispatchers.IO) {
        file.parentFile?.mkdirs()
        val stream = atomic.startWrite()
        try {
            stream.write(CoreJson.encodeToString(serializer, value).toByteArray(Charsets.UTF_8))
            atomic.finishWrite(stream)
        } catch (e: Exception) {
            atomic.failWrite(stream)
            throw e
        }
    }

    private fun setAside(): T {
        val aside = File(file.path + ".unreadable-" + System.currentTimeMillis())
        check(file.renameTo(aside)) { "$file is unreadable and could not be moved aside" }
        return default()
    }
}
