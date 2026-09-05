//! **A TURN THAT DIES TO THE MODEL API DOES NOT LOSE SILENTLY** — row 3.30's second and
//! third answers, driven through the REAL `Spine` against an INJECTED upstream.
//!
//! Nothing here touches a network. The fault is injected at the `Cognition` seam by two
//! doubles that reproduce the two shapes an upstream failure can take, and the failure
//! TEXT is the verbatim `529` line this machine captured on 2026-09-03 (committed at
//! `docs/verification/upstream-failure-2026-09-05/captured-529.txt`, request id
//! `req_011Cegb417YK6i1BEVDFmzU1`).
//!
//! **The second shape is the one that mattered most and would have been missed.** `claude`
//! reports an API failure as an ASSISTANT MESSAGE, so the turn ends with an ordinary
//! terminal and the vendor's diagnostic is persisted as Rich's own reply. A test that only
//! injected an `Err` would have proved nothing about it.
//!
//! **What this suite does NOT cover, named rather than left to be found.** Neither wire
//! shape is captured: the twelve runs in
//! `docs/verification/native-claude-stream-json-2026-08-31/raw/` contain no API error at
//! all. These doubles reproduce what the vendor's own code says it emits and what its own
//! transcripts on this machine contain; they are not a recording of the `claude`
//! stream-json wire under an outage, because no such recording exists.

use richos_core::cognition::{Cognition, CognitionError, TurnItem};
use richos_core::entity::EntityId;
use richos_core::ledger::{Ledger, Source, TurnState};
use richos_core::stream::{StreamEvent, TurnObserver};
use richos_core::timeline::{TimelineItem, ViewMode, Visibility};
use richos_core::upstream::{RetryBudget, UpstreamFault, MAX_UPSTREAM_RETRIES};
use richos_core::LeaseFactory;
use std::sync::{Arc, Mutex};

mod support;

/// The verbatim bytes. Line 1 carries `req_011Cegb417YK6i1BEVDFmzU1`.
const CAPTURED_529: &str =
    include_str!("../../../../docs/verification/upstream-failure-2026-09-05/captured-529.txt");
const CONSTRUCTED_429: &str =
    include_str!("../../../../docs/verification/upstream-failure-2026-09-05/constructed-429.txt");

fn captured_529() -> &'static str {
    CAPTURED_529.lines().next().unwrap()
}

fn constructed_429() -> &'static str {
    CONSTRUCTED_429.lines().next().unwrap()
}

fn femcboost() -> EntityId {
    EntityId::parse("femcboost").unwrap()
}

fn tmp_ledger(tag: &str) -> (std::path::PathBuf, Ledger) {
    let path = std::env::temp_dir().join(format!(
        "richos-upstream-test-{tag}-{}-{}.jsonl",
        std::process::id(),
        richos_core::util::now_millis()
    ));
    let _ = std::fs::remove_file(&path);
    let ledger = Ledger::open(&path).unwrap();
    (path, ledger)
}

#[derive(Clone, Default)]
struct RecordingObserver {
    events: Arc<Mutex<Vec<StreamEvent>>>,
}
impl RecordingObserver {
    fn errors(&self) -> Vec<String> {
        self.events
            .lock()
            .unwrap()
            .iter()
            .filter_map(|e| match e {
                StreamEvent::TurnError { reason, .. } => Some(reason.clone()),
                _ => None,
            })
            .collect()
    }
}
impl TurnObserver for RecordingObserver {
    fn on_event(&self, event: &StreamEvent) {
        self.events.lock().unwrap().push(event.clone());
    }
}

// =========================================================================================
// THE TWO INJECTED SHAPES
// =========================================================================================

/// **SHAPE 1 — the vendor's line arrives as ASSISTANT TEXT and the turn ends normally.**
///
/// This is what `claude` actually does: an API error is an assistant message with
/// `isApiErrorMessage`, so `native.rs` streams it as `TurnItem::Text` and `prompt` returns
/// an ordinary terminal. Before this row's work, that produced a COMPLETED turn whose
/// answer was a vendor diagnostic written in Rich's voice.
///
/// `preamble` is real reply text that arrived before the outage, so the tests can prove
/// the loss statement counts what survived and does NOT count the error message as part of
/// the answer.
struct ApiErrorAsTextCognition {
    session_id: String,
    preamble: Option<String>,
    error_line: String,
}

