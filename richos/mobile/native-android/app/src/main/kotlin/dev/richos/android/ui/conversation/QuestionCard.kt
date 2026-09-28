package dev.richos.android.ui.conversation

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicText
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import dev.richos.android.design.Rich
import dev.richos.android.design.RichFonts
import dev.richos.android.design.floating
import dev.richos.android.ui.UiEvent
import dev.richos.android.ui.model.Body

/** Round 13, HQ c50ed191. Rich's bubble above a full-width inline keyboard. */
@Composable
fun QuestionCard(body: Body.Question, onEvent: (UiEvent) -> Unit, modifier: Modifier = Modifier) {
    val q = body.card
    val c = Rich.colors
    val t = Rich.type
    val goldText = if (c.isDark) c.signal else Color(0xFF715715)
    val boundary = if (c.isDark) c.ink.copy(alpha = 0.46f) else c.line
    var selected by remember(q.id, q.revision) { mutableStateOf(emptySet<String>()) }
    var editing by remember(q.id, q.revision) { mutableStateOf(false) }
    var other by remember(q.id) { mutableStateOf(false) }
    var text by remember(q.id) { mutableStateOf("") }
    val canEdit = !q.delivered && !q.handoffStarted && (body.pending == null || body.canEditLocal)
    val active = body.pending == null && q.state == "open" || editing && canEdit
    fun submit(ids: List<String>, words: String) {
        onEvent(UiEvent.AnswerQuestion(q.id, ids, words, if (editing) q.revision else null))
        editing = false
    }
    Column(modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(6.dp)) {
        if (q.asker != "Rich") BasicText(q.asker + " · through Rich", style = t.read.copy(color = c.inkSoft), modifier = Modifier.padding(start = 6.dp))
        Box(Modifier.fillMaxWidth().floating(RoundedCornerShape(20.dp)).background(c.surface, RoundedCornerShape(20.dp))) {
            Column(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 10.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                if (q.setCount > 1) BasicText("Question ${q.setIndex} of ${q.setCount}", style = t.read.copy(color = c.inkSoft))
                BasicText(q.text, style = t.answer.copy(fontFamily = RichFonts.Newsreader, fontSize = if (active) 22.sp else 18.sp, lineHeight = if (active) 28.sp else 25.sp, color = if (q.state == "withdrawn") c.inkSoft else c.ink))
                if (!active) {
                    if (q.state == "answered" || body.savedAnswer != null) {
                        Row(Modifier.padding(top = 8.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                            BasicText("✓", style = t.bodyStrong.copy(color = goldText))
                            BasicText("You answered: " + (body.savedAnswer ?: q.answerText), style = t.body.copy(color = c.ink))
                        }
                        q.answer?.let { answer ->
                            val methods = mapOf("click" to "click", "keyboard" to "keyboard", "typed" to "typing", "spoken" to "voice", "phone_tap" to "tap", "phone_typed" to "typing", "phone_voice" to "voice note")
                            BasicText("By ${methods[answer.method] ?: "your words"}, on ${if (answer.surface == "mac") "your Mac" else "your phone"}", style = t.read.copy(color = c.inkSoft))
                        }
                        BasicText(body.pending ?: if (q.delivered) "Rich has your answer" else if (q.endedBeforeTaken) "This job stopped before Rich got your answer." else if (q.remaining > 0) "Waiting for the remaining answers" else if (q.waitingForTurn) "It reaches Rich when his current reply ends" else "On its way to Rich", style = t.read.copy(color = if (q.delivered) goldText else c.inkSoft), modifier = Modifier.padding(top = 6.dp))
                        if (canEdit) Box(Modifier.heightIn(min = 48.dp).clickable(role = Role.Button) { editing = true; selected = q.answer?.optionIds.orEmpty().toSet(); text = q.answer?.text.orEmpty() }, contentAlignment = Alignment.CenterStart) {
                            BasicText("Change answer", style = t.readStrong.copy(color = c.ink, textDecoration = TextDecoration.Underline))
                        }
                    } else if (q.state == "withdrawn") BasicText("Rich no longer needs this: " + (q.withdrawalReason ?: "The work has ended"), style = t.read.copy(color = c.inkSoft), modifier = Modifier.padding(top = 8.dp))
                }
            }
            Box(Modifier.matchParentSize().padding(vertical = 12.dp)) { Box(Modifier.width(3.dp).fillMaxHeight().background(if (q.state == "withdrawn") c.line else c.signal, RoundedCornerShape(2.dp))) }
        }
        if (active) {
            q.options.forEach { option ->
                val checked = option.id in selected
                val shape = RoundedCornerShape(18.dp)
                Row(Modifier.fillMaxWidth().floating(shape).background(if (checked) c.signalWash else c.surface, shape).border(1.dp, if (checked) c.signal else boundary, shape).semantics { this.selected = checked }.clickable(role = if (q.multiple) Role.Checkbox else Role.Button) {
                    if (q.multiple) selected = if (checked) selected - option.id else selected + option.id else submit(listOf(option.id), "")
                }.padding(horizontal = 14.dp, vertical = 11.dp), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                    if (q.multiple) Box(Modifier.size(24.dp).background(if (checked) c.signal else Color.Transparent, RoundedCornerShape(7.dp)).border(1.5.dp, if (checked) c.signal else boundary, RoundedCornerShape(7.dp)), contentAlignment = Alignment.Center) {
                        if (checked) BasicText("✓", style = t.readStrong.copy(color = c.onSignal))
                    }
                    Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                        BasicText(option.label, style = t.bodyStrong.copy(color = c.ink))
                        BasicText(option.description, style = t.read.copy(color = c.inkSoft))
                        if (q.recommended == option.id) Row(Modifier.padding(top = 4.dp), horizontalArrangement = Arrangement.spacedBy(7.dp), verticalAlignment = Alignment.CenterVertically) {
                            Box(Modifier.size(7.dp).background(c.signal, CircleShape))
                            BasicText(if (q.asker == "Your team") "Your team recommends" else "Rich recommends", style = t.read.copy(color = goldText, fontWeight = FontWeight.Medium))
                        }
                    }
                }
            }
            Row(horizontalArrangement = Arrangement.spacedBy(12.dp), verticalAlignment = Alignment.CenterVertically) {
                if (q.freeAnswer) BasicText("Other answer", style = t.read.copy(color = c.ink, textDecoration = TextDecoration.Underline), modifier = Modifier.clickable(role = Role.Button) { other = true }.padding(12.dp))
                if (q.multiple) BasicText("Send answer", style = t.readStrong.copy(color = c.onSignal), modifier = Modifier.background(c.signal.copy(alpha = if (selected.isEmpty()) 0.42f else 1f), CircleShape).clickable(enabled = selected.isNotEmpty(), role = Role.Button) { submit(selected.sorted(), "") }.padding(horizontal = 18.dp, vertical = 12.dp))
            }
            if (other) Row(Modifier.fillMaxWidth().background(c.surface, RoundedCornerShape(22.dp)).border(1.dp, boundary, RoundedCornerShape(22.dp)).padding(8.dp), verticalAlignment = Alignment.Bottom, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                BasicTextField(text, { text = it }, textStyle = t.body.copy(color = c.ink), modifier = Modifier.weight(1f).semantics { contentDescription = "Your answer" }.padding(8.dp), decorationBox = { field ->
                    Box { if (text.isEmpty()) BasicText("Your answer", style = t.body.copy(color = c.inkSoft)); field() }
                })
                BasicText("Send", style = t.readStrong.copy(color = c.onSignal), modifier = Modifier.background(c.signal, CircleShape).clickable(enabled = text.isNotBlank(), role = Role.Button) { submit(if (q.multiple) selected.sorted() else emptyList(), text) }.padding(12.dp))
            }
        }
    }
}
