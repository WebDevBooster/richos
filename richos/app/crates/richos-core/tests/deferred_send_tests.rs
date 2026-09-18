//! **A Send issued while the front desk is being primed does not wait for the spine** —
//! the CEO's ruling §55, 2026-09-18.
//!
//! *"Rich **immediately** replies with: "On it!" and only after that does all that work."* …
//! *"Yes, a few seconds is fine. But 35 seconds of waiting for the first response is not."*
//!
//! # The measurement, and the half of it these tests can and cannot make true
//!
//! `docs/verification/first-words-2026-09-18-toolsearch.md` §4 decomposed Ray's measurement 1
//! on candidate .10 — "On it!" on the window at **+12 s** — as **≈5 s before the turn started
//! plus ≈7 s of turn**, the ≈7 s matching run E's 5.995 s in process. The ≈5 s is the spine's
//! mutex: `ready_the_front_desk` (`src-tauri/src/main.rs`) holds it for the whole of
//! `Spine::prime_front_desk`, and `send_message` opens by taking the same mutex. That run's
//! `app.log` logged the prime at **4412 ms** and Ray typed into the brand-new thread straight
//! away, so his Send blocked for the remainder of it with the window honestly reading
//! *"Sending your message / Waiting for Rich to accept it"*.
//!
//! **WHAT REMOVING THE BLOCK DOES NOT DO, stated first so no test here is read as claiming
//! it.** It does not make his first words arrive sooner, and no arrangement of this code can.
//! The priming is a MODEL TURN and the lease is serial — one turn at a time is continuity
//! design §3.1, enforced everywhere in `spine.rs` — so his prompt reaches the provider when
//! the priming turn ends, whether it waited on a mutex or on the intake log. The contended
//! cost is `prime_remainder + turn` under either shape, and it is not paid twice over
//! (`prime_lease_if_needed` returns early for a thread already primed, `spine.rs`). Recovering
//! those seconds needs a desk that was ALREADY primed when the thread opened; that is a
//! different slice and it is named in the record rather than pretended at here.
//!
//! # What these tests do pin, all of it observable and none of it a threshold
//!
//! 1. The Send is ACCEPTED while the spine is provably shut — `Mutex::try_lock` fails at the
//!    same instant the deferral succeeds.
//! 2. His sentence is `fsync`'d DURABLE before the accepting call returns, read back by a
//!    second reader. Today it lives only in the webview for the length of the prime, and
//!    quitting in that window loses it without a trace.
//! 3. It is handed to the lease EXACTLY ONCE, after the prime, in order, with no second
//!    priming turn.
//! 4. It lands through the same acceptance every typed message gets — so a correction he
//!    types during a prime is still staged.
//! 5. When nothing is priming, the deferral refuses and the caller takes the ordinary path.
//!    `None` is never a loss.
//!
//! Everything below is headless: no provider, no network, no model turn. The wall-clock
//! numbers belong to `examples/first_reply_timing_e2e.rs`.

use richos_core::cognition::{Cognition, CognitionError, TurnItem};
use richos_core::entity::EntityId;
use richos_core::ledger::{Ledger, Source};
use richos_core::spine::{FrontDeskReady, Spine};
use richos_core::staging::CandidateDesk;
use richos_core::steering::{IntakeLog, IntakeRecord, SteeringError, TurnControl};
use std::sync::{Arc, Condvar, Mutex};
use std::time::{Duration, Instant};

mod support;

fn femcboost() -> EntityId {
    EntityId::parse("femcboost").unwrap()
}

fn tmp_path(tag: &str) -> std::path::PathBuf {
    let p = std::env::temp_dir().join(format!(
        "richos-deferred-send-{tag}-{}-{}.jsonl",
        std::process::id(),
        richos_core::util::now_millis()
    ));
    let _ = std::fs::remove_file(&p);
    p
}

// -------------------------------------------------------------------------------------
// A LEASE WHOSE PRIMING TURN ACTUALLY TAKES TIME
// -------------------------------------------------------------------------------------

/// A one-shot latch: `raise` once, `wait` from anywhere, never lost if the raise came first.
#[derive(Clone, Default)]
struct Latch(Arc<(Mutex<bool>, Condvar)>);

impl Latch {
    fn raise(&self) {
        let (lock, cond) = &*self.0;
        *lock.lock().unwrap() = true;
        cond.notify_all();
    }

