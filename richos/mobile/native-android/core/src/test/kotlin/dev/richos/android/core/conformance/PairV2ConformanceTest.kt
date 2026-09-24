package dev.richos.android.core.conformance

import dev.richos.android.core.Action
import dev.richos.android.core.Clock
import dev.richos.android.core.IdSource
import dev.richos.android.core.Outbox
import dev.richos.android.core.OutboxItem
import dev.richos.android.core.OutboxState
import dev.richos.android.core.OutboxStorage
import dev.richos.android.core.PairingPhase
import dev.richos.android.core.Ports
import dev.richos.android.core.Receipt
import dev.richos.android.core.RichCore
import dev.richos.android.core.Session
import dev.richos.android.core.SessionStore
import dev.richos.android.core.TransportFailure
import dev.richos.android.core.dev.DevKeys
import dev.richos.android.core.protocol.DeviceKeys
import dev.richos.android.core.protocol.Fingerprint
import dev.richos.android.core.protocol.Http
import dev.richos.android.core.protocol.HttpRequest
import dev.richos.android.core.protocol.HttpResponse
import dev.richos.android.core.protocol.MacApi
import dev.richos.android.core.protocol.MacNeedsPairV2
import dev.richos.android.core.protocol.MacWait
import dev.richos.android.core.protocol.MissingIdentity
import dev.richos.android.core.protocol.PAIR_V2
import dev.richos.android.core.protocol.PAIR_WAIT
import dev.richos.android.core.protocol.PairLink
import dev.richos.android.core.protocol.Signing
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.boolean
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.long
import org.junit.Test
import org.junit.runner.RunWith
import org.junit.runners.Parameterized
import java.io.File
import java.net.URLDecoder
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue
import kotlin.test.fail

/**
 * PAIRING v2 AGAINST THE CONFORMANCE CORPUS (`richos/mobile/conformance`, README "Layout"): every
 * `fingerprint.json` `v2` case, every `pairing.json` `pair_v2` exchange and its relay scenario, and
 * every `mac_confirmation` vector, replayed through the Android core. One test per case, named by
 * the case's `name`; the arrays are iterated, never counted by hand. The corpus is read from the
 * repository at test time (Gradle passes `richos.conformance`), never a copy.
 *
 * The key is the corpus's TEST-ONLY key (`keys.json`), which is the development world's [DevKeys].
 * This phone's ECDSA signatures are randomized, so a signed request is checked by its bytes, its
 * signing string and a signature that verifies, never by the signature's bytes.
 */
@RunWith(Parameterized::class)
class PairV2ConformanceTest(@Suppress("unused") private val name: String, private val case: Case) {
    fun interface Case {
        suspend fun run()
    }

    @Test
    fun replay() = runTest { case.run() }

