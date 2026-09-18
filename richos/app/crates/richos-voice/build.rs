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

/// The fixture-location rule, compiled into this build script from the SAME source file the crate
/// compiles it from — `#[path]`, not a copy — so the cfg emitted below and the path the test
/// actually opens cannot drift apart. `src/private_fixtures.rs` depends on nothing but `std`
/// precisely so it can be pulled in here.
#[allow(dead_code)]
#[path = "src/private_fixtures.rs"]
mod private_fixtures;

fn main() {
    // Without this, `--cfg live_audio` trips the `unexpected_cfgs` lint on every build.
    println!("cargo::rustc-check-cfg=cfg(live_audio)");
    println!("cargo::rustc-check-cfg=cfg(private_fixtures)");
    println!("cargo::rerun-if-changed=src/private_fixtures.rs");

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

    private_fixtures_cfg();
}

/// **THE SAME DEFECT, THE SAME FIX, FOR A FILE THAT IS NOT IN THIS REPOSITORY.**
///
/// `ceo-rig-2026-09-18-nearend2-mic.wav` is the microphone track of the CEO speaking over Rich. It
/// is his voice, `richos` is public, so it lives in the private `richos-hq` repository and is
/// absent on any machine that does not have that checkout or has not said where it is.
///
/// The test that measures whether he is heard cannot run without it. **It must therefore report
/// `ignored, <reason>` and never `ok`** — the whole argument in this file's header applies
/// unchanged, and the naive form of this gate (`if !path.exists() { return; }`) is exactly the
/// green-line-asserting-nothing it was written to delete. So availability becomes a cfg here, and
/// the test carries `#[cfg_attr(not(private_fixtures), ignore = "…")]`.
///
/// | state of the machine                                  | report                       |
/// |-------------------------------------------------------|------------------------------|
/// | no `richos-hq`, `RICHOS_PRIVATE_FIXTURES` unset        | `ignored, PRIVATE FIXTURE: …` |
/// | `RICHOS_PRIVATE_FIXTURES=<dir containing the wav>`     | runs, `ok` — and it means it  |
/// | `richos-hq` checked out beside `richos`                | runs, `ok` — and it means it  |
///
/// # The one limitation, named rather than left to be discovered
///
/// `rerun-if-env-changed` puts `RICHOS_PRIVATE_FIXTURES` in this script's fingerprint, so setting
/// or unsetting it recompiles the crate and re-decides the cfg. The FILE APPEARING is not a
/// variable, so it is watched by `rerun-if-changed` on the deepest directory of each candidate
/// path that currently exists — cloning `richos-hq` beside `richos` changes `~/ab`'s mtime, and
/// creating `fixtures/echo-path` inside an existing `richos-hq` changes its. That covers the real
/// cases and is not a proof. If a run reports `ignored` when you believe the file is there,
/// `touch build.rs` (or `cargo clean -p richos-voice`) and run it again; the cfg is then correct.
/// Erring toward `ignored` is the safe direction: it under-claims, and a false `ok` is the thing
/// this file exists to prevent.
fn private_fixtures_cfg() {
    println!("cargo::rerun-if-env-changed={}", private_fixtures::ENV_DIR);

    let manifest = std::path::PathBuf::from(std::env::var("CARGO_MANIFEST_DIR").unwrap());
    for dir in private_fixtures::candidate_dirs(&manifest) {
        // Watch the deepest ANCESTOR THAT EXISTS. A `rerun-if-changed` on a path that is not
        // there makes Cargo re-run this script on every single build, which is a real cost paid
        // by every developer who does not have the private repository — i.e. by almost everyone.
        let mut d: &std::path::Path = &dir;
        loop {
            if d.exists() {
                println!("cargo::rerun-if-changed={}", d.display());
                break;
            }
            match d.parent() {
                Some(p) => d = p,
                None => break,
            }
        }
    }

    match private_fixtures::locate(&manifest, private_fixtures::CEO_MIC_TRACK) {
        // The PATH is deliberately not baked in as a `rustc-env`. The cfg decides whether the test
        // RUNS; the test opens the file itself through the same `locate`, so there is exactly one
        // resolution path and one place for it to be wrong. If the variable changes between build
        // and run, the test's first statement panics with the reason rather than reading a stale
        // compiled-in path.
        Ok(_) => println!("cargo::rustc-cfg=private_fixtures"),
        Err(u) => {
            // A `warning:` line, so it is visible in the build output of the run that is about to
            // report `ignored`, next to the reason libtest will print.
            for line in u.reason().lines() {
                println!("cargo::warning={line}");
            }
        }
    }
}
