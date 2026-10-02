package dev.richos.android.ui

import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp

/**
 * How tall the notes (cards) region above the composer may be. iPhone parity (isaac-opus-r3floor1
 * `4dd3544c3`): the conversation keeps [ConversationMinimum] between the header and the cards for
 * ANY number of cards, one included, so a card and the keyboard never hide the sender's own last
 * message. The cards scroll inside what is left, down to a [Floor]; with the keyboard down the room
 * is large and a single card still shows whole.
 */
object CardsRoom {
    val ConversationMinimum: Dp = 175.dp
    val Floor: Dp = 80.dp
    private val Gap: Dp = 16.dp

    /** The old flat bound: never more than 40% of the screen. */
    private const val ShareOfScreen = 0.4f

    fun maxHeight(screen: Dp, header: Dp, composerRow: Dp, keyboard: Dp): Dp {
        val left = screen - header - composerRow - keyboard - Gap
        val room = minOf(left - ConversationMinimum, screen * ShareOfScreen)
        return maxOf(Floor, room)
    }
}
