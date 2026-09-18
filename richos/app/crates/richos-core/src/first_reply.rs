//! **What the model did on his turn before he heard a word, and whether it was allowed to.**
//! The CEO's ruling §55, 2026-09-18: *"Rich **immediately** replies with: "On it!" and only
//! after that does all that work."* … *"Yes, a few seconds is fine. But 35 seconds of waiting
//! for the first response is not."*
//!
//! # Why this is a function and not three assertions inside one example
//!
//! The doctrine has said *"The register is your FIRST tool call, not your last"* since the
//! front desk existed, and on 2026-09-18 it was measured not being obeyed — four tool-call
//! frames and two `ToolSearch` round trips ahead of it
//! (`docs/verification/question-receipt-2026-09-18.md`, run 2). **A sentence that is not obeyed
//! is not a fix.** So the ordering is checked by something that can be run, that costs no model
//! turn to test, and that is proven able to go red against the real defect's own frame
//! sequence — which is what [`tests::the_measured_defect_of_2026_09_18_is_red`] is.
//!
//! # What is a fault and what is deliberately NOT one
//!
//! | On his turn, before his first word | Verdict | Why |
//! |---|---|---|
//! | `ToolSearch`, or a `select:…` frame | **fault** | tool DISCOVERY, 7.5 s of one measured turn, and it is removed by `native::TOOL_SEARCH_ENV` rather than asked for |
//! | the continuity checkpoint | **fault** | bookkeeping; `front-desk.md` puts it after the reply and `native::bookkeeping_before_the_reply` refuses it before |
//! | the register, but not first | **fault** | a hand-over that happens after something else is the §55 defect exactly |
//! | the register, first | fine | this is the shape §55 asks for |
//! | `richos_status.background_work` on a turn with no register | **fine** | the doctrine's case 2: *"a question about how work is going is answered from the read, at once"* — the one case where it looks before it speaks |
//! | anything at all, after his first word | fine | §55 measures his first word; what happens afterwards is off his wait |
//!
//! **The status read is the line worth being careful about.** Run 2's first question was
//! *"did that pricing review ever actually land?"*, the front desk read the status and answered
//! him directly, and that is the doctrine working. A rule that failed it would be grading a
//! judgment the CEO explicitly left to the model. So the read is a fault only when the turn ALSO
//! handed work over — then it happened ahead of the register and it cost him the wait.

use std::time::Duration;

/// The budget for **send → his first words** on a warm lease, and where the number comes from.
///
/// **RE-DERIVED 2026-09-18 from the run this slice measured, 12 s → 9 s**
/// (`docs/verification/first-words-2026-09-18.md`). The app now says the register's sentence
/// itself, at the register's return, so a warm turn is ONE model round trip and the streaming of
/// the register's arguments — not two round trips:
///
/// | | measured | what it was |
/// |---|---|---|
/// | **run A, question, warm** | **6.358 s** | register call at 3.968 s, arguments complete at 4.321 s, the register's answer AND his first words at 6.358 s |
/// | run B, question, warm | 12.176 s | **excluded, and the reason is named:** the model wrote a pre-reply continuity checkpoint (5.429 s → 7.813 s), which nothing on the real wire refuses (`native::bookkeeping_before_the_reply`'s own doc, and `esc-20260918T141320Z-49570979`). The probe fails that turn by name on the checkpoint, so the budget does not need to absorb it |
/// | the three warm turns before this slice | 7.128 / 8.505 / 8.920 s | the model repeating the sentence back, a round trip after the register answered |
///
/// 9 s is the one clean warm measurement plus ~42%, which is wider headroom than the 35% the
/// previous figure used — deliberately, because it rests on ONE clean turn rather than three.
///
/// **THE OLD SHAPE IS PROVEN RED BY [`first_words_not_from_the_app`], NOT BY THIS NUMBER, AND
/// THAT IS THE HONEST STATEMENT.** What this slice removed from a warm turn is the model's final
/// round trip: 1.094 s measured. A timing budget tight enough to fail 7.128 s would be a budget
/// that flaps on provider variance — 6.358 s and 7.998 s were measured 90 seconds apart on the
/// same code. So the structural change is enforced structurally, by the gap between the
/// register's answer and his first words, and this constant does what a budget is for: it
/// notices when a turn gets much slower than the thing that was measured.
///
/// **It is a budget, not the goal.** §55's goal is *"a few seconds"* and its defect line is
/// 35 s. A warm turn at 8.9 s passes this and is still not what he asked for, which is why the
/// probe prints the figure rather than only the verdict, and why the remaining seconds are
/// named in the record rather than declared finished.
pub const FIRST_WORDS_BUDGET: Duration = Duration::from_secs(9);

