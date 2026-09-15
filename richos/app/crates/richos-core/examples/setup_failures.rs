//! EVERY FAILURE PATH, AGAINST THE REAL SYSTEM — `curl`, `tar`, `codesign`, and a real host.
//!
//! `crates/richos-core/tests/setup.rs` exercises all twelve failures through injected seams,
//! which is where they belong: a test that needs a network condition somebody has to arrange
//! is a test that stops being run. **This file is the other half, and it exists because a
//! seam can be right about a fake and wrong about the real thing.** Two defects found on
//! 2026-09-01 were both of that shape — `codesign -R` reading its argument as a filename, and
//! `stapler` exiting 0 on a symlink having validated nothing — and neither was visible to a
//! fake.
//!
//! So every case below runs the SHIPPING `CurlFetcher` / `TarExtractor` /
//! `verify_claude_signature` against a real network, a real archive, and a real signature,
//! and prints the sentence the CEO would read plus the tag the operator's log would carry.
//!
//! ```bash
//! env -i HOME=/tmp/failures PATH=/usr/bin:/bin:/usr/sbin:/sbin ./setup_failures
//! ```
//!
//! **It installs nothing and writes only under `$HOME`.** Every case asserts, and prints,
//! that nothing was left behind.

use std::path::{Path, PathBuf};

use richos_core::setup::{
    self, CurlFetcher, EnginePin, Extractor, Fetcher, SetupError, TarExtractor,
};

