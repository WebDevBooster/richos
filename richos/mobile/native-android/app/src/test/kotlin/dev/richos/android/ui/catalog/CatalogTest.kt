package dev.richos.android.ui.catalog

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** The catalog is round 12's, id for id and in the same order: nothing missing, nothing invented. */
class CatalogTest {
    /** `grep -o 'id: "[a-z-]*"' design/mockups/rounds/round-12/shared/screens.js` (richos-hq 94541087). */
    private val round12 = """
        pair-intro pair-scanner pair-scanner-found pair-camera-denied pair-progress pair-words pair-refused
        pair-blocked pair-stale pair-consent pair-pwa-storage conv-empty conv-populated conv-pending
        conv-replying conv-streaming conv-playing-reply conv-preparing-reply conv-older-loading
        conv-beginning conv-scrolled conv-focused conv-retry comp-idle comp-typing comp-keyboard
        comp-disabled comp-too-long voice-press voice-permission voice-holding voice-slide-left voice-bin
        voice-sent voice-too-short voice-slide-up voice-lock-transition voice-locked voice-locked-scrolled
        voice-locked-cancel voice-locked-send voice-ceiling-warning voice-ceiling-reached voice-interrupted
        rec-card rec-unsupported rec-mic-denied conn-reconnecting conn-offline conn-service conn-mac
        conn-revoked conn-incompatible conn-cached notif-offer notif-pwa-install notif-settings
        notif-lock-preview notif-lock-generic settings settings-forget settings-forget-blocked upd-banner
        upd-dialog upd-blocking upd-feature-off launch-cached
    """.trim().split(Regex("\\s+"))

    /** `grep -o 'id: "[a-z-]*"' design/mockups/rounds/round-12/attach/screens.js` (richos-hq a2136389). */
    private val attachments = """
        att-entry att-menu att-voice-intact att-pick-photos att-pick-camera att-camera-review att-pick-files
        att-pending-one att-pending-many att-pending-file att-pending-caption att-pending-remove
        att-send-flight att-uploading att-sent att-failed att-conv-photo att-conv-album att-conv-file
        att-conv-jump att-viewer att-viewer-file share-host share-sheet share-compose share-compose-many
        share-compose-file share-sent share-saved share-landed att-too-large att-unsupported att-limit
        att-queued att-denied-camera att-denied-photos att-mac-unsupported share-unpaired share-too-large
    """.trim().split(Regex("\\s+"))

    @Test
    fun `every round-12 screen is in the catalog, in order`() {
        assertEquals(67, round12.size)
        assertEquals(round12, ScreenCatalog.round12.map { it.id })
    }

    /** The way in to pairing's states round 12 does not draw (`ScreenCatalog.pairingEntry`), each named. */
    private val pairingEntry = ("pair-link pair-link-refused pair-scanner-opening pair-scanner-unavailable pair-removed-blocked " +
        "pair-waiting-mac pair-mac-update pair-mac-declined pair-expired pair-words-rejected pair-fault").split(' ')

    @Test
    fun `every attachment screen follows, by its stable id, then the pairing entry's, and no id repeats`() {
        assertEquals(39, attachments.size)
        assertEquals(round12 + attachments + pairingEntry + "conn-tailscale-off", ScreenCatalog.all.map { it.id })
        assertEquals(ScreenCatalog.all.size, ScreenCatalog.all.map { it.id }.toSet().size)
    }

    @Test
    fun `every screen builds on a small and a large phone`() {
        for (spec in ScreenCatalog.all) for (w in listOf(360f, 412f)) spec.build(w)
    }

    @Test
    fun `a screen that does not apply to Android says why`() {
        val na = ScreenCatalog.all.filter { it.applies is Applies.NotApplicable }
        assertEquals(listOf("pair-pwa-storage", "notif-pwa-install"), na.map { it.id })
        na.forEach { assertTrue((it.applies as Applies.NotApplicable).reason.isNotBlank()) }
    }

    @Test
    fun `the conversation is core's rows and pending bubbles are core's outbox`() {
        val m = ScreenCatalog.byId("conv-pending").build(360f)
        assertEquals(ScreenCatalog.convo.map { it.id }, m.thread.filter { it.outboxClientId == null }.map { it.id })
        assertEquals(listOf("mobile-1", "mobile-2", "mobile-3"), m.thread.mapNotNull { it.outboxClientId })
    }

    @Test
    fun `a reply still arriving shows the dots, then the words with a caret`() {
        val replying = ScreenCatalog.byId("conv-replying").build(360f).thread.last()
        assertTrue(replying.replying)
        val streaming = ScreenCatalog.byId("conv-streaming").build(360f).thread.last()
        assertTrue(streaming.streaming)
    }

    @Test
    fun `times read as round 12 writes them`() {
        val m = ScreenCatalog.byId("conv-populated").build(360f)
        assertEquals("Yesterday 6:10 PM", m.thread.first().time)
        assertEquals("8:02 AM", m.thread.first { it.id == "c1" }.time)
    }
}