/// The budget for the **first VISIBLE turn of a lease**, which is no longer the cold one.
///
/// **RE-DERIVED 2026-09-18, 20 s → 11 s, and its meaning changed with the number.** The priming
/// turn is now spent before he types (`Spine::prime_front_desk`), so a lease's first visible turn
/// no longer contains it. Measured on the same run as the warm figure above:
///
/// | | measured | what it was |
/// |---|---|---|
/// | **run A, task, the lease's first visible turn** | **7.998 s** | on a desk primed 2.768 s earlier, before he typed |
/// | run B, task, the lease's first visible turn | 15.714 s | **excluded**: the pre-reply checkpoint again, refused by nothing (see [`FIRST_WORDS_BUDGET`]) |
/// | the three first turns before this slice | 13.464 / 13.628 / 15.513 s | the priming turn inside his first message, plus the model's final round trip |
///
/// 11 s is 7.998 s plus ~38%. It stays a SEPARATE constant because the first visible turn really
/// is slower than a warm one on a primed desk — 7.998 s against 6.358 s, measured 90 seconds
/// apart — and one budget covering both would be 11 s everywhere, which a warm regression would
/// pass.
///
/// **AND THIS IS WHERE THE OLD SHAPE GOES RED ON THE TIMING.** Every unprimed first turn ever
/// measured — 13.464 s, 13.628 s, 15.513 s, and run B's own 15.714 s — is over this budget, so
/// `examples/first_reply_timing_e2e.rs` run with `RICHOS_PROBE_UNPRIMED=1` fails by design: that
/// mode reproduces the shape where his first message pays for the priming turn, and it is a
/// measured failure rather than an argument.
pub const FIRST_TURN_BUDGET: Duration = Duration::from_secs(11);

/// The register, as the wire titles it.
fn register() -> &'static str {
    crate::assignment_tools::QUALIFIED_RECORD_TOOL
}

/// Is this frame the model looking for its own tools? Both shapes count: the `ToolSearch` call
/// and the `select:mcp__…` frame the binary reports its choice on.
fn is_discovery(name: &str) -> bool {
    name == crate::native::TOOL_SEARCH_TOOL || name.starts_with("select:")
}

