//! Integration tests for the runtime spine — the crash-safety, queue-not-interrupt,
//! thread-model, and re-prime-continuity invariants — all with a MOCK cognition, so
//! they run green with NO live Claude / network (the ACP round-trip itself is proven
//! separately by examples/acp_roundtrip.rs).

use richos_core::cognition::{Cognition, CognitionError, MockCognition};
use richos_core::ledger::{Ledger, Source, TurnState};
use richos_core::reprime::RePrimePayload;
use richos_core::spine::Spine;
use richos_core::stream::{StreamEvent, TurnObserver};
use std::sync::{Arc, Mutex};

fn tmp_ledger(tag: &str) -> (std::path::PathBuf, Ledger) {
    let path = std::env::temp_dir().join(format!(
        "richos-test-{tag}-{}-{}.jsonl",
        std::process::id(),
        richos_core::util::now_millis()
    ));
    let _ = std::fs::remove_file(&path);
    let ledger = Ledger::open(&path).unwrap();
    (path, ledger)
}

#[test]
fn prompt_is_persisted_received_before_send() {
    // Crash-safety: even with NO lease attached, submitting persists the prompt.
    let (path, ledger) = tmp_ledger("crashsafe");
    let mut spine = Spine::new(ledger);
    spine.create_thread("General").unwrap();

    // No lease attached -> delivery fails, but the prompt MUST already be durable.
    let result = spine.submit_prompt("remember this even if we crash", Source::Text);
    assert!(result.is_err(), "delivery should fail with no lease");

    // Re-open from disk: the prompt survived as a `received`/interrupted turn.
    drop(spine);
    let reopened = Ledger::open(&path).unwrap();
    let survived = reopened
        .turns()
        .iter()
        .any(|t| t.user_text == "remember this even if we crash");
    assert!(survived, "CEO prompt must be durable before send");
    let _ = std::fs::remove_file(&path);
}

#[test]
fn full_roundtrip_persists_and_renders_clean() {
    let (path, ledger) = tmp_ledger("roundtrip");
    let mut spine = Spine::new(ledger);
    let thread = spine.create_thread("General").unwrap();
    spine.attach_lease(Box::new(MockCognition::new("sess-1", vec!["Hello CEO, I'm Rich."])));

    let turn_id = spine.submit_prompt("hi", Source::Text).unwrap();

    let turn = spine.ledger().turn(&turn_id).unwrap();
    assert_eq!(turn.state, TurnState::Completed);
    assert_eq!(turn.assistant_text, "Hello CEO, I'm Rich.");

    // Clean output view: user + assistant, no internal machinery.
    let msgs = spine.messages(&thread);
    assert_eq!(msgs.len(), 2);
    assert_eq!(msgs[0].role, "user");
    assert_eq!(msgs[1].role, "assistant");
    assert_eq!(msgs[1].text, "Hello CEO, I'm Rich.");
    let _ = std::fs::remove_file(&path);
}

#[test]
fn lease_is_reprimed_before_first_turn() {
    // Continuity foundation: the re-prime (identity assertion) is injected once,
    // before the first CEO-visible turn.
    let (path, ledger) = tmp_ledger("reprime");
    let mut spine = Spine::new(ledger);
    spine.create_thread("General").unwrap();

    let mock = MockCognition::new("sess-1", vec!["reply"]);
    let reprimes_ref = mock.reprimes.clone();
    let prompts_ref = mock.prompts.clone();
    spine.attach_lease(Box::new(mock));

    spine.submit_prompt("hello", Source::Text).unwrap();

    let reprimes = reprimes_ref.lock().unwrap();
    assert_eq!(reprimes.len(), 1, "exactly one re-prime injection");
    assert!(reprimes[0].contains("You are Rich"), "identity assertion present");
    assert!(reprimes[0].contains("NO DENIAL FROM ABSENT MEMORY"), "anti-false-attribution rule present");
    // The re-prime happens; the CEO prompt is delivered after it.
    assert_eq!(*prompts_ref.lock().unwrap(), vec!["hello".to_string()]);
    let _ = std::fs::remove_file(&path);
}