impl Cognition for ApiErrorAsTextCognition {
    fn session_id(&self) -> &str {
        &self.session_id
    }
    fn reprime(&mut self, _p: &str, _on: &mut dyn FnMut(TurnItem)) -> Result<(), CognitionError> {
        Ok(())
    }
    fn prompt(
        &mut self,
        _text: &str,
        on_item: &mut dyn FnMut(TurnItem),
    ) -> Result<String, CognitionError> {
        let mut seq = 0u64;
        if let Some(p) = &self.preamble {
            on_item(TurnItem::Text { seq, text: p });
            seq += 1;
        }
        on_item(TurnItem::Text { seq, text: &self.error_line });
        // The vendor's own terminal for this case: the turn ended, and nothing about the
        // stop reason says an outage happened.
        Ok("end_turn".to_string())
    }
}

/// **SHAPE 2 — the client gives up and the line is in the error's `Display`.**
struct ApiErrorAsErrCognition {
    session_id: String,
    error_line: String,
}

impl Cognition for ApiErrorAsErrCognition {
    fn session_id(&self) -> &str {
        &self.session_id
    }
    fn reprime(&mut self, _p: &str, _on: &mut dyn FnMut(TurnItem)) -> Result<(), CognitionError> {
        Ok(())
    }
    fn prompt(
        &mut self,
        _text: &str,
        _on: &mut dyn FnMut(TurnItem),
    ) -> Result<String, CognitionError> {
        Err(CognitionError::Io(self.error_line.clone()))
    }
}

/// A factory whose every lease fails the same way — so a retry that DOES happen is
/// observable by its spawn count, and one that does not is observable by its absence.
struct OutageFactory {
    spawns: Arc<Mutex<u64>>,
    error_line: String,
}
impl LeaseFactory for OutageFactory {
    fn spawn(&self) -> Result<Box<dyn Cognition>, CognitionError> {
        let mut n = self.spawns.lock().unwrap();
        *n += 1;
        Ok(Box::new(ApiErrorAsErrCognition {
            session_id: format!("sess-outage-{n}"),
            error_line: self.error_line.clone(),
        }))
    }
}

// =========================================================================================
// 2. A DYING TASK MUST NOT LOSE SILENTLY
// =========================================================================================

/// INVARIANT: a `529` arriving as assistant text ends the turn as INTERRUPTED with a
/// durable upstream record — not as a completed turn whose answer was an error message.
///
/// This is the whole of the second answer in one test. The `assert_ne!` on
/// `TurnState::Completed` is the half that would have failed before this row's work.
#[test]
fn an_api_error_delivered_as_assistant_text_is_a_failure_and_not_a_completed_turn() {
    let (path, ledger) = tmp_ledger("text-shape");
    let mut spine = support::spine(ledger);
    let thread = spine.create_thread("General", &femcboost()).unwrap();
    spine.attach_lease(Box::new(ApiErrorAsTextCognition {
        session_id: "sess-1".into(),
        preamble: Some("Here is what I found so far. ".into()),
        error_line: captured_529().to_string(),
    }));

    let turn = spine.submit_prompt("how is the release going?", Source::Text).unwrap_err();
    // The turn id is not returned on the failure path, so it is read off the ledger.
    let _ = turn;
    let t = spine.ledger().thread_turns(&thread).unwrap();
    let t = t.iter().find(|t| t.source == Source::Text).expect("the CEO's turn exists");

    assert_ne!(t.state, TurnState::Completed, "a turn that never got an answer is not completed");
    assert_eq!(t.state, TurnState::Interrupted);

    let up = t.upstream_failure.as_ref().expect("the classification is durable");
    assert_eq!(up.fault, UpstreamFault::Overloaded.tag());
    assert_eq!(up.status, Some(529));
    assert_eq!(up.request_id.as_deref(), Some("req_011Cegb417YK6i1BEVDFmzU1"));
    assert_eq!(up.model.as_deref(), Some("claude-fable-5-1"));
    let _ = std::fs::remove_file(&path);
}