/// Everything wrong with the opening of one turn, in the order it happened.
///
/// `before_his_first_words` is the tool-call frames that arrived BEFORE the first
/// `MessageStarted`/`MessageDelta`, each with its offset in seconds from the send — exactly what
/// `examples/first_reply_timing_e2e.rs` collects off the machinery stream. `to_first_words` is
/// `None` when no live text event was seen at all, which is its own fault: nothing was measured.
///
/// Returns an empty vector when the turn opened the way §55 asks for. Every string names the
/// number that decided it, because a fault without its measurement is the thing this project
/// keeps getting burned by.
pub fn first_reply_faults(
    before_his_first_words: &[(String, f64)],
    to_first_words: Option<f64>,
    budget: Duration,
) -> Vec<String> {
    let mut faults = Vec::new();

    for (name, at) in before_his_first_words {
        if is_discovery(name) {
            faults.push(format!(
                "he waited on tool DISCOVERY at {at:.3} s ({name}) — the front desk's tools must be \
                 resident from its first turn (native::TOOL_SEARCH_ENV)"
            ));
        }
        if name == crate::native::CONTINUITY_CHECKPOINT_TOOL {
            faults.push(format!(
                "the continuity checkpoint was written at {at:.3} s, before he had heard anything — \
                 it is bookkeeping and front-desk.md puts it after the reply"
            ));
        }
    }

    // **The register, if it happened at all, happened FIRST.** A turn with no register is a
    // turn he was answered on, and the doctrine's read is allowed to precede that answer.
    if let Some(position) = before_his_first_words.iter().position(|(name, _)| name == register()) {
        if position != 0 {
            let earlier: Vec<&str> = before_his_first_words[..position].iter().map(|(name, _)| name.as_str()).collect();
            faults.push(format!(
                "the register was tool call {} of {} and not the first: {earlier:?} came before it",
                position + 1,
                before_his_first_words.len()
            ));
        }
    }

    match to_first_words {
        None => faults.push("no live text event was observed, so his first words were never measured".into()),
        Some(seconds) if seconds > budget.as_secs_f64() => faults.push(format!(
            "send -> his first words was {seconds:.3} s, over the {:.0} s budget (§55: a few seconds; 35 s is a defect)",
            budget.as_secs_f64()
        )),
        Some(_) => {}
    }

    faults
}

/// **The words the register handed back, read off the register's own answer — so the APP says
/// them and he does not wait for the model to say them back.**
///
/// The CEO's §55 measure is his FIRST WORDS, and until 2026-09-18 those words cost two model
/// round trips: one for the model to call the register, and a second for the model to repeat the
/// sentence the register had just handed it. The second one is measured at **1.094 s** (the warm
/// question turn) and **1.427 s** (the cold task turn) of
/// `docs/verification/first-reply-2026-09-18.md`'s run 3, and none of it carries information the
/// app does not already have: the sentence is the app's own
/// ([`crate::assignment::Receipt::sentence`]), handed out by the app's own MCP server.
///
/// So the host reads the register's `tool_result` as it goes past and speaks the sentence itself
/// ([`crate::native`]'s reader). This is that read, as a pure function of one content block.
///
/// # What it refuses, and why every refusal is the safe direction
///
/// | The block says | This returns | Why |
/// |---|---|---|
/// | `{"recorded":true,"say":"On it!"}` | `Some("On it!")` | the work is written down AND the words are its receipt |
/// | `is_error: true` | `None` | the register refused; the app must not announce a hand-over that did not happen |
/// | a refusal sentence, not JSON | `None` | the same fact in the shape `assignment_tools` returns it on an error |
/// | `{"recorded":false,…}` | `None` | there is no record, so there is no receipt to read out |
/// | `say` missing, empty, or not a string | `None` | a receipt with no words is not a receipt |
///
/// **Every `None` degrades to exactly the behavior that shipped this morning**: the app says
/// nothing, the model says the words it was handed a round trip later, and he is answered. That
/// is the whole reason this is a read of the register's ANSWER rather than a sentence the host
/// composes from the tool NAME — a host that spoke on the strength of the call having been *made*
/// would tell him "On it!" for a registration that was refused.
pub fn receipt_sentence(block: &serde_json::Value) -> Option<String> {
    if block.get("is_error").and_then(serde_json::Value::as_bool) == Some(true) {
        return None;
    }
    // The wire carries a tool result's content EITHER as a plain string OR as an array of
    // `{type:"text",text}` blocks; both were observed on this wire (`machinery::block_text`
    // records the same thing, and a reader that handled one of them would work on half the runs).
    let text = match block.get("content") {
        Some(serde_json::Value::String(s)) => s.clone(),
        Some(serde_json::Value::Array(blocks)) => blocks
            .iter()
            .filter_map(|b| b.get("text").and_then(|t| t.as_str()))
            .collect::<Vec<_>>()
            .join(""),
        _ => return None,
    };
    let payload: serde_json::Value = serde_json::from_str(text.trim()).ok()?;
    if payload.get(crate::assignment_tools::RECEIPT_RECORDED_FIELD).and_then(serde_json::Value::as_bool)
        != Some(true)
    {
        return None;
    }
    let say = payload.get(crate::assignment_tools::RECEIPT_SAY_FIELD)?.as_str()?.trim();
    if say.is_empty() {
        return None;
    }
    Some(say.to_string())
}

