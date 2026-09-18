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
/// **Taken from six real turns**, not chosen — `docs/verification/first-reply-2026-09-18.md`,
/// three runs of `examples/first_reply_timing_e2e.rs` against the real provider:
///
/// | | task turn (the lease's first) | question turn (warm) |
/// |---|---|---|
/// | run 1 | 13.464 s | 8.505 s |
/// | run 2 | 13.628 s | 8.920 s |
/// | run 3 | 15.513 s | 7.128 s |
///
/// The three WARM turns are 7.128 s, 8.505 s and 8.920 s; 12 s is the slowest of them plus
/// ~35%, which is headroom for provider variance on a figure that is two model round trips and
/// ~1 ms of this app. The lease's FIRST visible turn is a different measurement and gets
/// [`FIRST_TURN_BUDGET`] — averaging the two would have produced a budget that is loose for one
/// and tight for the other.
///
/// **Why two model round trips are the floor, and why this is therefore not "a few hundred
/// milliseconds".** The register hands back the sentence the model then says, so the shape §55
/// asks for is: his prompt → the model decides and calls the register (3.122 s and 4.414 s
/// measured warm) → the register answers in ~1 ms (`examples/assignment_receipt_timing.rs`) →
/// the model says the words it was handed (another ~3 to 4 s). Neither round trip is this app's
/// to remove; what was removed was 7.5 s of tool discovery and a 4.0 s checkpoint that used to
/// sit between them.
///
/// **It is a budget, not the goal.** §55's goal is *"a few seconds"* and its defect line is
/// 35 s. A warm turn at 11.9 s passes this and is still not what he asked for, which is why the
/// probe prints the figure rather than only the verdict, and why the remaining seconds are named
/// in the record rather than declared finished.
pub const FIRST_WORDS_BUDGET: Duration = Duration::from_secs(12);

/// The budget for the **first visible turn of a lease**, which carries the cold start.
///
/// The same three runs measured 13.464 s, 13.628 s and 15.513 s, against 7.128 s to 8.920 s
/// warm, and the difference is in front of the register rather than after it: the model's first
/// tool call came at 11.714 s cold and at 3.122 s warm on the same run. So this is the slowest
/// of the three plus ~29%, and it is a SEPARATE constant because a single budget covering both
/// would be ~20 s for every turn and would let a warm regression through — a returned
/// `ToolSearch` (+7.5 s) or a pre-reply checkpoint (+4.0 s) would still pass it.
///
/// **What it does NOT do is excuse the cold start.** Eight of those seconds are the lease
/// waking up while he waits, and whether the lease is warmed before he types is a decision
/// about the app's start, not about this turn.
pub const FIRST_TURN_BUDGET: Duration = Duration::from_secs(20);

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
        assert!(faults.iter().any(|f| f.contains("22.956 s, over the 12 s budget")), "{faults:#?}");
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
        // other connection does better, and after his turn.
        let looked_then_handed_over =
            calls(&[("mcp__richos_status__background_work", 3.1), (crate::assignment_tools::QUALIFIED_RECORD_TOOL, 8.4)]);
        let faults = first_reply_faults(&looked_then_handed_over, Some(11.0), FIRST_WORDS_BUDGET);
        assert_eq!(faults.len(), 1, "{faults:#?}");
        assert!(faults[0].contains("tool call 2 of 2 and not the first"), "{faults:#?}");
    }

    #[test]
    fn every_turn_the_fix_was_measured_on_passes_its_own_budget() {
        // **THE SIX MEASUREMENTS, PINNED.** If a later edit loosens a budget, this test says
        // which real turn it was supposed to be about; if a later run comes in slower than
        // these, the budget is what fails rather than nobody noticing.
        for warm in [7.128, 8.505, 8.920] {
            let opening = calls(&[(crate::assignment_tools::QUALIFIED_RECORD_TOOL, 3.122)]);
            assert!(first_reply_faults(&opening, Some(warm), FIRST_WORDS_BUDGET).is_empty(), "{warm}");
        }
        for cold in [13.464, 13.628, 15.513] {
            let opening = calls(&[(crate::assignment_tools::QUALIFIED_RECORD_TOOL, 11.714)]);
            assert!(first_reply_faults(&opening, Some(cold), FIRST_TURN_BUDGET).is_empty(), "{cold}");
            // And a cold turn is NOT excused on the warm budget — the two are different
            // measurements and the probe has to pass the right one.
            assert!(!first_reply_faults(&opening, Some(cold), FIRST_WORDS_BUDGET).is_empty(), "{cold}");
        }
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
    fn everything_after_his_first_word_is_off_his_wait() {
        // The list this rule is given is, by construction, only what happened BEFORE his first
        // word — so a checkpoint written after the reply is invisible here, which is the whole
        // point of the change it enforces.
        assert!(first_reply_faults(&[], Some(6.7), FIRST_WORDS_BUDGET).is_empty());
    }
}
