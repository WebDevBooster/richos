package dev.richos.android.core

import dev.richos.android.core.protocol.Row
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** The provisional row a tapped notification opens on (Sage row 6): its shape, and when the Mac's own row retires it. */
class ProvisionalReplyTest {
    private val held = listOf(Row(id = "m1", threadId = "t", cursor = 4, role = "phone", text = "hi"))
    private fun ref(id: String) = ProvisionalReply.reference(id)

    @Test
    fun `the row follows the newest held row, is Rich's, and shows a cut-off preview as partial`() {
        val whole = ProvisionalReply.row("t", ref("r1"), "Done.", held)
        assertEquals(5L, whole.cursor)
        assertEquals("rich", whole.role)
        assertEquals("Done.", whole.text)
        assertTrue(ProvisionalReply.isProvisional(whole))
        assertTrue(ProvisionalReply.row("t", ref("r1"), "x".repeat(ProvisionalReply.PREVIEW_CAP), held).text.endsWith("…"))
        assertEquals(1L, ProvisionalReply.row("t", ref("r1"), "Done.", emptyList()).cursor)
    }

    @Test
    fun `only the Mac's row for that reply retires it`() {
        val provisional = ProvisionalReply.row("t", ref("r1"), "Done.", held)
        val rows = held + provisional
        assertEquals(held, ProvisionalReply.retire(rows, listOf(Row(id = "r1", threadId = "t", cursor = 5, role = "rich", text = "Done. All of it."))))
        assertEquals(rows, ProvisionalReply.retire(rows, listOf(Row(id = "r2", threadId = "t", cursor = 6, role = "rich", text = "Another"))))
    }
}
