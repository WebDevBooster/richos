//! **"NOT NOW", WRITTEN DOWN** — the two spine methods the first-run notice is built on, and
//! the one property that makes the notice worth building.
//!
//! `OnboardingRecord::record_declination` shipped in `onboarding.rs` on 2026-09-06 with NO
//! CALLER anywhere in the product:
//!
//! ```text
//! $ grep -rn "record_declination" app/ --include="*.rs" | grep -v "src/onboarding.rs"
//!   (no output)
//! ```
//!
//! So `OnboardingState::Declined` and `DECLINED_BLOCK` were unreachable outside their own unit
//! tests, and a CEO who said "not now" into the conversation was re-offered the interview at
//! every prime of every new thread, forever — the M5 nag with nothing holding it back, in a
//! module whose own doc names that nag as the reason the record exists.
//!
//! That is the same defect one layer up that this whole line of work is about: a correct,
//! tested mechanism that nothing invokes. So the tests that matter are not "does the record
//! round-trip" — `onboarding.rs` already proves that. They are:
//!
//!   1. the button's write REACHES RICH — the next priming turn stops offering and says he
//!      was asked (`the_declination_changes_what_rich_is_primed_with`);
//!   2. the notice and the priming turn are DERIVED FROM THE SAME FACT and cannot disagree
//!      (`the_notice_state_and_the_priming_block_never_disagree`);
//!   3. a write with nowhere to go is REFUSED and says so, rather than reporting success over
//!      a record that was never written (`a_declination_with_nowhere_to_go_is_refused`).
//!
//! Every test uses `MockCognition`. No `claude` process, no network, no audio device.

use richos_core::cognition::MockCognition;
use richos_core::company::{company_file, company_home};
use richos_core::entity::EntityId;
use richos_core::ledger::{Ledger, Source};
use richos_core::onboarding::{record_path, OnboardingRecord, OnboardingState};
use richos_core::spine::Spine;
use std::path::PathBuf;

mod support;

/// `femcboost` rather than a new id: `support::registry()` is the shared fixture and a
/// bare spine accepts no entity outside it. The company being described here is a fixture and
/// exists on no machine.
fn company() -> EntityId {
    EntityId::parse("femcboost").unwrap()
}

/// The same per-process counter every other suite in this crate needed, for the same measured
/// reason: cargo runs these in parallel threads of ONE process and `now_millis()` collides.
static SEQ: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);

fn tag(name: &str) -> String {
    format!(
        "{name}-{}-{}-{}",
        std::process::id(),
        richos_core::util::now_millis(),
        SEQ.fetch_add(1, std::sync::atomic::Ordering::Relaxed)
    )
}

fn tmp_ledger(name: &str) -> (PathBuf, Ledger) {
    let path = std::env::temp_dir().join(format!("richos-declination-{}.jsonl", tag(name)));
    let _ = std::fs::remove_file(&path);
    let ledger = Ledger::open(&path).unwrap();
    (path, ledger)
}

fn tmp_dir(name: &str) -> PathBuf {
    let d = std::env::temp_dir().join(format!("richos-declination-{}", tag(name)));
    std::fs::create_dir_all(&d).unwrap();
    d
}

/// Drive one prompt through a spine and hand back every priming turn the lease received.
fn primings(spine: &mut Spine) -> Vec<String> {
    let mock = MockCognition::new("s-1", vec!["ok"]);
    let reprimes = mock.reprimes.clone();
    spine.attach_lease(Box::new(mock));
    spine.submit_prompt("what are we doing", Source::Text).unwrap();
    let out = reprimes.lock().unwrap().clone();
    out
}

// ---------------------------------------------------------------------------
// 1. The button's write reaches Rich. This is the whole reason the control exists.
// ---------------------------------------------------------------------------

/// BEFORE the press Rich is told to offer; AFTER it he is told he already asked. Both halves
/// in one test, on one spine, with nothing changing between them but the press — because the
/// "before" is what makes the "after" mean anything, and a test that only asserted the after
/// would pass against a spine that never offered in the first place.
#[test]
fn the_declination_changes_what_rich_is_primed_with() {
    let (path, ledger) = tmp_ledger("reaches-rich");
    let central = tmp_dir("reaches-rich-central");
    let config = tmp_dir("reaches-rich-config");
    let mut spine = support::spine(ledger);
    spine.set_central_root(central.clone());
    spine.set_onboarding_record(record_path(&config));
    spine.ensure_active_thread_in(&company()).unwrap();

    let before = primings(&mut spine);
    assert!(
        before[0].contains("He has not been asked yet."),
        "before the press, Rich is told to offer: {}",
        before[0]
    );

    spine.record_onboarding_declination(1_788_634_800_000).unwrap();

    // A SECOND SPINE OVER THE SAME FILES, not the same one re-primed: the record is on disk
    // and the next launch has to read it, which is the property the notice depends on.
    let ledger2 = Ledger::open(&path).unwrap();
    let mut spine2 = support::spine(ledger2);
    spine2.set_central_root(central.clone());
    spine2.set_onboarding_record(record_path(&config));
    spine2.ensure_active_thread_in(&company()).unwrap();

    let after = primings(&mut spine2);
    assert!(
        after[0].contains("said not now"),
        "after the press, Rich is told he already asked: {}",
        after[0]
    );
    assert!(
        !after[0].contains("He has not been asked yet."),
        "and he is NOT told to offer again — that is the nag: {}",
        after[0]
    );
    let _ = std::fs::remove_file(&path);
}

