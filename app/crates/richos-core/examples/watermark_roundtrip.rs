//! Headless proof that the rotation watermark is driven by the ADAPTER'S OWN
//! `usage_update` numbers on a REAL turn, against the REAL `claude-agent-acp` — no mock,
//! no GUI, no window.
//!
//! A unit test proves the arithmetic. It cannot prove that `usage_update` actually arrives
//! from the live adapter, in the phase where the spine can see it, in a shape
//! `MachineryRecord::context_usage` can read. That is what this is for, and it is why the
//! done-criterion for this change was "demonstrated on a real turn, not a unit test alone".
//!
//! Four things it demonstrates, in order:
//!
//!   1. **The fallback state is real and is labelled.** Before the first turn the spine
//!      reports `ContextSource::Estimated` and hands out no measurement at all.
//!   2. **The measurement arrives and takes over.** After one live turn the source flips to
//!      `Measured`, `used`/`size` are the adapter's, and the window the spine reports is the
//!      one the wire stated (1_000_000 on every event measured on 2026-08-28), not the
//!      200_000 the app used to assume.
//!   3. **It drives rotation.** With the ratio set BELOW the fraction the adapter actually
//!      reported, the next turn boundary rotates for `context-watermark` — decided by real
//!      `used`/`size`, and the backing session id provably changes.
//!   4. **The successor inherits nothing.** After the swap the spine is back on
//!      `Estimated` with no carried-over number, which is what stops rotation becoming a
//!      loop.
//!
//! Run (needs the `claude` CLI logged in; adapter under app/acp-adapter — `npm i` there once):
//!   cd app && RICHOS_ACP_BIN=$PWD/acp-adapter/node_modules/.bin/claude-agent-acp \
//!     cargo run -p richos-core --example watermark_roundtrip -- <engine_dir>
//!
//! It asserts its own claims and exits non-zero if any of them fails.

use richos_core::acp::{resolve_acp_bin, AcpCognition};
use richos_core::cognition::{Cognition, CognitionError, LeaseFactory};
use richos_core::entity::EntityId;
use richos_core::ledger::{Ledger, Source};
use richos_core::spine::{ContextSource, Spine};
use std::path::PathBuf;

/// Mirrors `src-tauri/src/main.rs`'s `EngineLeaseFactory`, exactly as `rotation_roundtrip`
/// does — the point is to exercise the production seam, not a test-only one.
struct LiveLeaseFactory {
    acp_bin: PathBuf,
    engine_dir: PathBuf,
}
impl LeaseFactory for LiveLeaseFactory {
    fn spawn(&self) -> Result<Box<dyn Cognition>, CognitionError> {
        Ok(Box::new(AcpCognition::start(&self.acp_bin, &self.engine_dir)?))
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

    let acp_bin = resolve_acp_bin(None);
    eprintln!("[watermark] adapter   = {}", acp_bin.display());
    eprintln!("[watermark] engine cwd = {}", engine_dir.display());

    let factory = LiveLeaseFactory { acp_bin: acp_bin.clone(), engine_dir: engine_dir.clone() };
    let initial = factory.spawn().expect("start initial ACP session");
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