fn main() {
    let home = std::env::var_os("HOME").map(PathBuf::from).expect("HOME");
    let work = home.join("failures");
    std::fs::create_dir_all(&work).unwrap();
    println!("[failures] work: {}", work.display());
    let mut failed = 0usize;

    // ---- 1. NO NETWORK (a host that does not resolve) ----------------------------------
    // A name reserved by RFC 6761 to never resolve, so this is a real DNS failure and not a
    // guess about one.
    failed += case(
        "no network — a host that cannot be resolved",
        "no-network",
        &work,
        |dest| CurlFetcher.fetch("https://richos-setup-probe.invalid/engine.tar.gz", dest),
    );

    // ---- 2. A RELEASE ASSET THAT IS NOT THERE ------------------------------------------
    // A real request to the real host the pin names, for a tag that does not exist. This is
    // exactly what every customer would get if a build shipped before its upload.
    failed += case(
        "the release asset is not there — a real 404 from the real host",
        "download-failed",
        &work,
        |dest| {
            CurlFetcher.fetch(
                "https://github.com/WebDevBooster/richos/releases/download/no-such-tag-9e1f/richos-engine-0.0.0.tar.gz",
                dest,
            )
        },
    );

    // ---- 3. PLAIN HTTP IS REFUSED AT THE WIRE ------------------------------------------
    // `--proto '=https'`. The pin's https rule is a string check; this is the same rule
    // enforced by curl itself, so a redirect could not talk it out of one.
    failed += case(
        "plain http is refused at the wire, not only in the pin",
        "download-failed",
        &work,
        |dest| CurlFetcher.fetch("http://example.com/engine.tar.gz", dest),
    );

    // ---- 4. A TAMPERED ARCHIVE -------------------------------------------------------
    // The digest is checked BEFORE `tar` is handed anything, so the extractor below would
    // panic if it were ever reached.
    let dest = work.join("engine-tampered");
    let tampered = work.join("tampered.tar.gz");
    std::fs::write(&tampered, b"these are not the bytes the pin names").unwrap();
    struct MustNotRun;
    impl Extractor for MustNotRun {
        fn extract(&self, _a: &Path, _i: &Path) -> Result<(), SetupError> {
            panic!("EXTRACTION RAN ON BYTES THAT FAILED THE DIGEST CHECK");
        }
    }
    struct LocalFile(PathBuf);
    impl Fetcher for LocalFile {
        fn fetch(&self, _u: &str, d: &Path) -> Result<u64, SetupError> {
            std::fs::copy(&self.0, d).map_err(|e| SetupError::DownloadFailed {
                url: self.0.display().to_string(),
                status: e.to_string(),
            })
        }
    }
    let pin = a_pin("0000000000000000000000000000000000000000000000000000000000000000");
    failed += engine_case(
        "a tampered archive — the digest stops it before tar ever sees it",
        "digest-mismatch",
        &LocalFile(tampered),
        &MustNotRun,
        &pin,
        &dest,
    );

    // ---- 5. AN ARCHIVE THAT IS NOT AN ENGINE, THROUGH REAL TAR -------------------------
    // A genuine gzip tarball with the wrong thing inside it, extracted by /usr/bin/tar.
    let junk_dir = work.join("junk/not-an-engine");
    std::fs::create_dir_all(&junk_dir).unwrap();
    std::fs::write(junk_dir.join("hello.txt"), b"hi\n").unwrap();
    let junk_tar = work.join("junk.tar.gz");
    run_tar_create(&work.join("junk"), &junk_tar);
    let junk_digest = setup::sha256_file(&junk_tar).unwrap();
    failed += engine_case(
        "a real tarball with the wrong thing inside it, through real tar",
        "engine-shape-invalid",
        &LocalFile(junk_tar.clone()),
        &TarExtractor,
        &a_pin(&junk_digest),
        &work.join("engine-junk"),
    );

    // ---- 6. AN ENGINE-SHAPED ARCHIVE WITH THE WRONG VERSION ----------------------------
    let e_dir = work.join("wrongver/engine");
    std::fs::create_dir_all(e_dir.join("scripts/hooks")).unwrap();
    std::fs::write(e_dir.join("VERSION"), b"9.9.9\n").unwrap();
    let ver_tar = work.join("wrongver.tar.gz");
    run_tar_create(&work.join("wrongver"), &ver_tar);
    let ver_digest = setup::sha256_file(&ver_tar).unwrap();
    failed += engine_case(
        "an engine-shaped archive carrying a version the pin does not name",
        "engine-version-mismatch",
        &LocalFile(ver_tar),
        &TarExtractor,
        &a_pin(&ver_digest),
        &work.join("engine-wrongver"),
    );

    // ---- 7. A BINARY THAT IS NOT ANTHROPIC'S, THROUGH REAL CODESIGN --------------------
    // The negative half of the signature pin, run against the real `/usr/bin/codesign`.
    println!("\n=== a binary that is not Anthropic's, through real codesign ===");
    let fake = work.join("fake-claude");
    std::fs::write(&fake, b"#!/bin/sh\necho not claude\n").unwrap();
    let verdict = setup::verify_claude_signature(&fake);
    println!("  trusted : {}", verdict.trusted);
    println!("  checked : {}", verdict.checked);
    println!("  codesign: {}", verdict.detail);
    if verdict.trusted {
        println!("  UNEXPECTED — a plain file satisfied Anthropic's designated requirement");
        failed += 1;
    } else {
        println!("  REFUSED, which is the outcome that keeps an unverified binary from running.");
    }

    // ---- 8. THE POSITIVE HALF, if this machine has the real one ------------------------
    // A negative-only signature check is one that passes because everything fails.
    println!("\n=== the real claude on this machine, through the same function ===");
    let real = home.join(".local/bin/claude");
    if real.exists() {
        let v = setup::verify_claude_signature(&real);
        println!("  trusted : {}", v.trusted);
        println!("  checked : {}   <- the SYMLINK was resolved first", v.checked);
        println!("  codesign: {}", v.detail);
        if !v.trusted {
            println!("  UNEXPECTED — the installed claude failed its own designated requirement");
            failed += 1;
        }
    } else {
        println!("  not present under this HOME — the negative case above still ran.");
    }

    // ---- 9. NOTHING WAS LEFT BEHIND ----------------------------------------------------
    println!("\n=== residue: what any of the above left in the install locations ===");
    let mut residue = 0usize;
    for d in [
        work.join("engine-tampered"),
        work.join("engine-junk"),
        work.join("engine-wrongver"),
    ] {
        let here: Vec<String> = std::fs::read_dir(d.parent().unwrap())
            .map(|rd| {
                rd.flatten()
                    .map(|e| e.file_name().to_string_lossy().to_string())
                    .filter(|n| n.starts_with(d.file_name().unwrap().to_string_lossy().as_ref()))
                    .collect()
            })
            .unwrap_or_default();
        for n in &here {
            println!("  LEFT BEHIND: {n}");
            residue += 1;
        }
    }
    println!("  residue: {residue}");
    failed += residue;

    println!("\n[failures] {}", if failed == 0 { "every failure behaved" } else { "SOMETHING DID NOT BEHAVE" });
    std::process::exit(if failed == 0 { 0 } else { 1 });
}