    /// Blocks until raised. Bounded, so a broken build fails the test instead of hanging the
    /// suite — a test that never returns is indistinguishable from a machine that is busy.
    fn wait(&self, within: Duration) {
        let (lock, cond) = &*self.0;
        let mut raised = lock.lock().unwrap();
        let deadline = Instant::now() + within;
        while !*raised {
            let left = deadline.saturating_duration_since(Instant::now());
            assert!(!left.is_zero(), "the latch was never raised within {within:?}");
            let (next, _) = cond.wait_timeout(raised, left).unwrap();
            raised = next;
        }
    }
}

/// **The lease the app actually has during a pre-prime, for as long as the test wants it.**
///
/// `MockCognition::reprime` returns instantly, so with it there is no window to send into and
/// the contended case cannot exist. This one announces that its priming turn has started and
/// then blocks inside `reprime` until the test releases it — which is exactly the shape of the
/// real thing: `prepare_request` is inside the caller's `MutexGuard`, so while `reprime` is
/// running the spine is shut to everybody.
struct SlowPrimingLease {
    session_id: String,
    reply: String,
    priming_started: Latch,
    release_priming: Latch,
    reprimes: Arc<Mutex<Vec<String>>>,
    prompts: Arc<Mutex<Vec<String>>>,
}

impl Cognition for SlowPrimingLease {
    fn session_id(&self) -> &str {
        &self.session_id
    }

    fn reprime(&mut self, priming_text: &str, _on_item: &mut dyn FnMut(TurnItem)) -> Result<(), CognitionError> {
        self.reprimes.lock().unwrap().push(priming_text.to_string());
        self.priming_started.raise();
        self.release_priming.wait(Duration::from_secs(10));
        Ok(())
    }

    fn prompt(&mut self, text: &str, on_item: &mut dyn FnMut(TurnItem)) -> Result<String, CognitionError> {
        self.prompts.lock().unwrap().push(text.to_string());
        on_item(TurnItem::Text { seq: 0, text: &self.reply });
        Ok("end_turn".to_string())
    }
}

/// Everything a contended send needs: a spine behind the mutex the shell holds it behind, a
/// durable intake log, one thread, and a lease whose priming turn can be held open.
struct Contended {
    spine: Arc<Mutex<Spine>>,
    control: TurnControl,
    thread: String,
    priming_started: Latch,
    release_priming: Latch,
    reprimes: Arc<Mutex<Vec<String>>>,
    prompts: Arc<Mutex<Vec<String>>>,
    paths: Vec<std::path::PathBuf>,
}

impl Contended {
    fn open(tag: &str, reply: &str) -> Contended {
        let ledger_path = tmp_path(&format!("{tag}-ledger"));
        let intake_path = tmp_path(&format!("{tag}-intake"));
        let mut spine = support::spine(Ledger::open(&ledger_path).unwrap());
        let thread = spine.create_thread("Running", &femcboost()).unwrap();
        spine.switch_thread(&thread).unwrap();
        let control = TurnControl::open(&intake_path).unwrap();
        spine.set_turn_control(control.clone());

        let priming_started = Latch::default();
        let release_priming = Latch::default();
        let reprimes: Arc<Mutex<Vec<String>>> = Arc::default();
        let prompts: Arc<Mutex<Vec<String>>> = Arc::default();
        spine.attach_lease(Box::new(SlowPrimingLease {
            session_id: "sess-one".to_string(),
            reply: reply.to_string(),
            priming_started: priming_started.clone(),
            release_priming: release_priming.clone(),
            reprimes: reprimes.clone(),
            prompts: prompts.clone(),
        }));

        Contended {
            spine: Arc::new(Mutex::new(spine)),
            control,
            thread,
            priming_started,
            release_priming,
            reprimes,
            prompts,
            paths: vec![ledger_path, intake_path],
        }
    }

    /// `ready_the_front_desk`'s own shape: a background thread that takes the spine's mutex
    /// and holds it for the whole of `prime_front_desk`. Returns once the priming turn is
    /// genuinely under way, which is the only moment a "contended" send means anything.
    fn start_priming(&self) -> std::thread::JoinHandle<FrontDeskReady> {
        let spine = self.spine.clone();
        let thread = self.thread.clone();
        let handle = std::thread::spawn(move || spine.lock().unwrap().prime_front_desk(&thread));
        self.priming_started.wait(Duration::from_secs(10));
        handle
    }

    fn ceo_turns(&self) -> Vec<String> {
        let spine = self.spine.lock().unwrap();
        let binding = spine.ledger().thread_binding(&self.thread).unwrap();
        spine
            .ledger()
            .thread_turns_scoped(&binding)
            .unwrap()
            .into_iter()
            .filter(|t| t.source == Source::Text)
            .map(|t| t.user_text.clone())
            .collect()
    }
}

