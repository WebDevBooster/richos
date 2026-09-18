//! **THE DESK THAT IS PRIMED BEFORE THE THREAD IT WILL SERVE EXISTS** — the CEO's ruling §55,
//! 2026-09-18, and the half of it `first-words-2026-09-18-sendlock.md` §2.2 could not move.
//!
//! *"Yes, a few seconds is fine. But 35 seconds of waiting for the first response is not. Go."*
//!
//! # The measurement these tests are about
//!
//! Run F measured a contended brand-new thread at **9.647 s** from Send to his first words, of
//! which **2.368 s** was the remainder of a priming turn his message was queued behind. The
//! sendlock slice made the Send itself instant (4 ms) and durable; it did not and could not move
//! those seconds, because the priming is a model turn and the lease is serial (continuity §3.1).
//!
//! And the real path is worse than "a remainder". `ui/main.js:1688` creates the thread INSIDE the
//! Send handler, so the prime and the send are back-to-back: he pays the WHOLE priming turn. The
//! only thing that removes it is a desk that was primed before the thread existed.
//!
//! Every test here runs headless on `MockCognition` — no provider, no network, no model turn. The
//! real-provider numbers are `examples/first_reply_timing_e2e.rs`'s job and are recorded in
//! `docs/verification/first-words-2026-09-18-primed.md`.

use richos_core::cognition::{MockCognition, MockLeaseFactory};
use richos_core::entity::EntityId;
use richos_core::ledger::{Ledger, Source};
use richos_core::spine::{SpareReady, FrontDeskReady};

mod support;

fn femcboost() -> EntityId {
    EntityId::parse("femcboost").unwrap()
}

fn deeply() -> EntityId {
    EntityId::parse("deeply").unwrap()
}

fn tmp_ledger(tag: &str) -> (std::path::PathBuf, Ledger) {
    let path = std::env::temp_dir().join(format!(
        "richos-spare-test-{tag}-{}-{}.jsonl",
        std::process::id(),
        richos_core::util::now_millis()
    ));
    let _ = std::fs::remove_file(&path);
    let ledger = Ledger::open(&path).unwrap();
    (path, ledger)
}

/// **THE WHOLE POINT, AS A SEQUENCE.** The priming turn is spent while no thread exists; the
/// thread is then created; his first message finds a primed desk and no second priming turn is
/// ever run. That is the 2.368 s of run F, removed.
#[test]
fn the_priming_turn_is_spent_before_the_thread_exists_and_his_first_message_finds_it_done() {
    let (path, ledger) = tmp_ledger("primed-before-the-thread");
    let mut spine = support::spine(ledger);
    let factory = MockLeaseFactory::new(vec!["On it!"]);
    let spawned = factory.spawned.clone();
    let prompts = factory.spawned_prompts.clone();
    spine.set_lease_factory(Box::new(factory));

    // Nothing exists yet: no thread, no child, no turn.
    assert_eq!(spine.threads().len(), 0);
    assert_eq!(spawned.lock().unwrap().len(), 0);

    match spine.ready_a_spare_front_desk(&femcboost()) {
        SpareReady::Ready { .. } => {}
        other => panic!("the spare was not made ready: {other:?}"),
    }
    // ONE child, ONE priming turn, and still NO thread record (UX §3.3).
    assert_eq!(spawned.lock().unwrap().len(), 1, "exactly one spare child");
    assert_eq!(spawned.lock().unwrap()[0].lock().unwrap().len(), 1, "exactly one priming turn");
    assert_eq!(spine.threads().len(), 0, "§3.3: no thread record until he sends");

    // He presses Send on the entity's new-thread screen. The thread is created here, inside
    // the send handler, exactly as `ui/main.js` does it.
    let thread = spine.create_thread("Pricing", &femcboost()).unwrap();

    // His first message. Nothing is spawned and nothing is primed a second time.
    let verdict = spine.prime_front_desk(&thread);
    assert_eq!(spawned.lock().unwrap().len(), 1, "no second child was spawned for his thread");
    assert_eq!(
        spawned.lock().unwrap()[0].lock().unwrap().len(), 1,
        "the desk was primed once, before his thread existed — not again for it"
    );
    match verdict {
        // `prepare_request` resumed the adopted desk and `prime_lease_if_needed` returned
        // early, so the "prime" cost nothing. The verdict is `Ready` rather than
        // `AlreadyReady` because the chair was empty when it was asked.
        FrontDeskReady::Ready { millis, spawned: was_spawned } => {
            assert!(!was_spawned, "the lease was adopted, not started");
            assert!(millis < 500, "a prime that ran no model turn took {millis} ms");
        }
        FrontDeskReady::AlreadyReady => {}
        other => panic!("the desk was not ready for his first message: {other:?}"),
    }

    spine.submit_prompt("Land the pricing branch.", Source::Text).unwrap();
    assert_eq!(
        prompts.lock().unwrap()[0].lock().unwrap().len(), 1,
        "his sentence went to the desk that was already standing there"
    );
    let _ = std::fs::remove_file(path);
}

