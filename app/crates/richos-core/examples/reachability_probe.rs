//! **IS CLAUDE REACHABLE AT THE SIZE THIS INSTALL ACTUALLY WORKS AT?** — the operator's
//! runnable half of `open-items.md` row 3.30's fourth answer.
//!
//! Everything in `reachability.rs` is proved headlessly against an injected upstream. This
//! is the other half: the same rules, against the REAL `claude` on this machine, so the
//! guard has a caller rather than only a test.
//!
//! ## IT COSTS MONEY AND IT SAYS SO BEFORE IT SPENDS ANY
//!
//! A realistic-size probe is realistic-size. Under BYO-Anthropic the customer is billed for
//! every token of it, which is exactly why nothing in RichOS runs one on a timer. This
//! program prints what it is about to send and **refuses to send it without `--spend`**:
//!
//! ```sh
//!   # what it WOULD send, and what it would cost. Sends nothing.
//!   cargo run -p richos-core --example reachability_probe -- <ledger.jsonl> <engine_dir>
//!
//!   # actually run it
//!   cargo run -p richos-core --example reachability_probe -- <ledger.jsonl> <engine_dir> --spend
//! ```
//!
//! ## THE FLOOR IS READ OFF A REAL LEDGER
//!
//! Not a constant, and not this file's opinion. The floor is the LARGEST request this
//! install has actually made — `user_text` plus the reply it drew, per turn, which is the
//! best proxy a ledger holds for what crossed the wire. That is the request that has to work
//! for RichOS to be usable, so it is the size a status has to be earned at.
//!
//! **What it does NOT measure, said plainly.** The ledger holds no record of the re-prime
//! payload's size, so a real turn on a long-lived session is BIGGER than the floor this
//! derives — meaning a `Reachable` verdict here is a floor on the truth, never an
//! overstatement. Erring in that direction is deliberate: the failure mode this row exists
//! to stop is a status that claims more than it proved.

use richos_core::ledger::Ledger;
use richos_core::native::{resolve_claude_bin, NativeCognition};
use richos_core::reachability::{ReachabilityProbe, ReachabilityVerdict};
use richos_core::Cognition;
use std::path::PathBuf;

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let spend = args.iter().any(|a| a == "--spend");
    let positional: Vec<&String> = args.iter().filter(|a| !a.starts_with("--")).collect();

    let ledger_path = positional.first().map(PathBuf::from).unwrap_or_else(|| {
        eprintln!("usage: reachability_probe <conversation-ledger.jsonl> [engine_dir] [--spend]");
        std::process::exit(2);
    });
    let engine_dir = positional
        .get(1)
        .map(|s| PathBuf::from(s.as_str()))
        .unwrap_or_else(|| PathBuf::from("../../engine"));

    // ---- the floor, measured -------------------------------------------------------
    let ledger = match Ledger::open(&ledger_path) {
        Ok(l) => l,
        Err(e) => {
            eprintln!("cannot read {}: {e}", ledger_path.display());
            std::process::exit(1);
        }
    };
    let sizes: Vec<usize> = ledger
        .turns()
        .iter()
        .map(|t| t.user_text.chars().count() + t.assistant_text.chars().count())
        .collect();
    let probe = ReachabilityProbe::from_recent(&sizes);

    println!("ledger        {}", ledger_path.display());
    println!("turns         {}", sizes.len());
    match probe.floor() {
        Some(f) => println!("floor         {} chars (largest of {} measured turns)", f.largest_chars, f.sample),
        None => println!("floor         none — this install has sent nothing measurable"),
    }
    match probe.estimated_cost_chars() {
        Some(n) => println!("would send    {n} chars"),
        None => println!("would send    nothing"),
    }

    if !spend {
        println!("\nNOTHING WAS SENT. Re-run with --spend to actually probe; this request is");
        println!("billed to whoever is signed in to Claude Code on this machine.");
        return;
    }

    // ---- the probe -----------------------------------------------------------------
    let claude_bin = resolve_claude_bin();
    eprintln!("[probe] claude     = {}", claude_bin.display());
    eprintln!("[probe] engine cwd = {}", engine_dir.display());

    let verdict = match NativeCognition::start(&claude_bin, &engine_dir) {
        Err(e) => {
            // A LOCAL failure is reported to `judge` as one, and `judge` refuses to turn it
            // into a statement about the API. That is the point: "claude would not start"
            // and "Anthropic is overloaded" are different problems with different fixes.
            eprintln!("[probe] the local session would not start: {e}");
            probe.judge(0, Err(e.to_string()))
        }
        Ok(mut cognition) => {
            eprintln!("[probe] session    = {}", cognition.session_id());
            let payload = ReachabilityProbe::payload(probe.estimated_cost_chars().unwrap_or(0));
            let sent = payload.chars().count();
            let started = std::time::Instant::now();
            let mut reply = String::new();
            let outcome = cognition.prompt(&payload, &mut |item| {
                if let richos_core::cognition::TurnItem::Text { text, .. } = item {
                    reply.push_str(text);
                }
            });
            let elapsed = started.elapsed();
            eprintln!("[probe] elapsed    = {:.3}s", elapsed.as_secs_f64());

            // BOTH CHANNELS, exactly as `Spine::detect_upstream_failure` reads them: the
            // client's own error, and the assistant TEXT — because `claude` reports an API
            // failure as a message, not as a transport error.
            let result = match outcome {
                Err(e) => Err(e.to_string()),
                Ok(_) => match richos_core::upstream::UpstreamFailure::classify_lines(&reply) {
                    Some(f) => Err(f.raw),
                    None => Ok(()),
                },
            };
            probe.judge(sent, result)
        }
    };

    println!("\nverdict       {}", verdict.summary());
    println!("vouches for the work? {}", verdict.vouches_for(probe.estimated_cost_chars().unwrap_or(0)));
    println!("\n{}", verdict.ceo_message());

    // Exit codes an operator can script against: 0 proved reachable, 1 a classified upstream
    // failure, 3 NOT PROVEN. Three is its own code rather than folded into either, because
    // "we did not establish it" is the answer this whole row exists to stop being rounded.
    std::process::exit(match verdict {
        ReachabilityVerdict::Reachable { .. } => 0,
        ReachabilityVerdict::Failed { .. } => 1,
        ReachabilityVerdict::Unproven { .. } | ReachabilityVerdict::Unmeasured => 3,
    });
}
