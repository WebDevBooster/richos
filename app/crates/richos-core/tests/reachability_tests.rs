//! **A CHEAP HEALTH CHECK IS WORSE THAN NONE** — row 3.30's fourth answer, proved against
//! the size-dependent fault the incident actually had.
//!
//! The whole suite rests on one measurement from 2026-09-03: while four large briefs died
//! on `529 Overloaded`, a one-command probe — `pwd`, three characters — completed normally
//! in 51 seconds. So `the_cheap_probe_would_have_reported_healthy_while_real_work_died`
//! below is not an analogy for the finding. It IS the finding, run through the code.
//!
//! Nothing here touches a network. `upstream::FakeUpstream` fails requests larger than a
//! floor and passes smaller ones, which is the shape that was measured; a fake that failed
//! uniformly could not tell a cheap probe from a realistic one and would make every
//! assertion in this file vacuous.
//!
//! **What is NOT covered, stated rather than found later.** The size threshold in a real
//! outage is unknown and unknowable from outside — the fake's `fails_above_chars` is a
//! MODEL of "expensive first", not a measurement of Anthropic's admission control. What the
//! suite proves is that RichOS's verdict is a function of the probe's size relative to the
//! work, which is true whatever the real threshold turns out to be.

use richos_core::reachability::{ReachabilityProbe, ReachabilityVerdict, WorkSize};
use richos_core::upstream::{FakeUpstream, UpstreamFault};

const CAPTURED_529: &str =
    include_str!("../../../../docs/verification/upstream-failure-2026-09-05/captured-529.txt");

fn captured_529() -> &'static str {
    CAPTURED_529.lines().next().unwrap()
}

/// The two numbers from the incident. `pwd` is three characters; the briefs were tens of
/// thousands. The fake's threshold sits between them.
const CHEAP_PROBE_CHARS: usize = 3;
const REAL_WORK_CHARS: usize = 120_000;
const DEGRADED_THRESHOLD: usize = 4_096;

// =========================================================================================
// THE FINDING
// =========================================================================================

/// **THE TEST THIS MODULE EXISTS FOR.** Under the measured failure, a cheap ping succeeds
/// and real work dies in the same instant — and RichOS refuses to call that "healthy".
///
/// Both arms run against the SAME degraded upstream, in the same test, so the difference
/// between them is the probe size and nothing else.
#[test]
fn the_cheap_probe_would_have_reported_healthy_while_real_work_died() {
    let api = FakeUpstream::size_dependent(DEGRADED_THRESHOLD, captured_529());
    let probe = ReachabilityProbe::from_recent(&[REAL_WORK_CHARS, 900, 1_200]);

    // ARM 1 — the cheap ping. It SUCCEEDS against the degraded API, exactly as `pwd` did.
    let cheap = probe.judge(CHEAP_PROBE_CHARS, api.send(CHEAP_PROBE_CHARS));
    assert!(
        api.failures() == 0,
        "the three-character request must have gone through, as it did on 2026-09-03"
    );
    assert_eq!(
        cheap,
        ReachabilityVerdict::Unproven {
            probe_chars: CHEAP_PROBE_CHARS,
            floor_chars: REAL_WORK_CHARS
        },
        "a successful cheap request must NOT be reported as reachable — that is the whole row"
    );
    assert!(!cheap.vouches_for(REAL_WORK_CHARS));
    assert!(
        !cheap.vouches_for(CHEAP_PROBE_CHARS),
        "and it does not even vouch for its own size, because it proved nothing"
    );

    // ARM 2 — the same API, a realistic-size request. It fails, and says which fault.
    let real = probe.run(|p| api.send(p.chars().count()));
    match &real {
        ReachabilityVerdict::Failed { failure, probe_chars } => {
            assert_eq!(failure.fault, UpstreamFault::Overloaded);
            assert_eq!(*probe_chars, REAL_WORK_CHARS, "the probe was sent at the work's size");
        }
        other => panic!("a realistic-size probe against a degraded API must fail: {other:?}"),
    }

    // THE ARITHMETIC, SHOWN. One upstream, two questions, two opposite answers.
    assert_eq!(api.attempts(), 2);
    assert_eq!(api.failures(), 1);
}

/// POSITIVE CONTROL, and without it the test above proves only that everything fails.
/// A HEALTHY upstream + a realistic-size probe = `Reachable`, and it vouches for the work.
#[test]
fn a_healthy_api_probed_at_realistic_size_is_reported_reachable() {
    // `fails_above_chars` beyond any request: nothing fails.
    let api = FakeUpstream::size_dependent(usize::MAX, captured_529());
    let probe = ReachabilityProbe::from_recent(&[REAL_WORK_CHARS]);

    let v = probe.run(|p| api.send(p.chars().count()));
    assert_eq!(v, ReachabilityVerdict::Reachable { probe_chars: REAL_WORK_CHARS });
    assert!(v.vouches_for(REAL_WORK_CHARS), "it vouches for the size it actually sent");
    assert!(v.vouches_for(1), "and for anything smaller");
    assert!(
        !v.vouches_for(REAL_WORK_CHARS + 1),
        "and for nothing larger — a verdict only ever covers its own size"
    );
    assert_eq!(api.failures(), 0);
}