/// INVARIANT: the same for the OTHER shape — the client's own `Err`.
#[test]
fn an_api_error_delivered_as_a_client_error_classifies_the_same_way() {
    let (path, ledger) = tmp_ledger("err-shape");
    let mut spine = support::spine(ledger);
    let thread = spine.create_thread("General", &femcboost()).unwrap();
    spine.attach_lease(Box::new(ApiErrorAsErrCognition {
        session_id: "sess-1".into(),
        error_line: captured_529().to_string(),
    }));

    let _ = spine.submit_prompt("how is the release going?", Source::Text);
    let turns = spine.ledger().thread_turns(&thread).unwrap();
    let t = turns.iter().find(|t| t.source == Source::Text).unwrap();
    let up = t.upstream_failure.as_ref().expect("the classification is durable on this shape too");
    assert_eq!(up.fault, UpstreamFault::Overloaded.tag());
    let _ = std::fs::remove_file(&path);
}

/// INVARIANT: the loss statement reaches the CEO AT the failure, and it names what is on
/// disk and what is not.
///
/// The character count is the load-bearing assertion: it counts the real preamble and
/// EXCLUDES the vendor's error line, because telling him "169 characters of the answer are
/// saved" when all 169 are the error message is a true number about the wrong thing.
#[test]
fn the_loss_statement_is_emitted_at_the_failure_and_excludes_the_error_message_itself() {
    let (path, ledger) = tmp_ledger("loss-live");
    let mut spine = support::spine(ledger);
    let obs = RecordingObserver::default();
    spine.set_observer(Box::new(obs.clone()));
    let _thread = spine.create_thread("General", &femcboost()).unwrap();
    let preamble = "Here is what I found so far. ";
    spine.attach_lease(Box::new(ApiErrorAsTextCognition {
        session_id: "sess-1".into(),
        preamble: Some(preamble.to_string()),
        error_line: captured_529().to_string(),
    }));

    let _ = spine.submit_prompt("how is the release going?", Source::Text);

    let errors = obs.errors();
    assert_eq!(errors.len(), 1, "exactly one statement, at the moment it happened");
    let m = &errors[0];
    assert!(m.contains("Anthropic's servers are at capacity"), "what happened: {m}");
    assert!(m.contains("what you asked for is saved"), "what survived: {m}");
    assert!(
        m.contains(&format!("the {} characters", preamble.chars().count())),
        "the measured count is the PREAMBLE ({} chars), not the error line: {m}",
        preamble.chars().count()
    );
    assert!(m.contains("Not on disk:"), "what did not survive: {m}");
    assert!(
        !m.contains("API Error: 529"),
        "the vendor's raw line is kept in the ledger, not read out to him here: {m}"
    );
    let _ = std::fs::remove_file(&path);
}

/// INVARIANT: it survives a reload. This is the difference between "visible at the moment
/// it happens" and "discoverable afterward" — the exact distinction row 3.30 draws.
///
/// The spine is dropped, the ledger reopened from the same bytes, and the CEO-mode
/// timeline still carries the outage row with all three sentences.
#[test]
fn the_statement_survives_a_cold_reopen_and_renders_in_the_ceo_view() {
    let (path, ledger) = tmp_ledger("reload");
    let thread = {
        let mut spine = support::spine(ledger);
        let thread = spine.create_thread("General", &femcboost()).unwrap();
        spine.attach_lease(Box::new(ApiErrorAsTextCognition {
            session_id: "sess-1".into(),
            preamble: None,
            error_line: captured_529().to_string(),
        }));
        let _ = spine.submit_prompt("how is the release going?", Source::Text);
        thread
    };

    let reopened = Ledger::open(&path).unwrap();
    let spine = support::spine(reopened);
    let view = spine.timeline(&thread).unwrap().view(ViewMode::Ceo);
    let outage = view
        .items
        .iter()
        .find_map(|i| match i {
            TimelineItem::UpstreamOutage { ceo_message, loss_message, fault, request_id, .. } => {
                Some((ceo_message.clone(), loss_message.clone(), fault.clone(), request_id.clone()))
            }
            _ => None,
        })
        .expect("the outage row is in the CEO view after a cold reopen");
    assert_eq!(outage.2, "overloaded");
    assert!(outage.0.contains("at capacity"));
    assert!(outage.1.contains("Not on disk:"));
    assert_eq!(
        outage.3, None,
        "the vendor's request id is technical and is redacted out of a CEO view"
    );
    let _ = std::fs::remove_file(&path);
}

