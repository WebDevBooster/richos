//! A MACHINE THAT HAS NEITHER, SET UP, AND THEN FOUND — the whole sequence, printed.
//!
//! The headless half of `docs/verification/first-run-setup-2026-09-02/`. It runs the SAME
//! `setup::detect`, `setup::install_claude_code` and `setup::install_engine` that the
//! `setup_status` and `run_setup` Tauri commands run, with the SAME `CurlFetcher`,
//! `BashRunner` and `TarExtractor`, so what it prints is what the app does rather than a
//! rehearsal of it.
//!
//! ```bash
//! # a HOME that has never seen RichOS, and nothing else in the environment
//! env -i HOME=/tmp/fresh PATH=/usr/bin:/bin:/usr/sbin:/sbin \
//!   RICHOS_ENGINE_ASSET_FILE=/path/to/richos-engine-1.0.0.tar.gz \
//!   ./setup_demo --install
//! ```
//!
//! # `RICHOS_ENGINE_ASSET_FILE`, and exactly what it costs this proof
//!
//! It is a **build/verification input**, not a runtime setting, and it is here for one
//! measured reason: **the release does not exist yet.** `WebDevBooster/richos` is private
//! today and `ceo-decisions.md` §18 sequences the license — and therefore the repository
//! going public, and therefore its Releases — last. A run against the pinned URL would
//! therefore be a 404, which is a real failure path and is exercised in `setup_failures`,
//! but it is not a fresh-install proof.
//!
//! So when it is set, the bytes come from a file instead of from `curl`, and **everything
//! else in the engine path is the shipping code**: the same pin, the same SHA-256 check
//! before extraction, the same `/usr/bin/tar`, the same shape and version checks, the same
//! atomic swap, the same `INSTALLED-FROM` stamp. What is NOT proved by a run with it set is
//! the HTTPS transport — which is `/usr/bin/curl`, and which the same run DOES exercise for
//! real when it drives Anthropic's installer, because that download is not stood in for.
//!
//! **Claude Code is installed for real, or not at all.** There is no stand-in for it: the
//! license permits driving Anthropic's own installer and nothing else, so `--install` either
//! downloads the real thing into the throwaway HOME or the step is skipped and said to be
//! skipped.
//!
//! **It prints, and it writes only under `$HOME`.** Nothing outside the HOME it is given is
//! read or written by this file.

use std::path::{Path, PathBuf};

use richos_core::setup::{
    self, BashRunner, Component, CurlFetcher, Fetcher, SetupError, SetupPaths, TarExtractor,
};

/// The stand-in for a release asset that does not exist yet. It copies bytes from a path and
/// reports the count, and **it is the only thing this file substitutes** — the digest check
/// that follows is the shipping one, over the bytes this hands over.
struct FileFetcher {
    from: PathBuf,
}

impl Fetcher for FileFetcher {
    fn fetch(&self, _url: &str, dest: &Path) -> Result<u64, SetupError> {
        std::fs::copy(&self.from, dest).map_err(|e| SetupError::DownloadFailed {
            url: self.from.display().to_string(),
            status: e.to_string(),
        })
    }
}

