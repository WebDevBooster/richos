//! Rotation, crash-recovery, and proactive-seam invariants — P1.4's continuity leg.
//! All run headless with `MockCognition`/`MockLeaseFactory` (no live Claude/network);
//! the live ACP round-trip itself is proven separately (examples/acp_roundtrip.rs).
//!
//! Test names document the invariant, per the engineering convention this codebase
//! already follows (spine_tests.rs).

use richos_core::cognition::{Cognition, CognitionError, TurnItem, MockCognition, MockLeaseFactory};
use richos_core::ledger::{ActionVisibility, AttentionTier, Ledger, Source, TurnState};
use richos_core::machinery::MachineryRecord;
use richos_core::spine::ContextSource;
use richos_core::entity::EntityId;
use richos_core::spine::Spine;

/// The dogfood entity these tests run under. Every thread now has an immutable entity
/// home (ECS §3.2) and there is no entity-less path, so the tests NAME one rather than
/// inheriting a default that no longer exists.
fn femcboost() -> EntityId {
    EntityId::parse("femcboost").unwrap()
}
use richos_core::stream::{StreamEvent, TurnObserver};
use richos_core::LeaseFactory;
use std::sync::{Arc, Mutex};

fn tmp_ledger(tag: &str) -> (std::path::PathBuf, Ledger) {
    let path = std::env::temp_dir().join(format!(
        "richos-rotation-test-{tag}-{}-{}.jsonl",
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
    fn events(&self) -> Vec<StreamEvent> {
        self.events.lock().unwrap().clone()
    }
}
impl TurnObserver for RecordingObserver {
    fn on_event(&self, event: &StreamEvent) {
        self.events.lock().unwrap().push(event.clone());
    }
}

/// A lease that streams one partial chunk then dies (a positive-signal crash, never
/// inferred from silence) — mirrors `spine_tests.rs`'s private `FailingCognition`.
struct FailingCognition {
    session_id: String,
}
impl Cognition for FailingCognition {
    fn session_id(&self) -> &str {
        &self.session_id
    }
    fn reprime(&mut self, _priming_text: &str, _on_item: &mut dyn FnMut(TurnItem)) -> Result<(), CognitionError> {
        Ok(())
    }
    fn prompt(&mut self, _text: &str, on_item: &mut dyn FnMut(TurnItem)) -> Result<String, CognitionError> {
        on_item(TurnItem::Text { seq: 0, text: "partial before the lease dies" });
        Err(CognitionError::Io("adapter exited mid-turn".into()))
    }
}

/// A `LeaseFactory` whose every spawned lease ALSO dies immediately — used to prove
/// recovery is bounded to ONE attempt, not an infinite crash loop.
struct AlwaysFailingLeaseFactory {
    spawn_count: Arc<Mutex<u64>>,
}
impl LeaseFactory for AlwaysFailingLeaseFactory {
    fn spawn(&self) -> Result<Box<dyn Cognition>, CognitionError> {
        let mut n = self.spawn_count.lock().unwrap();
        *n += 1;
        Ok(Box::new(FailingCognition { session_id: format!("sess-always-fails-{n}") }))
    }
}

// ============================================================================
// Rotation — invisible continuity (continuity design §3, done-criterion (a))
// ============================================================================

#[test]
fn explicit_rotation_swaps_the_lease_and_the_conversation_survives_it() {
    // Forces a rotation mid-conversation (the "!rotate equivalent" trigger, §3.2) and
    // shows the conversation continuing seamlessly on the successor — done-criterion (a).
    let (path, ledger) = tmp_ledger("explicit-rotation");
    let mut spine = Spine::new(ledger);
    let thread = spine.create_thread("General", &femcboost()).unwrap();

    let factory = MockLeaseFactory::new(vec!["reply from successor lease"]);
    let initial = MockCognition::new("sess-initial", vec!["reply from the first lease"]);
    spine.attach_lease(Box::new(initial));
    spine.set_lease_factory(Box::new(factory));

    // Turn 1, on the ORIGINAL lease.
    let turn1 = spine.submit_prompt("what's on my plate today?", Source::Text).unwrap();
    let session_after_turn1 = spine.ledger().turn(&turn1).unwrap().session_id.clone();

    assert_eq!(spine.rotation_count(), 0, "no rotation triggered yet");

    // Force the rotation NOW, at the current (clear) turn boundary.
    spine.request_rotation("test-forced").unwrap();
    assert_eq!(spine.rotation_count(), 1);
    assert_eq!(spine.last_rotation_reason(), Some("test-forced"));

    // Turn 2, on the SUCCESSOR lease — the CEO just keeps talking.
    let turn2 = spine.submit_prompt("and what's still open from before?", Source::Text).unwrap();
    let session_after_turn2 = spine.ledger().turn(&turn2).unwrap().session_id.clone();

    // Different backing sessions...
    assert_ne!(session_after_turn1, session_after_turn2, "rotation actually swapped the lease");
    // ...but ONE unbroken conversation: both exchanges are still there, in order.
    let msgs = spine.messages(&thread).unwrap();
    assert_eq!(msgs.len(), 4, "both turns' user+assistant pairs are intact across the rotation");
    assert_eq!(msgs[0].text, "what's on my plate today?");
    assert_eq!(msgs[1].text, "reply from the first lease");
    assert_eq!(msgs[2].text, "and what's still open from before?");
    assert_eq!(msgs[3].text, "reply from successor lease");
    let _ = std::fs::remove_file(&path);
}

/// A lease that streams a reply AND reports `usage_update` the way the real adapter does.
///
/// The usage record is built by the PRODUCTION normalizer (`MachineryRecord::from_acp_update`)
/// from the EXACT wire shape captured on 2026-08-28 — `{"sessionUpdate":"usage_update",
/// "used":N,"size":M}`, run1.raw.jsonl n=8 — so these tests exercise the same parse the
/// live adapter drives, not a hand-built struct that could drift away from it.
struct ReportingCognition {
    session_id: String,
    /// The `{used, size}` pairs to report, in order, before the reply text.
    usage: Vec<(u64, u64)>,
    reply: String,
}

impl ReportingCognition {
    fn new(session_id: &str, usage: Vec<(u64, u64)>, reply: &str) -> Self {
        ReportingCognition { session_id: session_id.to_string(), usage, reply: reply.to_string() }
    }
    fn emit_usage(&self, on_item: &mut dyn FnMut(TurnItem), seq: &mut u64) {
        for (used, size) in &self.usage {
            let update = serde_json::json!({"sessionUpdate":"usage_update","used":used,"size":size});
            let rec = MachineryRecord::from_acp_update(&update, &self.session_id, *seq)
                .expect("a usage_update is machinery");
            on_item(TurnItem::Machinery(rec));
            *seq += 1;
        }
    }
}

impl Cognition for ReportingCognition {
    fn session_id(&self) -> &str {
        &self.session_id
    }
    fn reprime(&mut self, _priming_text: &str, _on_item: &mut dyn FnMut(TurnItem)) -> Result<(), CognitionError> {
        Ok(())
    }
    fn prompt(&mut self, _text: &str, on_item: &mut dyn FnMut(TurnItem)) -> Result<String, CognitionError> {
        let mut seq = 0u64;
        self.emit_usage(on_item, &mut seq);
        on_item(TurnItem::Text { seq, text: &self.reply });
        Ok("end_turn".to_string())
    }
}

#[test]
fn the_watermark_is_driven_by_the_measured_usage_not_by_the_char_estimate() {
    // Frank F2, the fix. 70% of a MEASURED 1_000_000 window is 700_000 tokens; the lease
    // says it is there, so rotation fires — while the char estimate over the same turn is
    // three orders of magnitude smaller and could not have triggered anything.
    let (path, ledger) = tmp_ledger("measured-watermark");
    let mut spine = Spine::new(ledger);
    spine.create_thread("General", &femcboost()).unwrap();
    spine.attach_lease(Box::new(ReportingCognition::new("sess-1", vec![(700_000, 1_000_000)], "ok")));
    spine.set_lease_factory(Box::new(MockLeaseFactory::new(vec!["post-rotation reply"])));

    assert_eq!(spine.context_source(), ContextSource::Estimated, "nothing reported yet");
    spine.submit_prompt("hello", Source::Text).unwrap();

    // 700_000 / 1_000_000 = 0.70, and the default ratio is 0.70 -> reached (>=, not >).
    assert_eq!(spine.rotation_count(), 1, "the MEASURED watermark rotated at the boundary");
    assert_eq!(spine.last_rotation_reason(), Some("context-watermark"));
    let _ = std::fs::remove_file(&path);
}

#[test]
fn an_unreported_lease_falls_back_to_the_estimate_and_says_it_is_an_estimate() {
    // The fallback must be honest about being one. A lease that has not reported is in a
    // genuinely different state, and `context_source()` is the type-level way to say so.
    let (path, ledger) = tmp_ledger("fallback-honest");
    let mut spine = Spine::new(ledger);
    spine.create_thread("General", &femcboost()).unwrap();
    spine.attach_lease(Box::new(MockCognition::new("sess-1", vec!["short reply"])));

    assert_eq!(spine.context_source(), ContextSource::Estimated);
    assert!(!spine.context_source().is_measured(), "an estimate must never read as measured");
    assert_eq!(spine.context_usage(), None, "no measurement exists to hand out");

    spine.submit_prompt("hello", Source::Text).unwrap();

    // MockCognition emits no usage_update ever, so it stays on the fallback forever - and
    // the fallback still WORKS: the estimate is non-zero and the window is the configured
    // one, not a measured one.
    assert_eq!(spine.context_source(), ContextSource::Estimated, "still nothing reported");
    assert!(spine.context_estimate_tokens() > 0, "the estimate still accumulates");
    assert_eq!(spine.context_window_tokens(), 200_000, "no measurement -> the configured fallback");
    assert_eq!(spine.context_used_tokens(), spine.context_estimate_tokens());
    let _ = std::fs::remove_file(&path);
}

#[test]
fn a_lease_that_has_not_reported_yet_still_rotates_sensibly() {
    // The fallback path, exercised end to end: same tiny-budget setup as the pre-existing
    // watermark test, against a lease that never reports. Rotation must still happen -
    // "we have no measurement" may not become "we never rotate".
    let (path, ledger) = tmp_ledger("fallback-rotates");
    let mut spine = Spine::new(ledger);
    spine.create_thread("General", &femcboost()).unwrap();
    spine.attach_lease(Box::new(MockCognition::new("sess-1", vec!["short reply"])));
    spine.set_lease_factory(Box::new(MockLeaseFactory::new(vec!["post-rotation reply"])));
    spine.set_context_budget(1000, 0.001); // threshold = 1 token

    spine.submit_prompt("hello", Source::Text).unwrap();

    assert_eq!(spine.rotation_count(), 1, "the ESTIMATE still triggers rotation when it is all we have");
    assert_eq!(spine.last_rotation_reason(), Some("context-watermark"));
    let _ = std::fs::remove_file(&path);
}

#[test]
fn the_measured_window_supersedes_the_configured_one_and_the_configured_ratio_survives() {
    // The "wrong scale" half of F2. 200_000 was the app's guess; 1_000_000 is what the
    // adapter reported in 50 of 50 measured events. The wire wins on the WINDOW (it knows
    // which model is behind the session); the RATIO is policy and stays ours.
    let (path, ledger) = tmp_ledger("measured-window");
    let mut spine = Spine::new(ledger);
    spine.create_thread("General", &femcboost()).unwrap();
    spine.attach_lease(Box::new(ReportingCognition::new("sess-1", vec![(150_000, 1_000_000)], "ok")));
    spine.set_context_budget(200_000, 0.70);

    spine.submit_prompt("hello", Source::Text).unwrap();

    assert_eq!(spine.context_source(), ContextSource::Measured);
    assert_eq!(spine.context_window_tokens(), 1_000_000, "the wire's size, not the guess");
    assert_eq!(spine.configured_context_window_tokens(), 200_000, "the guess stays inspectable");
    assert_eq!(spine.context_used_tokens(), 150_000);
    // 150_000 / 1_000_000 = 0.15, ratio 0.70 -> not reached. Under the OLD arithmetic
    // 150_000 >= 200_000 * 0.70 = 140_000, so it WOULD have rotated at 15% of capacity.
    assert!(!spine.watermark_reached(), "15% of the real window is not 70% of it");
    assert!((spine.context_fraction() - 0.15).abs() < 1e-12, "got {}", spine.context_fraction());
    let _ = std::fs::remove_file(&path);
}

#[test]
fn removing_the_measurement_brings_the_defect_back_the_lease_runs_to_the_wall_unrotated() {
    // THE NEGATIVE CONTROL, and it is a real one: the only thing removed is the signal.
    // Two identical spines, identical budget, identical prompt; one lease reports
    // usage_update, the other does not. The non-reporting lease IS the pre-fix code path
    // (`context_usage == None` selects exactly the old branch), and it is at 99% of a real
    // 1_000_000-token window while its char estimate reads a few dozen tokens.
    //
    // This is the failure that matters: not an early rotation, but a lease that never
    // rotates and then hits the hard limit mid-turn.
    let (path_a, ledger_a) = tmp_ledger("negctl-measured");
    let mut measured = Spine::new(ledger_a);
    measured.create_thread("General", &femcboost()).unwrap();
    measured.attach_lease(Box::new(ReportingCognition::new("sess-m", vec![(990_000, 1_000_000)], "ok")));
    measured.set_lease_factory(Box::new(MockLeaseFactory::new(vec!["successor"])));
    measured.submit_prompt("hello", Source::Text).unwrap();

    let (path_b, ledger_b) = tmp_ledger("negctl-blind");
    let mut blind = Spine::new(ledger_b);
    blind.create_thread("General", &femcboost()).unwrap();
    blind.attach_lease(Box::new(MockCognition::new("sess-b", vec!["ok"])));
    blind.set_lease_factory(Box::new(MockLeaseFactory::new(vec!["successor"])));
    blind.submit_prompt("hello", Source::Text).unwrap();

    assert!(measured.rotation_count() >= 1, "with the measurement, it rotates");
    assert_eq!(
        blind.rotation_count(),
        0,
        "WITHOUT the measurement the defect returns: the char estimate reads {} tokens \
         against a 140_000 threshold, so nothing rotates - while the real session it \
         describes could be at 99% of a 1_000_000-token window",
        blind.context_estimate_tokens()
    );
    assert!(
        blind.context_estimate_tokens() < 140_000,
        "the estimate is the thing that never gets there: {}",
        blind.context_estimate_tokens()
    );
    let _ = std::fs::remove_file(&path_a);
    let _ = std::fs::remove_file(&path_b);
}

#[test]
fn a_successor_never_inherits_its_predecessors_measurement() {
    // If it did, every fresh lease would open above the watermark and rotate immediately -
    // rotation as a loop, which is worse than no rotation at all. `install_lease` is the
    // only place `self.lease` is assigned, so clearing there makes this structural.
    let (path, ledger) = tmp_ledger("no-inherit");
    let mut spine = Spine::new(ledger);
    spine.create_thread("General", &femcboost()).unwrap();
    // 0.90 measured: over the 0.70 watermark, UNDER the 0.95 critical threshold, so this
    // rotates for the ordinary reason and the test stays about inheritance.
    spine.attach_lease(Box::new(ReportingCognition::new("sess-1", vec![(900_000, 1_000_000)], "ok")));
    spine.set_lease_factory(Box::new(MockLeaseFactory::new(vec!["successor reply", "another"])));

    spine.submit_prompt("hello", Source::Text).unwrap();
    assert_eq!(spine.rotation_count(), 1, "the measured watermark rotated once");
    assert_eq!(spine.last_rotation_reason(), Some("context-watermark"));

    // The successor is a MockCognition (never reports), so after the swap the spine must
    // be back on the honest fallback with NO carried-over number.
    assert_eq!(spine.context_usage(), None, "the dead session's number did not survive it");
    assert_eq!(spine.context_source(), ContextSource::Estimated);

    // And the proof that this is not a rotation loop: another turn, still one rotation.
    spine.submit_prompt("again", Source::Text).unwrap();
    assert_eq!(spine.rotation_count(), 1, "a fresh lease must not rotate itself immediately");
    let _ = std::fs::remove_file(&path);
}

#[test]
fn a_mid_turn_crossing_of_the_hard_limit_is_recorded_and_settled_at_the_boundary_never_inside_it() {
    // The failure the whole change is aimed at: a turn's OWN consumption crossing the
    // limit while it is running. Rotation is forbidden there (continuity §3.1), so what
    // this system does is: finish the turn, write the crossing down against that turn,
    // then rotate at the first legal instant under `context-critical`.
    let (path, ledger) = tmp_ledger("mid-turn-critical");
    let mut spine = Spine::new(ledger);
    let thread = spine.create_thread("General", &femcboost()).unwrap();
    // 0.99 configured: an operator ratio that would NOT have rotated at 96%. The critical
    // threshold outranks it, because at 96% measured the policy has been overtaken.
    spine.set_context_budget(1_000_000, 0.99);
    spine.attach_lease(Box::new(ReportingCognition::new(
        "sess-1",
        vec![(500_000, 1_000_000), (960_000, 1_000_000), (970_000, 1_000_000)],
        "the reply still finished",
    )));
    spine.set_lease_factory(Box::new(MockLeaseFactory::new(vec!["successor reply"])));

    spine.submit_prompt("a turn that eats the window", Source::Text).unwrap();

    // 1. The turn FINISHED. Nothing rotated inside it.
    let msgs = spine.messages(&thread).unwrap();
    assert_eq!(msgs.last().unwrap().text, "the reply still finished", "the running turn was never cut short");
    let turn_id = msgs.last().unwrap().turn_id.clone();
    assert_eq!(spine.ledger().turn(&turn_id).unwrap().state, TurnState::Completed);

    // 2. It rotated at the boundary, under the reason that names WHY.
    assert_eq!(spine.rotation_count(), 1);
    assert_eq!(spine.last_rotation_reason(), Some("context-critical"));

    // 3. The crossing is durable, Internal, and attached to the turn it happened in -
    //    the FIRST crossing (960_000), not the last reading.
    let pressure: Vec<_> =
        spine.ledger().internal_actions().into_iter().filter(|a| a.kind == "context_pressure").collect();
    assert_eq!(pressure.len(), 1, "exactly one crossing per turn, at the first crossing");
    assert_eq!(pressure[0].visibility, ActionVisibility::Internal, "the CEO never sees rotation's cause");
    assert_eq!(pressure[0].turn_id.as_deref(), Some(turn_id.as_str()));
    assert!(
        pressure[0].detail.contains("used=960000"),
        "the FIRST crossing is the honest 'when': {}",
        pressure[0].detail
    );
    assert!(pressure[0].detail.contains("size=1000000"), "detail = {}", pressure[0].detail);
    let _ = std::fs::remove_file(&path);
}

#[test]
fn staying_under_the_critical_ratio_records_no_pressure_and_no_critical_rotation() {
    // The positive probe for the negative test above: the same machinery, below 0.95,
    // must produce nothing. A guard that fires either way proves nothing.
    let (path, ledger) = tmp_ledger("no-critical");
    let mut spine = Spine::new(ledger);
    spine.create_thread("General", &femcboost()).unwrap();
    spine.set_context_budget(1_000_000, 0.99);
    spine.attach_lease(Box::new(ReportingCognition::new("sess-1", vec![(940_000, 1_000_000)], "ok")));
    spine.set_lease_factory(Box::new(MockLeaseFactory::new(vec!["successor"])));

    spine.submit_prompt("hello", Source::Text).unwrap();

    // 0.94 < 0.95 critical AND < 0.99 configured -> nothing happens at all.
    assert_eq!(spine.rotation_count(), 0);
    assert!(spine.context_pressure().is_none());
    assert!(spine
        .ledger()
        .internal_actions()
        .into_iter()
        .all(|a| a.kind != "context_pressure"));
    let _ = std::fs::remove_file(&path);
}

#[test]
fn an_adapter_that_reports_a_zero_window_falls_back_rather_than_dividing_by_it() {
    // Never observed on the wire; refused anyway, because a NaN watermark would rotate
    // never or always and there is no way to tell which from the outside.
    let (path, ledger) = tmp_ledger("zero-window");
    let mut spine = Spine::new(ledger);
    spine.create_thread("General", &femcboost()).unwrap();
    spine.attach_lease(Box::new(ReportingCognition::new("sess-1", vec![(500, 0)], "ok")));
    spine.set_context_budget(1000, 0.001); // the fallback WOULD fire

    spine.submit_prompt("hello", Source::Text).unwrap();

    assert!(spine.context_fraction().is_finite(), "no NaN, no inf");
    assert!(spine.watermark_reached(), "a zero window falls back to the estimate, which is over");
    assert_eq!(spine.context_window_tokens(), 1000, "a zero size is not a window");
    let _ = std::fs::remove_file(&path);
}

#[test]
fn watermark_triggers_rotation_automatically_at_the_next_turn_boundary() {
    // continuity §3.2's PRIMARY trigger: the context watermark, not idle/explicit. Set
    // an artificially tiny budget so a single turn's measured context crosses it, then
    // confirm rotation fires WITHOUT any explicit request — proving the scheduled,
    // automatic path (not just the manual one exercised above).
    let (path, ledger) = tmp_ledger("watermark-rotation");
    let mut spine = Spine::new(ledger);
    spine.create_thread("General", &femcboost()).unwrap();
    spine.attach_lease(Box::new(MockCognition::new("sess-1", vec!["short reply"])));
    spine.set_lease_factory(Box::new(MockLeaseFactory::new(vec!["post-rotation reply"])));

    // window=1000 tokens, ratio=0.001 -> threshold = 1 token. Nothing has been sent yet,
    // so the measured estimate is exactly 0 tokens (below threshold) — then the very
    // first turn's re-prime injection alone (dozens of chars) crosses it.
    spine.set_context_budget(1000, 0.001);
    assert_eq!(spine.context_estimate_tokens(), 0, "nothing sent yet");
    assert!(!spine.watermark_reached(), "0 tokens is below a 1-token threshold");

    spine.submit_prompt("hello", Source::Text).unwrap();

    assert_eq!(spine.rotation_count(), 1, "watermark crossing scheduled a rotation automatically");
    assert_eq!(spine.last_rotation_reason(), Some("context-watermark"));
    let _ = std::fs::remove_file(&path);
}

#[test]
fn context_estimate_is_measured_not_asserted() {
    // The voice engineer's discipline: show the frame math, don't trust it (precedent:
    // independently re-derive `313 × 256 ÷ 16000 = 5.008s` rather than trusting a
    // comment). Rather than re-deriving the priming text's length by a SEPARATE call
    // (which can drift from what the spine actually computed, since re-prime assembly
    // depends on exact ledger state at injection time), read the EXACT text the spine
    // actually sent — captured by the mock's `reprimes` log — and measure THAT.
    let (path, ledger) = tmp_ledger("context-math");
    let mut spine = Spine::new(ledger);
    spine.create_thread("General", &femcboost()).unwrap();

    let reply = "exactly forty chars in this canned reply!!"; // length MEASURED below, not assumed
    let mock = MockCognition::new("sess-1", vec![reply]);
    let reprimes = mock.reprimes.clone();
    spine.attach_lease(Box::new(mock));
    let prompt_text = "hi";
    spine.submit_prompt(prompt_text, Source::Text).unwrap();

    let sent_priming_text = reprimes.lock().unwrap()[0].clone();

    // MEASURED formula (spine.rs `deliver`/`prime_lease_if_needed`): context_chars =
    // len(priming text ACTUALLY injected) + len(prompt) + len(reply). Token estimate =
    // chars / 4 (CHARS_PER_TOKEN_ESTIMATE — an estimate, shown not asserted).
    let expected_chars = sent_priming_text.len() + prompt_text.len() + reply.len();
    let expected_tokens = expected_chars / 4;

    assert_eq!(
        spine.context_estimate_tokens(),
        expected_tokens,
        "measured token estimate must equal chars/4 over EXACTLY (the priming text actually \
         sent + prompt + reply) — priming_len={}, prompt_len={}, reply_len={}",
        sent_priming_text.len(),
        prompt_text.len(),
        reply.len()
    );

    // And the load-bearing claim this whole mechanism exists for: the estimate is NEVER
    // just "this turn's prompt+reply" — it must include the re-prime payload too, or the
    // watermark would systematically under-count and rotation would fire too late.
    let naive_wrong_estimate = (prompt_text.len() + reply.len()) / 4;
    assert!(
        spine.context_estimate_tokens() > naive_wrong_estimate,
        "context estimate must include the re-prime payload, not just this turn's prompt+reply \
         (got {} tokens, naive-wrong estimate would be {naive_wrong_estimate})",
        spine.context_estimate_tokens()
    );
    let _ = std::fs::remove_file(&path);
}

#[test]
fn rotation_re_primes_the_successor_with_identity_and_the_action_ledger() {
    // The mechanism behind done-criterion (b), "no false attribution": EVERY successor
    // is re-primed BEFORE its first CEO-visible turn, and the re-prime text carries the
    // action ledger as ground truth. Verify this lands on the ACTUAL spawned successor
    // lease (via MockLeaseFactory's per-spawn reprime log), not just on the payload
    // object in isolation.
    let (path, mut ledger) = tmp_ledger("attribution-rotation");
    let thread = ledger.create_thread("General", &femcboost()).unwrap();
    let turn = ledger.record_prompt_received(&ledger.thread_binding(&thread).unwrap(), "dispatch a worker", Source::Text).unwrap();
    ledger.record_action(&turn, "dispatch", "spawned worker mark-sonnet-f1").unwrap();

    let mut spine = Spine::new(ledger);
    spine.switch_thread(&thread).unwrap();
    spine.attach_lease(Box::new(MockCognition::new("sess-initial", vec!["ack"])));
    let factory = MockLeaseFactory::new(vec!["ack2"]);
    let spawned_reprimes = factory.spawned.clone();
    spine.set_lease_factory(Box::new(factory));

    spine.request_rotation("test").unwrap();
    assert_eq!(spine.rotation_count(), 1);

    let per_spawn_reprimes = spawned_reprimes.lock().unwrap();
    assert_eq!(per_spawn_reprimes.len(), 1, "exactly one successor lease was spawned");
    let successor_reprimes = per_spawn_reprimes[0].lock().unwrap();
    assert_eq!(successor_reprimes.len(), 1, "the successor was re-primed exactly once, before any CEO turn");
    let priming_text = &successor_reprimes[0];
    assert!(priming_text.contains("You are Rich"), "identity assertion present");
    assert!(priming_text.contains("NO DENIAL FROM ABSENT MEMORY"), "anti-false-attribution rule present");
    assert!(
        priming_text.contains("spawned worker mark-sonnet-f1"),
        "the action ledger (ground truth) is in the successor's re-prime, not just the predecessor's memory"
    );
    let _ = std::fs::remove_file(&path);
}

#[test]
fn clean_rotation_asks_the_outgoing_lease_for_a_self_authored_handoff_summary() {
    // continuity §2.4: "before tearing down the outgoing session at a turn boundary, the
    // app asks it for a self-authored handoff summary" — one cheap INTERNAL turn, never
    // rendered. Confirm the outgoing lease was prompted, the summary text is what the
    // successor's re-prime carries (via handoff_summary upgrading rolling_summary), and
    // the internal ask never appears in the CEO-visible conversation.
    let (path, ledger) = tmp_ledger("handoff-summary");
    let mut spine = Spine::new(ledger);
    let thread = spine.create_thread("General", &femcboost()).unwrap();

    let outgoing = MockCognition::new("sess-outgoing", vec!["the CEO's own reply", "We discussed the Acme deal and Q4 hiring."]);
    let outgoing_prompts = outgoing.prompts.clone();
    spine.attach_lease(Box::new(outgoing));
    let factory = MockLeaseFactory::new(vec!["ack from successor"]);
    spine.set_lease_factory(Box::new(factory));

    spine.submit_prompt("what's the Acme status?", Source::Text).unwrap();
    spine.request_rotation("test").unwrap();

    // The outgoing lease was asked TWO things: the CEO's real turn, then the internal
    // handoff-summary request (in that order).
    let prompts = outgoing_prompts.lock().unwrap().clone();
    assert_eq!(prompts.len(), 2);
    assert!(prompts[1].contains("summarize this conversation"), "handoff summary was requested");

    // The internal ask + its reply are durable (ledger.turns()) but NEVER rendered.
    let msgs = spine.messages(&thread).unwrap();
    assert!(msgs.iter().all(|m| !m.text.contains("We discussed the Acme deal")), "internal handoff turn is not CEO-visible");
    assert!(spine
        .ledger()
        .turns()
        .iter()
        .any(|t| t.source == Source::Internal && t.assistant_text.contains("We discussed the Acme deal")));

    // And it became the ROLLING SUMMARY the successor carries forward (continuity §2.4:
    // "upgrade to a self-authored summary on clean rotation").
    assert_eq!(spine.ledger().handoff_summary(&thread), Some("We discussed the Acme deal and Q4 hiring."));
    let _ = std::fs::remove_file(&path);
}

// ============================================================================
// Mid-turn-crash recovery (continuity §5, done-criterion (c))
// ============================================================================

#[test]
fn mid_turn_crash_recovers_and_replays_without_duplicating_the_message() {
    // The child dies mid-turn (a positive signal — a partial chunk then Err, never
    // inferred from silence). A lease factory is attached, so the spine automatically
    // respawns, re-primes, and RE-SERVES the CEO's original prompt — done-criterion (c),
    // "the CEO's prompt is provably never lost." Also verifies the render stays CLEAN:
    // one exchange, not a duplicate of the failed attempt.
    let (path, ledger) = tmp_ledger("crash-recovery");
    let mut spine = Spine::new(ledger);
    let thread = spine.create_thread("General", &femcboost()).unwrap();
    spine.attach_lease(Box::new(FailingCognition { session_id: "sess-doomed".into() }));
    spine.set_lease_factory(Box::new(MockLeaseFactory::new(vec!["I'm back — here's your answer."])));

    let observer = RecordingObserver::default();
    spine.set_observer(Box::new(observer.clone()));

    // submit_prompt is TRANSPARENT: the crash + recovery happen inside this ONE call,
    // and it still returns Ok because the replay succeeded.
    let result = spine.submit_prompt("what's my Q3 revenue?", Source::Text);
    assert!(result.is_ok(), "recovery succeeded, so the CEO's call never surfaces a hard error");

    assert_eq!(spine.rotation_count(), 1);
    assert_eq!(spine.last_rotation_reason(), Some("mid-turn-crash"));
    assert!(!spine.is_turn_in_progress(), "turn boundary is clear again after recovery");

    // CLEAN OUTPUT: exactly ONE user+assistant pair, not two — the failed attempt is
    // superseded, not re-shown.
    let msgs = spine.messages(&thread).unwrap();
    assert_eq!(msgs.len(), 2, "no duplicate exchange from the failed attempt");
    assert_eq!(msgs[0].role, "user");
    assert_eq!(msgs[0].text, "what's my Q3 revenue?");
    assert_eq!(msgs[1].role, "assistant");
    assert_eq!(msgs[1].text, "I'm back — here's your answer.");

    // But the CRASH RECORD is still durable in the raw ledger (never edited in place) —
    // "provably never lost" means provable, not just asserted.
    let raw_turns = spine.ledger().turns();
    let failed = raw_turns
        .iter()
        .find(|t| t.user_text == "what's my Q3 revenue?" && t.state == TurnState::Interrupted)
        .expect("the interrupted attempt is still in the durable ledger");
    assert_eq!(failed.assistant_text, "partial before the lease dies");
    assert!(failed.superseded_by.is_some(), "marked superseded, not deleted");
    let replay = raw_turns.iter().find(|t| t.id == *failed.superseded_by.as_ref().unwrap()).unwrap();
    assert_eq!(replay.state, TurnState::Completed);
    assert_eq!(replay.assistant_text, "I'm back — here's your answer.");

    // A calm reconnect cue was ALSO emitted (the UI's job — main.js renders this as an
    // ephemeral "lost my train of thought" bubble, never a stack trace).
    assert!(observer.events().iter().any(|e| matches!(e, StreamEvent::TurnError { .. })));
    let _ = std::fs::remove_file(&path);
}

#[test]
fn mid_turn_crash_without_a_lease_factory_degrades_to_an_honest_error() {
    // No factory attached => no way to respawn => the failure surfaces honestly rather
    // than silently vanishing or hanging. (The always-there floor beneath automatic
    // recovery.)
    let (path, ledger) = tmp_ledger("crash-no-factory");
    let mut spine = Spine::new(ledger);
    spine.create_thread("General", &femcboost()).unwrap();
    spine.attach_lease(Box::new(FailingCognition { session_id: "sess-doomed".into() }));
    // Deliberately NOT calling set_lease_factory.

    let result = spine.submit_prompt("hello", Source::Text);
    assert!(result.is_err(), "with no recovery path, the crash must surface, never be swallowed");
    assert_eq!(spine.rotation_count(), 0, "no recovery was attempted without a factory");
    let _ = std::fs::remove_file(&path);
}

#[test]
fn mid_turn_crash_recovery_is_bounded_to_one_attempt() {
    // If the FRESH lease ALSO dies immediately, the spine must not loop forever — one
    // recovery attempt, then an honest failure (positive-signal doctrine: never infer,
    // never spin).
    let (path, ledger) = tmp_ledger("crash-loop-bound");
    let mut spine = Spine::new(ledger);
    spine.create_thread("General", &femcboost()).unwrap();
    spine.attach_lease(Box::new(FailingCognition { session_id: "sess-doomed-1".into() }));
    let spawn_count = Arc::new(Mutex::new(0u64));
    spine.set_lease_factory(Box::new(AlwaysFailingLeaseFactory { spawn_count: spawn_count.clone() }));

    let result = spine.submit_prompt("hello", Source::Text);
    assert!(result.is_err(), "the replay also failed, so this must surface, not hang");
    assert_eq!(*spawn_count.lock().unwrap(), 1, "exactly ONE respawn was attempted, not an infinite loop");
    assert_eq!(spine.rotation_count(), 1, "the one attempted recovery is still recorded");
    let _ = std::fs::remove_file(&path);
}

// ============================================================================
// The proactive-attention seam (persistence + UI event; judgment is a LATER leg)
// ============================================================================

#[test]
fn proactive_tier1_and_tier2_render_as_rich_only_messages_no_preceding_ceo_prompt() {
    let (path, ledger) = tmp_ledger("proactive-render");
    let mut spine = Spine::new(ledger);
    let thread = spine.create_thread("General", &femcboost()).unwrap();

    spine
        .raise_proactive(None, AttentionTier::InterruptNow, "The Acme counter expires at noon — what's your floor?")
        .unwrap();
    spine
        .raise_proactive(None, AttentionTier::Digest, "Morning brief: three things need your attention.")
        .unwrap();

    let msgs = spine.messages(&thread).unwrap();
    assert_eq!(msgs.len(), 2, "both tiers render; NO paired user message (nothing was prompted)");
    assert!(msgs.iter().all(|m| m.role == "assistant"));
    assert_eq!(msgs[0].text, "The Acme counter expires at noon — what's your floor?");
    assert_eq!(msgs[1].text, "Morning brief: three things need your attention.");
    let _ = std::fs::remove_file(&path);
}

#[test]
fn proactive_silent_tier_never_renders_but_stays_durable() {
    // UX §5.1 Tier 3: "Does not appear in the conversation and never notifies." But it
    // must still be durably logged (a CEO who goes looking, or a future activity view).
    let (path, ledger) = tmp_ledger("proactive-silent");
    let mut spine = Spine::new(ledger);
    let thread = spine.create_thread("General", &femcboost()).unwrap();

    let observer = RecordingObserver::default();
    spine.set_observer(Box::new(observer.clone()));

    spine.raise_proactive(None, AttentionTier::Silent, "FYI: renewed the Acme NDA, nothing needed from you.").unwrap();

    assert!(spine.messages(&thread).unwrap().is_empty(), "Silent tier has NO render path");
    assert!(observer.events().is_empty(), "Silent tier never notifies — no live UI event either");
    // But it's not lost — durable in the raw ledger.
    assert!(spine
        .ledger()
        .turns()
        .iter()
        .any(|t| t.assistant_text.contains("renewed the Acme NDA")));
    let _ = std::fs::remove_file(&path);
}

#[test]
fn proactive_message_raised_mid_turn_is_durable_immediately_but_ui_event_waits_for_the_boundary() {
    // Never collide with the "Rich is working" row: the WRITE is immediate/durable
    // (never lost), but the live-UI-visible event is deferred until the turn boundary
    // clears. This spine is fully synchronous/single-threaded (module doc), so the test
    // uses the documented test-only seam to force the in-flight state deterministically.
    let (path, ledger) = tmp_ledger("proactive-deferred");
    let mut spine = Spine::new(ledger);
    let thread = spine.create_thread("General", &femcboost()).unwrap();
    spine.attach_lease(Box::new(MockCognition::new("sess-1", vec!["a reply"])));

    let observer = RecordingObserver::default();
    spine.set_observer(Box::new(observer.clone()));

    spine.debug_set_turn_in_progress(true);
    let proactive_turn_id = spine.raise_proactive(None, AttentionTier::Digest, "queued while busy").unwrap();
    assert!(observer.events().is_empty(), "no live event fires while a turn is (simulated) in flight");
    // But durability doesn't wait for the boundary.
    assert_eq!(spine.messages(&thread).unwrap().len(), 1, "the message is already durable/readable");
    spine.debug_set_turn_in_progress(false);

    // Drive a REAL turn boundary — its own after_turn_boundary() flushes the deferred emit.
    spine.submit_prompt("hi", Source::Text).unwrap();

    let events = observer.events();
    assert!(
        events.iter().any(|e| matches!(
            e,
            StreamEvent::ProactiveMessage { turn_id, .. } if turn_id == &proactive_turn_id
        )),
        "the deferred proactive event was flushed at the next turn boundary"
    );
    let _ = std::fs::remove_file(&path);
}

#[test]
fn proactive_message_defaults_to_active_thread_when_none_given() {
    let (path, ledger) = tmp_ledger("proactive-default-thread");
    let mut spine = Spine::new(ledger);
    let thread = spine.create_thread("General", &femcboost()).unwrap();
    spine.raise_proactive(None, AttentionTier::Digest, "hello").unwrap();
    assert_eq!(spine.messages(&thread).unwrap().len(), 1);
    let _ = std::fs::remove_file(&path);
}