/// **How long after the register's ANSWER his first words may arrive, before they are the model's
/// words rather than the app's.**
///
/// Both numbers this is between are measured, and they are two orders of magnitude apart:
///
/// | | measured | what it is |
/// |---|---|---|
/// | the app saying the sentence | **0.000 s** (7.998/7.998 and 6.358/6.358, 2026-09-18 run A) | the text is routed off the same frame, before the frame's own machinery record |
/// | the model saying it back | **1.094 s** warm, **1.427 s** cold (run 3, 2026-09-18) | a whole model round trip repeating four of the app's own words |
///
/// 0.25 s sits an order of magnitude above the first and four times below the second, so neither
/// a slow observer nor a busy machine can make the fast path look like the slow one, and the round
/// trip cannot hide inside the tolerance.
pub const RECEIPT_TO_FIRST_WORDS: Duration = Duration::from_millis(250);

/// **Did his first words come from the APP, at the register's return — or from the model, a round
/// trip later?**
///
/// Both arguments are offsets from the send, in seconds, as
/// `examples/first_reply_timing_e2e.rs` reads them off the same two observers the webview reads:
/// `register_answered_at` is when the register's `tool_result` frame arrived, and `first_words_at`
/// is the first `LiveEvent::MessageStarted`/`MessageDelta`.
///
/// **This is the one fact the timing budgets cannot see.** A warm turn at 7.128 s passes a 12 s
/// budget whether the app said the words or the model repeated them, so the budget cannot tell the
/// change happened and cannot tell it if it silently stops happening. The gap between those two
/// events can: it is ~0 when the app speaks and a whole round trip when the model does.
///
/// `None` for a turn that never handed work over — there is no receipt to be simultaneous with,
/// and a turn where he was simply answered is the best case rather than a fault.
pub fn first_words_not_from_the_app(
    register_answered_at: Option<f64>,
    first_words_at: Option<f64>,
) -> Option<String> {
    let answered = register_answered_at?;
    let Some(words) = first_words_at else {
        return Some("the register answered and he was never told anything at all".to_string());
    };
    let gap = words - answered;
    if gap > RECEIPT_TO_FIRST_WORDS.as_secs_f64() {
        return Some(format!(
            "his first words arrived {gap:.3} s AFTER the register's answer ({answered:.3} s -> \
             {words:.3} s), which is a model round trip: the app's own sentence did not reach him \
             (first_reply::receipt_sentence / native.rs's reader)"
        ));
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    fn calls(pairs: &[(&str, f64)]) -> Vec<(String, f64)> {
        pairs.iter().map(|(name, at)| ((*name).to_string(), *at)).collect()
    }

    #[test]
    fn the_shape_55_asks_for_has_no_faults() {
        let opening = calls(&[(crate::assignment_tools::QUALIFIED_RECORD_TOOL, 4.212)]);
        assert!(first_reply_faults(&opening, Some(6.716), FIRST_WORDS_BUDGET).is_empty());
        // And a turn where he was simply answered, with no tool call at all, is the best case.
        assert!(first_reply_faults(&[], Some(2.4), FIRST_WORDS_BUDGET).is_empty());
    }

    #[test]
    fn the_measured_defect_of_2026_09_18_is_red() {
        // **THE POSITIVE CONTROL, AND IT IS NOT SYNTHETIC.** These are the twelve frames of the
        // nightly-build question, verbatim from `question-receipt-2026-09-18-logs/
        // run-2-instrumented.log`, whose reply reached him at 22.956 s. If this rule cannot
        // fail on the defect it was written for, it cannot be trusted when it passes.
        let opening = calls(&[
            ("ToolSearch", 3.934),
            ("select:mcp__richos_assignments__record", 3.940),
            ("ToolSearch", 7.593),
            ("select:mcp__richos_continuity__checkpoint,mcp__richos_continuity__inspect", 7.653),
            ("mcp__richos_continuity__checkpoint", 12.980),
            ("mcp__richos_assignments__record", 17.982),
        ]);
        let faults = first_reply_faults(&opening, Some(22.956), FIRST_WORDS_BUDGET);
        assert_eq!(faults.len(), 7, "{faults:#?}");
        assert_eq!(faults.iter().filter(|f| f.contains("tool DISCOVERY")).count(), 4);
        assert_eq!(faults.iter().filter(|f| f.contains("continuity checkpoint was written")).count(), 1);
        assert!(faults.iter().any(|f| f.contains("tool call 6 of 6 and not the first")), "{faults:#?}");
        assert!(faults.iter().any(|f| f.contains("22.956 s, over the 9 s budget")), "{faults:#?}");
        // **And it stays red under the COLD budget too**, which is the arm that matters: a
        // 20 s allowance for a lease's first turn must not quietly forgive the defect this
        // whole slice is about.
        assert!(!first_reply_faults(&opening, Some(22.956), FIRST_TURN_BUDGET).is_empty());
    }

    #[test]
    fn the_status_read_is_a_fault_only_when_the_turn_also_handed_work_over() {
        // The doctrine's case 2, which is NOT a defect: *"a question about how work is going is
        // answered from the read, at once"*. Run 2's first question took exactly this shape
        // (`background_work` at 8.748 s, then a direct answer) and it was right to.
        let answered_from_the_read = calls(&[("mcp__richos_status__background_work", 3.1)]);
        assert!(first_reply_faults(&answered_from_the_read, Some(5.9), FIRST_WORDS_BUDGET).is_empty());

        // The same read ahead of a hand-over is the §55 defect: he waited for a look that the
        // other connection does better, and after his turn. **The figures are under the budget on
        // purpose** — the fault asserted here is the ORDER, so a turn that also happened to be
        // slow would prove it with two faults and settle nothing about the one being tested.
        let looked_then_handed_over =
            calls(&[("mcp__richos_status__background_work", 2.1), (crate::assignment_tools::QUALIFIED_RECORD_TOOL, 4.4)]);
        let faults = first_reply_faults(&looked_then_handed_over, Some(6.9), FIRST_WORDS_BUDGET);
        assert_eq!(faults.len(), 1, "{faults:#?}");
        assert!(faults[0].contains("tool call 2 of 2 and not the first"), "{faults:#?}");
    }

    #[test]
    fn every_turn_the_fix_was_measured_on_passes_its_own_budget() {
        // **THE MEASUREMENTS THIS SLICE'S BUDGETS WERE TAKEN FROM, PINNED** — run A of
        // `docs/verification/first-words-2026-09-18.md`. If a later edit loosens a budget, this
        // test says which real turn it was supposed to be about.
        let warm_opening = calls(&[(crate::assignment_tools::QUALIFIED_RECORD_TOOL, 3.968)]);
        assert!(first_reply_faults(&warm_opening, Some(6.358), FIRST_WORDS_BUDGET).is_empty());
        let first_visible = calls(&[(crate::assignment_tools::QUALIFIED_RECORD_TOOL, 5.836)]);
        assert!(first_reply_faults(&first_visible, Some(7.998), FIRST_TURN_BUDGET).is_empty());
        // **WHY THEY ARE TWO CONSTANTS, AND THE HONEST FORM OF IT.** Both of run A's turns pass
        // both budgets — 7.998 s and 6.358 s are under 9 s as well as under 11 s. What the split
        // buys is the 2 s BETWEEN them: a warm turn that regresses to 10 s fails, while a lease's
        // first visible turn at 10 s does not, which is the 1.640 s of real difference the same
        // run measured (7.998 s against 6.358 s, 90 seconds apart) plus its headroom.
        let ten = calls(&[(crate::assignment_tools::QUALIFIED_RECORD_TOOL, 4.0)]);
        assert!(!first_reply_faults(&ten, Some(10.0), FIRST_WORDS_BUDGET).is_empty(), "a warm turn at 10 s is a regression");
        assert!(first_reply_faults(&ten, Some(10.0), FIRST_TURN_BUDGET).is_empty(), "a lease's first visible turn at 10 s is not");
    }

    #[test]
    fn the_shape_where_his_first_message_pays_for_the_priming_turn_is_red() {
        // **THE OLD SHAPE, RED ON THE TIMING, AGAINST ITS OWN MEASUREMENTS.** Before
        // `Spine::prime_front_desk`, the priming turn ran inside his first `submit_prompt`: three
        // runs of the previous record measured that first visible turn at 13.464 s, 13.628 s and
        // 15.513 s, and run B of this slice measured the same shape at 15.714 s when a pre-reply
        // checkpoint put it back. Every one of them is over the re-derived 11 s.
        for unprimed in [13.464, 13.628, 15.513, 15.714] {
            let opening = calls(&[(crate::assignment_tools::QUALIFIED_RECORD_TOOL, 11.714)]);
            let faults = first_reply_faults(&opening, Some(unprimed), FIRST_TURN_BUDGET);
            assert!(!faults.is_empty(), "{unprimed} s must fail the re-derived first-turn budget");
            assert!(faults.iter().any(|f| f.contains("over the 11 s budget")), "{faults:#?}");
            // And on the warm budget too — a slow first turn is never excused by either.
            assert!(!first_reply_faults(&opening, Some(unprimed), FIRST_WORDS_BUDGET).is_empty());
        }
        // The three warm turns of the previous shipped state pass the timing budget and are
        // caught by the ORDERING rule instead: 1.094 s between the register's answer and his
        // first words is the model repeating the app's own sentence. Stated as a pair, here,
        // because a reader who found only the budget would think nothing had changed for them.
        for warm in [7.128, 8.505, 8.920] {
            let opening = calls(&[(crate::assignment_tools::QUALIFIED_RECORD_TOOL, 3.122)]);
            assert!(first_reply_faults(&opening, Some(warm), FIRST_WORDS_BUDGET).is_empty(), "{warm}");
        }
        assert!(first_words_not_from_the_app(Some(6.034), Some(7.128)).is_some());
    }

    #[test]
    fn the_shape_where_the_model_repeats_the_app_s_own_sentence_is_red() {
        // **THE POSITIVE CONTROL, AND IT IS THE PREVIOUS SHIPPED STATE RATHER THAN A SYNTHETIC
        // ONE.** Both pairs are verbatim from run 3 of `docs/verification/first-reply-2026-09-18.md`
        // — the register answered, and his first words came a whole model round trip later because
        // the MODEL was the thing saying them.
        let warm = first_words_not_from_the_app(Some(6.034), Some(7.128));
        assert!(warm.is_some(), "the warm turn of the shipped state must be red");
        assert!(warm.unwrap().contains("1.094 s AFTER"));
        assert!(first_words_not_from_the_app(Some(14.086), Some(15.513)).is_some(), "and the cold one");

        // **AND THE STATE THIS SLICE MEASURED**, 2026-09-18 run A: the app says the sentence off
        // the register's own answer, so the two events are the same instant.
        assert_eq!(first_words_not_from_the_app(Some(7.998), Some(7.998)), None);
        assert_eq!(first_words_not_from_the_app(Some(6.358), Some(6.358)), None);
        // The text is routed BEFORE the frame's machinery record, so his words can legitimately be
        // a hair EARLIER than the record of the frame they came from. That is not a fault.
        assert_eq!(first_words_not_from_the_app(Some(6.358), Some(6.350)), None);
        // At the tolerance exactly: allowed. Past it: not.
        assert_eq!(first_words_not_from_the_app(Some(6.0), Some(6.25)), None);
        assert!(first_words_not_from_the_app(Some(6.0), Some(6.3)).is_some());

        // A turn with no register is not this rule's business at all.
        assert_eq!(first_words_not_from_the_app(None, Some(2.4)), None);
        assert_eq!(first_words_not_from_the_app(None, None), None);
        // A register that answered and a turn that said nothing is the worst outcome, not a pass.
        assert!(first_words_not_from_the_app(Some(6.0), None).is_some());
    }

    #[test]
    fn a_turn_that_said_nothing_is_a_fault_rather_than_a_pass() {
        // An unmeasured turn is not a fast turn. `None` is the state the probe reports when no
        // live text event arrived at all, and it must never be silently fine.
        let faults = first_reply_faults(&[], None, FIRST_WORDS_BUDGET);
        assert_eq!(faults.len(), 1);
        assert!(faults[0].contains("never measured"));
    }

    #[test]
    fn the_app_reads_the_register_s_own_answer_and_refuses_everything_that_is_not_one() {
        use serde_json::json;
        // **THE PAYLOAD IS NOT TYPED HERE, IT IS PRODUCED.** `assignment_tools::call` is the
        // only thing that writes this shape, so the happy case is taken from it rather than
        // transcribed — a rename of either field fails this test instead of silently stopping
        // the app from speaking.
        let produced = json!({
            crate::assignment_tools::RECEIPT_RECORDED_FIELD: true,
            crate::assignment_tools::RECEIPT_SAY_FIELD: "On it!",
            "say_nothing_else": true,
        })
        .to_string();
        let as_array = json!({"tool_use_id":"toolu_A","type":"tool_result",
                              "content":[{"type":"text","text":produced.clone()}]});
        assert_eq!(receipt_sentence(&as_array).as_deref(), Some("On it!"));
        // The same fact carried as a bare string, which this wire also does.
        let as_string = json!({"tool_use_id":"toolu_A","type":"tool_result","content":produced});
        assert_eq!(receipt_sentence(&as_string).as_deref(), Some("On it!"));
        // All four of §55/§58's sentences, so the reader is proven on the whole vocabulary and
        // not only on the one that happened to be measured.
        for words in ["On it!", "Got it. On it!", "I'll check.", "I'll investigate."] {
            let block = json!({"type":"tool_result","content":
                json!({"recorded":true,"say":words}).to_string()});
            assert_eq!(receipt_sentence(&block).as_deref(), Some(words));
        }

        // **AND THE REFUSALS, WHICH ARE THE HALF THAT MATTERS.** Each of these is a turn where
        // the app says nothing and the model's own copy still answers him — the behavior that
        // shipped this morning, reached by degrading rather than by lying.
        let refused = json!({"type":"tool_result","is_error":true,"content":
            "This conversation is not open for new assignments right now. Nothing was recorded."});
        assert_eq!(receipt_sentence(&refused), None, "a refused registration must not be announced");
        // The same refusal WITHOUT the error flag: it is not JSON, so there is no receipt in it.
        let prose = json!({"type":"tool_result","content":
            "This conversation is not open for new assignments right now. Nothing was recorded."});
        assert_eq!(receipt_sentence(&prose), None);
        for payload in [
            json!({"recorded":false,"say":"On it!"}),
            json!({"say":"On it!"}),
            json!({"recorded":true}),
            json!({"recorded":true,"say":""}),
            json!({"recorded":true,"say":"   "}),
            json!({"recorded":true,"say":42}),
            json!({"recorded":"true","say":"On it!"}),
        ] {
            let block = json!({"type":"tool_result","content":payload.to_string()});
            assert_eq!(receipt_sentence(&block), None, "{payload}");
        }
        // No content at all, and a content shape nobody has seen.
        assert_eq!(receipt_sentence(&json!({"type":"tool_result"})), None);
        assert_eq!(receipt_sentence(&json!({"type":"tool_result","content":7})), None);
    }

    #[test]
    fn everything_after_his_first_word_is_off_his_wait() {
        // The list this rule is given is, by construction, only what happened BEFORE his first
        // word — so a checkpoint written after the reply is invisible here, which is the whole
        // point of the change it enforces.
        assert!(first_reply_faults(&[], Some(6.7), FIRST_WORDS_BUDGET).is_empty());
    }
}
