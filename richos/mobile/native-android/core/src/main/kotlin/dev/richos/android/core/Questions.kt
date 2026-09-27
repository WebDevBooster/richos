package dev.richos.android.core

import kotlinx.serialization.Serializable
import kotlinx.serialization.SerialName
import kotlinx.serialization.json.*

@Serializable
data class QuestionCard(
    val id: String,
    @SerialName("thread_id") val threadId: String,
    val text: String,
    val options: List<QuestionOption>,
    val multiple: Boolean,
    @SerialName("free_answer") val freeAnswer: Boolean,
    val recommended: String? = null,
    val state: String,
    val answer: QuestionAnswer? = null,
    val revision: Long,
    val delivered: Boolean,
    @SerialName("handoff_started") val handoffStarted: Boolean = false,
    @SerialName("waiting_for_turn") val waitingForTurn: Boolean = false,
    val remaining: Int = 0,
    @SerialName("set_index") val setIndex: Int = 0,
    @SerialName("set_count") val setCount: Int = 0,
    val asker: String = "Rich",
    @SerialName("withdrawal_reason") val withdrawalReason: String? = null,
) {
    val answerText: String get() = answer?.let { a -> (options.filter { it.id in a.optionIds }.map { it.label } + a.text).filter { it.isNotEmpty() }.joinToString("; ") }.orEmpty()
}
@Serializable data class QuestionOption(val id: String, val label: String, val description: String)
@Serializable data class QuestionAnswer(@SerialName("option_ids") val optionIds: List<String>, val text: String, val method: String, val surface: String)

// Project saved bytes without claiming that the Mac has accepted the answer.
fun OutboxItem.localQuestionAnswer(): QuestionAnswer? = runCatching {
    if (questionId == null || wire == null) return null
    val fields = CoreJson.parseToJsonElement(wire).jsonObject
    val text = fields.getValue("text").jsonPrimitive.content
    QuestionAnswer(fields.getValue("option_ids").jsonArray.map { it.jsonPrimitive.content }, text, if (text.isBlank()) "phone_tap" else "phone_typed", "phone")
}.getOrNull()
