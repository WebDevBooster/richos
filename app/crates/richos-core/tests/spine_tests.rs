//! Integration tests for the runtime spine — the crash-safety, queue-not-interrupt,
//! thread-model, and re-prime-continuity invariants — all with a MOCK cognition, so
//! they run green with NO live Claude / network (the ACP round-trip itself is proven
//! separately by examples/acp_roundtrip.rs).

use richos_core::cognition::MockCognition;
use richos_core::ledger::{Ledger, Source, TurnState};
use richos_core::reprime::RePrimePayload;
use richos_core::spine::Spine;

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
