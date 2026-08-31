//! Headless proof that the rotation watermark is driven by the AGENT'S OWN reported token
//! numbers on a REAL turn, against the REAL `claude` binary — no mock, no GUI, no window,
//! no npm.
//!
//! A unit test proves the arithmetic. It cannot prove that the numbers actually arrive from
//! the live binary, in the phase where the spine can see it, in a shape
//! `MachineryRecord::context_usage` can read. That is what this is for, and it is why the
//! done-criterion for this change was "demonstrated on a real turn, not a unit test alone".
//!
//! **CAVEAT C3, AND THE LIVE RUN THAT NARROWED IT.** On this wire the numerator arrives
//! mid-turn on `stream_event/message_delta` and the denominator only when a turn ENDS, on
//! `result.modelUsage[<session model>].contextWindow` — so a lease's FIRST turn has a
//! numerator and no denominator. Measured 2026-08-31 through this example: the CEO never
//! sees that gap, because the lease's first turn is the RE-PRIME turn, which ends and
//! supplies the denominator before the CEO's first prompt is sent. The output below reads
//! `after one live turn source=measured`, and that is turn TWO on the lease.
//!
//! The gap is real and it is where the re-prime is: a lease that is handed a CEO turn with
//! no priming turn first has no measurement until that turn ends.
//! `between_turn_tests.rs::traffic_after_the_turn_result_lands_in_the_lane_and_not_in_the_finished_turn`
//! drives a raw client with no re-prime and pins exactly that.
//!
//! Four things it demonstrates, in order:
//!
//!   1. **The fallback state is real and is labelled.** Before the first turn the spine
//!      reports `ContextSource::Estimated` and hands out no measurement at all.
//!   2. **The measurement arrives and takes over.** After one CEO turn the source flips to
//!      `Measured`, `used`/`size` are the agent's, and the window the spine reports is the
//!      one the wire stated (`claude-sonnet-5`: **1_000_000**), not the 200_000 the app used
//!      to assume — and NOT `claude-haiku-4-5`'s 200_000, which is what an arbitrary read of
//!      the `modelUsage` map returns (findings §10) and is the same number by coincidence,
//!      which is exactly why the denominator is keyed BY MODEL NAME.
//!
//!      **The live run of 2026-08-31 also measured how wrong the estimate was**, on the same
//!      turn, which no unit test can: the chars÷4 estimate read **632** tokens against a
//!      measured **19,477** — **30.8x under**. The estimate is not a slightly worse
//!      measurement; on a fresh lease it is off by an order of magnitude and a half, because
//!      it counts the CEO's words and the reply and cannot see the system prompt, the
//!      persona, the hooks or the cached context the model is actually holding.
//!   3. **It drives rotation.** With the ratio set BELOW the fraction the adapter actually
//!      reported, the next turn boundary rotates for `context-watermark` — decided by real
//!      `used`/`size`, and the backing session id provably changes.
//!   4. **The successor inherits nothing.** After the swap the spine is back on
//!      `Estimated` with no carried-over number, which is what stops rotation becoming a
//!      loop.
//!
//! Run (needs the `claude` CLI installed and logged in — no npm, no adapter):
//!   cd app \
//!     cargo run -p richos-core --example watermark_roundtrip -- <engine_dir>
//!
//! It asserts its own claims and exits non-zero if any of them fails.

use richos_core::native::{resolve_claude_bin, NativeCognition};
use richos_core::cognition::{Cognition, CognitionError, LeaseFactory};
use richos_core::entity::EntityId;
use richos_core::ledger::{Ledger, Source};
use richos_core::spine::{ContextSource, Spine};
use std::path::PathBuf;

/// Mirrors `src-tauri/src/main.rs`'s `EngineLeaseFactory`, exactly as `rotation_roundtrip`
/// does — the point is to exercise the production seam, not a test-only one.
struct LiveLeaseFactory {
    claude_bin: PathBuf,
    engine_dir: PathBuf,
}
impl LeaseFactory for LiveLeaseFactory {
    fn spawn(&self) -> Result<Box<dyn Cognition>, CognitionError> {
        Ok(Box::new(NativeCognition::start(&self.claude_bin, &self.engine_dir)?))
    }
}

fn report(spine: &Spine, label: &str) {
    let src = spine.context_source();
    match spine.context_usage() {
        Some(u) => eprintln!(
            "[watermark] {label:<22} source={:<9} used={} size={} = {:.4}%  window={}  reached={}",
            src.as_str(),
            u.used,
            u.size,
            u.fraction() * 100.0,
            spine.context_window_tokens(),
            spine.watermark_reached()
        ),
        None => eprintln!(
            "[watermark] {label:<22} source={:<9} used=<none reported> estimate={} tokens  window={}  reached={}",
            src.as_str(),
            spine.context_estimate_tokens(),
            spine.context_window_tokens(),
            spine.watermark_reached()
        ),
    }
}