#[test]
fn internal_reprime_turn_is_never_rendered() {
    let (path, ledger) = tmp_ledger("internal");
    let mut spine = Spine::new(ledger);
    let thread = spine.create_thread("General").unwrap();
    spine.attach_lease(Box::new(MockCognition::new("sess-1", vec!["ok"])));
    spine.submit_prompt("hey", Source::Text).unwrap();

    // A `received` Internal turn exists in the ledger...
    assert!(spine.ledger().turns().iter().any(|t| t.source == Source::Internal));
    // ...but it has NO render path: messages() only shows the real user + assistant.
    let msgs = spine.messages(&thread);
    assert!(msgs.iter().all(|m| m.text != "[re-prime]"));
    assert_eq!(msgs.len(), 2);
    let _ = std::fs::remove_file(&path);
}

#[test]
fn default_thread_title_is_running_not_general() {
    // UX doc §2.1 / §6.1: "the empty rail shows only 'Running'" — the pinned default
    // thread's REAL title, not a client-side relabel of a literal "General" backend
    // value (that relabel in app/ui/main.js is now dead code, kept only as a defensive
    // fallback — this test is the backend-side proof the one-liner landed).
    let (path, ledger) = tmp_ledger("default-title");
    let mut spine = Spine::new(ledger);
    let thread_id = spine.ensure_active_thread().unwrap();
    let summaries = spine.threads();
    let default = summaries.iter().find(|t| t.id == thread_id).unwrap();
    assert_eq!(default.title, "Running");
    let _ = std::fs::remove_file(&path);
}

#[test]
fn threads_are_views_over_one_shared_ledger() {
    let (path, ledger) = tmp_ledger("threads");
    let mut spine = Spine::new(ledger);
    let germany = spine.create_thread("Germany").unwrap();
    let hiring = spine.create_thread("Q4 hiring").unwrap();
    spine.attach_lease(Box::new(MockCognition::new("sess-1", vec!["a", "b"])));

    spine.switch_thread(&germany).unwrap();
    spine.submit_prompt("about germany", Source::Text).unwrap();
    spine.switch_thread(&hiring).unwrap();
    spine.submit_prompt("about hiring", Source::Text).unwrap();

    // Two threads, each carrying only its own messages, but both projected from the
    // one shared ledger (topic separation WITHOUT fragmentation).
    assert_eq!(spine.messages(&germany).len(), 2);
    assert_eq!(spine.messages(&hiring).len(), 2);
    assert_eq!(spine.messages(&germany)[0].text, "about germany");
    assert_eq!(spine.messages(&hiring)[0].text, "about hiring");

    let summaries = spine.threads();
    assert_eq!(summaries.len(), 2);
    let _ = std::fs::remove_file(&path);
}

#[test]
fn history_survives_restart() {
    let (path, ledger) = tmp_ledger("restart");
    let thread;
    {
        let mut spine = Spine::new(ledger);
        thread = spine.create_thread("General").unwrap();
        spine.attach_lease(Box::new(MockCognition::new("sess-1", vec!["persisted reply"])));
        spine.submit_prompt("remember me", Source::Text).unwrap();
    } // spine + ledger dropped (app "restart")

    let reopened = Ledger::open(&path).unwrap();
    let spine2 = Spine::new(reopened);
    let msgs = spine2.messages(&thread);
    assert_eq!(msgs.len(), 2);
    assert_eq!(msgs[0].text, "remember me");
    assert_eq!(msgs[1].text, "persisted reply");
    let _ = std::fs::remove_file(&path);
}

#[test]
fn reprime_payload_carries_action_ledger_as_ground_truth() {
    // Anti-false-attribution: a recorded action appears in the re-prime as authoritative.
    let (path, mut ledger) = tmp_ledger("attribution");
    let thread = ledger.create_thread("General").unwrap();
    let turn = ledger.record_prompt_received(&thread, "dispatch a worker", Source::Text).unwrap();
    ledger.record_action(&turn, "dispatch", "spawned worker mark-sonnet-f1").unwrap();

    let payload = RePrimePayload::assemble(&ledger, &thread, &thread, 8);
    assert_eq!(payload.action_ledger_digest.len(), 1);
    assert_eq!(payload.action_ledger_digest[0].kind, "dispatch");
    let priming = payload.to_priming_prompt();
    assert!(priming.contains("ACTION LEDGER"));
    assert!(priming.contains("spawned worker mark-sonnet-f1"));
    let _ = std::fs::remove_file(&path);
}

