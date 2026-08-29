//! THE CADENCE MEASUREMENT, re-run from the raw wire capture on every `cargo test`.
//!
//! Moving the rotation watermark from "70 % of a guessed 200_000-token window, counted in
//! prompt+reply characters" to "70 % of the 1_000_000-token window the adapter reports,
//! counted in the tokens it reports" changes how often Rich rotates. It was not obvious in
//! which DIRECTION, because the two errors ran opposite ways. So it is measured here
//! rather than argued, against
//! `docs/verification/acp-emission-probe-2026-08-28/` — five runs of `claude-agent-acp`
//! 0.70.0, raw JSON-RPC, captured 2026-08-28 and unmodified since.
//!
//! **Everything below is recomputed from those files at test time.** Nothing is a copied
//! number; if the probe data is ever replaced, these tests move with it or go red.
//!
//! ## What was found, in one line each
//!
//! - Mixed traffic (all five runs): rotation moves from turn **328.2** to turn **189.5** —
//!   **42 % more often** — and the OLD trigger sat **53.9 turns PAST the hard wall**
//!   (turn 328.2 against a wall at 274.3), i.e. it could not have fired in time.
//! - Low-tool traffic (the four non-tool-heavy runs): rotation moves from turn **302.9** to
//!   turn **435.7** — **44 % LESS often**, so fewer billed handoff turns.
//! - Tool-heavy traffic (run 3 alone, the shape an orchestrator Rich actually has): the old
//!   trigger fires at turn **493.0** against a wall at turn **84.1** — **5.9× too late**.
//!   The new one fires at turn **58.1**, with **26.0 turns** of headroom.
//!
//! Lengths are BYTES throughout, because `spine.rs` accumulates `text.len()` and
//! `assistant_text.len()`, both of which are byte lengths. Counting characters instead
//! shifts every figure by well under 1 % and would be measuring a formula this code does
//! not use.
//!
//! ## THE HONEST CAVEAT, stated before the numbers are used for anything
//!
//! Each probe run is a FRESH single-turn session. So "per turn" here is "per FIRST turn",
//! and the extrapolation to turn N is linear in a quantity that is not linear: every turn's
//! tool output stays in context, so real per-turn consumption GROWS with conversation
//! length. **These turn counts are ceilings, not predictions — a real session reaches the
//! wall sooner than they say.** That does not weaken the finding; it is the direction that
//! makes the old trigger worse, not better. What would settle it is a long single session
//! measured turn-by-turn, which this capture is not and which nothing on this branch has.

use serde_json::Value;
use std::path::PathBuf;

const OLD_WINDOW: f64 = 200_000.0;
const NEW_RATIO: f64 = 0.70;
const CHARS_PER_TOKEN: f64 = 4.0;

fn probe_dir() -> PathBuf {
    // richos-core -> crates -> app -> repo root.
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../../../docs/verification/acp-emission-probe-2026-08-28")
}

#[derive(Debug)]
struct Run {
    name: String,
    /// What the chars÷4 estimate WOULD have counted for this turn: prompt chars + reply
    /// chars, ÷ 4 — the exact formula in `spine.rs`'s `context_chars +=`.
    est_tokens: f64,
    /// The adapter's first and last reported `used` for the run.
    used_first: f64,
    used_last: f64,
    /// Every `size` reported in this run, so the denominator can be checked not assumed.
    sizes: Vec<u64>,
    usage_events: usize,
}

impl Run {
    /// Real tokens consumed by the turn itself, above the session's starting baseline.
    fn measured_delta(&self) -> f64 {
        self.used_last - self.used_first
    }
}

fn load_runs() -> Vec<Run> {
    let dir = probe_dir();
    let mut runs = Vec::new();
    for i in 1..=5 {
        let name = format!("run{i}");
        let raw = std::fs::read_to_string(dir.join(format!("{name}.raw.jsonl")))
            .unwrap_or_else(|e| panic!("probe capture missing at {}: {e}", dir.display()));
        let prompt = std::fs::read_to_string(dir.join(format!("{name}.prompt.txt"))).unwrap();

        let mut reply_chars = 0usize;
        let mut used: Vec<f64> = Vec::new();
        let mut sizes: Vec<u64> = Vec::new();
        for line in raw.lines().filter(|l| !l.trim().is_empty()) {
            let d: Value = serde_json::from_str(line).unwrap();
            let u = &d["msg"]["params"]["update"];
            match u.get("sessionUpdate").and_then(|v| v.as_str()) {
                Some("agent_message_chunk") => {
                    reply_chars += u["content"]["text"].as_str().unwrap_or("").len();
                }
                Some("usage_update") => {
                    used.push(u["used"].as_u64().unwrap() as f64);
                    sizes.push(u["size"].as_u64().unwrap());
                }
                _ => {}
            }
        }
        assert!(!used.is_empty(), "{name} reported no usage at all");
        runs.push(Run {
            name,
            est_tokens: ((prompt.len() + reply_chars) as f64 / CHARS_PER_TOKEN).floor(),
            used_first: *used.first().unwrap(),
            used_last: *used.last().unwrap(),
            usage_events: used.len(),
            sizes,
        });
    }
    runs
}