// ---------------------------------------------------------------------------
// 2. One fact, two consumers. The screen and the priming turn cannot drift.
// ---------------------------------------------------------------------------

/// `Spine::onboarding_state` is what the window branches on and `company_block` is what Rich
/// is primed with. If those two were derived independently the notice could offer an interview
/// Rich had been told not to mention, or stay silent while he offered — so this walks all four
/// reachable states and asserts they move together.
#[test]
fn the_notice_state_and_the_priming_block_never_disagree() {
    let (path, ledger) = tmp_ledger("agree");
    let central = tmp_dir("agree-central");
    let config = tmp_dir("agree-config");
    let mut spine = support::spine(ledger);
    let b = spine.ensure_active_thread_in(&company()).unwrap();

    // (a) nobody has told the spine where to look.
    assert_eq!(spine.onboarding_state(&b), OnboardingState::NoCentralFolder);
    assert!(
        !primings(&mut spine)[0].contains("ONBOARDING —"),
        "nothing has looked, so nothing is claimed"
    );

    // (b) it looked, and this company is not described.
    let (path_b, ledger_b) = tmp_ledger("agree-b");
    let mut spine = support::spine(ledger_b);
    spine.set_central_root(central.clone());
    spine.set_onboarding_record(record_path(&config));
    let b = spine.ensure_active_thread_in(&company()).unwrap();
    assert_eq!(spine.onboarding_state(&b), OnboardingState::NotYet);
    assert!(primings(&mut spine)[0].contains("He has not been asked yet."));

    // (c) he was asked and declined.
    spine.record_onboarding_declination(1_788_634_800_000).unwrap();
    let (path_c, ledger_c) = tmp_ledger("agree-c");
    let mut spine = support::spine(ledger_c);
    spine.set_central_root(central.clone());
    spine.set_onboarding_record(record_path(&config));
    let b = spine.ensure_active_thread_in(&company()).unwrap();
    assert_eq!(spine.onboarding_state(&b), OnboardingState::Declined { at_millis: 1_788_634_800_000 });
    assert!(primings(&mut spine)[0].contains("said not now"));

    // (d) described — and DESCRIBED WINS OVER A DECLINATION, which is the ordering the
    // notice depends on: a company he later wrote up must stop being a company he declined
    // to be asked about, or the screen would offer him an interview about material it is
    // already using.
    std::fs::create_dir_all(company_home(&central, &company())).unwrap();
    std::fs::write(
        company_file(&central, &company()),
        "# FemcBoost\n\nWe run coastal freight scheduling for mid-size ports.\n",
    )
    .unwrap();
    let (path_d, ledger_d) = tmp_ledger("agree-d");
    let mut spine = support::spine(ledger_d);
    spine.set_central_root(central.clone());
    spine.set_onboarding_record(record_path(&config));
    let b = spine.ensure_active_thread_in(&company()).unwrap();
    assert_eq!(spine.onboarding_state(&b), OnboardingState::Described);
    let primed = primings(&mut spine)[0].clone();
    assert!(primed.contains("coastal freight scheduling"), "the material, not the offer: {primed}");
    assert!(!primed.contains("said not now"), "and not the declination either: {primed}");

    for p in [&path, &path_b, &path_c, &path_d] {
        let _ = std::fs::remove_file(p);
    }
}

// ---------------------------------------------------------------------------
// 3. A write with nowhere to go is refused, out loud.
// ---------------------------------------------------------------------------

/// The failure this refuses is the one the whole record is about: reporting success over work
/// that never happened. A press that silently wrote nothing would put him back in the
/// re-offered-forever state with a screen that told him he had settled it.
#[test]
fn a_declination_with_nowhere_to_go_is_refused() {
    let (path, ledger) = tmp_ledger("nowhere");
    let spine = support::spine(ledger);
    // `set_onboarding_record` deliberately NOT called — the shipped default for every
    // headless example and every other test in this crate.
    let err = spine
        .record_onboarding_declination(1_788_634_800_000)
        .expect_err("a declination with nowhere to go must be refused, not silently dropped");
    let said = err.to_string();
    assert!(
        said.contains("nowhere to write") || said.contains("nobody told this spine where"),
        "and the refusal must say what did not happen: {said}"
    );
    let _ = std::fs::remove_file(&path);
}

/// The record on disk still holds ONE fact after a write through the spine. `onboarding.rs`
/// has a unit test whose only job is to refuse a second field on the struct; this is the same
/// guarantee at the file, reached through the caller the product actually uses.
#[test]
fn the_spines_write_produces_a_record_holding_only_a_declination() {
    let config = tmp_dir("onefact-config");
    let (path, ledger) = tmp_ledger("onefact");
    let mut spine = support::spine(ledger);
    spine.set_onboarding_record(record_path(&config));
    spine.record_onboarding_declination(1_788_634_800_000).unwrap();

    let body = std::fs::read_to_string(record_path(&config)).unwrap();
    assert!(body.contains("declined_at_millis"), "the one fact is there: {body}");
    assert_eq!(body.matches(':').count(), 1, "and it is the ONLY key: {body}");
    assert_eq!(
        OnboardingRecord::load(&record_path(&config)).declined_at_millis(),
        Some(1_788_634_800_000),
        "and it reads back as what was written"
    );
    let _ = std::fs::remove_file(&path);
}