/// **THE SCOPING INVARIANT, AND IT IS THE FIRST DECISION THIS SLICE HAD TO MAKE.**
///
/// `EngineProfile::scope_to` pins `(entity_id, thread_id)` into the child's environment and
/// workspace partition before it is spawned, and `engine/mega-lander/app.py:62` refuses a
/// dispatch whose binding disagrees with them. So the spare is spawned under the id the thread
/// ends up with — the scoping does NOT move, and the id is reserved instead.
#[test]
fn the_spare_is_spawned_under_the_very_id_the_thread_is_then_created_with() {
    let (path, ledger) = tmp_ledger("scoped-to-the-reserved-id");
    let mut spine = support::spine(ledger);
    let factory = MockLeaseFactory::new(vec!["On it!"]);
    let scoped_to = factory.scoped_to.clone();
    spine.set_lease_factory(Box::new(factory));

    spine.ready_a_spare_front_desk(&femcboost());
    let reserved = spine.spare_front_desk_reserved_thread().unwrap().to_string();
    assert_eq!(
        scoped_to.lock().unwrap().as_slice(),
        &[("femcboost".to_string(), reserved.clone())],
        "the child was spawned scoped to the reserved id and its entity"
    );

    let thread = spine.create_thread("Pricing", &femcboost()).unwrap();
    assert_eq!(thread, reserved, "the thread took the id its desk was already scoped to");
    assert_eq!(
        spine.ledger().thread_binding(&thread).unwrap().entity_id().as_str(),
        "femcboost"
    );
    let _ = std::fs::remove_file(path);
}

/// UX §3.3, verbatim: *"no pre-created thread record until the CEO sends the first message"*.
/// A reserved id is not a record — nothing is appended, nothing is listed, and an app that is
/// quit before he types leaves no trace of the reservation at all.
#[test]
fn a_reserved_id_writes_no_thread_record_and_a_spare_he_never_uses_leaves_none() {
    let (path, ledger) = tmp_ledger("no-record-until-he-sends");
    let mut spine = support::spine(ledger);
    spine.set_lease_factory(Box::new(MockLeaseFactory::new(vec!["On it!"])));

    spine.ready_a_spare_front_desk(&femcboost());
    let reserved = spine.spare_front_desk_reserved_thread().unwrap().to_string();
    assert_eq!(spine.threads().len(), 0);
    assert!(spine.ledger().thread_binding(&reserved).is_err(), "a reserved id is not a thread");

    // He quits without typing. The ledger on disk is re-read from scratch: no thread.
    drop(spine);
    let reopened = Ledger::open(&path).unwrap();
    assert_eq!(reopened.threads().len(), 0, "a spare he never spoke to left no record");
    let _ = std::fs::remove_file(path);
}

/// **A SPARE PRIMED FOR ONE ENTITY IS NEVER ADOPTED BY ANOTHER** — the entity-boundary rule
/// `IntakeRecord::Steer::thread_id` states, and the re-prime payload is entity-scoped
/// (`reprime.rs`'s action digest is `ceo_facing_actions_for_entity`), so adopting across
/// entities would hand one company's Rich to another company's first sentence.
#[test]
fn a_spare_primed_for_one_company_is_never_adopted_by_another() {
    let (path, ledger) = tmp_ledger("never-across-entities");
    let mut spine = support::spine(ledger);
    let factory = MockLeaseFactory::new(vec!["On it!", "On it!"]);
    let spawned = factory.spawned.clone();
    spine.set_lease_factory(Box::new(factory));

    spine.ready_a_spare_front_desk(&femcboost());
    let reserved = spine.spare_front_desk_reserved_thread().unwrap().to_string();

    // He starts a thread in the OTHER company.
    let thread = spine.create_thread("Q4 board pack", &deeply()).unwrap();
    assert_ne!(thread, reserved, "Deeply's thread did not take FemcBoost's reserved id");
    assert!(
        spine.spare_front_desk_is_ready_for(&femcboost()),
        "FemcBoost's spare is still standing — starting a thread in Deeply says nothing about it"
    );
    assert_eq!(spawned.lock().unwrap().len(), 1, "no second spare was spawned by the switch");
    let _ = std::fs::remove_file(path);
}

