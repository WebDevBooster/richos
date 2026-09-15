//! **THE ONLY REASON THIS FILE EXISTS: A TEST THAT DID NOT RUN MUST NOT PRINT `ok`.**
//!
//! Four tests in this crate opened a real audio device, so they were gated behind
//! `RICHOS_VOICE_LIVE_AUDIO=1` — correctly, because one of them is audible for about a
//! second and the others need hardware a build machine does not have. The gate was written
//! as an early `return` at the top of the test body:
//!
//! ```ignore
//! if std::env::var("RICHOS_VOICE_LIVE_AUDIO").as_deref() != Ok("1") { return; }
//! ```
//!
//! **A test that returns is reported `ok`.** So on every machine that had not opted in —
//! which is every machine except the CEO's, plus `app-voice-ci.yml`'s `macos-latest` runner
//! from the day it landed — four green lines asserted nothing, and a reader counting 172
//! passing tests was counting four that never happened. `app-voice-ci.yml` named the defect
//! in its own header and left it, because the tests are this crate's to change, not that
//! file's. This is that change.
//!
//! # Why `#[ignore]` alone does not fit
//!
//! `#[ignore]` is the right REPORT — libtest prints `ignored, <reason>` and counts it in a
//! separate `N ignored` column, so both properties fall out for free. But it is a
//! **compile-time attribute** and the opt-in is a **run-time variable**. A bare `#[ignore]`
//! would mean `RICHOS_VOICE_LIVE_AUDIO=1 cargo test -p richos-voice` no longer runs them:
//! the documented way to exercise the live path would silently stop working, which is the
//! same failure — a command that looks like it did something — pointed the other way.
//!
//! # What this does instead
//!
//! It converts the run-time variable into a compile-time cfg, which is exactly the mismatch
//! above, resolved at the only place that can resolve it. `cargo::rerun-if-env-changed` puts
//! the variable in this script's fingerprint, so Cargo recompiles the crate when it is set
//! and recompiles it again when it is unset. The tests then carry
//! `#[cfg_attr(not(live_audio), ignore = "…")]`:
//!
//! | invocation                                          | report                          |
//! |-----------------------------------------------------|---------------------------------|
//! | `cargo test -p richos-voice`                         | `ignored, LIVE AUDIO: …`        |
//! | `RICHOS_VOICE_LIVE_AUDIO=1 cargo test -p richos-voice` | runs, `ok` — and it means it  |
//!
//! The existing opt-in command is unchanged. The default run stops lying.
//!
//! # The one hole this does not leave open
//!
//! `#[ignore]` suppresses the RUN, not the BODY. `cargo test -- --include-ignored` on a
//! machine that has not opted in would therefore still open a real output device and make
//! noise. Each of the four keeps a positive guard as its first statement —
//! `crate::live_audio::require_opt_in()` — which panics with an instruction rather than
//! returning. That is the same condition the deleted `return` tested, with the opposite
//! failure mode: asked-for and impossible is a red line that explains itself, never a green
//! one that does not.

fn main() {
    // Without this, `--cfg live_audio` trips the `unexpected_cfgs` lint on every build.
    println!("cargo::rustc-check-cfg=cfg(live_audio)");

    // THE LOAD-BEARING LINE. Cargo hashes this variable's value into the build script's
    // fingerprint, so flipping it re-runs this script and recompiles the crate. Without it
    // the cfg would be whatever it was the first time the crate was built and would never
    // change again — a gate that silently stopped responding to its own switch.
    println!("cargo::rerun-if-env-changed=RICHOS_VOICE_LIVE_AUDIO");

    // Exactly `1`, matching what the tests, `examples/aec_live.rs` and `examples/aec_probe.rs`
    // have always checked for. `0`, `true` and `yes` are not opt-ins here and never were.
    if std::env::var("RICHOS_VOICE_LIVE_AUDIO").as_deref() == Ok("1") {
        println!("cargo::rustc-cfg=live_audio");
    }
}