#[test]
fn queue_not_interrupt_orders_prompts_without_dropping() {
    // With the mock, turns complete synchronously, so this asserts the QUEUE PATH is
    // wired and ordered (a mid-turn arrival is journaled + delivered, never dropped).
    let (path, ledger) = tmp_ledger("queue");
    let mut spine = Spine::new(ledger);
    let thread = spine.create_thread("General").unwrap();
    spine.attach_lease(Box::new(MockCognition::new("sess-1", vec!["r1", "r2", "r3"])));

    spine.submit_prompt("first", Source::Text).unwrap();
    spine.submit_prompt("second", Source::Text).unwrap();
    spine.submit_prompt("third", Source::Text).unwrap();

    let msgs = spine.messages(&thread);
    let user_texts: Vec<_> = msgs.iter().filter(|m| m.role == "user").map(|m| m.text.clone()).collect();
    assert_eq!(user_texts, vec!["first", "second", "third"]);
    assert_eq!(spine.queue_depth(), 0);
    assert!(!spine.is_turn_in_progress());
    let _ = std::fs::remove_file(&path);
}

// ---- streaming / turn-state emission -------------------------------------------

/// A recording UI sink: captures every emitted event so tests can assert order, ids,
/// seq, and payload shape — the exact contract the Tauri UI consumes.
#[derive(Clone, Default)]
struct RecordingObserver {
    events: Arc<Mutex<Vec<StreamEvent>>>,
}
impl RecordingObserver {
    fn events(&self) -> Vec<StreamEvent> {
        self.events.lock().unwrap().clone()
    }
}
impl TurnObserver for RecordingObserver {
    fn on_event(&self, event: &StreamEvent) {
        self.events.lock().unwrap().push(event.clone());
    }
}

/// A cognition that streams one chunk then fails the turn — to exercise the error path.
struct FailingCognition {
    session_id: String,
}
impl Cognition for FailingCognition {
    fn session_id(&self) -> &str {
        &self.session_id
    }
    fn reprime(&mut self, _priming_text: &str) -> Result<(), CognitionError> {
        Ok(())
    }
    fn prompt(&mut self, _text: &str, on_chunk: &mut dyn FnMut(&str)) -> Result<String, CognitionError> {
        on_chunk("partial before the lease dies");
        Err(CognitionError::Io("adapter exited mid-turn".into()))
    }
}

#[test]
fn stream_emits_chunks_in_order_and_ledger_holds_full_reply() {
    // The core streaming guarantee: chunk events arrive in seq order, concatenate to the
    // full reply, and carry the right thread + turn ids — while the ledger (source of
    // truth) independently reflects the same full reply.
    let (path, ledger) = tmp_ledger("stream-order");
    let mut spine = Spine::new(ledger);
    let thread = spine.create_thread("General").unwrap();
    spine.attach_lease(Box::new(MockCognition::new("sess-1", vec!["Hello CEO, I am Rich and I am here."])));

    let observer = RecordingObserver::default();
    spine.set_observer(Box::new(observer.clone()));

    let turn_id = spine.submit_prompt("hi", Source::Text).unwrap();

    let events = observer.events();

    // Chunk events, in arrival order.
    let chunks: Vec<(u64, String, String, String)> = events
        .iter()
        .filter_map(|e| match e {
            StreamEvent::Chunk { thread_id, turn_id, seq, text_delta, .. } => {
                Some((*seq, thread_id.clone(), turn_id.clone(), text_delta.clone()))
            }
            _ => None,
        })
        .collect();
    assert!(chunks.len() >= 2, "mock streams multiple chunks");

    // seq is 0-based and strictly increasing in arrival order.
    for (i, (seq, tid, tur, _)) in chunks.iter().enumerate() {
        assert_eq!(*seq, i as u64, "seq is 0-based and in order");
        assert_eq!(tid, &thread, "chunk carries the active thread id");
        assert_eq!(tur, &turn_id, "chunk carries the current turn id");
    }

    // Concatenating textDelta in seq order reproduces the full reply...
    let streamed: String = chunks.iter().map(|(_, _, _, t)| t.clone()).collect();
    assert_eq!(streamed, "Hello CEO, I am Rich and I am here.");
    // ...and the ledger independently holds the same full reply.
    assert_eq!(spine.ledger().turn(&turn_id).unwrap().assistant_text, "Hello CEO, I am Rich and I am here.");

    let _ = std::fs::remove_file(&path);
}