impl Drop for Contended {
    fn drop(&mut self) {
        // Never leave a priming thread parked on the latch, whatever a failing assertion did
        // to the rest of the test (CEO §54: whatever this makes, it cleans up).
        self.release_priming.raise();
        for p in &self.paths {
            let _ = std::fs::remove_file(p);
        }
    }
}

// -------------------------------------------------------------------------------------
// THE ONE THIS SLICE EXISTS FOR
// -------------------------------------------------------------------------------------

#[test]
fn his_send_is_accepted_while_the_spine_is_shut_for_the_pre_prime() {
    // **THE WHOLE SLICE, AS ONE SEQUENCE.** The spine is provably locked, and the Send is
    // taken anyway — in the time one `fsync` costs rather than the remainder of a model turn.
    let c = Contended::open("accepted-while-shut", "On it!");
    let priming = c.start_priming();

    // The premise, asserted rather than assumed: the mutex `send_message` opens by taking is
    // held right now. Without this line the rest of the test would pass on an uncontended
    // spine and prove nothing at all.
    assert!(
        c.spine.try_lock().is_err(),
        "the pre-prime is supposed to be holding the spine — there is no contention to test"
    );
    assert_eq!(c.control.front_desk_priming().as_deref(), Some(c.thread.as_str()));

    let asked_at = Instant::now();
    let deferred = c
        .control
        .defer_send(&c.thread, Some(femcboost()), "Land the pricing branch and get the staging deploy done.")
        .unwrap();
    let waited = asked_at.elapsed();

    let record = deferred.expect("a send during the pre-prime must be accepted, not blocked");
    assert!(matches!(record, IntakeRecord::Desk { .. }), "a typed message is a desk record: {record:?}");
    // NOT A TUNED THRESHOLD. The thing being distinguished is "one local `fsync`" from "the
    // remainder of a model turn": the prime this test is holding open cannot end until the
    // latch is released, so anything that completes at all here completed without waiting for
    // it. The bound is generous on purpose — it is a smoke alarm for a re-introduced block,
    // not a performance budget.
    assert!(waited < Duration::from_secs(1), "the send waited {waited:?} — it is back on the lock");
    assert!(c.spine.try_lock().is_err(), "and the spine was still shut when it returned");

    // Nothing has been said to the provider except the priming payload.
    assert_eq!(c.reprimes.lock().unwrap().len(), 1);
    assert!(c.prompts.lock().unwrap().is_empty(), "his words must not reach a lease mid-prime (§3.1)");

    // Let the prime finish. `prime_front_desk` closes the road and drains it before it returns,
    // so by the time the handle joins his message has been delivered.
    c.release_priming.raise();
    let verdict = priming.join().unwrap();
    assert!(matches!(verdict, FrontDeskReady::Ready { .. }), "{verdict:?}");

    assert_eq!(c.reprimes.lock().unwrap().len(), 1, "his message must not have primed a desk that was ready");
    assert_eq!(
        *c.prompts.lock().unwrap(),
        vec!["Land the pricing branch and get the staging deploy done."],
        "his message reaches the lease exactly once, after the prime"
    );
    assert_eq!(c.ceo_turns(), vec!["Land the pricing branch and get the staging deploy done."]);
    assert_eq!(c.control.front_desk_priming(), None, "the road must be shut again");
    assert!(c.control.pending_intake().is_empty(), "a delivered record is marked drained");
}

#[test]
fn his_words_are_on_disk_before_the_call_that_took_them_returns() {
    // §9.2's "persisted before delivery", applied to the one path that did not have it. The
    // observable form of the claim is a SECOND reader, opened after the write returned, that
    // can already see the bytes — not a flag, and not the fact that a function was called.
    //
    // What this closes: during a 4412 ms prime his sentence existed only in the webview, so
    // quitting RichOS in that window lost it silently. The composer's optimistic bubble is not
    // durability.
    let c = Contended::open("durable-before-return", "On it!");
    let priming = c.start_priming();
    let record = c
        .control
        .defer_send(&c.thread, Some(femcboost()), "Why has the nightly build been failing since Tuesday?")
        .unwrap()
        .expect("accepted");

    let reopened = IntakeLog::open(&c.paths[1]).unwrap();
    assert!(reopened.health().is_clean(), "{:?}", reopened.skipped_records());
    let pending = reopened.pending();
    assert_eq!(pending.len(), 1, "his sentence was not on disk when the call returned");
    match &pending[0] {
        IntakeRecord::Desk { id, thread_id, text, .. } => {
            assert_eq!(*id, record.id());
            assert_eq!(thread_id, &c.thread);
            assert_eq!(text, "Why has the nightly build been failing since Tuesday?");
        }
        other => panic!("wrong record type: {other:?}"),
    }

    c.release_priming.raise();
    priming.join().unwrap();
}

