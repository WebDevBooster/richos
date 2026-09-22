package dev.richos.android.core

import dev.richos.android.core.dev.DevRequest
import dev.richos.android.core.dev.DevRuntime
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/** Connection states: `connection.js` `classify` and the client's quiet 3-second rule. */
class ConnectionTest {
    @Test
    fun `the reconnect-notice scenario passes`() = runTest {
        val result = DevRuntime.create().execute(DevRequest.Scenario("reconnect-notice")).jsonObject
        assertEquals("reconnect-notice", result["name"]!!.jsonPrimitive.content)
    }

    @Test
    fun `classify orders the evidence as the preserved client does`() {
        val c = Connections::classify
        assertEquals(ConnectionReason.REVOKED, c(true, true, true, false, ServiceState.UNAVAILABLE))
        assertEquals(ConnectionReason.INCOMPATIBLE, c(true, false, true, false, null))
        assertEquals(ConnectionReason.CONNECTED, c(true, false, false, false, ServiceState.UNAVAILABLE))
        assertEquals(ConnectionReason.PHONE_OFFLINE, c(false, false, false, false, ServiceState.UNAVAILABLE))
        assertEquals(ConnectionReason.SERVICE_UNAVAILABLE, c(false, false, false, true, ServiceState.UNAVAILABLE))
        assertEquals(ConnectionReason.MAC_UNREACHABLE, c(false, false, false, true, ServiceState.AVAILABLE))
    }

    @Test
    fun `only a RichOS Connect origin is a managed route`() {
        assertTrue(Connections.managed("https://c-5de0dbe0862dd461ae305af5cef35202-g2.richos.ceo"))
        assertFalse(Connections.managed("https://mm1.tail1a2b3c.ts.net:8443"))
        assertFalse(Connections.managed("https://c-5de0dbe0862dd461ae305af5cef35202-g0.richos.ceo"))
        assertFalse(Connections.managed(null))
    }

    @Test
    fun `a healthy relay while away says reconnecting, not that the Mac is broken`() = runTest {
        val runtime = DevRuntime.create().also { it.execute(DevRequest.Fixture("offline")) }
        runtime.core.dispatch(Action.Link(LinkStatus.AWAY))
        val s = runtime.core.dispatch(Action.Health(phoneOnline = true, service = ServiceState.AVAILABLE))
        assertEquals(ConnectionReason.RECONNECTING, s.connection.reason)
        val unavailable = runtime.core.dispatch(Action.Health(phoneOnline = true, service = ServiceState.UNAVAILABLE))
        assertEquals(ConnectionReason.SERVICE_UNAVAILABLE, unavailable.connection.notice, "a service outage is said at once")
    }

    @Test
    fun `revocation is the terminal notice`() = runTest {
        val result = DevRuntime.create()
        result.execute(DevRequest.Scenario("revoked"))
        val s = result.core.state
        assertEquals(ConnectionReason.REVOKED, s.connection.reason)
        assertEquals(ConnectionReason.REVOKED, s.connection.notice)
    }

    @Test
    fun `a Mac speaking another protocol version is incompatible, one without the field is not`() = runTest {
        fun hello(version: String) = "id: 1\nevent: hello\ndata: {\"thread_id\":\"general\",\"capabilities\":[\"text\"]$version,\"messages\":[]}\n\n"
        val core = DevRuntime.create().also { it.execute(DevRequest.Fixture("online")) }.core
        assertEquals(ConnectionReason.CONNECTED, core.dispatch(Action.Receive(hello(""))).connection.reason)
        assertEquals(ConnectionReason.INCOMPATIBLE, core.dispatch(Action.Receive(hello(",\"protocol_version\":2"))).connection.reason)
        assertEquals(ConnectionReason.INCOMPATIBLE, core.state.connection.notice)
        assertTrue(core.dispatch(Action.Receive(hello(",\"protocol_version\":1"))).connection.reason != ConnectionReason.INCOMPATIBLE)
    }
}