/// INVARIANT: the vendor's diagnostic NEVER renders as Rich's prose, and the real reply
/// that arrived before it still does.
///
/// This is the sharpest edge of "fails silent": the CEO is shown a stack-shaped sentence
/// in Rich's voice and left to work out that anything went wrong.
#[test]
fn the_vendors_diagnostic_never_renders_as_richs_words_but_the_real_reply_still_does() {
    let (path, ledger) = tmp_ledger("no-vendor-voice");
    let mut spine = support::spine(ledger);
    let thread = spine.create_thread("General", &femcboost()).unwrap();
    spine.attach_lease(Box::new(ApiErrorAsTextCognition {
        session_id: "sess-1".into(),
        preamble: Some("Here is what I found so far. ".into()),
        error_line: captured_529().to_string(),
    }));
    let _ = spine.submit_prompt("how is the release going?", Source::Text);

    let view = spine.timeline(&thread).unwrap().view(ViewMode::Ceo);
    let prose: Vec<String> = view
        .items
        .iter()
        .filter_map(|i| match i {
            TimelineItem::RichMessage { text, .. } => Some(text.clone()),
            _ => None,
        })
        .collect();
    // POSITIVE CONTROL: the guard admits the good case. The real reply is still there.
    assert!(
        prose.iter().any(|t| t.contains("Here is what I found so far")),
        "the answer that DID arrive must still render: {prose:?}"
    );
    // And the negative side.
    assert!(
        !prose.iter().any(|t| t.contains("API Error: 529")),
        "a vendor diagnostic must never render as Rich's own words: {prose:?}"
    );

    // It is DEMOTED, not deleted — the bytes are still evidence, at Internal visibility.
    let all = spine.timeline(&thread).unwrap().view(ViewMode::Technical);
    let hidden = all.items.iter().any(|i| matches!(
        i,
        TimelineItem::RichMessage { text, base, .. } if text.contains("API Error: 529")
            && base.visibility == Visibility::Internal
    ));
    assert!(!hidden, "internal items render in NO mode, so it is absent here too");
    let raw = std::fs::read_to_string(&path).unwrap();
    assert!(raw.contains("API Error: 529"), "and the bytes are still in the ledger as evidence");
    let _ = std::fs::remove_file(&path);
}

// =========================================================================================
// 3. RETRY IS BOUNDED AND VISIBLE
// =========================================================================================

/// INVARIANT: four consecutive turns against an outage do NOT produce four automatic
/// retries. The 2026-09-03 shape, run through the real spine.
///
/// **The arithmetic, shown rather than asserted.** `MAX_UPSTREAM_RETRIES` is 1 and the
/// budget resets only on a SUCCESS, so across four consecutive failing turns the spine
/// spawns a fresh lease exactly once. Four turns that would each have cost a retry cost
/// one between them.
#[test]
fn four_consecutive_failing_turns_buy_exactly_one_automatic_retry_between_them() {
    let (path, ledger) = tmp_ledger("bounded");
    let mut spine = support::spine(ledger);
    let _thread = spine.create_thread("General", &femcboost()).unwrap();
    let spawns = Arc::new(Mutex::new(0u64));
    spine.attach_lease(Box::new(ApiErrorAsErrCognition {
        session_id: "sess-0".into(),
        error_line: captured_529().to_string(),
    }));
    spine.set_lease_factory(Box::new(OutageFactory {
        spawns: spawns.clone(),
        error_line: captured_529().to_string(),
    }));

    for i in 0..4 {
        let _ = spine.submit_prompt(&format!("attempt {i}"), Source::Text);
    }

    let n = *spawns.lock().unwrap();
    assert_eq!(
        n, u64::from(MAX_UPSTREAM_RETRIES),
        "four failing turns bought {} automatic retries; the ceiling is {MAX_UPSTREAM_RETRIES}",
        n
    );
    let _ = std::fs::remove_file(&path);
}