#[test]
fn two_sends_during_one_prime_arrive_in_the_order_he_typed_them() {
    // He can type twice into a four-second window, and the ORDER is the whole of what a
    // conversation is. The intake log's `id` is the ordering key and `drain_intake` walks it
    // oldest-first, so this is the existing machinery being pinned rather than a new promise.
    let c = Contended::open("in-order", "On it!");
    let priming = c.start_priming();
    let first = c.control.defer_send(&c.thread, Some(femcboost()), "first").unwrap().expect("accepted");
    let second = c.control.defer_send(&c.thread, Some(femcboost()), "second").unwrap().expect("accepted");
    assert!(second.id() > first.id(), "the ordering key must advance");

    c.release_priming.raise();
    priming.join().unwrap();

    assert_eq!(*c.prompts.lock().unwrap(), vec!["first", "second"]);
    assert_eq!(c.ceo_turns(), vec!["first", "second"]);
    assert_eq!(c.reprimes.lock().unwrap().len(), 1, "two messages, still one priming turn");
}

#[test]
fn a_deferred_send_becomes_exactly_one_turn_however_often_the_intake_is_drained() {
    // AT-LEAST-ONCE INTO A LEDGER THAT CAN SPOT THE REPLAY. The record is marked drained only
    // AFTER the ledger write, so a crash in between re-presents it — and `turn_for_intake`
    // then refuses the second filing. Draining repeatedly is the cheap, deterministic stand-in
    // for that crash, and it is the assertion that makes "exactly once" a fact rather than a
    // hope.
    let c = Contended::open("exactly-once", "On it!");
    let priming = c.start_priming();
    c.control.defer_send(&c.thread, Some(femcboost()), "only once please").unwrap().expect("accepted");
    c.release_priming.raise();
    priming.join().unwrap();

    for _ in 0..3 {
        c.spine.lock().unwrap().poll_intake().unwrap();
    }
    assert_eq!(*c.prompts.lock().unwrap(), vec!["only once please"]);
    assert_eq!(c.ceo_turns(), vec!["only once please"], "his one sentence became one turn");
}

#[test]
fn a_send_with_no_prime_running_is_refused_deferral_and_takes_the_ordinary_path() {
    // `Ok(None)` is the answer that means "use the road you always used", and it is the answer
    // for the overwhelming majority of sends. It is never a failure and never a loss: this
    // test sends the message the ordinary way straight afterwards and it lands.
    let c = Contended::open("no-prime-running", "On it!");
    assert_eq!(c.control.front_desk_priming(), None);
    let deferred = c.control.defer_send(&c.thread, Some(femcboost()), "nothing is priming").unwrap();
    assert!(deferred.is_none(), "an uncontended send must not be diverted through the log");
    assert!(c.control.pending_intake().is_empty(), "and nothing was written down");

    c.release_priming.raise(); // this test never primes; keep the lease from blocking
    c.spine.lock().unwrap().submit_prompt("nothing is priming", Source::Text).unwrap();
    assert_eq!(c.ceo_turns(), vec!["nothing is priming"]);
}

#[test]
fn a_send_for_a_different_thread_is_not_deferred_onto_the_one_being_primed() {
    // The marker names ONE thread. A message typed into a thread that is not the one being
    // primed has no reason to wait and, more importantly, must never be filed against the
    // thread that happens to be priming — that is the entity-boundary laundering
    // `Steer::thread_id`'s own comment refuses, in a new place.
    let c = Contended::open("other-thread", "On it!");
    let priming = c.start_priming();
    let deferred = c.control.defer_send("thr_somewhere_else", Some(femcboost()), "different thread").unwrap();
    assert!(deferred.is_none(), "only the thread being primed may defer");
    assert!(c.control.pending_intake().is_empty());
    c.release_priming.raise();
    priming.join().unwrap();
}