/// The other half of the entity decision: asking for a spare in a DIFFERENT company retires the
/// one standing there rather than keeping one per company. Discard-and-re-prime, decided from
/// the idle-cost measurement in `docs/verification/first-words-2026-09-18-primed.md` §2.
#[test]
fn asking_for_a_spare_in_another_company_retires_the_one_standing_there() {
    let (path, ledger) = tmp_ledger("one-spare-only");
    let mut spine = support::spine(ledger);
    let factory = MockLeaseFactory::new(vec!["On it!", "On it!"]);
    let spawned = factory.spawned.clone();
    spine.set_lease_factory(Box::new(factory));

    spine.ready_a_spare_front_desk(&femcboost());
    let first = spine.spare_front_desk_reserved_thread().unwrap().to_string();
    match spine.ready_a_spare_front_desk(&deeply()) {
        SpareReady::Ready { .. } => {}
        other => panic!("the second spare was not made ready: {other:?}"),
    }
    assert!(!spine.spare_front_desk_is_ready_for(&femcboost()));
    assert!(spine.spare_front_desk_is_ready_for(&deeply()));
    assert_ne!(spine.spare_front_desk_reserved_thread().unwrap(), first);
    assert_eq!(spawned.lock().unwrap().len(), 2, "two spares were spawned, never held at once");
    let _ = std::fs::remove_file(path);
}

/// Idempotent per entity: the shell may call this on every view change, and a primed spare
/// already standing there costs nothing and sends nothing.
#[test]
fn a_second_ask_for_the_same_company_spends_nothing() {
    let (path, ledger) = tmp_ledger("idempotent");
    let mut spine = support::spine(ledger);
    let factory = MockLeaseFactory::new(vec!["On it!"]);
    let spawned = factory.spawned.clone();
    spine.set_lease_factory(Box::new(factory));

    spine.ready_a_spare_front_desk(&femcboost());
    let reserved = spine.spare_front_desk_reserved_thread().unwrap().to_string();
    for _ in 0..5 {
        assert_eq!(spine.ready_a_spare_front_desk(&femcboost()), SpareReady::AlreadyReady);
    }
    assert_eq!(spawned.lock().unwrap().len(), 1);
    assert_eq!(spawned.lock().unwrap()[0].lock().unwrap().len(), 1, "one priming turn, not six");
    assert_eq!(spine.spare_front_desk_reserved_thread().unwrap(), reserved);
    let _ = std::fs::remove_file(path);
}

/// Priming is NEVER run underneath a turn. The spare's turn is on its own child, so it breaks no
/// continuity-§3.1 invariant — but the caller holds the spine's mutex for the whole of it, and a
/// second multi-second hold in front of a running turn is what `FrontDeskReady::TurnInProgress`
/// already refuses. Same answer, same reason.
#[test]
fn a_spare_is_never_primed_underneath_a_running_turn() {
    let (path, ledger) = tmp_ledger("never-under-a-turn");
    let mut spine = support::spine(ledger);
    let factory = MockLeaseFactory::new(vec!["On it!"]);
    let spawned = factory.spawned.clone();
    spine.set_lease_factory(Box::new(factory));
    spine.debug_set_turn_in_progress(true);

    assert_eq!(spine.ready_a_spare_front_desk(&femcboost()), SpareReady::TurnInProgress);
    assert_eq!(spawned.lock().unwrap().len(), 0, "nothing was spawned under a turn");
    assert!(spine.spare_front_desk_reserved_thread().is_none());
    let _ = std::fs::remove_file(path);
}

/// An unregistered entity is refused here exactly as it is everywhere else (ECS §3.3) — a spare
/// is a child scoped to a company, so inventing one would be the same fault with a process
/// attached to it.
#[test]
fn an_unregistered_company_gets_no_spare() {
    let (path, ledger) = tmp_ledger("unregistered");
    let mut spine = support::spine(ledger);
    let factory = MockLeaseFactory::new(vec!["On it!"]);
    let spawned = factory.spawned.clone();
    spine.set_lease_factory(Box::new(factory));

    match spine.ready_a_spare_front_desk(&EntityId::parse("acme-holdings").unwrap()) {
        SpareReady::NotReady(why) => assert!(why.contains("acme-holdings"), "{why}"),
        other => panic!("an unregistered company got a spare: {other:?}"),
    }
    assert_eq!(spawned.lock().unwrap().len(), 0);
    let _ = std::fs::remove_file(path);
}