fn main() {
    let install = std::env::args().any(|a| a == "--install");
    let home = match std::env::var_os("HOME").map(PathBuf::from) {
        Some(h) => h,
        None => {
            eprintln!("[demo] no HOME — this demonstration is about a per-user install");
            std::process::exit(2);
        }
    };
    println!("[demo] HOME: {}", home.display());
    println!("[demo] PATH: {}", std::env::var("PATH").unwrap_or_default());

    // ---- BEFORE ------------------------------------------------------------------------
    let paths = SetupPaths::from_process();
    let before = setup::detect(&paths, &[]);
    println!("\n=== before ===");
    report(&before);

    // WHAT THE CEO WOULD BE SHOWN. Not the status — the sheet, which is what he reads.
    println!("\n=== what the sheet says ===");
    for c in before.needs() {
        println!("  {} — {}", c.display_name(), c.why());
    }
    if before.needs().is_empty() {
        println!("  (nothing; a machine that has everything is never asked)");
    }

    if !install {
        println!("\n[demo] read-only run. Pass --install to actually install.");
        std::process::exit(if before.complete() { 0 } else { 1 });
    }

    // ---- CLAUDE CODE, FOR REAL ---------------------------------------------------------
    if !before.claude.present {
        println!("\n=== installing Claude Code, by driving Anthropic's own installer ===");
        println!("  url: {}", setup::CLAUDE_INSTALLER_URL);
        match setup::install_claude_code(&CurlFetcher, &BashRunner, &paths) {
            Ok(r) => {
                println!("  installer: {} bytes", r.installer_bytes);
                println!("  installed: {}", r.installed_at);
                println!(
                    "  signature: {} — {}",
                    if r.signature.trusted { "VERIFIED" } else { "REJECTED" },
                    r.signature.detail
                );
                println!("  checked  : {}", r.signature.checked);
            }
            Err(e) => {
                println!("  FAILED [{}]: {e}", e.kind());
                println!("  your Mac is unchanged: {}", e.machine_unchanged());
                std::process::exit(3);
            }
        }
    }

    // ---- THE ENGINE --------------------------------------------------------------------
    if !before.engine.present {
        println!("\n=== installing the engine ===");
        let pin = match setup::engine_pin() {
            Some(p) => p,
            None => {
                let e = SetupError::EngineUnpinned;
                println!("  FAILED [{}]: {e}", e.kind());
                println!(
                    "  (build with RICHOS_ENGINE_VERSION / RICHOS_ENGINE_URL / \
                     RICHOS_ENGINE_SHA256 set — `app/scripts/make-engine-asset.sh` prints them)"
                );
                std::process::exit(4);
            }
        };
        println!("  pinned version: {}", pin.version);
        println!("  pinned url    : {}", pin.url);
        println!("  pinned sha256 : {}", pin.sha256);

        let asset_file = std::env::var_os("RICHOS_ENGINE_ASSET_FILE").map(PathBuf::from);
        let fetcher: Box<dyn Fetcher> = match &asset_file {
            Some(p) => {
                println!("  transport     : LOCAL FILE {} (standing in for the release asset,", p.display());
                println!("                  which does not exist yet — the repository is private)");
                Box::new(FileFetcher { from: p.clone() })
            }
            None => {
                println!("  transport     : /usr/bin/curl, against the pinned URL");
                Box::new(CurlFetcher)
            }
        };

        let dest = setup::engine_install_dir(&home);
        match setup::install_engine(fetcher.as_ref(), &TarExtractor, &pin, &dest) {
            Ok(r) => {
                println!("  downloaded    : {} bytes", r.bytes);
                println!("  digest        : MATCHED the pin");
                println!("  installed     : {}", r.installed_at);
                println!("  version       : {}", r.version);
                println!("  stamp         : {}", r.stamp.replace('\n', " | "));
            }
            Err(e) => {
                println!("  FAILED [{}]: {e}", e.kind());
                println!("  your Mac is unchanged: {}", e.machine_unchanged());
                std::process::exit(5);
            }
        }
    }

    // ---- AFTER, RE-READ FROM DISK ------------------------------------------------------
    println!("\n=== after (re-read from disk, not inferred from the steps) ===");
    let after = setup::detect(&SetupPaths::from_process(), &[]);
    report(&after);
    if after.complete() {
        println!("\n[demo] nothing is missing.");
        std::process::exit(0);
    }
    println!("\n[demo] SOMETHING IS STILL MISSING — and this is not reported as a success.");
    std::process::exit(6);
}

fn report(s: &setup::SetupStatus) {
    for (c, st) in [(Component::ClaudeCode, &s.claude), (Component::Engine, &s.engine)] {
        if st.present {
            println!(
                "  {:<18} PRESENT at {}{}",
                c.display_name(),
                st.at.as_deref().unwrap_or("?"),
                st.detail.as_deref().map(|d| format!(" ({d})")).unwrap_or_default()
            );
        } else {
            println!("  {:<18} MISSING", c.display_name());
            for place in &st.looked_in {
                println!("  {:<18}   tried {place}", "");
            }
        }
    }
    println!(
        "  {:<18} {}",
        "engine pin",
        match &s.engine_pin_version {
            Some(v) => format!("this build installs engine {v}"),
            None => "NONE — this build cannot install an engine".to_string(),
        }
    );
}