#[test]
fn a_control_with_nowhere_durable_to_write_refuses_rather_than_accepting_what_it_cannot_record() {
    // The same refusal `steer` and `request_stop` make, and for the same reason: accepting a
    // message that is not written down is worse than making the caller block, because the
    // caller's fallback path works and a silently dropped sentence does not.
    let control = TurnControl::detached();
    control.begin_front_desk_prime("thr_1");
    assert!(matches!(
        control.defer_send("thr_1", Some(femcboost()), "no log here"),
        Err(SteeringError::NoDurableIntake)
    ));
}

#[test]
fn a_correction_he_types_during_a_prime_is_staged_exactly_as_one_he_types_at_any_other_time() {
    // **THE REGRESSION THIS SLICE WOULD HAVE SHIPPED, PINNED SO IT CANNOT COME BACK.**
    //
    // `submit_prompt_inner`'s own comment calls it *"the ONE function every CEO utterance
    // passes through"*, and three correction families hang off that claim. `drain_intake`'s
    // `Steer` and `Channel` arms file the turn and stage NOTHING — today that only costs the
    // phone. Had a deferred desktop send been filed as a `Channel`, a correction he typed
    // during a front-desk prime would have vanished with no trace anywhere: the turn would
    // look perfectly normal and the flywheel would simply not have fired.
    //
    // So the `Desk` arm goes through `accept_prompt`, and this is the assertion that says so.
    // The correction and the misspelling are invented for the test.
    let dir = std::env::temp_dir().join(format!(
        "richos-deferred-correction-{}-{}",
        std::process::id(),
        richos_core::util::now_millis()
    ));
    std::fs::create_dir_all(&dir).unwrap();
    let mut spine = support::spine(Ledger::open(dir.join("ledger.jsonl")).unwrap());
    let thread = spine.create_thread("General", &femcboost()).unwrap();
    spine.switch_thread(&thread).unwrap();
    spine.attach_lease(Box::new(richos_core::cognition::MockCognition::new(
        "sess-1",
        vec!["I have put the Kestral review in for the fourteenth.", "Noted — Kestrel."],
    )));
    let control = TurnControl::open(dir.join("intake.jsonl")).unwrap();
    spine.set_turn_control(control.clone());
    let desk = CandidateDesk::open(dir.join("candidates.jsonl")).unwrap().shared();
    spine.set_candidate_desk(desk.clone());

    spine.submit_prompt("What is on for the Kestral account?", Source::Text).unwrap();
    assert!(desk.lock().unwrap().pending().is_empty(), "nothing to correct yet");

    // The front desk is being primed and his correction goes down the deferred road.
    control.begin_front_desk_prime(&thread);
    control
        .defer_send(&thread, Some(femcboost()), "No, it's Kestrel, not Kestral.")
        .unwrap()
        .expect("accepted");
    control.end_front_desk_prime();
    spine.poll_intake().unwrap();

    let guard = desk.lock().unwrap();
    let pending = guard.pending();
    assert_eq!(pending.len(), 1, "the correction was dropped because of which road it took: {pending:?}");
    assert_eq!(pending[0].ask.from, "Kestral");
    assert_eq!(pending[0].ask.to, "Kestrel");
    assert_eq!(
        pending[0].ask.anchor.as_deref(),
        Some("I have put the Kestral review in for the fourteenth."),
        "the anchor must quote the line the wrong word appeared on, deferred or not"
    );
    drop(guard);
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn the_road_is_shut_before_the_drain_so_no_accepted_record_is_left_undelivered() {
    // **THE RACE, PINNED.** `end_front_desk_prime` clears the marker from under the spine's
    // mutex and `poll_intake` runs immediately after, so every ordering is covered: a send
    // accepted before the clear is drained by the call that cleared it, and a send that
    // arrives after it is refused deferral and blocks on a spine about to be free. The
    // observable consequence is that when `prime_front_desk` returns, the marker is gone AND
    // nothing accepted under it is still pending.
    let c = Contended::open("shut-before-drain", "On it!");
    let priming = c.start_priming();
    c.control.defer_send(&c.thread, Some(femcboost()), "accepted under the marker").unwrap().expect("accepted");
    c.release_priming.raise();
    priming.join().unwrap();

    assert_eq!(c.control.front_desk_priming(), None);
    assert!(
        c.control.pending_intake().is_empty(),
        "a record accepted under the marker was left for some later boundary to find"
    );
    assert_eq!(*c.prompts.lock().unwrap(), vec!["accepted under the marker"]);

    // And the very next send, with the marker clear, takes the ordinary path.
    assert!(c.control.defer_send(&c.thread, Some(femcboost()), "after").unwrap().is_none());
}
