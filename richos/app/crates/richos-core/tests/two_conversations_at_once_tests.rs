//! **TWO CONVERSATIONS WITH TURNS OPEN AT THE SAME TIME, BOTH CHECKPOINTING.**
//!
//! The CEO's Two Riches spec: *"a CEO can create a conversation thread (i.e. any number of
//! conversation threads) … the CEO could open and run multiple things in parallel."*
//!
//! This suite drives the REAL engine — the same `EcsBridge` the app's conversation lease
//! uses, over the delivered `ecs` component, with no double in the path. It is the app's
//! half of the per-thread CEO cursor that landed engine-side at `5cee0cf4`; the engine's own
//! tests prove the store's behavior, and these prove the APP names the seat the engine
//! derives, carries it on every call, and asks before assuming it is there.
//!
//! **Every positive here has the old behavior as its negative control, in the same test.**
//! Two threads checkpointing successfully proves nothing on its own — an engine that had
//! stopped fencing would also pass. So each one runs the identical sequence on the legacy
//! single cursor and requires it to FAIL, which is what makes the passing half evidence.
use richos_core::ecs::{ceo_seat, EcsBridge, CEO_SEAT_PREFIX};
use serde_json::json;
use std::path::{Path, PathBuf};
use std::process::Command;

struct Fixture(PathBuf);
impl Drop for Fixture {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

fn fixture() -> (Fixture, EcsBridge) {
    let dir = std::env::temp_dir().join(format!("richos two conversations {}", uuid::Uuid::new_v4()));
    std::fs::create_dir_all(&dir).unwrap();
    let out = Command::new("python3").args(["-c", "import sys; print(sys.executable)"]).output().unwrap();
    assert!(out.status.success());
    let python = PathBuf::from(String::from_utf8(out.stdout).unwrap().trim());
    let engine = Path::new(env!("CARGO_MANIFEST_DIR")).ancestors().nth(3).unwrap().join("engine");
    let bridge = EcsBridge::new(&python, &engine, &dir.join("state")).unwrap();
    (Fixture(dir), bridge)
}

fn commitment(id: &str, title: &str) -> serde_json::Value {
    json!({"verb":"commitment","fields":{"id":id,"title":title}})
}

/// **THE HEADLINE, and the exact sequence that used to dead-letter a turn.**
///
/// Thread A opens a turn, thread B opens a turn while A's is still open, and THEN A writes
/// its checkpoint. On the single cursor, B's bind upserted A's row and A's checkpoint was
/// refused with *"stale app binding"* — a `ScopeError`, which `with_fresh_active_fence`
/// never retries, so his whole turn was lost before it was observed.
#[test]
fn two_conversations_hold_turns_open_at_once_and_both_check_point() {
    let (_fixture, bridge) = fixture();
    let (one, two) = ("thread-pricing", "thread-hiring");
    let seat_one = ceo_seat(one).unwrap();
    let seat_two = ceo_seat(two).unwrap();

    // Both turns open. B binds INSIDE A's turn, which is the collision.
    let first = bridge.bind("depot", one, "session-a", "turn-a", Some(&seat_one), "ceo").unwrap();
    let second = bridge.bind("depot", two, "session-b", "turn-b", Some(&seat_two), "ceo").unwrap();

    // A check points after B bound — the call that used to be refused.
    let a = bridge.request("checkpoint", json!({"binding":first,"seat":seat_one,"request_id":"a",
        "checkpoint":{"statements":[commitment("pricing","Finish the pricing review")]}})).unwrap();
    assert_eq!(a["accepted"], true, "the first conversation's checkpoint was refused after the second bound");
    let b = bridge.request("checkpoint", json!({"binding":second,"seat":seat_two,"request_id":"b",
        "checkpoint":{"statements":[commitment("hiring","Shortlist the two candidates")]}})).unwrap();
    assert_eq!(b["accepted"], true);

    // Each conversation's brief is its own, read on its own seat, with both turns still open.
    let brief_one = bridge.brief(&first, Some(&seat_one)).unwrap();
    let brief_two = bridge.brief(&second, Some(&seat_two)).unwrap();
    assert!(brief_one.contains("Finish the pricing review"));
    assert!(!brief_one.contains("Shortlist"), "one conversation's brief carried the other's work");
    assert!(brief_two.contains("Shortlist the two candidates"));
    assert!(!brief_two.contains("pricing review"));

    // **THE NEGATIVE CONTROL: the identical sequence on the legacy single cursor.** Without
    // this, everything above would also pass on an engine that had simply stopped fencing.
    let legacy_one = bridge.bind("depot", one, "session-c", "turn-c", None, "ceo").unwrap();
    let _legacy_two = bridge.bind("depot", two, "session-d", "turn-d", None, "ceo").unwrap();
    let refused = bridge.request("checkpoint", json!({"binding":legacy_one,"request_id":"c",
        "checkpoint":{"statements":[commitment("pricing-legacy","Finish the pricing review")]}}));
    assert!(refused.is_err(), "the single cursor no longer collides, so this suite proves nothing");
    assert!(bridge.brief(&legacy_one, None).is_err(), "the superseded single-cursor binding still reads");
}

/// A thread's seat is its OWN and is named by derivation on both sides. The app spells it;
/// the engine re-derives it from the row's own thread and refuses a CEO-shaped seat that
/// names a different one (`engine/ecs/core/ecs_core.py:196-213`).
#[test]
fn a_ceo_shaped_seat_that_names_another_thread_is_refused() {
    let (_fixture, bridge) = fixture();
    let borrowed = format!("{CEO_SEAT_PREFIX}thread-pricing");
    // Binding thread-hiring on thread-pricing's seat: the derivation disagrees with the row.
    let bound = bridge.bind("depot", "thread-hiring", "session-a", "turn-a", Some(&borrowed), "ceo");
    let refused = match &bound {
        Err(_) => true,
        // If the bind is accepted, the checkpoint must not be: either refusal is the
        // engine's to choose, and this suite asserts the OUTCOME rather than the site.
        Ok(binding) => bridge.request("checkpoint", json!({"binding":binding,"seat":borrowed,"request_id":"x",
            "checkpoint":{"statements":[commitment("x","Borrowed seat")]}})).is_err(),
    };
    assert!(refused, "a conversation bound another conversation's seat and wrote to it");

    // Positive control: the same thread on its OWN derived seat is accepted and writes.
    let own = ceo_seat("thread-hiring").unwrap();
    let binding = bridge.bind("depot", "thread-hiring", "session-b", "turn-b", Some(&own), "ceo").unwrap();
    assert_eq!(
        bridge.request("checkpoint", json!({"binding":binding,"seat":own,"request_id":"y",
            "checkpoint":{"statements":[commitment("hiring","Shortlist the two candidates")]}})).unwrap()["accepted"],
        true
    );
}

/// The capability is read from `hello` rather than inferred, and the delivered engine
/// answers it. **This is the assertion that the app and the engine agree on the SPELLING**,
/// which is the one thing a derived-on-both-sides name can get wrong.
#[test]
fn the_delivered_engine_answers_the_per_thread_seat_capability_and_its_prefix() {
    let (_fixture, bridge) = fixture();
    assert!(bridge.supports_ceo_thread_seats(), "the delivered engine does not hold one cursor per thread");
    let hello = bridge.request("hello", json!({})).unwrap();
    assert_eq!(hello["ceo_thread_seats"], true);
    assert_eq!(hello["ceo_seat_prefix"].as_str(), Some(CEO_SEAT_PREFIX),
        "the app and the engine derive his seat from the same thread id and spell it differently");
}

/// An engine that cannot answer at all is a `false`, never a guess — and `false` means the
/// legacy cursor, which still works for one conversation at a time.
#[test]
fn an_unreachable_engine_answers_no_rather_than_assuming_support() {
    let (_fixture, bridge) = fixture();
    let mut broken = bridge.clone();
    broken.python = PathBuf::from("/fictional/python3");
    assert!(!broken.supports_ceo_thread_seats());
    // Positive control: the same call on the real bridge answers yes, so the `false` above
    // is about the transport rather than about a probe that can only ever say no.
    assert!(bridge.supports_ceo_thread_seats());
}

/// His seat is one row per thread, and the row belongs to the thread rather than to the
/// session: a new session on the same thread takes the same seat back, which is what makes
/// a front desk that was re-primed after a crash still HIS front desk for that thread.
#[test]
fn a_new_session_on_the_same_thread_takes_that_threads_seat_back() {
    let (_fixture, bridge) = fixture();
    let seat = ceo_seat("thread-pricing").unwrap();
    let first = bridge.bind("depot", "thread-pricing", "session-a", "turn-a", Some(&seat), "ceo").unwrap();
    bridge.request("checkpoint", json!({"binding":first,"seat":seat,"request_id":"a",
        "checkpoint":{"statements":[commitment("pricing","Finish the pricing review")]}})).unwrap();

    let restarted = bridge.bind("depot", "thread-pricing", "session-b", "turn-b", Some(&seat), "ceo").unwrap();
    assert!(bridge.brief(&restarted, Some(&seat)).unwrap().contains("Finish the pricing review"));
    // And the superseded binding is stale on its own seat, exactly as it always was on the
    // single cursor: residency is about the THREAD's row, not about an old turn staying live.
    assert!(bridge.brief(&first, Some(&seat)).is_err());
}