    companion object {
        private val dir = File(System.getProperty("richos.conformance") ?: error("richos.conformance is not set: run through Gradle (bin/randroid test core)"))

        private fun load(file: String): JsonObject {
            val doc = Json.parseToJsonElement(File(dir, file).readText()).jsonObject
            // Reject an unknown schema rather than guess (README "Shared shapes").
            assertEquals(1, doc.getValue("schema").jsonPrimitive.int, "$file schema")
            assertEquals(file, doc.getValue("file").jsonPrimitive.content)
            return doc
        }

        private val pairing by lazy { load("pairing.json") }
        private val fingerprint by lazy { load("fingerprint.json") }
        private val fcm by lazy { load("push-registration-fcm.json") }
        private val keys by lazy { load("keys.json") }

        private const val ORIGIN = "https://mm1.tail1a2b3c.ts.net:8443"

        private fun JsonElement.str() = jsonPrimitive.content
        private fun JsonObject.str(key: String) = getValue(key).str()
        private fun JsonObject.obj(key: String) = getValue(key).jsonObject
        private fun JsonObject.arr(key: String) = getValue(key).jsonArray

        /** A corpus answer as the wire delivers it: header names lowercase, as `MacApi` reads them. */
        private fun answer(o: JsonObject): HttpResponse {
            val body = when (val b = o["body"]) {
                null, is JsonNull -> ""
                is JsonPrimitive -> b.content
                else -> b.toString()
            }
            val headers = o["headers"]?.jsonObject.orEmpty().mapKeys { it.key.lowercase() }.mapValues { it.value.str() }
            return HttpResponse(o.getValue("status").jsonPrimitive.int, headers, body.toByteArray())
        }

        private fun corpusKey(): DeviceKeys = object : DeviceKeys {
            override suspend fun publicPoint(origin: String) = DevKeys.point
            override suspend fun sign(origin: String, data: ByteArray) = DevKeys.sign(data)
            override suspend fun delete(origin: String) = Unit
        }

        /** The body fields in order, parsed from JSON bytes. */
        private fun fields(body: ByteArray?): JsonObject = Json.parseToJsonElement(String(body!!, Charsets.UTF_8)).jsonObject

        /** The signed `Authorization` credential's parts, and that its signature verifies over [signingString]. */
        private fun assertSigned(authorization: String, deviceId: String, challenge: String, signingString: String) {
            val credential = authorization.removePrefix("RichOS-Device ")
            val (device, sentChallenge, signature) = credential.split('.')
            assertEquals(deviceId, device)
            assertEquals(challenge, sentChallenge)
            assertTrue(DevKeys.verify(DevKeys.point, signingString.toByteArray(Charsets.UTF_8), Signing.fromBase64url(signature)), "the signature verifies over the Mac's signing string")
        }

        /** A phone over injected ports: a clock the test moves, a scripted Mac, and the corpus key per origin. */
        private class Phone(val mac: (HttpRequest) -> HttpResponse) {
            var now = 1_700_000_000_000L
            val requests = mutableListOf<Pair<Long, HttpRequest>>()
            val held = mutableSetOf<String>()
            private var saved = Session(online = true)
            val ports = Ports(
                storage = object : OutboxStorage {
                    override suspend fun all() = emptyList<OutboxItem>()
                    override suspend fun put(item: OutboxItem) = Unit
                    override suspend fun remove(clientId: String) = Unit
                },
                session = object : SessionStore {
                    override suspend fun read() = saved
                    override suspend fun write(session: Session) { saved = session }
                },
                transport = null,
                clock = Clock { now },
                ids = IdSource { "c-1" },
                http = Http { r -> requests += now to r; mac(r) },
                keys = object : DeviceKeys {
                    override suspend fun publicPoint(origin: String): ByteArray { held += origin; return DevKeys.point }
                    override suspend fun sign(origin: String, data: ByteArray): ByteArray {
                        if (origin !in held) throw MissingIdentity(origin)
                        return DevKeys.sign(data)
                    }
                    override suspend fun delete(origin: String) { held -= origin }
                },
            )

            suspend fun core() = RichCore.open(ports)

            fun unsigned() = requests.filter { it.second.headers["Authorization"] == null && it.second.method == "POST" }
            fun signedPairPosts() = requests.filter { it.second.url.endsWith("/api/pair") && it.second.headers["Authorization"] != null }
            fun probes() = requests.filter { it.second.url.contains("/api/events?") }
        }

        private val v2Exchanges get() = pairing.obj("pair_v2").arr("exchanges").map { it.jsonObject }
        private val confirmation get() = pairing.obj("mac_confirmation")

        /** The pair-v2 Mac's answer, with [edit] applied to its body. */
        private fun v2Answer(edit: (JsonObject) -> JsonObject = { it }): HttpResponse {
            val o = v2Exchanges.first { !it.getValue("refused_for_missing_pair_v2").jsonPrimitive.boolean }.arr("mac_answers")[0].jsonObject
            return answer(JsonObject(o + ("body" to edit(o.obj("body")))))
        }

        private fun ok(json: String, challenge: String = "c-next") =
            HttpResponse(200, mapOf("x-richos-challenge" to challenge, "content-type" to "application/json"), json.toByteArray())

        @JvmStatic
        @Parameterized.Parameters(name = "{0}")
        fun cases(): List<Array<Any>> = buildList {
            fun add(name: String, case: Case) = add(arrayOf<Any>(name, case))

            add("index lists the pairing, fingerprint and FCM files") {
                val listed = load("index.json").toString()
                for (f in listOf("pairing.json", "fingerprint.json", "push-registration-fcm.json", "keys.json")) assertTrue(f in listed, f)
            }

            add("keys.json is the development world's test key") {
                assertEquals(keys.str("public_point_b64url"), DevKeys.POINT_B64URL)
                assertEquals(keys.str("device_id"), Signing.deviceId(DevKeys.point))
                assertEquals(keys.str("test_only_private_scalar_hex"), DevKeys.SCALAR_HEX)
            }

            // ---- fingerprint.json -------------------------------------------------------------
            add("fingerprint: the word list is the corpus's, checked by its SHA-256") {
                assertEquals(fingerprint.getValue("word_count").jsonPrimitive.int, Fingerprint.WORD_COUNT)
                assertEquals(fingerprint.arr("wordlist").map { it.str() }, Fingerprint.WORDS)
                val sha = fingerprint.str("wordlist_sha256_of_newline_joined")
                assertEquals(sha, Fingerprint.WORDLIST_SHA256)
                assertEquals(sha, Signing.hex(Signing.sha256(Fingerprint.WORDS.joinToString("\n").toByteArray())))
                assertEquals(fingerprint.obj("v2").str("label"), Fingerprint.PAIR_V2_LABEL)
            }
            for (c in fingerprint.obj("v2").arr("cases").map { it.jsonObject }) {
                add("fingerprint v2: ${c.str("name")}") {
                    val point = c.str("device_point_b64url")
                    assertEquals(c.str("input_utf8"), Fingerprint.v2Input(c.str("origin"), c.str("ca_fingerprint_sha256"), point))
                    assertEquals(c.arr("words").map { it.str() }, Fingerprint.wordsV2(c.str("origin"), c.str("ca_fingerprint_sha256"), point))
                    assertEquals(c.str("phrase"), Fingerprint.wordsV2(c.str("origin"), c.str("ca_fingerprint_sha256"), point).joinToString(" "))
                }
            }
            add("fingerprint: a v2 phone never shows the v1 words (the hash alone)") {
                val phone = Phone { r -> if (r.headers["Authorization"] == null) v2Answer() else ok("{\"ok\":true}") }
                val s = phone.core().dispatch(Action.Pair("$ORIGIN/#pair=K7M2QX9H"))
                val ca = v2Answer().text.let { Json.parseToJsonElement(it).jsonObject.str("ca_fingerprint_sha256") }
                val v1 = fingerprint.arr("cases").map { it.jsonObject }.first { it.str("input") == ca }.arr("words").map { it.str() }
                val v2 = fingerprint.obj("v2").arr("cases").map { it.jsonObject }
                    .first { it.str("origin") == ORIGIN && it.str("ca_fingerprint_sha256") == ca && it.str("device_point_b64url") == DevKeys.POINT_B64URL }
                    .arr("words").map { it.str() }
                assertEquals(PairingPhase.CONFIRMING, s.pairing.phase)
                assertEquals(v2, s.pairing.words, "the screen shows the v2 words")
                assertNotEquals(v1, s.pairing.words, "and never the v1 words of the same hash")
            }

            // ---- pairing.json: pair_v2 --------------------------------------------------------
            val pairV2 = pairing.obj("pair_v2")
            val bodyFields = pairV2.arr("native_v2_body_fields").map { it.str() }
            for (x in v2Exchanges) {
                val refused = x.getValue("refused_for_missing_pair_v2").jsonPrimitive.boolean
                val recorded = x.arr("requests")[0].jsonObject
                val macAnswer = answer(x.arr("mac_answers")[0].jsonObject)
                add("pair_v2 (MacApi): ${x.str("name")}") {
                    val sent = mutableListOf<HttpRequest>()
                    val api = MacApi(Http { r -> sent += r; macAnswer }, corpusKey())
                    val code = fields(recorded.obj("body").str("utf8").toByteArray()).str("code")
                    val result = runCatching { api.pair(PairLink(ORIGIN, code), "Android phone", DevKeys.point) }
                    // Exactly one request: the recorded shape, the native v2 fields in order, unsigned.
                    val r = sent.single()
                    assertEquals(recorded.str("method"), r.method)
                    assertEquals(ORIGIN + recorded.str("target"), r.url)
                    assertEquals(recorded.obj("headers").str("Content-Type"), r.headers["Content-Type"])
                    assertNull(r.headers["Authorization"], "the pairing request is unsigned")
                    val body = fields(r.body)
                    assertEquals(bodyFields, body.keys.toList(), "native_v2_body_fields, in order")
                    val reference = fields(recorded.obj("body").str("utf8").toByteArray())
                    for ((k, v) in reference) assertEquals(v, body[k], "body field $k")
                    assertEquals(JsonPrimitive("android"), body["platform"])
                    assertEquals(JsonPrimitive(x.getValue("pairing_version").jsonPrimitive.int), body["pairing_version"])
                    // The outcome, and whether it was refused for a missing pair-v2.
                    val outcome = x.obj("outcome")
                    if (outcome.getValue("ok").jsonPrimitive.boolean) {
                        val a = result.getOrThrow()
                        val value = outcome.obj("value")
                        assertEquals(value.str("device_id"), a.deviceId)
                        assertEquals(value.str("ca_fingerprint_sha256"), a.caFingerprint)
                        assertEquals(value.str("challenge"), a.challenge)
                        assertFalse(refused)
                    } else {
                        val e = result.exceptionOrNull()
                        assertTrue(e is MacNeedsPairV2, "refused_for_missing_pair_v2 (got $e)")
                        assertTrue(refused)
                        val error = outcome.obj("error")
                        assertEquals(error.str("reason"), e.reason)
                        assertEquals(error.getValue("retryable").jsonPrimitive.boolean, e.retryable)
                        // state_after: what the one fingerprint_confirmed:false is signed with.
                        val after = x.obj("state_after")
                        assertEquals(after.str("device_id"), e.answer.deviceId)
                        assertEquals(after.str("challenge"), e.answer.challenge)
                    }
                }
                add("pair_v2 (core): ${x.str("name")}") {
                    val phone = Phone { r -> if (r.headers["Authorization"] == null) macAnswer else ok("{\"ok\":true}") }
                    val s = phone.core().dispatch(Action.Pair("$ORIGIN/#pair=K7M2QX9H"))
                    assertEquals(1, phone.unsigned().size, "one pairing request: a v2 phone never falls back to v1")
                    assertTrue(fields(phone.unsigned().single().second.body).containsKey("pairing_version"))
                    if (refused) {
                        assertEquals(PairingPhase.UNPAIRED, s.pairing.phase)
                        assertEquals(RichCore.PROBLEM_MAC_NEEDS_UPDATE, s.pairing.problem)
                        assertTrue(s.pairing.words.isEmpty(), "no words are shown for a Mac without pair-v2")
                        // It signs ONE fingerprint_confirmed:false so that Mac forgets the key, then forgets it here.
                        val forget = phone.signedPairPosts().single().second
                        val after = x.obj("state_after")
                        assertEquals(JsonPrimitive(false), fields(forget.body)["fingerprint_confirmed"])
                        assertEquals(JsonPrimitive(after.str("device_id")), fields(forget.body)["device_id"])
                        assertSigned(forget.headers.getValue("Authorization"), after.str("device_id"), after.str("challenge"),
                            Signing.signingString(after.str("challenge"), "POST", "/api/pair", forget.body))
                        assertFalse(ORIGIN in phone.held, "the key is gone")
                    } else {
                        assertEquals(PairingPhase.CONFIRMING, s.pairing.phase)
                        assertEquals(null, s.pairing.problem)
                        assertTrue(phone.signedPairPosts().isEmpty())
                        assertEquals(MacWait.boundMs(300.0), s.pairing.macWaitBoundMs)
                    }
                }
            }
            val relay = pairV2.obj("relay_scenario")
            add("pair_v2 relay: ${relay.str("name")}") {
                val phone = Phone { r -> if (r.headers["Authorization"] == null) v2Answer() else ok("{\"ok\":true}") }
                val dialed = relay.str("phone_dialed")
                val s = phone.core().dispatch(Action.Pair("$dialed/#pair=K7M2QX9H"))
                val sent = phone.unsigned().single().second
                assertEquals(dialed + relay.obj("request").str("target"), sent.url, "the phone dials the relay")
                val reference = fields(relay.obj("request").obj("body").str("utf8").toByteArray())
                for ((k, v) in reference) assertEquals(v, fields(sent.body)[k], "body field $k")
                val phoneWords = relay.arr("phone_words").map { it.str() }
                val macWords = relay.arr("mac_words").map { it.str() }
                assertEquals(phoneWords, s.pairing.words, "the phone's words are over the origin it DIALED")
                // What the Mac shows: the same derivation over its own origin and the key it registered.
                assertEquals(macWords, Fingerprint.wordsV2(relay.str("mac_origin"), relay.str("ca_fingerprint_sha256"), relay.str("device_point_b64url")))
                assertNotEquals(macWords, s.pairing.words, "the two screens show different words")
                assertEquals(dialed, s.pairing.apiBase, "the advertised api_base does not replace the origin the words name")
            }

            // ---- pairing.json: mac_confirmation -----------------------------------------------
            add("mac_confirmation: the schedule is wait_schedule_ms, at most max_requests_in_the_window") {
                val schedule = confirmation.arr("wait_schedule_ms").map { it.jsonObject }
                var at = 0L
                for (step in schedule) {
                    val attempt = step.getValue("attempt").jsonPrimitive.int
                    assertEquals(step.getValue("delay_ms").jsonPrimitive.long, MacWait.delayMs(attempt), "attempt $attempt")
                    at += MacWait.delayMs(attempt)
                    assertEquals(step.getValue("asked_at_ms").jsonPrimitive.long, at, "attempt $attempt")
                }
                assertEquals(confirmation.getValue("max_requests_in_the_window").jsonPrimitive.int, MacWait.MAX_REQUESTS)
                assertEquals(schedule.size, MacWait.MAX_REQUESTS)
                assertTrue(at + MacWait.delayMs(schedule.size) > MacWait.WINDOW_MS, "a 23rd ask would fall past the window")
            }
            add("mac_confirmation: wait_bound_ms") {
                val bound = confirmation.obj("wait_bound_ms")
                assertEquals(bound.getValue("from_answer_240_seconds").jsonPrimitive.long, MacWait.boundMs(240.0))
                assertEquals(bound.getValue("from_answer_9999_seconds").jsonPrimitive.long, MacWait.boundMs(9999.0))
                assertEquals(bound.getValue("when_the_mac_says_nothing").jsonPrimitive.long, MacWait.boundMs(null))
            }
            add("mac_confirmation: phone_answer_while_waiting, as the Android app sends it (push_transport fcm)") {
                val android = fcm.arr("requests").map { it.jsonObject }.first { "Android" in it.str("name") }.obj("request")
                val signed = android.obj("signed")
                val sent = mutableListOf<HttpRequest>()
                val outcome = confirmation.obj("phone_answer_while_waiting").obj("outcome").obj("value")
                val api = MacApi(Http { r -> sent += r; ok(outcome.toString()) }, corpusKey())
                val deviceId = keys.str("device_id")
                val c = api.confirm(ORIGIN, deviceId, signed.str("challenge"), match = true, fcm = true)
                assertTrue(c.awaitingMac, "the Mac's answer says it waits for its own press")
                val r = sent.single()
                assertEquals(android.str("method"), r.method)
                assertEquals(ORIGIN + android.str("target"), r.url)
                assertEquals(android.obj("headers").str("Content-Type"), r.headers["Content-Type"])
                assertEquals(android.obj("body").str("utf8"), String(r.body!!, Charsets.UTF_8), "byte for byte")
                assertSigned(r.headers.getValue("Authorization"), deviceId, signed.str("challenge"), android.obj("mac").str("signing_string"))
                // The recorded web request says the same thing, apart from the push service it names.
                val web = confirmation.obj("phone_answer_while_waiting").arr("requests")[0].jsonObject
                assertEquals(fields(web.obj("body").str("utf8").toByteArray()) - "push_transport", fields(r.body) - "push_transport")
            }
            for (probe in confirmation.arr("probes").map { it.jsonObject }) {
                add("mac_confirmation probe (MacApi): ${probe.str("name")}") {
                    val recorded = probe.arr("requests")[0].jsonObject
                    val signed = recorded.obj("signed")
                    val sent = mutableListOf<HttpRequest>()
                    val mac = answer(probe.obj("mac_answer"))
                    val api = MacApi(Http { r -> sent += r; mac }, corpusKey())
                    val thread = signed.str("path_with_query").substringAfter("thread_id=").substringBefore('&')
                    val result = runCatching { api.macConfirmed(ORIGIN, keys.str("device_id"), signed.str("challenge"), thread) }
                    val r = sent.single()
                    assertEquals(recorded.str("method"), r.method)
                    val (path, auth) = r.url.removePrefix(ORIGIN).split("&auth=")
                    assertEquals(signed.str("path_with_query"), path, "the smallest read: one backfill row")
                    assertEquals(recorded.str("target").substringBefore("&auth="), path)
                    assertSigned(URLDecoder.decode(auth, Charsets.UTF_8), keys.str("device_id"), signed.str("challenge"), recorded.obj("mac").str("signing_string"))
                    val outcome = probe.obj("outcome")
                    if (outcome.getValue("ok").jsonPrimitive.boolean) {
                        val (confirmed, challenge) = result.getOrThrow()
                        assertEquals(outcome.getValue("value").jsonPrimitive.boolean, confirmed)
                        assertEquals(probe.obj("mac_answer").obj("headers").str("X-RichOS-Challenge"), challenge, "the answer's challenge is the next one")
                    } else {
                        val e = result.exceptionOrNull() as? TransportFailure ?: fail("expected a classified refusal, got ${result.exceptionOrNull()}")
                        val error = outcome.obj("error")
                        assertEquals(error.str("reason"), e.reason)
                        assertEquals(error.getValue("retryable").jsonPrimitive.boolean, e.retryable)
                    }
                }
            }
            val classification = confirmation.obj("awaiting_answer_classification")
            add("mac_confirmation: ${classification.str("name")}") {
                assertEquals(confirmation.str("awaiting_body"), classification.obj("mac_answer").str("body"))
                val mac = answer(classification.obj("mac_answer"))
                val api = MacApi(Http { mac }, corpusKey())
                val required = classification.obj("required")
                assertEquals("retry_same_bytes_after_backoff", required.str("client_action"))
                // The classifier: retryable, never final, and named.
                val e = runCatching { api.signed(ORIGIN, keys.str("device_id"), "c", "POST", "/api/messages", "{}".toByteArray(), "application/json") }
                    .exceptionOrNull() as? TransportFailure ?: fail("the awaiting 409 must be a classified failure")
                assertTrue(e.retryable, "wait and retry, never refused")
                assertFalse(e.aboutThisMessage)
                assertTrue(e.awaitingMac)
                // The outbox takes it as the reference does: the message waits, the same bytes, after the back-off.
                var now = 1_700_000_000_000L
                val stored = mutableMapOf<String, OutboxItem>()
                val outbox = Outbox(object : OutboxStorage {
                    override suspend fun all() = stored.values.toList()
                    override suspend fun put(item: OutboxItem) { stored[item.clientId] = item }
                    override suspend fun remove(clientId: String) { stored.remove(clientId) }
                }, Clock { now })
                val wire = "{\"client_id\":\"a\"}"
                outbox.enqueue(OutboxItem(clientId = "a", threadId = "thr_5c1e", kind = "text", text = "one", queuedAt = "2026-09-24T00:00:00.000Z", wire = wire))
                outbox.enqueue(OutboxItem(clientId = "b", threadId = "thr_5c1e", kind = "text", text = "two", queuedAt = "2026-09-24T00:00:01.000Z", wire = "{}"))
                val attempted = mutableListOf<String>()
                outbox.flush { item -> attempted += item.clientId; api.signed(ORIGIN, keys.str("device_id"), "c", "POST", "/api/messages", item.wire!!.toByteArray(), "application/json"); Receipt("x", false, 1) }
                val reference = classification.obj("reference")
                val item = outbox.all().first { it.clientId == "a" }
                assertEquals(reference.str("message_state_after"), if (item.state == OutboxState.WAITING) "waiting" else item.state.name.lowercase())
                assertEquals(required.getValue("retry_after_ms").jsonPrimitive.long, item.notBefore!! - now)
                assertEquals(wire, item.wire, "the same bytes")
                assertEquals(reference.getValue("next_message_attempted").jsonPrimitive.boolean, "b" in attempted)
            }

            // ---- pairing.json: pair_wait (Echo's handoff, 2026-09-24; Sage's hypotheses review §1, §2) --
            val pw = pairing.obj("pair_wait")
            val androidAnswer = fcm.arr("requests").map { it.jsonObject }.first { "Android" in it.str("name") }.obj("request").obj("body").str("utf8")
            add("pair_wait: the capability and its limits are the file's") {
                assertEquals(pw.str("capability"), PAIR_WAIT)
                assertEquals(pw.str("offered_beside"), PAIR_V2)
                assertEquals("Prefer: wait=<seconds>", pw.str("prefer_header"))
                assertEquals(pw.getValue("hold_seconds_max").jsonPrimitive.int, MacWait.HOLD_SECONDS_MAX)
                assertEquals(pw.getValue("min_ask_spacing_ms").jsonPrimitive.long, MacWait.MIN_SPACING_MS)
                val floor = pw.getValue("request_timeout_must_exceed_ms").jsonPrimitive.long
                assertTrue(RichCore.MAC_WAIT_REQUEST_MS > floor, "one ask's timeout (${RichCore.MAC_WAIT_REQUEST_MS} ms) must exceed $floor ms, or a full hold is cut off")
                // Every corpus pairing answer names pair-wait beside pair-v2, additively.
                assertTrue(v2Exchanges.all { x -> PAIR_WAIT in x.arr("mac_answers")[0].jsonObject.obj("body").arr("capabilities").map { it.str() } })
            }
            for (ask in pw.arr("asks").map { it.jsonObject }) {
                add("pair_wait ask (MacApi): ${ask.str("name")}") {
                    val recorded = ask.arr("requests")[0].jsonObject
                    val signed = recorded.obj("signed")
                    val sent = mutableListOf<HttpRequest>()
                    val mac = answer(ask.obj("mac_answer"))
                    val api = MacApi(Http { r -> sent += r; mac }, corpusKey())
                    val wait = ask.getValue("wait_seconds").jsonPrimitive.int
                    val result = runCatching { api.macAnswer(ORIGIN, keys.str("device_id"), signed.str("challenge"), fcm = true, waitSeconds = wait) }
                    // Exactly requests[0]: the method, the target, Prefer if and only if the Mac holds, the body, the signature.
                    val r = sent.single()
                    assertEquals(recorded.str("method"), r.method)
                    assertEquals(ORIGIN + recorded.str("target"), r.url)
                    assertEquals(recorded.obj("headers").str("Content-Type"), r.headers["Content-Type"])
                    assertEquals(recorded.obj("headers")["Prefer"]?.str(), r.headers["Prefer"], "Prefer is sent exactly when wait_seconds > 0")
                    assertEquals(wait > 0, r.headers.containsKey("Prefer"))
                    // The body is THIS phone's own "They match", byte for byte as it sent it at the press.
                    assertEquals(androidAnswer, String(r.body!!, Charsets.UTF_8), "the Android confirmation body, byte for byte")
                    val reference = recorded.obj("body").str("utf8")
                    assertEquals(fields(reference.toByteArray()) - "push_transport", fields(r.body) - "push_transport")
                    // The canonical string follows the recorded one's rule; Prefer stays outside it.
                    assertEquals(signed.str("signing_string"), Signing.signingString(signed.str("challenge"), "POST", "/api/pair", reference.toByteArray()))
                    assertSigned(r.headers.getValue("Authorization"), keys.str("device_id"), signed.str("challenge"),
                        Signing.signingString(signed.str("challenge"), "POST", "/api/pair", r.body))
                    val outcome = ask.obj("outcome")
                    if (outcome.getValue("ok").jsonPrimitive.boolean) {
                        val c = result.getOrThrow()
                        assertEquals(outcome.getValue("value").jsonPrimitive.boolean, !c.awaitingMac, "pressed on the Mac")
                        assertEquals(ask.obj("mac_answer").obj("headers").str("X-RichOS-Challenge"), c.challenge)
                    } else {
                        val e = result.exceptionOrNull() as? TransportFailure ?: fail("expected a classified refusal, got ${result.exceptionOrNull()}")
                        val error = outcome.obj("error")
                        assertEquals(error.str("reason"), e.reason)
                        assertEquals(error.getValue("retryable").jsonPrimitive.boolean, e.retryable)
                    }
                }
            }
            for (c in pw.arr("next_delay_cases").map { it.jsonObject }) {
                val attempt = c.getValue("attempt").jsonPrimitive.int
                val took = c.getValue("previous_ask_took_ms").jsonPrimitive.long
                val holds = c.getValue("mac_offers_pair_wait").jsonPrimitive.boolean
                add("pair_wait next_delay: attempt $attempt, took $took ms, holds $holds") {
                    assertEquals(c.getValue("next_ask_after_ms").jsonPrimitive.long, MacWait.nextDelayMs(attempt, took, holds))
                }
            }
            for (c in pw.arr("last_ask_cases").map { it.jsonObject }) {
                add("pair_wait last_ask: ${c.str("name")}") {
                    assertEquals(
                        c.getValue("next_ask_at_ms").jsonPrimitive.long,
                        MacWait.nextAskAt(
                            c.getValue("attempt").jsonPrimitive.int, c.getValue("previous_ask_at_ms").jsonPrimitive.long,
                            c.getValue("previous_answer_at_ms").jsonPrimitive.long, c.getValue("deadline_ms").jsonPrimitive.long,
                            c.getValue("mac_offers_pair_wait").jsonPrimitive.boolean,
                        ),
                    )
                }
            }
            add("pair_wait: no plan can exceed the phone's own ceiling on asks") {
                assertTrue(pw.arr("wait_plans").all { it.jsonObject.getValue("total_asks").jsonPrimitive.int <= MacWait.MAX_ASKS })
                // While the Mac holds, at most one ask per spacing inside the window, then the last ask.
                assertEquals((MacWait.WINDOW_MS / MacWait.MIN_SPACING_MS + 1 + 1).toInt(), MacWait.MAX_ASKS)
            }

            /** A pairing answer from a Mac that does ([holds]) or does not offer pair-wait. */
            fun pairAnswer(holds: Boolean) = v2Answer { body ->
                val caps = body.arr("capabilities").map { it.str() }.filter { it != PAIR_WAIT } + listOfNotNull(PAIR_WAIT.takeIf { holds })
                JsonObject(body + ("capabilities" to JsonArray(caps.map(::JsonPrimitive))))
            }
            val stillWaiting = pw.obj("answers").obj("still_waiting")

            /** The asks this phone made after the press, the press included: (when, the request). */
            fun Phone.asks() = signedPairPosts().filter { fields(it.second.body)["fingerprint_confirmed"] == JsonPrimitive(true) }
            fun preferOf(r: HttpRequest): Int? = r.headers["Prefer"]?.let { v -> assertTrue(v.startsWith("wait=")); v.removePrefix("wait=").toInt() }

            for (plan in pw.arr("wait_plans").map { it.jsonObject }) {
                add("pair_wait plan (core): ${plan.str("name")}") {
                    val holds = plan.getValue("mac_offers_pair_wait").jsonPrimitive.boolean
                    // The plan's Mac: one that holds every ask for as long as it was asked, or one that answers at once.
                    val holdsForAsLongAsAsked = holds && "holds every ask" in plan.str("name")
                    lateinit var phone: Phone
                    phone = Phone { r ->
                        if (r.headers["Authorization"] == null && r.method == "POST") pairAnswer(holds) else {
                            if (holdsForAsLongAsAsked) preferOf(r)?.let { phone.now += it * 1000L }
                            answer(stillWaiting)
                        }
                    }
                    val core = phone.core()
                    core.dispatch(Action.Pair("$ORIGIN/#pair=K7M2QX9H"))
                    val t0 = phone.now
                    val until = t0 + MacWait.WINDOW_MS
                    var s = core.dispatch(Action.ConfirmWords(true))
                    // The app's timer, exactly: sleep until the published due time, then `mac-wait`.
                    while (s.pairing.phase == PairingPhase.AWAITING_MAC) {
                        val due = s.macWaitDueInMs ?: fail("a visible wait always has a due time")
                        phone.now += due
                        s = core.dispatch(Action.MacWait)
                        if (phone.now - t0 > 400_000) fail("the wait did not end")
                    }
                    val made = phone.asks().map { (at, r) -> Triple(at - t0, preferOf(r), at >= until) }
                    val expected = plan.arr("asks").map { it.jsonObject }.map { a ->
                        val prefer = a.getValue("prefer_wait_seconds").let { if (it is JsonNull) null else it.jsonPrimitive.int }
                        Triple(a.getValue("at_ms").jsonPrimitive.long, prefer, a.getValue("final").jsonPrimitive.boolean)
                    }
                    assertEquals(expected, made)
                    assertEquals(plan.getValue("total_asks").jsonPrimitive.int, made.size)
                    assertEquals(plan.getValue("smallest_gap_between_asks_ms").jsonPrimitive.long, made.zipWithNext { a, b -> b.first - a.first }.min())
                    // Never pressed: after the last ask the phone says it did not hear back, and forgets the key.
                    assertEquals(PairingPhase.UNPAIRED, s.pairing.phase)
                    assertEquals(RichCore.PROBLEM_EXPIRED, s.pairing.problem)
                    assertNull(s.macWaitDueInMs)
                    assertFalse(ORIGIN in phone.held)
                    // Every ask is the phone's own answer, byte for byte.
                    for ((_, r) in phone.asks()) assertEquals(androidAnswer, String(r.body!!, Charsets.UTF_8))
                    assertTrue(phone.probes().isEmpty(), "the backfill probe is no longer the wait")
                }
            }

            for ((label, seconds) in listOf("240 s" to 240, "nothing" to -1)) {
                add("pair_wait (core): a Mac without pair-wait is asked on wait_schedule_ms, then once at the bound, confirm_within_seconds $label") {
                    val schedule = confirmation.arr("wait_schedule_ms").map { it.jsonObject.getValue("asked_at_ms").jsonPrimitive.long }
                    val phone = Phone { r ->
                        if (r.headers["Authorization"] == null && r.method == "POST") {
                            val a = pairAnswer(holds = false)
                            val body = Json.parseToJsonElement(a.text).jsonObject
                            val edited = if (seconds < 0) body - "confirm_within_seconds" else body + ("confirm_within_seconds" to JsonPrimitive(seconds))
                            HttpResponse(a.status, a.headers, JsonObject(edited).toString().toByteArray())
                        } else {
                            answer(stillWaiting)
                        }
                    }
                    val core = phone.core()
                    core.dispatch(Action.Pair("$ORIGIN/#pair=K7M2QX9H"))
                    val t0 = phone.now
                    var s = core.dispatch(Action.ConfirmWords(true))
                    while (s.pairing.phase == PairingPhase.AWAITING_MAC) {
                        phone.now += s.macWaitDueInMs ?: fail("a visible wait always has a due time")
                        s = core.dispatch(Action.MacWait)
                        if (phone.now - t0 > 400_000) fail("the wait did not end")
                    }
                    val bound = MacWait.boundMs(if (seconds < 0) null else seconds.toDouble())
                    val asked = phone.asks().map { it.first - t0 }
                    assertEquals(listOf(0L) + schedule.filter { it < bound } + bound, asked, "the press, the schedule inside the bound, then the last ask at the bound")
                    assertTrue(phone.asks().none { it.second.headers.containsKey("Prefer") }, "no Prefer to a Mac that does not offer pair-wait")
                    assertEquals(RichCore.PROBLEM_EXPIRED, s.pairing.problem)
                }
            }

            // The core's action for each of the Mac's answer shapes (`pair_wait.answers`), on the ask after the press.
            for ((shape, a) in pw.obj("answers")) {
                add("pair_wait answer (core): $shape") {
                    val o = a.jsonObject
                    var released = false
                    val phone = Phone { r ->
                        when {
                            r.headers["Authorization"] == null && r.method == "POST" -> pairAnswer(holds = true)
                            !released -> { released = true; answer(stillWaiting) }
                            o["status"] is JsonNull -> throw java.io.IOException("no route to the Mac")
                            else -> answer(o)
                        }
                    }
                    val core = phone.core()
                    core.dispatch(Action.Pair("$ORIGIN/#pair=K7M2QX9H"))
                    var s = core.dispatch(Action.ConfirmWords(true))
                    assertEquals(PairingPhase.AWAITING_MAC, s.pairing.phase)
                    phone.now += s.macWaitDueInMs!!
                    s = core.dispatch(Action.MacWait)
                    assertEquals(2, phone.asks().size)
                    when (shape) {
                        "pressed" -> {
                            assertEquals(PairingPhase.PAIRED, s.pairing.phase)
                            assertTrue(s.paired)
                            assertNull(s.macWaitDueInMs)
                        }
                        "still_waiting", "still_waiting_as_409", "unreachable" -> {
                            assertEquals(PairingPhase.AWAITING_MAC, s.pairing.phase, "waiting is never refused")
                            assertNull(s.pairing.problem)
                            assertTrue(ORIGIN in phone.held)
                        }
                        "refused_on_the_mac", "window_closed" -> {
                            assertEquals(PairingPhase.UNPAIRED, s.pairing.phase)
                            assertEquals(RichCore.PROBLEM_MAC_DECLINED, s.pairing.problem, "declined, never removed-from-Mac")
                            assertNull(s.macWaitDueInMs, "nothing more is asked")
                            assertFalse(ORIGIN in phone.held)
                        }
                        else -> fail("an answer shape this phone does not know: $shape")
                    }
                }
            }
            add("pair_wait (core): at the last ask, pressed means paired, a refusal declined, anything else expired") {
                val answers = pw.obj("answers")
                for ((last, expect) in listOf<Pair<HttpResponse?, Any>>(
                    answer(answers.obj("pressed")) to PairingPhase.PAIRED,
                    answer(answers.obj("refused_on_the_mac")) to RichCore.PROBLEM_MAC_DECLINED,
                    answer(answers.obj("still_waiting")) to RichCore.PROBLEM_EXPIRED,
                    null to RichCore.PROBLEM_EXPIRED,
                )) {
                    var until = Long.MAX_VALUE
                    lateinit var phone: Phone
                    phone = Phone { r ->
                        when {
                            r.headers["Authorization"] == null && r.method == "POST" -> pairAnswer(holds = false)
                            phone.now < until -> answer(stillWaiting)
                            last == null -> throw java.io.IOException("no route to the Mac")
                            else -> last
                        }
                    }
                    val core = phone.core()
                    core.dispatch(Action.Pair("$ORIGIN/#pair=K7M2QX9H"))
                    until = phone.now + MacWait.WINDOW_MS
                    var s = core.dispatch(Action.ConfirmWords(true))
                    while (s.pairing.phase == PairingPhase.AWAITING_MAC) {
                        phone.now += s.macWaitDueInMs!!
                        s = core.dispatch(Action.MacWait)
                    }
                    val final = phone.asks().last()
                    assertEquals(until, final.first, "the last ask goes at the deadline")
                    assertNull(final.second.headers["Prefer"], "the last ask carries no Prefer")
                    if (expect == PairingPhase.PAIRED) assertEquals(PairingPhase.PAIRED, s.pairing.phase) else assertEquals<Any?>(expect, s.pairing.problem)
                }
            }
        }
    }
}