/// INVARIANT: the guard has no escape hatch. Whatever the caller reports, a probe below the
/// floor cannot produce `Reachable`.
#[test]
fn no_probe_below_the_floor_can_report_reachable_however_it_is_called() {
    let probe = ReachabilityProbe::from_recent(&[10_000]);
    for chars in [0usize, 1, 3, 999, 9_999] {
        let v = probe.judge(chars, Ok(()));
        assert_eq!(
            v,
            ReachabilityVerdict::Unproven { probe_chars: chars, floor_chars: 10_000 },
            "{chars} chars under a 10,000 floor"
        );
    }
    // POSITIVE CONTROL on the same boundary: exactly at the floor IS enough.
    assert_eq!(
        probe.judge(10_000, Ok(())),
        ReachabilityVerdict::Reachable { probe_chars: 10_000 },
        "the boundary is inclusive — a probe the size of the work has earned its answer"
    );
}

/// INVARIANT: a FAILURE is reported at any size, and the asymmetry is deliberate. A small
/// request that failed is real evidence; a small request that succeeded is not.
#[test]
fn a_failure_is_believed_at_any_size_while_a_success_is_not() {
    let probe = ReachabilityProbe::from_recent(&[10_000]);
    match probe.judge(3, Err(captured_529().to_string())) {
        ReachabilityVerdict::Failed { failure, probe_chars } => {
            assert_eq!(failure.fault, UpstreamFault::Overloaded);
            assert_eq!(probe_chars, 3);
        }
        other => panic!("a 529 on a tiny probe is still a 529: {other:?}"),
    }
    // And the other half of the asymmetry, in the same test so neither can drift alone.
    assert!(matches!(probe.judge(3, Ok(())), ReachabilityVerdict::Unproven { .. }));
}

/// INVARIANT: a LOCAL failure does not get to answer a question about the API. A broken
/// pipe is not an outage and must not be reported as one.
#[test]
fn a_local_failure_does_not_become_a_reachability_verdict() {
    let probe = ReachabilityProbe::from_recent(&[10_000]);
    let v = probe.judge(10_000, Err("cognition io: broken pipe".to_string()));
    assert_eq!(
        v,
        ReachabilityVerdict::Unproven { probe_chars: 10_000, floor_chars: 10_000 },
        "the request never reached the API, so nothing about the API was learned"
    );
    assert!(!v.vouches_for(1));
}

/// INVARIANT: an unmeasured install SENDS NOTHING and is billed for nothing. The closure
/// panics if it is ever called.
#[test]
fn an_unmeasured_install_spends_no_money_to_learn_nothing() {
    let probe = ReachabilityProbe::from_recent(&[]);
    assert_eq!(probe.estimated_cost_chars(), None);
    let v = probe.run(|_| panic!("a probe with no floor must not send anything"));
    assert_eq!(v, ReachabilityVerdict::Unmeasured);
    assert!(!v.vouches_for(1));
}

/// INVARIANT: the cost is stated BEFORE it is spent, and it is the floor.
#[test]
fn the_cost_of_a_probe_is_stated_before_it_is_sent() {
    let probe = ReachabilityProbe::from_recent(&[900, 120_000, 1_200]);
    assert_eq!(probe.estimated_cost_chars(), Some(120_000));
    assert_eq!(probe.floor(), Some(WorkSize { largest_chars: 120_000, sample: 3 }));

    let mut sent = 0usize;
    let _ = probe.run(|p| {
        sent = p.chars().count();
        Ok(())
    });
    assert_eq!(sent, 120_000, "what it said it would send is what it sent");
}

/// INVARIANT: the four verdicts say four different things, and `Unproven` says neither
/// "healthy" nor "down".
#[test]
fn the_verdicts_are_four_different_statements_and_unproven_claims_nothing() {
    let reachable = ReachabilityVerdict::Reachable { probe_chars: 120_000 };
    let unproven = ReachabilityVerdict::Unproven { probe_chars: 3, floor_chars: 120_000 };
    let unmeasured = ReachabilityVerdict::Unmeasured;
    let failed = ReachabilityVerdict::Failed {
        failure: richos_core::upstream::UpstreamFailure::classify(captured_529()).unwrap(),
        probe_chars: 120_000,
    };

    let lines = [
        reachable.ceo_message(),
        unproven.ceo_message(),
        unmeasured.ceo_message(),
        failed.ceo_message(),
    ];
    let unique: std::collections::BTreeSet<&str> = lines.iter().map(|s| s.as_str()).collect();
    assert_eq!(unique.len(), 4, "four states, four sentences: {lines:?}");

    let u = unproven.ceo_message();
    assert!(u.contains("proves nothing"), "it must not imply health: {u}");
    assert!(u.contains("3 characters"), "it names what it sent: {u}");
    assert!(u.contains("120000"), "and what the work is: {u}");
    assert!(
        !u.contains("working") && !u.contains("at capacity"),
        "it is neither a green tick nor an outage notice: {u}"
    );
}