fn main() {
    let mut args = std::env::args().skip(1);
    let engine_dir = args.next().map(PathBuf::from).unwrap_or_else(|| PathBuf::from("../../engine"));

    let scratch = std::env::temp_dir().join(format!("richos-watermark-roundtrip-{}.jsonl", std::process::id()));
    let ledger = Ledger::open(&scratch).expect("open ledger");
    let mut spine = Spine::new(ledger);
    let thread = spine.create_thread("Watermark proof", &EntityId::parse("richos").unwrap()).expect("thread");

    let claude_bin = resolve_claude_bin();
    eprintln!("[watermark] claude    = {}", claude_bin.display());
    eprintln!("[watermark] engine cwd = {}", engine_dir.display());

    let factory = LiveLeaseFactory { claude_bin: claude_bin.clone(), engine_dir: engine_dir.clone() };
    let initial = factory.spawn().expect("start the initial native claude session");
    let session0 = initial.session_id().to_string();
    eprintln!("[watermark] session 0 = {session0}");
    spine.attach_lease(initial);
    spine.set_lease_factory(Box::new(factory));

    // ---- 1. THE FALLBACK, before anything has been reported ---------------------
    report(&spine, "before any turn");
    assert_eq!(
        spine.context_source(),
        ContextSource::Estimated,
        "a lease that has not reported must say so, not pretend to a measurement"
    );
    assert!(spine.context_usage().is_none(), "there is no measurement to hand out yet");

    // ---- 2. ONE REAL TURN, and the measurement takes over -----------------------
    println!("\nCEO> In five words or fewer, what is 2+2?\n");
    spine.submit_prompt("In five words or fewer, what is 2+2?", Source::Text).expect("turn 1");
    let msgs = spine.messages(&thread).expect("read");
    println!("Rich> {}\n", msgs.last().map(|m| m.text.as_str()).unwrap_or("<none>"));
    report(&spine, "after one live turn");

    let usage = spine.context_usage().expect(
        "THE PROOF: `usage_update` must reach the spine from the live adapter. If this is \
         None, the wire, the phase, or the payload shape changed and the watermark is back \
         on the estimate — which is the defect this example exists to catch.",
    );
    assert_eq!(spine.context_source(), ContextSource::Measured);
    assert!(usage.used > 0 && usage.size > 0, "a measurement needs both halves: {usage:?}");
    assert_eq!(
        spine.context_window_tokens(),
        usage.size as usize,
        "the window the spine reports must be the one the ADAPTER stated"
    );
    eprintln!(
        "[watermark] the wire's window is {} against the app's old assumption of 200000 ({:.1}x)",
        usage.size,
        usage.size as f64 / 200_000.0
    );

    // The estimate is computed alongside, and printed, so the size of what was being
    // trusted is visible rather than described.
    eprintln!(
        "[watermark] over the SAME turn the chars/4 estimate reads {} tokens against a measured {} ({:.1}x under)",
        spine.context_estimate_tokens(),
        usage.used,
        usage.used as f64 / spine.context_estimate_tokens().max(1) as f64
    );

    // ---- 3. REAL used/size DRIVES ROTATION --------------------------------------
    // Set the ratio just under the fraction the adapter actually reported. Nothing else
    // changes: the numerator and denominator are both the adapter's.
    let ratio = (usage.fraction() * 0.9).max(0.0001);
    eprintln!(
        "\n[watermark] setting watermark_ratio = {ratio:.6} (90% of the MEASURED fraction {:.6})",
        usage.fraction()
    );
    spine.set_context_budget(200_000, ratio); // window arg deliberately still the old guess
    assert_eq!(
        spine.context_window_tokens(),
        usage.size as usize,
        "the measured window must outrank the configured one"
    );
    assert!(spine.watermark_reached(), "the MEASURED fraction is now over the ratio");

    let rotations_before = spine.rotation_count();
    println!("\nCEO> Say the word: ok\n");
    spine.submit_prompt("Say the word: ok", Source::Text).expect("turn 2");
    let msgs = spine.messages(&thread).expect("read");
    println!("Rich> {}\n", msgs.last().map(|m| m.text.as_str()).unwrap_or("<none>"));

    eprintln!(
        "[watermark] rotation_count {rotations_before} -> {} reason={:?}",
        spine.rotation_count(),
        spine.last_rotation_reason()
    );
    assert_eq!(spine.rotation_count(), rotations_before + 1, "the measured watermark must have rotated");
    assert_eq!(spine.last_rotation_reason(), Some("context-watermark"));

    let session1 = spine.lease_session_id().expect("a lease is attached").to_string();
    eprintln!("[watermark] session before = {session0}");
    eprintln!("[watermark] session after  = {session1}");
    assert_ne!(session0, session1, "rotation must actually swap the backing session");

    // ---- 4. THE SUCCESSOR INHERITS NOTHING --------------------------------------
    report(&spine, "after rotation");
    assert!(
        spine.context_usage().is_none(),
        "the dead session's number must not survive it — carrying it forward would put the \
         successor over the watermark on its first turn and rotate forever"
    );
    assert_eq!(spine.context_source(), ContextSource::Estimated, "a fresh lease is back on the fallback");

    // And it is not a loop: one more real turn, still exactly one rotation... unless the
    // fresh session's own reported usage legitimately crosses the (now very low) ratio,
    // which is a correct rotation and not the bug. So the ratio is restored first.
    spine.set_context_budget(200_000, 0.70);
    println!("\nCEO> Without re-explaining, what did I just ask you?\n");
    spine.submit_prompt("Without re-explaining, what did I just ask you?", Source::Text).expect("turn 3");
    let msgs = spine.messages(&thread).expect("read");
    println!("Rich> {}\n", msgs.last().map(|m| m.text.as_str()).unwrap_or("<none>"));
    report(&spine, "after successor's turn");
    assert_eq!(spine.rotation_count(), rotations_before + 1, "a fresh lease must not rotate itself immediately");

    eprintln!("\n[watermark] rendered messages across the rotation = {}", msgs.len());
    eprintln!("[watermark] ledger at {}", scratch.display());
    println!("PASS — the rotation watermark ran on the adapter's own numbers, on real turns.");
}