fn a_pin(sha: &str) -> EnginePin {
    setup::pin_from_parts(
        "1.0.0",
        "https://github.com/WebDevBooster/richos/releases/download/engine-v1.0.0/richos-engine-1.0.0.tar.gz",
        sha,
    )
    .expect("the fixture pin must itself be well formed")
}

/// Create a deterministic-enough gzip tarball of `dir`'s CONTENTS (so the top level inside
/// the archive is whatever `dir` holds). Only used to build fixtures.
fn run_tar_create(dir: &Path, out: &Path) {
    let status = std::process::Command::new("/usr/bin/tar")
        .args(["-c", "-z", "-f"])
        .arg(out)
        .arg("-C")
        .arg(dir)
        .arg(".")
        .status()
        .expect("tar");
    assert!(status.success(), "could not build the fixture archive");
}

/// A fetch that must fail, printed with the sentence and the tag.
fn case(
    title: &str,
    expect_kind: &str,
    work: &Path,
    f: impl Fn(&Path) -> Result<u64, SetupError>,
) -> usize {
    println!("\n=== {title} ===");
    let dest = work.join("download-under-test");
    let _ = std::fs::remove_file(&dest);
    match f(&dest) {
        Ok(n) => {
            println!("  UNEXPECTED SUCCESS — {n} bytes arrived");
            1
        }
        Err(e) => {
            println!("  kind    : {}", e.kind());
            println!("  he reads: {e}");
            println!("  Mac unchanged: {}", e.machine_unchanged());
            let leftover = dest.exists();
            println!("  partial file left behind: {leftover}");
            let mut bad = 0;
            if e.kind() != expect_kind {
                println!("  UNEXPECTED KIND — expected {expect_kind}");
                bad += 1;
            }
            if leftover {
                println!("  UNEXPECTED RESIDUE");
                let _ = std::fs::remove_file(&dest);
                bad += 1;
            }
            bad
        }
    }
}

/// An engine install that must fail, printed the same way, and asserting nothing landed.
fn engine_case(
    title: &str,
    expect_kind: &str,
    fetcher: &dyn Fetcher,
    extractor: &dyn Extractor,
    pin: &EnginePin,
    dest: &Path,
) -> usize {
    println!("\n=== {title} ===");
    match setup::install_engine(fetcher, extractor, pin, dest) {
        Ok(r) => {
            println!("  UNEXPECTED SUCCESS — installed {} at {}", r.version, r.installed_at);
            1
        }
        Err(e) => {
            println!("  kind    : {}", e.kind());
            println!("  he reads: {e}");
            println!("  Mac unchanged: {}", e.machine_unchanged());
            println!("  anything installed at the destination: {}", dest.exists());
            let mut bad = 0;
            if e.kind() != expect_kind {
                println!("  UNEXPECTED KIND — expected {expect_kind}");
                bad += 1;
            }
            if dest.exists() {
                println!("  UNEXPECTED — something was installed after a failure");
                bad += 1;
            }
            bad
        }
    }
}
