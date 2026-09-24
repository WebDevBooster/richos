package dev.richos.android.platform

import dev.richos.android.core.Microphone
import org.junit.Assert.assertEquals
import org.junit.Test

/** What the app tells core about the microphone at launch and each time an activity starts (D03). */
class MicrophoneMirrorTest {
    @Test
    fun `a grant, from the dialog or Settings, always reaches core`() {
        assertEquals(Microphone.GRANTED to false, mirrored(granted = true, canAsk = false, core = Microphone.DENIED, coreCanAsk = true))
        assertEquals(Microphone.GRANTED to false, mirrored(granted = true, canAsk = false, core = Microphone.UNKNOWN, coreCanAsk = false))
        assertEquals(null, mirrored(granted = true, canAsk = false, core = Microphone.GRANTED, coreCanAsk = false))
    }

    @Test
    fun `Don't allow is kept while not granted, and whether Android would still ask follows the OS`() {
        assertEquals(null, mirrored(granted = false, canAsk = false, core = Microphone.DENIED, coreCanAsk = false))
        assertEquals(Microphone.DENIED to true, mirrored(granted = false, canAsk = true, core = Microphone.DENIED, coreCanAsk = false))
        assertEquals(Microphone.DENIED to false, mirrored(granted = false, canAsk = false, core = Microphone.DENIED, coreCanAsk = true))
    }

    @Test
    fun `never asked stays never asked, and a grant that went away asks again at the next press`() {
        assertEquals(null, mirrored(granted = false, canAsk = false, core = Microphone.UNKNOWN, coreCanAsk = false))
        assertEquals(Microphone.UNKNOWN to false, mirrored(granted = false, canAsk = false, core = Microphone.GRANTED, coreCanAsk = false))
    }
}