/// POSITIVE CONTROL for the ceiling: it is an allowance, not a refusal. A turn that
/// SUCCEEDS restores it, so the app is not left with nothing on the day it matters.
#[test]
fn a_successful_turn_between_failures_restores_the_allowance() {
    // Held at the budget level, because driving a heal through the spine needs a lease
    // that changes behavior mid-run and that would prove the double, not the rule.
    let mut b = RetryBudget::new();
    assert!(b.charge(UpstreamFault::Overloaded), "first failure buys the retry");
    assert!(!b.charge(UpstreamFault::Overloaded), "second does not");
    b.succeeded();
    assert!(b.may_retry(), "a completed turn restores it");
    assert!(b.charge(UpstreamFault::Overloaded), "and it can be spent again");
}

/// INVARIANT: what was spent reaches the CEO, in attempts, with the cost named.
#[test]
fn the_attempts_spent_are_stated_to_the_ceo_by_the_second_failing_turn() {
    let (path, ledger) = tmp_ledger("visible");
    let mut spine = support::spine(ledger);
    let obs = RecordingObserver::default();
    spine.set_observer(Box::new(obs.clone()));
    let _thread = spine.create_thread("General", &femcboost()).unwrap();
    spine.attach_lease(Box::new(ApiErrorAsErrCognition {
        session_id: "sess-0".into(),
        error_line: captured_529().to_string(),
    }));

    let _ = spine.submit_prompt("first", Source::Text);
    let _ = spine.submit_prompt("second", Source::Text);

    let errors = obs.errors();
    assert_eq!(errors.len(), 2);
    assert!(errors[0].contains("tried once"), "first: {}", errors[0]);
    assert!(errors[1].contains("tried 2 times"), "second: {}", errors[1]);
    assert!(
        errors[1].contains("costs against your Claude usage"),
        "the reason the ceiling exists is named: {}",
        errors[1]
    );
    let _ = std::fs::remove_file(&path);
}

// =========================================================================================
// 5. `429` AND `529` ARE PRESENTED DIFFERENTLY, END TO END
// =========================================================================================

/// INVARIANT: through the real spine, a `429` produces a different sentence, a different
/// stored classification, and — the part that costs money — NO automatic retry.
#[test]
fn a_quota_failure_says_something_different_and_spends_no_retry() {
    let (path, ledger) = tmp_ledger("quota");
    let mut spine = support::spine(ledger);
    let obs = RecordingObserver::default();
    spine.set_observer(Box::new(obs.clone()));
    let thread = spine.create_thread("General", &femcboost()).unwrap();
    let spawns = Arc::new(Mutex::new(0u64));
    spine.attach_lease(Box::new(ApiErrorAsErrCognition {
        session_id: "sess-0".into(),
        error_line: constructed_429().to_string(),
    }));
    spine.set_lease_factory(Box::new(OutageFactory {
        spawns: spawns.clone(),
        error_line: constructed_429().to_string(),
    }));

    let _ = spine.submit_prompt("first", Source::Text);

    let turns = spine.ledger().thread_turns(&thread).unwrap();
    let t = turns.iter().find(|t| t.source == Source::Text).unwrap();
    assert_eq!(t.upstream_failure.as_ref().unwrap().fault, UpstreamFault::RateLimited.tag());

    let m = &obs.errors()[0];
    assert!(m.contains("usage limit is used up"), "{m}");
    assert!(m.contains("schedule"), "the wait has an end, and it says so: {m}");
    assert!(!m.contains("at capacity"), "it must not read as an overload: {m}");

    assert_eq!(
        *spawns.lock().unwrap(),
        0,
        "a usage window that rolls over in hours cannot be helped by an immediate retry, \
         so no attempt is spent on it"
    );

    // And the timeline carries the distinction as a BOOLEAN, so no renderer has to read
    // the prose to get it right.
    let view = spine.timeline(&thread).unwrap().view(ViewMode::Ceo);
    let clears = view.items.iter().find_map(|i| match i {
        TimelineItem::UpstreamOutage { clears_on_a_known_schedule, .. } => {
            Some(*clears_on_a_known_schedule)
        }
        _ => None,
    });
    assert_eq!(clears, Some(true));
    let _ = std::fs::remove_file(&path);
}