/// **AN UN-PRIMED SPARE IS ADOPTED, NOT THROWN AWAY.** The central folder moving un-primes every
/// front desk; a spare is the one primed EARLIEST, so it is the likeliest to be holding material
/// the app has stopped believing in. Its child is still correctly scoped, so it takes the chair
/// and primes at his first message — which is what every thread did before spares existed. The
/// degrade is the old path, never a new failure.
#[test]
fn a_spare_the_app_has_stopped_believing_in_still_takes_the_chair_and_primes_on_his_first_message() {
    let (path, ledger) = tmp_ledger("unprimed-spare");
    let mut spine = support::spine(ledger);
    let factory = MockLeaseFactory::new(vec!["On it!"]);
    let spawned = factory.spawned.clone();
    spine.set_lease_factory(Box::new(factory));

    spine.ready_a_spare_front_desk(&femcboost());
    let reserved = spine.spare_front_desk_reserved_thread().unwrap().to_string();
    assert_eq!(spawned.lock().unwrap()[0].lock().unwrap().len(), 1);

    // The company material moved. Every desk is un-primed, the spare included.
    spine.set_central_root(std::env::temp_dir().join("richos-spare-test-central"));
    assert!(!spine.spare_front_desk_is_ready_for(&femcboost()));

    let thread = spine.create_thread("Pricing", &femcboost()).unwrap();
    assert_eq!(thread, reserved, "it was still adopted — the child is correctly scoped");
    spine.prime_front_desk(&thread);
    assert_eq!(spawned.lock().unwrap().len(), 1, "no second child: the same desk primed again");
    assert_eq!(
        spawned.lock().unwrap()[0].lock().unwrap().len(), 2,
        "it primed a second time, on his clock — the old path, which is the honest degrade"
    );
    let _ = std::fs::remove_file(path);
}

/// **THE SPARE'S SESSION-START CHATTER NEVER REACHES A TURN THE CEO IS WATCHING.**
///
/// A fresh child re-announces its commands on the between-turn lane at session start, with no
/// turn in flight to own them. The chair's priming drains that lane and stamps it
/// `internal: true` (`prime_lease_if_needed`'s last lines). The spare's binding cannot be
/// verified — its thread has no record — so `pump_between_turn_stamped` refuses it and leaves
/// those records sitting in the lease, where the FIRST VISIBLE TURN drains them at
/// `spine.rs:2332` with `internal: false` and stamps them against a turn he is looking at. That
/// is the rotation-tell shape §1.5 exists to exclude, arriving by a new road.
///
/// **A POSITIVE PROBE, not a negative that passes because the double is silent.**
/// `every_child_announces_itself` parks a real frame on every spawned lease, exactly as a live
/// child does, so removing the drain in `prime_the_spare` makes this test fail with the record
/// in hand.
#[test]
fn the_spares_own_session_start_chatter_is_dropped_and_never_lands_in_his_first_turn() {
    use std::sync::{Arc, Mutex};

    #[derive(Default)]
    struct Seen(Mutex<Vec<(String, Option<String>, bool)>>);
    impl richos_core::machinery::MachineryObserver for Seen {
        fn on_machinery(&self, record: &richos_core::machinery::MachineryRecord) {
            self.0.lock().unwrap().push((
                record.title.clone(), record.turn_id.clone(), record.internal,
            ));
        }
    }

    let (path, ledger) = tmp_ledger("residue-dropped");
    let mut spine = support::spine(ledger);
    let factory = MockLeaseFactory::new(vec!["On it!"]);
    let spawned = factory.spawned.clone();
    // The announcement a real child makes at session start, in the vendor's own frame shape.
    factory.every_child_announces_itself(serde_json::json!({
        "type": "assistant",
        "message": {"role": "assistant", "content": [{"type": "text", "text": "commands reloaded"}]}
    }));
    spine.set_lease_factory(Box::new(factory));
    let seen = Arc::new(Seen::default());
    struct Forward(Arc<Seen>);
    impl richos_core::machinery::MachineryObserver for Forward {
        fn on_machinery(&self, record: &richos_core::machinery::MachineryRecord) {
            self.0.on_machinery(record);
        }
    }
    spine.set_machinery_observer(Box::new(Forward(seen.clone())));

    spine.ready_a_spare_front_desk(&femcboost());
    let thread = spine.create_thread("Pricing", &femcboost()).unwrap();
    spine.prime_front_desk(&thread);
    spine.submit_prompt("Land the pricing branch.", Source::Text).unwrap();

    let records = seen.0.lock().unwrap().clone();
    assert!(
        !records.iter().any(|(title, _, internal)| title == "assistant:text" && !*internal),
        "the spare's session-start chatter reached a turn the CEO can see: {records:#?}"
    );
    assert!(
        !records.iter().any(|(title, turn, _)| title == "assistant:text" && turn.is_some()),
        "it was attached to one of his turns: {records:#?}"
    );

    // And what he CAN see is his own sentence and its reply, and nothing else.
    let messages = spine.messages(&thread).unwrap();
    assert_eq!(messages.len(), 2, "one CEO message and one reply: {messages:#?}");
    let binding = spine.ledger().thread_binding(&thread).unwrap();
    let turns = spine.ledger().thread_turns_scoped(&binding).unwrap();
    assert_eq!(turns.iter().filter(|t| t.source == Source::Text).count(), 1, "one visible turn");
    assert_eq!(
        turns.iter().filter(|t| t.source == Source::Internal).count(), 0,
        "the spare's priming was recorded as an ACTION, never as an Internal turn against a \
         thread that did not exist when it ran"
    );
    assert_eq!(spawned.lock().unwrap().len(), 1);
    let _ = std::fs::remove_file(path);
}

