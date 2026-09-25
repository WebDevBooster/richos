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

    /**
     * D05 (native acceptance r1): on the Tailscale route, with the phone's own Tailscale off (the OS
     * reports no VPN on the default network), "Reconnecting…" is not true, because the app cannot
     * reconnect by itself. Once the trouble has lasted the usual 3 s, the one line names the fix,
     * and then nothing more: no new timer, no repeat, the draft and the queue kept.
     */
    @Test
    fun `D05 - Tailscale off on the Tailscale route names the fix once the trouble persists, and nothing nags`() = runTest {
        val runtime = DevRuntime.create().also { it.execute(DevRequest.Fixture("queued")) }
        assertEquals(Route.TAILNET, runtime.core.state.pairing.route)
        val queued = runtime.core.state.outbox
        assertTrue(queued.isNotEmpty())
        runtime.core.dispatch(Action.Compose("Still here"))
        runtime.core.dispatch(Action.Health(vpn = false))
        var s = runtime.core.dispatch(Action.Link(LinkStatus.AWAY))
        assertEquals(ConnectionReason.TAILSCALE_OFF, s.connection.reason)
        assertEquals(null, s.connection.notice, "quiet at first, like any trouble")
        assertEquals(ConnectionState.NOTICE_AFTER_MS, s.connection.noticeDueInMs)
        s = runtime.execute(DevRequest.Advance(ConnectionState.NOTICE_AFTER_MS)).let { runtime.core.state }
        assertEquals(ConnectionReason.TAILSCALE_OFF, s.connection.notice, "the persistent trouble names the fix")
        assertEquals(null, s.connection.noticeDueInMs, "shown once: no timer after it")
        // More failed attempts change nothing: the same line, no new timer, nothing lost.
        repeat(5) {
            runtime.core.dispatch(Action.Link(LinkStatus.OPENING))
            s = runtime.core.dispatch(Action.Link(LinkStatus.AWAY))
            assertEquals(ConnectionReason.TAILSCALE_OFF, s.connection.notice)
            assertEquals(null, s.connection.noticeDueInMs)
        }
        assertEquals("Still here", s.draft)
        assertEquals(queued.map { it.clientId }, s.outbox.map { it.clientId })
        // The phone's own offline state still comes first.
        assertEquals(ConnectionReason.PHONE_OFFLINE, runtime.core.dispatch(Action.Health(phoneOnline = false)).connection.notice)
        runtime.core.dispatch(Action.Health(phoneOnline = true))
        // Tailscale back on: the fix is done, so the line says what is true now, then goes on open.
        s = runtime.core.dispatch(Action.Health(vpn = true))
        assertEquals(ConnectionReason.RECONNECTING, s.connection.notice)
        s = runtime.core.dispatch(Action.Link(LinkStatus.OPEN))
        assertEquals(null, s.connection.notice)
        assertEquals(ConnectionReason.CONNECTED, s.connection.reason)
    }

    @Test
    fun `D05 - the line is only for the Tailscale route, only on the OS's word, and only while away`() = runTest {
        // Unknown: no report from the OS yet. Never guessed.
        val unknown = DevRuntime.create().also { it.execute(DevRequest.Fixture("offline")) }
        assertEquals(ConnectionReason.RECONNECTING, unknown.core.dispatch(Action.Link(LinkStatus.AWAY)).connection.reason)
        // A VPN is up (Tailscale on): reconnecting is the truth.
        unknown.core.dispatch(Action.Health(vpn = true))
        assertEquals(ConnectionReason.RECONNECTING, unknown.core.state.connection.reason)
        // Connected: nothing to say, whatever the VPN.
        unknown.core.dispatch(Action.Health(vpn = false))
        assertEquals(ConnectionReason.CONNECTED, unknown.core.dispatch(Action.Link(LinkStatus.OPEN)).connection.reason)
        // Not paired over the Tailscale route (RichOS Connect needs no VPN): never about Tailscale.
        assertEquals(ConnectionReason.RECONNECTING, Connections.cause(ConnectionReason.RECONNECTING, Route.CONNECT, paired = true, vpn = false))
        assertEquals(ConnectionReason.RECONNECTING, Connections.cause(ConnectionReason.RECONNECTING, null, paired = true, vpn = false))
        assertEquals(ConnectionReason.RECONNECTING, Connections.cause(ConnectionReason.RECONNECTING, Route.TAILNET, paired = false, vpn = false))
        assertEquals(ConnectionReason.TAILSCALE_OFF, Connections.cause(ConnectionReason.CONNECTING, Route.TAILNET, paired = true, vpn = false))
        assertEquals(ConnectionReason.SERVICE_UNAVAILABLE, Connections.cause(ConnectionReason.SERVICE_UNAVAILABLE, Route.TAILNET, paired = true, vpn = false))
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
