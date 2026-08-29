//! STEERING AND STOP (UX §9.2 / §9.3 / §25 "Steering and stop") — the invariants.
//!
//! The problem this file exists to close, stated as slice 5 left it (`timeline.rs`,
//! before this change):
//!
//! > `Interrupted` covers a crash, a rotation and a cancel alike, so rendering *"You
//! > stopped after 18s"* would attribute the stop to the CEO on no evidence.
//!
//! §6.1 spends `You stopped after {duration}` on an ATTRIBUTION to the CEO. An attribution
//! needs evidence, and the evidence is a stop REQUEST that was durable before anything was
//! interrupted. These tests prove the two states never bleed into one another in either
//! direction: a crash can never be reported as a CEO stop, and a CEO stop is never
//! reported as a crash.
//!
//! Headless throughout: no live Claude, no network, no Tauri.

use richos_core::entity::EntityId;
use richos_core::ledger::{Ledger, Source, TurnState};
use richos_core::timeline::{Timeline, TimelineItem, ViewMode, WorkState};

fn femcboost() -> EntityId {
    EntityId::parse("femcboost").unwrap()
}

fn tmp_ledger(tag: &str) -> (std::path::PathBuf, Ledger) {
    let path = std::env::temp_dir().join(format!(
        "richos-steering-test-{tag}-{}-{}.jsonl",
        std::process::id(),
        richos_core::util::now_millis()
    ));
    let _ = std::fs::remove_file(&path);
    let ledger = Ledger::open(&path).unwrap();
    (path, ledger)
}

/// One received + started turn, ready to be ended one way or the other.
fn started_turn(ledger: &mut Ledger, text: &str) -> (String, String) {
    let thread = ledger.create_thread("stop", &femcboost()).unwrap();
    let binding = ledger.thread_binding(&thread).unwrap();
    let turn = ledger.record_prompt_received(&binding, text, Source::Text).unwrap();
    ledger.mark_turn_started(&turn, "sess-1").unwrap();
    (thread, turn)
}

#[test]
fn a_ceo_stop_and_a_crash_are_different_terminal_states_in_the_log() {
    let (_p, mut ledger) = tmp_ledger("distinct");
    let (_t, stopped) = started_turn(&mut ledger, "the one he stopped");
    let (_t2, crashed) = started_turn(&mut ledger, "the one that died");

    ledger.stop_turn(&stopped, 1_000).unwrap();
    ledger.interrupt_turn(&crashed, "cognition io: broken pipe").unwrap();

    assert_eq!(ledger.turn(&stopped).unwrap().state, TurnState::Stopped);
    assert_eq!(ledger.turn(&crashed).unwrap().state, TurnState::Interrupted);
    // The stop carries the CEO's request time; the crash carries nobody's.
    assert_eq!(ledger.turn(&stopped).unwrap().stop_requested_at, Some(1_000));
    assert_eq!(ledger.turn(&crashed).unwrap().stop_requested_at, None);
}

#[test]
fn the_distinction_survives_a_reopen_because_it_is_two_events_not_one_reason_string() {
    let path;
    let (stopped, crashed);
    {
        let (p, mut ledger) = tmp_ledger("reopen");
        path = p;
        let (_t, s) = started_turn(&mut ledger, "stopped");
        let (_t2, c) = started_turn(&mut ledger, "crashed");
        ledger.stop_turn(&s, 4_242).unwrap();
        ledger.interrupt_turn(&c, "adapter_exited").unwrap();
        stopped = s;
        crashed = c;
    }
    let reopened = Ledger::open(&path).unwrap();
    assert_eq!(reopened.turn(&stopped).unwrap().state, TurnState::Stopped);
    assert_eq!(reopened.turn(&stopped).unwrap().stop_requested_at, Some(4_242));
    assert_eq!(reopened.turn(&crashed).unwrap().state, TurnState::Interrupted);
}

#[test]
fn a_stop_arriving_after_the_turn_already_completed_does_not_rewrite_history() {
    // The race §9.3 has to survive: the CEO presses stop at the exact moment Rich finishes.
    // Whoever wins, the log must say what actually happened — and what happened is that the
    // turn completed.
    let (_p, mut ledger) = tmp_ledger("late-stop");
    let (_t, turn) = started_turn(&mut ledger, "nearly done");
    ledger.complete_turn(&turn, "end_turn").unwrap();
    ledger.stop_turn(&turn, richos_core::util::now_millis()).unwrap();

    assert_eq!(ledger.turn(&turn).unwrap().state, TurnState::Completed);
    assert_eq!(ledger.turn(&turn).unwrap().stop_reason.as_deref(), Some("end_turn"));
    assert_eq!(ledger.turn(&turn).unwrap().stop_requested_at, None);
}

#[test]
fn a_stopped_turn_is_measured_not_estimated_and_reaches_the_timeline_as_stopped() {
    let (_p, mut ledger) = tmp_ledger("measured");
    let (thread, turn) = started_turn(&mut ledger, "measure me");
    ledger.stop_turn(&turn, 1).unwrap();

    let t = ledger.turn(&turn).unwrap();
    // ended_at was written by the stop event, so the span is MEASURED — the §6.1 label
    // "You stopped after {duration}" has a real number behind it rather than a clock read
    // at render time (§6.3's twelve-hour trap).
    assert!(t.ended_at.is_some(), "a stop must write an end time or the duration is unrenderable");
    assert!(t.active_ms().is_some());

    let binding = ledger.thread_binding(&thread).unwrap();
    let timeline = Timeline::project(&ledger, &binding, &[]).unwrap();
    let view = timeline.view(ViewMode::Ceo);
    let states: Vec<WorkState> = view
        .items
        .iter()
        .filter_map(|i| match i {
            TimelineItem::WorkDuration { state, .. } => Some(*state),
            _ => None,
        })
        .collect();
    assert_eq!(states, vec![WorkState::Stopped]);
}

#[test]
fn a_stopped_turn_raises_no_system_error_row_because_nothing_went_wrong() {
    // §5.5/§21's failure treatment belongs to failures. The CEO pressing stop is not one,
    // and drawing an error under it would tell him something broke.
    let (_p, mut ledger) = tmp_ledger("no-error-row");
    let (thread, turn) = started_turn(&mut ledger, "stop me");
    ledger.stop_turn(&turn, 1).unwrap();

    let binding = ledger.thread_binding(&thread).unwrap();
    let timeline = Timeline::project(&ledger, &binding, &[]).unwrap();
    let view = timeline.view(ViewMode::Technical);
    let errors = view.items.iter().filter(|i| matches!(i, TimelineItem::SystemError { .. })).count();
    assert_eq!(errors, 0, "a CEO stop is not a system error");
}