/// The durable record that the spare WAS primed — the fact the whole saving rests on — is an
/// Internal action naming the reserved id, so a later reader can join it to the thread it became.
/// Internal, therefore never in the CEO-facing digest and never rendered.
#[test]
fn the_spares_priming_is_durably_recorded_and_is_never_ceo_facing() {
    let (path, ledger) = tmp_ledger("durable-action");
    let mut spine = support::spine(ledger);
    spine.set_lease_factory(Box::new(MockLeaseFactory::new(vec!["On it!"])));

    spine.ready_a_spare_front_desk(&femcboost());
    let reserved = spine.spare_front_desk_reserved_thread().unwrap().to_string();

    let primed: Vec<_> = spine.ledger().actions().iter()
        .filter(|a| a.kind == "spare_front_desk_reprime").collect();
    assert_eq!(primed.len(), 1, "one priming, durably recorded");
    assert!(primed[0].detail.contains(&reserved), "it names the id it was scoped to");
    assert!(primed[0].detail.contains("femcboost"), "and the company it was primed for");
    assert_eq!(primed[0].status, richos_core::ledger::ActionStatus::Completed);
    assert!(
        !spine.ledger().ceo_facing_actions_for_entity(&femcboost()).iter()
            .any(|a| a.kind == "spare_front_desk_reprime"),
        "machinery is never in the digest that is asserted to a successor as ground truth"
    );
    let _ = std::fs::remove_file(path);
}

/// A reserved id is spent exactly once. Ids are uuid v4, so a second spend would mean the
/// reservation was used twice — two conversations in one workspace partition — and the ledger
/// refuses rather than quietly picking another id.
#[test]
fn a_reserved_id_can_be_spent_exactly_once() {
    let (path, ledger) = tmp_ledger("spent-once");
    let mut ledger = ledger;
    let reserved = Ledger::reserve_thread_id();
    let id = ledger.create_thread_with_reserved_id(&reserved, "Pricing", &femcboost()).unwrap();
    assert_eq!(id, reserved);
    let again = ledger.create_thread_with_reserved_id(&reserved, "Pricing again", &femcboost());
    assert!(matches!(again, Err(richos_core::ledger::LedgerError::ThreadIdAlreadySpent(_))), "{again:?}");
    assert_eq!(ledger.threads().len(), 1, "nothing was appended by the refused call");
    let _ = std::fs::remove_file(path);
}

/// With no lease factory the app cannot spawn anything, so it says so and the next brand-new
/// thread primes the way it does today. Nothing is surfaced to the CEO and nothing is retried.
#[test]
fn a_build_that_cannot_spawn_a_lease_says_so_and_costs_him_nothing() {
    let (path, ledger) = tmp_ledger("no-factory");
    let mut spine = support::spine(ledger);
    match spine.ready_a_spare_front_desk(&femcboost()) {
        SpareReady::NotReady(_) => {}
        other => panic!("a spine with no factory claimed a spare: {other:?}"),
    }
    // And the ordinary path is untouched: his thread is created and primed exactly as before.
    let thread = spine.create_thread("Pricing", &femcboost()).unwrap();
    let lease = MockCognition::new("sess-one", vec!["On it!"]);
    let reprimes = lease.reprimes.clone();
    spine.attach_lease(Box::new(lease));
    spine.prime_front_desk(&thread);
    assert_eq!(reprimes.lock().unwrap().len(), 1);
    let _ = std::fs::remove_file(path);
}