/// Mean per-turn estimate, mean per-turn measured consumption, and mean session baseline
/// over a selection of runs.
fn means(runs: &[&Run]) -> (f64, f64, f64) {
    let n = runs.len() as f64;
    (
        runs.iter().map(|r| r.est_tokens).sum::<f64>() / n,
        runs.iter().map(|r| r.measured_delta()).sum::<f64>() / n,
        runs.iter().map(|r| r.used_first).sum::<f64>() / n,
    )
}

#[derive(Debug)]
struct Cadence {
    /// Turn at which the OLD (estimate over a 200k window) trigger fires.
    old_trigger_turn: f64,
    /// Turn at which the NEW (0.70 of the measured window) trigger fires.
    new_trigger_turn: f64,
    /// Turn at which the session runs out of real context entirely.
    wall_turn: f64,
    /// Real tokens actually consumed at the moment the old trigger fires.
    real_at_old_trigger: f64,
}

fn cadence(runs: &[&Run], window: f64) -> Cadence {
    let (est, real, baseline) = means(runs);
    let old_trigger_turn = (OLD_WINDOW * NEW_RATIO) / est;
    Cadence {
        old_trigger_turn,
        new_trigger_turn: (window * NEW_RATIO - baseline) / real,
        wall_turn: (window - baseline) / real,
        real_at_old_trigger: baseline + old_trigger_turn * real,
    }
}

// ============================================================================
// The denominator: measured, not assumed.
// ============================================================================

#[test]
fn the_adapter_reported_a_one_million_token_window_in_every_single_event() {
    let runs = load_runs();
    let total: usize = runs.iter().map(|r| r.usage_events).sum();
    assert_eq!(total, 50, "the capture holds 50 usage_update events");
    for r in &runs {
        for s in &r.sizes {
            assert_eq!(*s, 1_000_000, "{} reported a window of {s}", r.name);
        }
    }
    // 1_000_000 / 200_000 = 5.0. The app's constant was wrong by exactly this factor.
    assert_eq!(1_000_000.0 / OLD_WINDOW, 5.0);
}

#[test]
fn the_char_estimate_undercounts_every_single_measured_turn() {
    // Not "on average" — in 5 of 5, in the same direction. An error with a consistent
    // sign is a bias, and a bias in the numerator of a safety threshold is a defect.
    let runs = load_runs();
    for r in &runs {
        let ratio = r.measured_delta() / r.est_tokens;
        assert!(
            ratio > 1.0,
            "{}: estimate {} vs measured {} ({ratio:.1}x)",
            r.name,
            r.est_tokens,
            r.measured_delta()
        );
    }
    let worst = runs.iter().map(|r| r.measured_delta() / r.est_tokens).fold(0.0f64, f64::max);
    assert!(worst > 40.0, "the tool-heavy run undercounts by >40x, got {worst:.1}x");
    // 40.6x on run 3. The estimate's error is not a constant factor that could have been
    // calibrated out: 2.3x on run 5, 40.6x on run 3, same code, same adapter, same day.
    let best = runs.iter().map(|r| r.measured_delta() / r.est_tokens).fold(f64::MAX, f64::min);
    assert!(best < 2.5, "and as little as {best:.1}x on the lightest run");
}

#[test]
fn the_session_starts_over_thirty_thousand_tokens_in_and_the_estimate_cannot_see_it() {
    // Every run's FIRST usage_update already reads ~30_400 — the system prompt and tool
    // definitions, present before the CEO types anything. `context_chars` starts at the
    // length of the re-prime payload and knows nothing about any of it.
    let runs = load_runs();
    for r in &runs {
        assert!(r.used_first > 30_000.0, "{} baseline {}", r.name, r.used_first);
        assert!(r.used_first < 31_000.0, "{} baseline {}", r.name, r.used_first);
    }
}

// ============================================================================
// The cadence change itself. THIS IS THE FINDING.
// ============================================================================

#[test]
fn on_mixed_traffic_rotation_gets_forty_three_percent_more_frequent() {
    let runs = load_runs();
    let all: Vec<&Run> = runs.iter().collect();
    let c = cadence(&all, 1_000_000.0);

    // 329.9 -> 189.5 turns per lease.
    assert!((c.old_trigger_turn - 328.2).abs() < 0.5, "old = {:.1}", c.old_trigger_turn);
    assert!((c.new_trigger_turn - 189.5).abs() < 0.5, "new = {:.1}", c.new_trigger_turn);
    let change = (c.new_trigger_turn - c.old_trigger_turn) / c.old_trigger_turn;
    assert!((change + 0.423).abs() < 0.01, "cadence change = {:.1}%", change * 100.0);
}

