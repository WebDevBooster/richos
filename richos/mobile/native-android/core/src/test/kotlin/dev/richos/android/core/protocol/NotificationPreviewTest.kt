package dev.richos.android.core.protocol

import dev.richos.android.core.CoreError
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith

/** The preserved app's own vector (`richos/mobile/test/fixtures/notification-preview.json`). */
class NotificationPreviewTest {
    private val key = Signing.fromBase64url("BwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwc")
    private val thread = "b".repeat(64)
    private val event = "c".repeat(64)
    private val preview = """{"v":1,"nonce":"CQkJCQkJCQkJCQkJ","body":"c-3htM2FsRHMC65KxovAvLHAF5ZQzjVjW5xqluVEL1qKipKxwjNaYA3c03coFIqnXDr78XbxymBH6z5pqbYRSOqSk9ipbsuc"}"""

    @Test
    fun `the fixture's envelope opens to the fixture's words`() {
        assertEquals("The supplier accepted £42,000. Your approval is needed.", NotificationPreview.decrypt(key, thread, event, preview))
    }

    @Test
    fun `the envelope is bound to its conversation and event`() {
        assertFailsWith<CoreError> { NotificationPreview.decrypt(key, "d".repeat(64), event, preview) }
        assertFailsWith<CoreError> { NotificationPreview.decrypt(key, thread, "d".repeat(64), preview) }
        assertFailsWith<CoreError> { NotificationPreview.decrypt(ByteArray(32), thread, event, preview) }
    }

    @Test
    fun `anything that does not open shows the generic line, never nothing`() {
        assertEquals("Rich has replied.", NotificationPreview.textOrGeneric(null, thread, event, preview))
        assertEquals("Rich has replied.", NotificationPreview.textOrGeneric(key, thread, event, """{"v":2}"""))
        assertEquals("Rich has replied.", NotificationPreview.textOrGeneric(key, "not-hex", event, preview))
        assertEquals("The supplier accepted £42,000. Your approval is needed.", NotificationPreview.textOrGeneric(key, thread, event, preview))
    }
}
