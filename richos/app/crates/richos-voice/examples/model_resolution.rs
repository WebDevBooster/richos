//! `cargo run -p richos-voice --example model_resolution`
//!
//! **Which model would hear the CEO on THIS machine, and why that one.** The end-to-end proof
//! that the choice is read off the hardware rather than compiled in.
//!
//! WHY AN EXAMPLE AND NOT A TEST. Same split `toolchain_probe` already uses: the rules in
//! `hardware.rs` are decided from struct literals so they run on any machine including a CI
//! runner with no whisper at all, and this is the other half — the thing you point at a real
//! install to watch the resolution actually happen, with real decodes and a real cache.
//!
//! ```text
//!   cargo run -p richos-voice --example model_resolution
//!       # the plain question, on the machine you are standing on
//!
//!   RICHOS_HW_AVAILABLE_MEMORY_BYTES=500000000 \
//!     cargo run -p richos-voice --example model_resolution
//!       # a forced low-memory machine: watch it demote and say so
//!
//!   RICHOS_VOICE_WHISPER_MODEL_ID=large-v3-turbo \
//!     cargo run -p richos-voice --example model_resolution
//!       # an engineer's override: watch the resolver stand down entirely
//! ```
//!
//! The first run on a machine pays for one `say` render and one decode per rung tried; every run
//! after that reads the cache. `--fresh` deletes the cache first, which is how the calibration
//! itself gets watched rather than assumed.

use richos_voice::hardware::{self, Basis, Costs, Machine};
use richos_voice::stt::{Recognizer, SttError};

fn gb(bytes: u64) -> String {
    format!("{:.2} GB", bytes as f64 / 1_000_000_000.0)
}

fn main() {
    if std::env::args().any(|a| a == "--fresh") {
        let p = hardware::speed_cache_path();
        match std::fs::remove_file(&p) {
            Ok(()) => println!("cleared the speed cache at {}\n", p.display()),
            Err(_) => println!("no speed cache to clear at {}\n", p.display()),
        }
    }

    let machine = Machine::read();
    let costs = Costs::load();

    println!("== THIS MACHINE, as it answers for itself ==");
    println!("  hw.memsize                          {} ({} B)", gb(machine.total_bytes), machine.total_bytes);
    println!("  available now                       {} ({} B)", gb(machine.available_bytes), machine.available_bytes);
    println!("  cores                               {}", machine.cores);
    println!("  memory pressure                     {}  <- RECORDED, DECIDES NOTHING", machine.pressure.as_str());
    println!("      it reads WARN on the CEO's own machine during ordinary work, in all six");
    println!("      samples — a resolver that demoted on it would demote him permanently.");
    println!();

    println!("== THE LADDER, best first, and what each rung costs ==");
    println!("  live ceiling                        {:.3} s per utterance  (stt.rs's stated failure point)", costs.live_ceiling_secs);
    println!("  live target                         {:.3} s               (stt.rs's stated promise)", costs.live_target_secs);
    println!("  safe rung when unmeasurable         {}", costs.safe_rung);
    println!();
    let mut installed = costs.clone();
    installed.retain_installed(|id| richos_voice::stt::resolve_model(id).is_ok());
    for id in &costs.live_ladder {
        let here = installed.live_ladder.contains(id);
        let cost = &costs.models[id];
        println!(
            "  {:<22} peak {:>13} B   reference {:.3} s/utt   {}",
            id,
            cost.utterance_peak_rss,
            cost.reference_utterance_secs,
            if here { "installed" } else { "NOT INSTALLED — not a rung on this machine" }
        );
    }
    println!();
    println!("  Note the ordering of the two middle rows: large-v3-turbo-q5_0 costs LESS resident");
    println!("  memory than small.en. The model kept for \"low-RAM hosts\" is the more expensive of");
    println!("  the two — memory never chose it, latency did.");
    println!();

    println!("== WHAT IT RESOLVED TO, end to end ==");
    match Recognizer::resolve() {
        Ok(rec) => {
            let r = rec.resolution();
            println!("  model                               {}", rec.model_id());
            println!("  weights                             {}", rec.model_path().display());
            println!("  basis                               {:?}", r.basis);
            if let Some((rejected, secs)) = &r.rejected {
                if *secs > 0.0 {
                    println!("  rejected                            {rejected} at {secs:.3} s/utt on this machine");
                } else {
                    println!("  rejected                            {rejected} — does not fit the memory available");
                }
            }
            if let Some(s) = r.measured_secs {
                println!("  measured here                       {s:.3} s/utt");
                if let Some(f) = hardware::speed_factor(&costs, &r.model_id, s) {
                    println!("  speed factor vs the reference M4    {f:.2}x   (1.00 = as fast)");
                }
            }
            println!();
            println!("  provenance line carried by every transcript:");
            println!("    {}", rec.provenance_full());
            println!();
            match r.ceo_message() {
                Some(m) => {
                    println!("  WHAT THE CEO IS TOLD, on a surface he reads:");
                    println!("    \"{m}\"");
                }
                None => {
                    println!("  WHAT THE CEO IS TOLD: nothing, and deliberately.");
                    println!("    {}", if r.basis == Basis::Override {
                        "an engineer named this model; his own choice is not explained back to him."
                    } else {
                        "this machine got the best rung it has. The product working as designed is\n    not a notification, and noise is what makes a real notice get ignored."
                    });
                }
            }
        }
        Err(SttError::ToolchainRefused(detail)) => {
            println!("  REFUSED by the toolchain check: {detail}");
        }
        Err(e) => {
            println!("  could not resolve a recognizer: {e}");
            println!("  the CEO would see: \"{}\"", e.ceo_message());
        }
    }

    println!();
    println!("speed cache: {}", hardware::speed_cache_path().display());
}