#[test]
fn turn_state_events_bracket_the_turn() {
    // turn-started fires first (the "Rich is working" affordance), turn-completed fires
    // last, both keyed to the same thread + turn; chunks live strictly between them.
    let (path, ledger) = tmp_ledger("stream-bracket");
    let mut spine = Spine::new(ledger);
    let thread = spine.create_thread("General").unwrap();
    spine.attach_lease(Box::new(MockCognition::new("sess-1", vec!["working then done"])));

    let observer = RecordingObserver::default();
    spine.set_observer(Box::new(observer.clone()));

    let turn_id = spine.submit_prompt("go", Source::Text).unwrap();
    let events = observer.events();

    // First event is TurnStarted for this thread + turn.
    match &events[0] {
        StreamEvent::TurnStarted { thread_id, turn_id: t, .. } => {
            assert_eq!(thread_id, &thread);
            assert_eq!(t, &turn_id);
        }
        other => panic!("expected TurnStarted first, got {other:?}"),
    }
    // Last event is TurnCompleted for this turn, carrying the stopReason.
    match events.last().unwrap() {
        StreamEvent::TurnCompleted { turn_id: t, stop_reason, .. } => {
            assert_eq!(t, &turn_id);
            assert_eq!(stop_reason, "end_turn");
        }
        other => panic!("expected TurnCompleted last, got {other:?}"),
    }
    // Every chunk sits strictly between start and complete.
    let n = events.len();
    for (i, e) in events.iter().enumerate() {
        if matches!(e, StreamEvent::Chunk { .. }) {
            assert!(i > 0 && i < n - 1, "chunks are bracketed by start/complete");
        }
    }
    let _ = std::fs::remove_file(&path);
}

#[test]
fn failed_turn_emits_turn_error_and_persists_partial() {
    // A lease that dies mid-turn: the partial reply is persisted + streamed, and a
    // terminal turn-error is emitted (never a silent hang, never a leaked stack trace).
    let (path, ledger) = tmp_ledger("stream-error");
    let mut spine = Spine::new(ledger);
    let thread = spine.create_thread("General").unwrap();
    spine.attach_lease(Box::new(FailingCognition { session_id: "sess-x".into() }));

    let observer = RecordingObserver::default();
    spine.set_observer(Box::new(observer.clone()));

    let turn_id = spine.submit_prompt("cause a failure", Source::Text).unwrap_err_turn(&spine);
    let events = observer.events();

    // A partial chunk streamed before the failure.
    assert!(events.iter().any(|e| matches!(e, StreamEvent::Chunk { .. })), "partial chunk streamed");
    // Terminal event is TurnError for this thread + turn.
    match events.last().unwrap() {
        StreamEvent::TurnError { thread_id, turn_id: t, reason, .. } => {
            assert_eq!(thread_id, &thread);
            assert_eq!(t, &turn_id);
            assert!(reason.contains("adapter exited"), "carries the failure reason");
        }
        other => panic!("expected TurnError last, got {other:?}"),
    }
    // The ledger captured the partial reply and marked the turn interrupted.
    let turn = spine.ledger().turn(&turn_id).unwrap();
    assert_eq!(turn.state, TurnState::Interrupted);
    assert_eq!(turn.assistant_text, "partial before the lease dies");
    // The turn boundary is clear again (queue-not-interrupt invariant intact).
    assert!(!spine.is_turn_in_progress());
    let _ = std::fs::remove_file(&path);
}

/// Small helper: submit_prompt returns the turn id even when delivery fails (the prompt
/// is always journaled first). This recovers that id from the ledger for the error test.
trait UnwrapErrTurn {
    fn unwrap_err_turn(self, spine: &Spine) -> String;
}
impl UnwrapErrTurn for Result<String, richos_core::spine::SpineError> {
    fn unwrap_err_turn(self, spine: &Spine) -> String {
        match self {
            Ok(id) => id,
            Err(_) => spine
                .ledger()
                .turns()
                .iter()
                .rev()
                .find(|t| t.source == Source::Text)
                .expect("a text turn was journaled")
                .id
                .clone(),
        }
    }
}