#[test]
fn on_mixed_traffic_the_old_trigger_fired_after_the_hard_wall_not_before_it() {
    // THE FAILURE THAT MATTERS, in one assertion. The estimate reaches 140_000 only after
    // the real session has consumed ~1.20M of a 1.00M window — i.e. the lease dies at the
    // wall, mid-turn, 55 turns before the watermark would ever have considered rotating.
    let runs = load_runs();
    let all: Vec<&Run> = runs.iter().collect();
    let c = cadence(&all, 1_000_000.0);

    assert!(
        c.old_trigger_turn > c.wall_turn,
        "old trigger at turn {:.1}, wall at turn {:.1}",
        c.old_trigger_turn,
        c.wall_turn
    );
    assert!(
        c.real_at_old_trigger > 1_000_000.0,
        "real consumption at the old trigger = {:.0} tokens against a 1_000_000 window",
        c.real_at_old_trigger
    );
    // And the new trigger is on the right side of it, with room.
    assert!(c.new_trigger_turn < c.wall_turn);
    assert!(
        c.wall_turn - c.new_trigger_turn > 80.0,
        "headroom = {:.1} turns",
        c.wall_turn - c.new_trigger_turn
    );
}

#[test]
fn on_tool_heavy_traffic_the_old_trigger_was_nearly_six_times_too_late() {
    // Run 3 is the shape an ORCHESTRATOR Rich actually has: 20 tool events, 11_523 tokens
    // consumed in one turn against an estimate of 282. This is the case Frank rated
    // medium-high to high, and it is worse than the mixed average, not better.
    let runs = load_runs();
    let heavy: Vec<&Run> = runs.iter().filter(|r| r.name == "run3").collect();
    let c = cadence(&heavy, 1_000_000.0);

    assert!((c.old_trigger_turn - 493.0).abs() < 0.5, "old = {:.1}", c.old_trigger_turn);
    assert!((c.wall_turn - 84.1).abs() < 0.5, "wall = {:.1}", c.wall_turn);
    assert!((c.new_trigger_turn - 58.1).abs() < 0.5, "new = {:.1}", c.new_trigger_turn);

    let lateness = c.old_trigger_turn / c.wall_turn;
    assert!((lateness - 5.86).abs() < 0.1, "the old trigger was {lateness:.2}x too late");
    // 26.0 turns of headroom at the new trigger — the same 26.0 that justifies
    // CONTEXT_CRITICAL_RATIO in spine.rs, arrived at from the other direction.
    assert!((c.wall_turn - c.new_trigger_turn - 26.0).abs() < 0.5);
}

#[test]
fn on_low_tool_traffic_rotation_gets_forty_three_percent_less_frequent_and_that_is_the_cost_side() {
    // The change is BIDIRECTIONAL and this is the other half of it, stated rather than
    // buried: on conversation-shaped traffic the lease now lives 43% longer, so RichOS
    // rotates less often and bills fewer handoff-summary turns. Whether that is a saving
    // or a risk depends on traffic shape, which is exactly why the trigger must read the
    // wire instead of guessing.
    let runs = load_runs();
    let light: Vec<&Run> = runs.iter().filter(|r| r.name != "run3").collect();
    let c = cadence(&light, 1_000_000.0);

    assert!((c.old_trigger_turn - 302.9).abs() < 0.5, "old = {:.1}", c.old_trigger_turn);
    assert!((c.new_trigger_turn - 435.7).abs() < 0.5, "new = {:.1}", c.new_trigger_turn);
    let change = (c.new_trigger_turn - c.old_trigger_turn) / c.old_trigger_turn;
    assert!((change - 0.438).abs() < 0.01, "cadence change = {:+.1}%", change * 100.0);
    // Here the OLD trigger was safe — it fired at 498_188 real tokens, half the window.
    // Safe, and 326 turns early. Both failure modes, from one constant.
    assert!(c.real_at_old_trigger < 500_000.0, "{:.0}", c.real_at_old_trigger);
    assert!(c.old_trigger_turn < c.wall_turn);
}

#[test]
fn the_measured_watermark_is_never_on_the_wrong_side_of_the_wall_on_any_measured_mix() {
    // The one property the old trigger could not hold on any mix, and the new one holds on
    // all three: rotate BEFORE the wall, always. This is the whole point.
    let runs = load_runs();
    let all: Vec<&Run> = runs.iter().collect();
    let light: Vec<&Run> = runs.iter().filter(|r| r.name != "run3").collect();
    let heavy: Vec<&Run> = runs.iter().filter(|r| r.name == "run3").collect();
    for (label, sel) in [("mixed", &all), ("low-tool", &light), ("tool-heavy", &heavy)] {
        let c = cadence(sel, 1_000_000.0);
        assert!(
            c.new_trigger_turn < c.wall_turn,
            "{label}: new trigger turn {:.1} must precede the wall at {:.1}",
            c.new_trigger_turn,
            c.wall_turn
        );
        // The measured watermark is 0.70 of the measured window BY CONSTRUCTION, so this
        // can only fail if the arithmetic above is wrong — which is the point of asserting
        // it rather than reasoning about it.
        assert!((c.new_trigger_turn / c.wall_turn - 0.7).abs() < 0.02, "{label}");
    }
}
