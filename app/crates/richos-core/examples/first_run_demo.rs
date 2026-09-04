//! A FRESH INSTALL WITH NO MEMORY, PROVISIONED, AND THEN FOUND — the whole sequence, printed.
//!
//! This is the headless half of `docs/verification/first-run-provisioning-2026-09-01/`. It
//! runs the SAME `provision::provision` the `provision_memory` Tauri command runs and the
//! SAME `CliContextCompiler::locate` the boot runs, so what it prints is what the app does,
//! not a rehearsal of it.
//!
//! ```bash
//! # a HOME that has never seen RichOS, and nothing else in the environment
//! env -i HOME=/tmp/fresh PATH=/usr/bin:/bin:/usr/sbin:/sbin \
//!   RICHOS_LORO_SOURCE=/path/to/loro \
//!   cargo run -p richos-core --example first_run_demo
//! ```
//!
//! `RICHOS_LORO_SOURCE` is an INSTALLER input, not a runtime setting, and it is here because
//! nothing ships the compiler yet: the product repo holds no `loro/` and the signed bundle's
//! `Resources` hold `icon.icns` and nothing else (`BLOCKED.md`). It stands in for the bundle
//! resource that does not exist. **The resolution afterwards reads no environment at all** —
//! that is the half that has to be true on a customer's machine, and it is the half this
//! prints.
//!
//! **It prints; the corpus it creates is empty.** No record of the CEO's is read, written or
//! copied anywhere by this file.

use richos_core::loro::{CliContextCompiler, CorpusPaths};
use richos_core::provision::{
    offered_corpus_dir, provision, CompilerOutcome, GitOutcome, ProvisionRequest,
};
use std::path::PathBuf;

fn main() {
    let home = match std::env::var_os("HOME").map(PathBuf::from) {
        Some(h) => h,
        None => {
            eprintln!("[demo] no HOME — this demonstration is about a per-user install");
            std::process::exit(2);
        }
    };
    println!("[demo] HOME: {}", home.display());

    // WHAT THE APP FINDS BEFORE ANYTHING IS DONE. The same call the boot makes.
    match CliContextCompiler::locate(&CorpusPaths::from_process(), &demo_registry(&home)) {
        Ok((Some((c, source)), _)) => {
            println!("[demo] before: a corpus already resolves at {} (via {})", c.root().path().display(), source.as_str());
            println!("[demo] before: nothing below will run — an existing corpus is left alone");
            return;
        }
        Ok((None, tried)) => {
            println!("[demo] before: no corpus configured. Tried:");
            for t in tried {
                println!("[demo]   {t}");
            }
        }
        Err(e) => println!("[demo] before: {e}"),
    }

    // THE OFFER. This value is what the window pre-fills into the question; it is passed in
    // explicitly here for the same reason it is there — `provision` has no default and
    // refuses a target nobody named.
    let target = offered_corpus_dir(&home);
    println!("[demo] the location offered: {}", target.display());

    // THE SAME LIST THE COMMAND USES — the entity registry, not a name invented here. A
    // partition per company the build knows, so the lane map has something real to reconcile
    // against on the first boot instead of five entities bound to nothing.
    let companies: Vec<(String, String)> = demo_registry(&home)
        .entities()
        .iter()
        .map(|e| (e.id.to_string(), e.display_name.clone()))
        .collect();
    let report = match provision(&ProvisionRequest {
        target,
        home: Some(home.clone()),
        companies,
        compiler_source: None,
    }) {
        Ok(r) => r,
        Err(e) => {
            println!("[demo] REFUSED: {e}");
            std::process::exit(1);
        }
    };

    println!("[demo] provisioned: {}", report.root.display());
    for c in &report.created {
        println!("[demo]   created {}", c.display());
    }
    match &report.pointer {
        Some(p) => println!("[demo] pointer: {} -> {}", p.display(), report.root.display()),
        None => println!("[demo] pointer: none written (no HOME)"),
    }
    match &report.git {
        GitOutcome::Committed { sha, branch } => println!("[demo] git: {branch} @ {sha}, no remote"),
        GitOutcome::Unavailable(why) => println!("[demo] git: unavailable — {why}"),
    }
    match &report.compiler {
        CompilerOutcome::Installed { source, dest, files } => {
            println!("[demo] compiler: {} file(s) from {} -> {}", files, source.display(), dest.display())
        }
        CompilerOutcome::AlreadyPresent(d) => println!("[demo] compiler: already at {}", d.display()),
        CompilerOutcome::NoSource { looked_in } => {
            println!("[demo] compiler: NOT INSTALLED. Looked in:");
            for l in looked_in {
                println!("[demo]   {l}");
            }
        }
        CompilerOutcome::Failed(e) => println!("[demo] compiler: install failed — {e}"),
    }
    for c in &report.companies {
        match &c.problem {
            None => println!("[demo] company partition: {}", c.id),
            Some(p) => println!("[demo] company partition {}: NOT created — {p}", c.id),
        }
    }

    // AND WHAT THE APP FINDS NOW. Same call as the boot, same process, and — when this is
    // run the documented way — an environment holding nothing but HOME and PATH.
    println!("[demo] --- the app's own resolver, run again ---");
    match CliContextCompiler::locate(&CorpusPaths::from_process(), &demo_registry(&home)) {
        Ok((Some((c, source)), _)) => {
            println!(
                "[demo] after: compiling from {} (via {}), tools {}, node {}",
                c.root().path().display(),
                source.as_str(),
                c.tools().dir().display(),
                c.tools().node()
            );
        }
        Ok((None, tried)) => {
            println!("[demo] after: STILL no corpus — this is a defect. Tried:");
            for t in tried {
                println!("[demo]   {t}");
            }
            std::process::exit(1);
        }
        Err(e) => println!("[demo] after: {e}"),
    }
}

/// THE COMPANY THIS DEMO REGISTERS — invented, and belonging to nobody.
///
/// Before 2026-09-04 this was `EntityRegistry::ceos_companies()`: a `const` table of the
/// CEO's six real companies that shipped inside the binary and was the registry of every
/// install. The registry is per-user now (`entity.rs` rule 4) and a fresh machine has none,
/// so a demo that needs a company to exist REGISTERS one, exactly as a first-run user does.
fn demo_registry(home: &std::path::Path) -> richos_core::entity::EntityRegistry {
    let mut registry = richos_core::entity::EntityRegistry::empty();
    registry
        .register(
            richos_core::entity::Entity::try_new(
                "northwind",
                "Northwind Traders",
                vec![home.join("Projects").join("northwind")],
            )
            .expect("a valid demo company"),
        )
        .expect("the first registration cannot conflict with anything");
    registry
}