/// POSITIVE CONTROL for the boolean above: the overload arm is `false`, so the field
/// discriminates rather than always answering the same way.
#[test]
fn the_overload_arm_reports_no_known_schedule() {
    let (path, ledger) = tmp_ledger("overload-bool");
    let mut spine = support::spine(ledger);
    let thread = spine.create_thread("General", &femcboost()).unwrap();
    spine.attach_lease(Box::new(ApiErrorAsErrCognition {
        session_id: "sess-0".into(),
        error_line: captured_529().to_string(),
    }));
    let _ = spine.submit_prompt("first", Source::Text);
    let view = spine.timeline(&thread).unwrap().view(ViewMode::Ceo);
    let clears = view.items.iter().find_map(|i| match i {
        TimelineItem::UpstreamOutage { clears_on_a_known_schedule, .. } => {
            Some(*clears_on_a_known_schedule)
        }
        _ => None,
    });
    assert_eq!(clears, Some(false));
    let _ = std::fs::remove_file(&path);
}

// =========================================================================================
// THE ANTI-VACUOUS HALF
// =========================================================================================

/// POSITIVE CONTROL, and the most important test in this file. An ORDINARY failure — a
/// broken pipe, the thing that actually happens most days — must NOT be dressed up as an
/// outage, or the whole vocabulary is noise.
#[test]
fn an_ordinary_local_failure_produces_no_upstream_record_at_all() {
    let (path, ledger) = tmp_ledger("local");
    let mut spine = support::spine(ledger);
    let obs = RecordingObserver::default();
    spine.set_observer(Box::new(obs.clone()));
    let thread = spine.create_thread("General", &femcboost()).unwrap();
    spine.attach_lease(Box::new(ApiErrorAsErrCognition {
        session_id: "sess-0".into(),
        // NOT an API error. The `claude` child's stdio went away.
        error_line: "adapter exited mid-turn".into(),
    }));

    let _ = spine.submit_prompt("first", Source::Text);

    let turns = spine.ledger().thread_turns(&thread).unwrap();
    let t = turns.iter().find(|t| t.source == Source::Text).unwrap();
    assert_eq!(t.state, TurnState::Interrupted, "it still failed, and still says so");
    assert!(
        t.upstream_failure.is_none(),
        "but it was not the model API, and nothing claims it was"
    );
    let view = spine.timeline(&thread).unwrap().view(ViewMode::Ceo);
    assert!(
        !view.items.iter().any(|i| matches!(i, TimelineItem::UpstreamOutage { .. })),
        "no outage row for a local failure"
    );
    let m = &obs.errors()[0];
    assert!(!m.contains("Anthropic"), "and he is not told to wait for Anthropic: {m}");
    let _ = std::fs::remove_file(&path);
}

/// POSITIVE CONTROL: a HEALTHY turn produces no outage row, no interruption and no error
/// event. A suite whose every case is a failure proves only that failing works.
#[test]
fn a_healthy_turn_produces_no_outage_and_no_error() {
    let (path, ledger) = tmp_ledger("healthy");
    let mut spine = support::spine(ledger);
    let obs = RecordingObserver::default();
    spine.set_observer(Box::new(obs.clone()));
    let thread = spine.create_thread("General", &femcboost()).unwrap();
    spine.attach_lease(Box::new(richos_core::cognition::MockCognition::new(
        "sess-ok",
        vec!["the release is on track"],
    )));

    let turn = spine.submit_prompt("how is the release going?", Source::Text).unwrap();
    let t = spine.ledger().turn(&turn).unwrap();
    assert_eq!(t.state, TurnState::Completed);
    assert!(t.upstream_failure.is_none());
    assert!(obs.errors().is_empty(), "no error statement on a good turn");

    let view = spine.timeline(&thread).unwrap().view(ViewMode::Ceo);
    assert!(!view.items.iter().any(|i| matches!(i, TimelineItem::UpstreamOutage { .. })));
    let prose: Vec<String> = view
        .items
        .iter()
        .filter_map(|i| match i {
            TimelineItem::RichMessage { text, .. } => Some(text.clone()),
            _ => None,
        })
        .collect();
    assert!(
        prose.iter().any(|t| t.contains("release")),
        "and the answer still renders — the demotion is narrow: {prose:?}"
    );
    let _ = std::fs::remove_file(&path);
}
