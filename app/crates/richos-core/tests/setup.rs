//! FIRST-RUN SETUP — every failure path exercised, none described.
//!
//! The three seams in `setup.rs` ([`Fetcher`], [`Runner`], [`Extractor`]) exist for exactly
//! this: "no network", "a 404", "a truncated body", "a tampered body", "an installer that
//! refuses" and "an archive with the wrong thing in it" are **values** here, so none of them
//! needs a network condition somebody has to arrange, and none can be skipped because it was
//! inconvenient to reproduce.
//!
//! It is an INTEGRATION test rather than a `#[cfg(test)]` module on purpose: everything below
//! goes through the crate's public surface, which proves the surface is sufficient for the
//! Tauri layer that consumes it, and keeps a private helper from being tested in place of the
//! thing that ships.

use std::path::{Path, PathBuf};
use std::sync::Mutex;

use richos_core::setup::*;

fn scratch(name: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!(
        "richos-setup-{name}-{}",
        std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos()
    ));
    std::fs::create_dir_all(&dir).unwrap();
    dir
}

/// A directory that passes [`engine_looks_valid`], shaped the way the real one is.
fn make_engine(at: &Path, version: &str) {
    std::fs::create_dir_all(at.join("scripts/hooks")).unwrap();
    std::fs::write(at.join("VERSION"), format!("{version}\n")).unwrap();
}

fn siblings_of(dir: &Path) -> Vec<String> {
    let mut out: Vec<String> = std::fs::read_dir(dir)
        .map(|rd| rd.flatten().map(|e| e.file_name().to_string_lossy().to_string()).collect())
        .unwrap_or_default();
    out.sort();
    out
}

const A_DIGEST: &str = "0000000000000000000000000000000000000000000000000000000000000000";

const ASSET_URL: &str =
    "https://github.com/WebDevBooster/richos/releases/download/engine-v1.0.0/richos-engine-1.0.0.tar.gz";

fn a_pin(sha: &str) -> EnginePin {
    pin_from_parts("1.0.0", ASSET_URL, sha).expect("the fixture pin must itself be well formed")
}

// ===========================================================================================
// FAKES
// ===========================================================================================

/// Writes fixed bytes. The URL it was asked for is recorded, so a test can assert that
/// Anthropic's own URL is what gets fetched and nothing else.
struct FakeFetcher {
    body: Vec<u8>,
    asked: Mutex<Vec<String>>,
}
impl FakeFetcher {
    fn new(body: &[u8]) -> Self {
        FakeFetcher { body: body.to_vec(), asked: Mutex::new(Vec::new()) }
    }
}
impl Fetcher for FakeFetcher {
    fn fetch(&self, url: &str, dest: &Path) -> Result<u64, SetupError> {
        self.asked.lock().unwrap().push(url.to_string());
        std::fs::write(dest, &self.body).unwrap();
        Ok(self.body.len() as u64)
    }
}

/// Fails, with whatever the test wants to happen.
struct FailingFetcher(fn(&str) -> SetupError);
impl Fetcher for FailingFetcher {
    fn fetch(&self, url: &str, _dest: &Path) -> Result<u64, SetupError> {
        Err((self.0)(url))
    }
}

/// Copies a prepared directory tree in, instead of running `tar`.
struct FakeExtractor {
    /// What to place under `into`: (relative path, is_dir, contents).
    plan: Vec<(String, bool, String)>,
}
impl Extractor for FakeExtractor {
    fn extract(&self, _archive: &Path, into: &Path) -> Result<(), SetupError> {
        for (rel, is_dir, body) in &self.plan {
            let p = into.join(rel);
            if *is_dir {
                std::fs::create_dir_all(&p).unwrap();
            } else {
                std::fs::create_dir_all(p.parent().unwrap()).unwrap();
                std::fs::write(&p, body).unwrap();
            }
        }
        Ok(())
    }
}

fn good_engine_plan(version: &str) -> FakeExtractor {
    FakeExtractor {
        plan: vec![
            ("engine/scripts/hooks".into(), true, String::new()),
            ("engine/VERSION".into(), false, format!("{version}\n")),
            ("engine/README.md".into(), false, "the engine\n".into()),
        ],
    }
}

struct FakeRunner {
    code: i32,
    stderr: String,
    /// Run when the installer "runs", so a test can make it produce a binary — or not.
    effect: Option<Box<dyn Fn() + Send + Sync>>,
}
impl Runner for FakeRunner {
    fn run_installer(&self, _script: &Path, _home: &Path) -> Result<(i32, String), SetupError> {
        if let Some(f) = &self.effect {
            f();
        }
        Ok((self.code, self.stderr.clone()))
    }
}

/// The bytes a test will serve, plus their true digest — so no test ever hard-codes a digest
/// it did not compute from the same bytes it is about to hand over.
fn body_and_digest(root: &Path, body: &[u8]) -> String {
    let p = root.join("body-under-test");
    std::fs::write(&p, body).unwrap();
    sha256_file(&p).unwrap()
}

// ===========================================================================================
// THE GAP: detection
// ===========================================================================================

/// **THE LAUNCH BLOCKER, AS A VALUE.** A customer's Mac: a real HOME, nothing installed, a GUI
/// launch with an `.app` in `/Applications` and no environment. Both components missing, both
/// naming every place they looked, and `needs()` putting Claude Code first.
#[test]
fn a_customers_mac_is_missing_both_and_says_where_it_looked() {
    let root = scratch("customer-mac");
    let home = root.join("home");
    std::fs::create_dir_all(&home).unwrap();
    let exe = root.join("Applications/RichOS.app/Contents/MacOS/richos-tauri");
    std::fs::create_dir_all(exe.parent().unwrap()).unwrap();

    let paths = SetupPaths {
        home: Some(home.clone()),
        exe: Some(exe),
        path_var: Some("/usr/bin:/bin".into()),
        ..Default::default()
    };
    let status = detect(&paths, &[]);

    assert!(!status.claude.present, "{:?}", status.claude);
    assert!(!status.engine.present, "{:?}", status.engine);
    assert_eq!(status.needs(), vec![Component::ClaudeCode, Component::Engine]);
    assert!(!status.complete());

    // NAMED, not "not found".
    let claude_places = status.claude.looked_in.join(" ");
    assert!(claude_places.contains(".local/bin/claude"), "{claude_places}");
    assert!(claude_places.contains("/usr/bin/claude"), "{claude_places}");
    let engine_places = status.engine.looked_in.join(" ");
    assert!(engine_places.contains("Contents/Resources/engine"), "{engine_places}");
    assert!(engine_places.contains(".claude/richos-engine"), "{engine_places}");
    assert!(
        engine_places.contains("Application Support/RichOS/engine"),
        "candidate 7 must be searched, or an install nobody can find is possible: {engine_places}"
    );
}

/// **THE CEO'S OWN MACHINE**: `~/.claude/richos-engine` is a valid engine and `claude` is where
/// Anthropic's installer puts it. Nothing is missing, so first run says nothing.
#[test]
fn a_machine_that_already_has_both_is_asked_nothing() {
    let root = scratch("has-both");
    let home = root.join("home");
    make_engine(&home.join(".claude/richos-engine"), "1.0.0");
    std::fs::create_dir_all(home.join(".local/bin")).unwrap();
    std::fs::write(home.join(".local/bin/claude"), b"#!/bin/sh\n").unwrap();

    let paths = SetupPaths { home: Some(home), ..Default::default() };
    let status = detect(&paths, &[]);
    assert!(status.complete(), "{status:?}");
    assert!(status.needs().is_empty());
    assert!(!status.blocked());
}

/// **A FETCHED ENGINE IS FOUND WHERE IT WAS PUT.** The install location and the resolver's
/// candidate 7 are the same path by construction — this is the test that keeps them so.
#[test]
fn an_engine_installed_into_application_support_is_the_one_detection_finds() {
    let root = scratch("candidate-7");
    let home = root.join("home");
    make_engine(&engine_install_dir(&home), "1.0.0");

    let paths = SetupPaths { home: Some(home.clone()), ..Default::default() };
    let found = find_engine(&paths, &[]);
    assert!(found.present, "{found:?}");
    assert_eq!(found.at.as_deref(), Some(engine_install_dir(&home).display().to_string().as_str()));
    assert_eq!(found.detail.as_deref(), Some("version 1.0.0"));
}

/// A directory called `engine` that is not one is REJECTED, so an installer cannot leave
/// something the resolver would then refuse. The same predicate governs both sides.
#[test]
fn a_directory_that_is_not_an_engine_is_not_detected_as_one() {
    let root = scratch("decoy");
    let home = root.join("home");
    std::fs::create_dir_all(engine_install_dir(&home).join("scripts")).unwrap(); // no hooks/, no VERSION
    let paths = SetupPaths { home: Some(home), ..Default::default() };
    assert!(!find_engine(&paths, &[]).present);
}

/// An explicit override is EXCLUSIVE in both directions, matching `engine.rs`: a wrong one is
/// reported, never routed around to something nobody named.
#[test]
fn an_explicit_override_never_falls_through_to_something_nobody_named() {
    let root = scratch("exclusive");
    let home = root.join("home");
    make_engine(&home.join(".claude/richos-engine"), "1.0.0");
    std::fs::create_dir_all(home.join(".local/bin")).unwrap();
    std::fs::write(home.join(".local/bin/claude"), b"#!/bin/sh\n").unwrap();

    let paths = SetupPaths {
        home: Some(home),
        engine_override: Some(root.join("nope")),
        claude_bin_override: Some(root.join("also-nope")),
        ..Default::default()
    };
    let status = detect(&paths, &[]);
    assert!(!status.engine.present, "a bad override fell through: {:?}", status.engine);
    assert!(!status.claude.present, "a bad override fell through: {:?}", status.claude);
    assert!(status.engine.looked_in[0].contains("RICHOS_ENGINE_DIR"), "{:?}", status.engine.looked_in);
    assert!(status.claude.looked_in[0].contains("RICHOS_CLAUDE_BIN"), "{:?}", status.claude.looked_in);
}

/// The dogfood layout is not asked to install anything: an engine reachable from the repo is
/// passed in as an extra candidate and answers before the two per-user locations.
#[test]
fn a_repo_engine_passed_in_as_a_candidate_answers_before_the_install_location() {
    let root = scratch("dogfood");
    let home = root.join("home");
    let repo_engine = root.join("richos/engine");
    make_engine(&repo_engine, "1.0.0");
    make_engine(&engine_install_dir(&home), "9.9.9");

    let paths = SetupPaths { home: Some(home), ..Default::default() };
    let found = find_engine(&paths, &[repo_engine.clone()]);
    assert_eq!(found.at.as_deref(), Some(repo_engine.display().to_string().as_str()), "{found:?}");
}

// ===========================================================================================
// THE PIN
// ===========================================================================================

/// **UNPINNED IS A REFUSAL, NEVER A FALLBACK.** Five bad pins, five `None`s, and the plain-http
/// one is the reason the rule exists.
#[test]
fn a_pin_that_is_not_exactly_right_is_no_pin_at_all() {
    assert!(pin_from_parts("", "https://x/y", A_DIGEST).is_none(), "blank version");
    assert!(pin_from_parts("1.0.0", "", A_DIGEST).is_none(), "blank url");
    assert!(
        pin_from_parts("1.0.0", "http://github.com/x/y.tar.gz", A_DIGEST).is_none(),
        "PLAIN HTTP MUST BE REFUSED"
    );
    assert!(pin_from_parts("1.0.0", "https://x/y", "deadbeef").is_none(), "short digest");
    assert!(
        pin_from_parts("1.0.0", "https://x/y", &A_DIGEST.replace('0', "G")).is_none(),
        "non-hex digest"
    );
    assert!(
        pin_from_parts("1.0.0", "https://x/y", "ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789")
            .is_none(),
        "uppercase hex is not the form the comparison uses, so it is not a pin"
    );
    assert!(pin_from_parts("1.0.0", "https://x/y.tar.gz", A_DIGEST).is_some());
}

/// An unpinned build says so in its status AND refuses at the door — two places, because a
/// surface that offers a button the backend will refuse is the failure this prevents.
#[test]
fn an_unpinned_build_reports_it_and_is_blocked_rather_than_guessing() {
    let root = scratch("unpinned");
    let home = root.join("home");
    std::fs::create_dir_all(&home).unwrap();
    let status = detect(&SetupPaths { home: Some(home), ..Default::default() }, &[]);
    // The test build carries no `RICHOS_ENGINE_*` at compile time.
    assert!(!status.engine_installable, "the test build must carry no pin");
    assert!(status.blocked(), "an engine that is missing and unpinnable is blocked");
    assert_eq!(status.engine_pin_version, None);
}

// ===========================================================================================
// THE ENGINE INSTALL — the happy path
// ===========================================================================================

/// **THE DELIVERABLE, IN ONE TEST**: nothing on disk, a pinned asset, and afterwards an engine
/// at the path the resolver searches, carrying its own freshness stamp.
#[test]
fn a_pinned_engine_lands_where_the_resolver_looks_and_stamps_itself() {
    let root = scratch("engine-happy");
    let home = root.join("home");
    let dest = engine_install_dir(&home);
    let body = b"not really a tarball, but the digest is what is checked";
    let digest = body_and_digest(&root, body);

    let report =
        install_engine(&FakeFetcher::new(body), &good_engine_plan("1.0.0"), &a_pin(&digest), &dest)
            .unwrap();

    assert!(engine_looks_valid(&dest), "the installed directory must satisfy the resolver");
    assert_eq!(engine_version(&dest).as_deref(), Some("1.0.0"));
    assert_eq!(report.version, "1.0.0");
    assert_eq!(report.sha256, digest);
    assert_eq!(report.bytes, body.len() as u64);

    // THE FRESHNESS STAMP, inside the artifact.
    let stamp = std::fs::read_to_string(dest.join("INSTALLED-FROM")).unwrap();
    assert!(stamp.contains(&digest), "{stamp}");
    assert!(stamp.contains("engine 1.0.0"), "{stamp}");
    assert!(stamp.contains("https://github.com/WebDevBooster/richos/releases/"), "{stamp}");

    // And detection now finds it, which is the whole point.
    let paths = SetupPaths { home: Some(home), ..Default::default() };
    assert!(find_engine(&paths, &[]).present);
}

/// NO RESIDUE. After a success the only thing beside the engine is the engine — no
/// `.incoming`, no `.previous`. His Application Support directory is not a scratch space.
#[test]
fn a_successful_install_leaves_no_staging_directory_behind() {
    let root = scratch("no-residue");
    let home = root.join("home");
    let dest = engine_install_dir(&home);
    let body = b"bytes";
    let digest = body_and_digest(&root, body);

    install_engine(&FakeFetcher::new(body), &good_engine_plan("1.0.0"), &a_pin(&digest), &dest)
        .unwrap();

    assert_eq!(siblings_of(dest.parent().unwrap()), vec!["engine".to_string()]);
}

// ===========================================================================================
// THE ENGINE INSTALL — every failure path
// ===========================================================================================

/// **A TAMPERED ARCHIVE IS REFUSED BEFORE `tar` SEES IT**, and nothing is installed. The
/// extractor here would happily produce a perfect engine; it never gets the chance.
#[test]
fn a_digest_mismatch_stops_before_extraction_and_installs_nothing() {
    let root = scratch("digest-mismatch");
    let home = root.join("home");
    let dest = engine_install_dir(&home);

    struct MustNotRun;
    impl Extractor for MustNotRun {
        fn extract(&self, _a: &Path, _i: &Path) -> Result<(), SetupError> {
            panic!("EXTRACTION RAN ON BYTES THAT FAILED THE DIGEST CHECK");
        }
    }

    let err =
        install_engine(&FakeFetcher::new(b"tampered"), &MustNotRun, &a_pin(A_DIGEST), &dest)
            .unwrap_err();

    assert_eq!(err.kind(), "digest-mismatch");
    assert!(err.machine_unchanged());
    assert!(!dest.exists(), "something was installed after a digest mismatch");
    assert!(err.to_string().contains("installed nothing"), "{err}");
}

/// An archive that opens to something that is not an engine is refused, by the SAME predicate
/// the resolver uses — so nothing can be installed that the next boot rejects.
#[test]
fn an_archive_without_the_engines_shape_is_refused_and_names_what_is_missing() {
    let root = scratch("wrong-shape");
    let home = root.join("home");
    let dest = engine_install_dir(&home);
    let body = b"x";
    let digest = body_and_digest(&root, body);

    // An `engine/` with a VERSION but no `scripts/hooks`.
    let half = FakeExtractor { plan: vec![("engine/VERSION".into(), false, "1.0.0\n".into())] };
    let err = install_engine(&FakeFetcher::new(body), &half, &a_pin(&digest), &dest).unwrap_err();
    assert_eq!(err.kind(), "engine-shape-invalid");
    assert!(err.to_string().contains("scripts/hooks"), "{err}");
    assert!(!dest.exists());

    // And an archive with no `engine/` at all names what it did find.
    let elsewhere = FakeExtractor { plan: vec![("something-else/x".into(), false, "y".into())] };
    let err =
        install_engine(&FakeFetcher::new(body), &elsewhere, &a_pin(&digest), &dest).unwrap_err();
    assert_eq!(err.kind(), "engine-shape-invalid");
    assert!(err.to_string().contains("something-else"), "{err}");
    assert!(!dest.exists());
}

/// A release asset rebuilt under the same name, carrying a different engine, is caught by the
/// version check even though its digest matched the pin.
#[test]
fn an_engine_whose_version_is_not_the_pinned_one_is_refused() {
    let root = scratch("version-mismatch");
    let home = root.join("home");
    let dest = engine_install_dir(&home);
    let body = b"x";
    let digest = body_and_digest(&root, body);

    let err =
        install_engine(&FakeFetcher::new(body), &good_engine_plan("2.0.0"), &a_pin(&digest), &dest)
            .unwrap_err();
    assert_eq!(err.kind(), "engine-version-mismatch");
    assert!(err.to_string().contains("2.0.0") && err.to_string().contains("1.0.0"), "{err}");
    assert!(!dest.exists());
}

/// **NO NETWORK.** Nothing is installed, the sentence says so, and no staging survives.
#[test]
fn no_network_installs_nothing_and_leaves_no_residue() {
    let root = scratch("no-network");
    let home = root.join("home");
    let dest = engine_install_dir(&home);
    std::fs::create_dir_all(dest.parent().unwrap()).unwrap();

    let err = install_engine(
        &FailingFetcher(|url| SetupError::NoNetwork {
            url: url.to_string(),
            detail: "could not resolve host".into(),
        }),
        &good_engine_plan("1.0.0"),
        &a_pin(A_DIGEST),
        &dest,
    )
    .unwrap_err();

    assert_eq!(err.kind(), "no-network");
    assert!(err.machine_unchanged());
    assert!(err.to_string().contains("nothing has been changed on your Mac"), "{err}");
    assert!(siblings_of(dest.parent().unwrap()).is_empty(), "residue after a failed download");
}

/// A refused download (a 404 on the release asset) is its own sentence.
#[test]
fn a_release_asset_that_is_not_there_is_named_as_one() {
    let root = scratch("asset-404");
    let dest = engine_install_dir(&root.join("home"));
    let err = install_engine(
        &FailingFetcher(|url| SetupError::DownloadFailed {
            url: url.to_string(),
            status: "The requested URL returned error: 404".into(),
        }),
        &good_engine_plan("1.0.0"),
        &a_pin(A_DIGEST),
        &dest,
    )
    .unwrap_err();
    assert_eq!(err.kind(), "download-failed");
    assert!(err.to_string().contains("404"), "{err}");
    assert!(!dest.exists());
}

/// A partial download is its own sentence, not "something went wrong".
#[test]
fn a_partial_download_is_named_as_one() {
    let root = scratch("partial");
    let dest = engine_install_dir(&root.join("home"));
    let err = install_engine(
        &FailingFetcher(|url| SetupError::DownloadIncomplete {
            url: url.to_string(),
            expected: 5_800_000,
            got: 1_204_224,
        }),
        &good_engine_plan("1.0.0"),
        &a_pin(A_DIGEST),
        &dest,
    )
    .unwrap_err();
    assert_eq!(err.kind(), "download-incomplete");
    assert!(err.to_string().contains("1204224"), "{err}");
    assert!(!dest.exists());
}

/// **THE ONE THAT DECIDES WHETHER A FAILURE COSTS HIM WHAT HE HAD.** An install over an
/// EXISTING engine that fails must leave the existing one exactly as it was.
#[test]
fn a_failed_reinstall_leaves_the_engine_he_already_had() {
    let root = scratch("keep-existing");
    let home = root.join("home");
    let dest = engine_install_dir(&home);
    make_engine(&dest, "1.0.0");
    std::fs::write(dest.join("MINE"), b"the engine he already had\n").unwrap();

    let err = install_engine(
        &FakeFetcher::new(b"tampered"),
        &good_engine_plan("1.0.0"),
        &a_pin(A_DIGEST),
        &dest,
    )
    .unwrap_err();
    assert_eq!(err.kind(), "digest-mismatch");

    assert!(engine_looks_valid(&dest), "the existing engine did not survive a failed install");
    assert_eq!(std::fs::read_to_string(dest.join("MINE")).unwrap(), "the engine he already had\n");
    assert_eq!(siblings_of(dest.parent().unwrap()), vec!["engine".to_string()]);
}

/// A successful REINSTALL over an existing engine replaces it and removes the old copy.
#[test]
fn a_successful_reinstall_replaces_the_previous_engine_and_removes_it() {
    let root = scratch("replace");
    let home = root.join("home");
    let dest = engine_install_dir(&home);
    make_engine(&dest, "0.9.0");
    std::fs::write(dest.join("OLD"), b"stale\n").unwrap();

    let body = b"x";
    let digest = body_and_digest(&root, body);
    install_engine(&FakeFetcher::new(body), &good_engine_plan("1.0.0"), &a_pin(&digest), &dest)
        .unwrap();

    assert_eq!(engine_version(&dest).as_deref(), Some("1.0.0"));
    assert!(!dest.join("OLD").exists(), "the old engine's files survived the swap");
    assert_eq!(siblings_of(dest.parent().unwrap()), vec!["engine".to_string()]);
}

/// **A PANIC LEAVES NO RESIDUE.** `Staging`'s `Drop` removes its directory on unwind, so a
/// crash midway through an install cannot leave a half-tree the next boot would resolve.
#[test]
fn a_panic_during_an_install_removes_the_staging_directory() {
    let root = scratch("panic-residue");
    let home = root.join("home");
    let dest = engine_install_dir(&home);
    std::fs::create_dir_all(dest.parent().unwrap()).unwrap();

    struct Panicking;
    impl Extractor for Panicking {
        fn extract(&self, _a: &Path, _i: &Path) -> Result<(), SetupError> {
            panic!("something went wrong halfway through");
        }
    }
    let body = b"x";
    let digest = body_and_digest(&root, body);

    let outcome = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        install_engine(&FakeFetcher::new(body), &Panicking, &a_pin(&digest), &dest)
    }));
    assert!(outcome.is_err(), "the fixture must actually panic");
    assert!(siblings_of(dest.parent().unwrap()).is_empty(), "residue after a panic");
}

// ===========================================================================================
// CLAUDE CODE
// ===========================================================================================

/// **RICHOS FETCHES ANTHROPIC'S INSTALLER AND NOTHING ELSE.** The URL is asserted, because the
/// license condition that matters most is "installed as published", and a mirror would break
/// it silently.
#[test]
fn the_only_url_fetched_for_claude_code_is_anthropics_own_installer() {
    let root = scratch("claude-url");
    let home = root.join("home");
    std::fs::create_dir_all(&home).unwrap();
    let fetcher = FakeFetcher::new(b"#!/bin/bash\necho hi\n");
    let runner = FakeRunner { code: 1, stderr: "no".into(), effect: None };

    let paths = SetupPaths { home: Some(home), ..Default::default() };
    let _ = install_claude_code(&fetcher, &runner, &paths);

    let asked = fetcher.asked.lock().unwrap().clone();
    assert_eq!(asked, vec![CLAUDE_INSTALLER_URL.to_string()]);
    assert_eq!(CLAUDE_INSTALLER_URL, "https://claude.ai/install.sh");
}

/// **A REFUSED INSTALL is the installer's own words, relayed.** Not paraphrased: what
/// Anthropic's script says is the instruction the customer needs.
#[test]
fn an_installer_that_refuses_is_relayed_verbatim_and_changes_nothing() {
    let root = scratch("installer-refused");
    let home = root.join("home");
    std::fs::create_dir_all(&home).unwrap();
    let runner = FakeRunner {
        code: 1,
        stderr: "Error: do not run this installer with sudo.".into(),
        effect: None,
    };
    let err = install_claude_code(
        &FakeFetcher::new(b"#!/bin/bash\n"),
        &runner,
        &SetupPaths { home: Some(home.clone()), ..Default::default() },
    )
    .unwrap_err();

    assert_eq!(err.kind(), "installer-refused");
    assert!(err.to_string().contains("do not run this installer with sudo"), "{err}");
    assert!(err.machine_unchanged());
    assert!(siblings_of(&app_support_richos(&home)).is_empty(), "the installer's staging survived");
}

/// **AN INSTALLER THAT EXITS 0 AND INSTALLED NOTHING IS A FAILURE.** The house lesson as a
/// test: the binary is located again from scratch, and a missing one is an error however
/// cheerful the exit code was.
#[test]
fn an_installer_that_exits_zero_without_installing_anything_is_still_a_failure() {
    let root = scratch("exit-zero-lie");
    let home = root.join("home");
    std::fs::create_dir_all(&home).unwrap();
    let runner = FakeRunner { code: 0, stderr: String::new(), effect: None };
    let err = install_claude_code(
        &FakeFetcher::new(b"#!/bin/bash\n"),
        &runner,
        &SetupPaths {
            home: Some(home),
            path_var: Some("/nonexistent".into()),
            ..Default::default()
        },
    )
    .unwrap_err();
    assert_eq!(err.kind(), "claude-still-missing");
    assert!(err.to_string().contains(".local/bin/claude"), "{err}");
    assert!(!err.machine_unchanged(), "their installer ran; the Mac may have changed");
}

/// **A BODY THAT IS NOT A SCRIPT IS NEVER RUN.** A captive portal's HTML page reaching `bash`
/// is the worst possible way to find out the network was lying.
#[test]
fn a_download_that_is_not_a_script_is_never_executed() {
    let root = scratch("not-a-script");
    let home = root.join("home");
    std::fs::create_dir_all(&home).unwrap();

    struct MustNotRun;
    impl Runner for MustNotRun {
        fn run_installer(&self, _s: &Path, _h: &Path) -> Result<(i32, String), SetupError> {
            panic!("BASH RAN ON A BODY WITH NO SHEBANG");
        }
    }

    let err = install_claude_code(
        &FakeFetcher::new(b"<!DOCTYPE html><html>Sign in to the WiFi</html>"),
        &MustNotRun,
        &SetupPaths { home: Some(home), ..Default::default() },
    )
    .unwrap_err();
    assert_eq!(err.kind(), "download-failed");
    assert!(err.to_string().contains("not a script"), "{err}");
}

/// **AN UNSIGNED, WRONGLY-SIGNED OR UNVERIFIABLE BINARY IS NOT RUN.** The installer here
/// "succeeds" and produces a plain file; `codesign` cannot make it Anthropic's, so setup
/// refuses. This is the negative half of the signature pin, and it needs no network.
#[test]
fn a_binary_that_is_not_anthropics_is_refused_after_the_installer_succeeds() {
    let root = scratch("bad-signature");
    let home = root.join("home");
    std::fs::create_dir_all(home.join(".local/bin")).unwrap();
    let home_for_effect = home.clone();

    let runner = FakeRunner {
        code: 0,
        stderr: String::new(),
        effect: Some(Box::new(move || {
            std::fs::write(
                home_for_effect.join(".local/bin/claude"),
                b"#!/bin/sh\necho not claude\n",
            )
            .unwrap();
        })),
    };
    let err = install_claude_code(
        &FakeFetcher::new(b"#!/bin/bash\n"),
        &runner,
        &SetupPaths { home: Some(home), ..Default::default() },
    )
    .unwrap_err();

    assert_eq!(err.kind(), "signature-rejected");
    assert!(err.to_string().contains("won't confirm it came from Anthropic"), "{err}");
    assert!(!err.machine_unchanged());
}

/// **THE POSITIVE HALF, ON THE REAL BINARY.** If this machine has Anthropic's `claude`, the
/// same function that guards an install verifies it and says `trusted`. A negative-only
/// signature test is one that passes because everything fails.
///
/// # It used to be a negative-only signature test on most machines, and it said so itself
///
/// Until 2026-09-05 this body opened with two early `return`s — no `$HOME`, and no
/// `~/.local/bin/claude` — each preceded by an `eprintln!("SKIPPED: …")`. **A test that
/// returns is reported `ok`, and cargo captures the stderr of a passing test and throws it
/// away**, so the intent was legible in this file and nowhere in any log. It carried no
/// `cfg`, `app-spine-ci.yml` runs `cargo test --locked -p richos-core` on `ubuntu-latest`,
/// and no Linux runner has a `claude` — so this line has read `ok` on every CI run since
/// that job landed, over a signature check that could not even have been attempted there.
///
/// # Two conditions, and only one of them is a machine's business
///
/// [`verify_claude_signature`] runs `/usr/bin/codesign`. That is macOS's, so **off macOS
/// this test can never run, whatever is installed** — a compile-time fact about the target,
/// which is what `#[cfg_attr(…, ignore)]` is for. libtest then prints `ignored, <reason>`
/// and counts it in its own column: visibly not-run, in the log, on the runner that until
/// today printed `ok`.
///
/// **On macOS the absence of `claude` is a finding, not a reason to skip**, and this test is
/// a hard failure rather than a quiet pass. `richos-voice`'s `tts.rs` reached the same
/// conclusion about `/usr/bin/say` on 2026-09-05, and the reason is the same one: the value
/// of a green suite is that somebody checked, so a run that could not check must not be
/// green. The message names what is missing and what to do about it — installing Claude Code
/// is what `install_claude_code` above exists to do, and `$RICHOS_CLAUDE_BIN` points this at
/// a binary anywhere.
///
/// # Why the condition is NOT a build-script `cfg`, unlike `richos-voice`
///
/// `crates/richos-voice/build.rs` turns `RICHOS_VOICE_LIVE_AUDIO` into `cfg(live_audio)`, and
/// the obvious move here was to do the same for "does this machine have a `claude`". It was
/// measured instead of assumed: emitting one extra `cargo::rustc-cfg` from
/// `crates/richos-core/build.rs` changes the release library's bytes —
/// `librichos_core.rlib` went `c3f2d079…` → `e8b810c7…` and back to `c3f2d079…` when the line
/// was removed. That would make a crate that ships inside the signed `.app` compile
/// differently depending on whether the BUILD machine happened to have Claude Code installed,
/// which is a real cost against `docs/verification/reproducible-rust-builds-2026-09-04/` and
/// against this crate's own `build.rs` header (*"Nothing else belongs in this file"*). A
/// `target_os` cfg costs nothing: it is part of the build's identity already.
#[test]
#[cfg_attr(
    not(target_os = "macos"),
    ignore = "NOT CHECKABLE ON THIS TARGET: the Anthropic signature pin is read by \
              /usr/bin/codesign, which is macOS's. This is a not-run, not a pass — run \
              it on a Mac. --include-ignored reaches a panic here, never a green line."
)]
fn the_real_claude_binary_on_this_machine_satisfies_the_requirement() {
    // `#[ignore]` suppresses the RUN, not the BODY: `--include-ignored` on Linux would reach
    // this line. Refuse in words rather than assert something meaningless about `codesign`.
    assert!(
        cfg!(target_os = "macos") && Path::new("/usr/bin/codesign").is_file(),
        "the signature pin is a macOS designated-requirement check and /usr/bin/codesign \
         is not runnable here, so nothing was verified. You reached this body with \
         `--include-ignored` or `--ignored`; on a Mac it runs by default."
    );

    // THE PRODUCT'S OWN LOCATOR, not a second definition of where `claude` lives: the
    // explicit `$RICHOS_CLAUDE_BIN`, then `~/.local/bin/claude`, then `$PATH` — so a binary
    // this app WOULD drive is a binary this test checks, and an install somewhere unusual is
    // not silently treated as no install at all.
    let found = find_claude(&SetupPaths::from_process());
    let at = match (found.present, &found.at) {
        (true, Some(at)) => PathBuf::from(at),
        _ => panic!(
            "no `claude` on this machine, so THE SIGNATURE PIN WAS NOT CHECKED BY THIS \
             RUN — and a check that did not happen must not report `ok`. Looked in: {}. \
             Install Claude Code (`install_claude_code`, tested above, is what RichOS \
             does for a customer) or set $RICHOS_CLAUDE_BIN to an existing binary.",
            found.looked_in.join("; ")
        ),
    };

    let verdict = verify_claude_signature(&at);
    assert!(verdict.trusted, "the installed claude failed its own designated requirement: {verdict:?}");

    // The SYMLINK is resolved, so the verdict names the file that was checked. `stapler`
    // exits 0 on the unresolved symlink having validated nothing; this must not do that.
    // Stated as the exact identity rather than a substring, so it holds for an install that
    // is not laid out the way Anthropic's installer lays one out.
    let canonical = std::fs::canonicalize(&at)
        .unwrap_or_else(|e| panic!("{} could not be resolved: {e}", at.display()));
    assert_eq!(
        verdict.checked,
        canonical.display().to_string(),
        "the verdict does not name the file that was checked: {verdict:?}"
    );

    // And for the standard install — the launcher Anthropic's installer writes and retargets
    // on every self-update — the resolved path is the versioned one, which is the concrete
    // form of the same property and the one that caught the unresolved-symlink bug.
    if at.ends_with(".local/bin/claude") {
        assert!(
            verdict.checked.contains("versions/"),
            "the symlink was not resolved before checking: {verdict:?}"
        );
    }
}

/// The designated requirement is the measured one, character for character. If somebody
/// loosens it this fails — a requirement without the team identifier would accept any
/// Developer ID binary that happened to use the same bundle identifier.
#[test]
fn the_designated_requirement_names_both_the_identifier_and_the_team() {
    assert!(CLAUDE_DESIGNATED_REQUIREMENT.contains("identifier \"com.anthropic.claude-code\""));
    assert!(CLAUDE_DESIGNATED_REQUIREMENT.contains("anchor apple generic"));
    assert!(CLAUDE_DESIGNATED_REQUIREMENT.contains("subject.OU] = \"Q6L2SF6YDW\""));
}

/// **THE ARGUMENT SYNTAX IS PART OF THE CHECK.** Without the leading `=`, `codesign -R` reads
/// its argument as a FILENAME, fails to open it, and exits non-zero — a false rejection that
/// is indistinguishable from a bad signature. This module made that mistake once; the test
/// above caught it against the real binary, and this one keeps the fix from being tidied away.
#[test]
fn the_requirement_is_passed_to_codesign_as_text_and_not_as_a_filename() {
    let arg = codesign_requirement_arg();
    assert!(arg.starts_with('='), "codesign would read this as a path: {arg}");
    assert_eq!(&arg[1..], CLAUDE_DESIGNATED_REQUIREMENT);
}

/// No HOME is a named error, not a panic and not a guess at `/Users/somebody`.
#[test]
fn no_home_is_a_named_refusal() {
    let err = install_claude_code(
        &FakeFetcher::new(b"#!/bin/bash\n"),
        &FakeRunner { code: 0, stderr: String::new(), effect: None },
        &SetupPaths::default(),
    )
    .unwrap_err();
    assert_eq!(err.kind(), "no-home");
}

// ===========================================================================================
// DIGEST
// ===========================================================================================

/// The digest is SHA-256, and it matches the vectors every implementation agrees on.
#[test]
fn the_digest_is_sha256_and_matches_the_known_vectors() {
    let root = scratch("digest");
    let empty = root.join("empty");
    std::fs::write(&empty, b"").unwrap();
    assert_eq!(
        sha256_file(&empty).unwrap(),
        "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
    );

    let abc = root.join("abc");
    std::fs::write(&abc, b"abc").unwrap();
    assert_eq!(
        sha256_file(&abc).unwrap(),
        "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
    );
}

/// **THE DIGEST STREAMS.** 200,000 bytes is past the 64 KiB buffer, and the expected value was
/// computed independently rather than by the code under test. A single-read implementation
/// that silently hashed only the first block would pass the vectors above and fail here.
#[test]
fn the_digest_is_correct_across_the_buffer_boundary() {
    let root = scratch("streaming");
    let big = root.join("big");
    let bytes: Vec<u8> = (0..200_000u32).map(|i| (i % 251) as u8).collect();
    std::fs::write(&big, &bytes).unwrap();
    assert_eq!(
        sha256_file(&big).unwrap(),
        "e24bc62381f1224fbbb74688663f8f9743b9680b193edd666835e97b06e730eb"
    );
}

/// And it agrees with the tool everybody else uses. Not because `shasum` is trusted more —
/// the point of a pure-Rust digest is that it is not a subprocess — but because a private
/// definition of SHA-256 that nobody else shares would make the published digest useless.
#[test]
fn the_digest_agrees_with_shasum() {
    let root = scratch("shasum-agreement");
    let f = root.join("bytes");
    std::fs::write(&f, b"RichOS engine asset\n").unwrap();

    let out = std::process::Command::new("/usr/bin/shasum").args(["-a", "256"]).arg(&f).output();
    let Ok(out) = out else {
        eprintln!("SKIPPED: /usr/bin/shasum is not on this machine");
        return;
    };
    let theirs = String::from_utf8_lossy(&out.stdout)
        .split_whitespace()
        .next()
        .unwrap_or_default()
        .to_string();
    assert_eq!(sha256_file(&f).unwrap(), theirs);
}

// ===========================================================================================
// THE CONSENT COPY
// ===========================================================================================

/// **NO TERMINAL, NO PATH, NO VERSION NUMBER.** The strings the CEO reads are checked for what
/// they must not contain, because the constraint is about what he is spared.
#[test]
fn the_consent_copy_carries_no_path_no_version_and_no_terminal() {
    for c in [Component::ClaudeCode, Component::Engine] {
        let line = format!("{} — {}", c.display_name(), c.why());
        assert!(!line.contains('/'), "a path reached his screen: {line}");
        assert!(!line.contains("Terminal"), "{line}");
        assert!(!line.contains('$'), "{line}");
        assert!(
            !line.chars().any(|ch| ch.is_ascii_digit()),
            "a version number reached his screen: {line}"
        );
    }
    // Plain text, and the mark is nobody's but Anthropic's to use.
    assert_eq!(Component::ClaudeCode.display_name(), "Claude Code");
}

/// Every error carries a sentence a non-technical reader can act on, none is a bare code, and
/// `machine_unchanged` is never unknown.
#[test]
fn every_failure_says_something_a_person_can_act_on() {
    let cases: Vec<SetupError> = vec![
        SetupError::NoHome,
        SetupError::NoNetwork { url: "u".into(), detail: "d".into() },
        SetupError::DownloadFailed { url: "u".into(), status: "404".into() },
        SetupError::DownloadIncomplete { url: "u".into(), expected: 10, got: 3 },
        SetupError::DigestMismatch { url: "u".into(), expected: "a".into(), got: "b".into() },
        SetupError::EngineUnpinned,
        SetupError::EngineShapeInvalid { detail: "d".into() },
        SetupError::EngineVersionMismatch { expected: "1".into(), found: "2".into() },
        SetupError::InstallerRefused { code: 1, stderr: "s".into() },
        SetupError::ClaudeStillMissing { looked_in: "p".into() },
        SetupError::SignatureRejected { path: "p".into(), detail: "d".into() },
        SetupError::InstallFailed { what: "w".into(), detail: "d".into() },
    ];
    let mut kinds = std::collections::HashSet::new();
    for e in &cases {
        let s = e.to_string();
        assert!(s.len() > 40, "too terse to act on: {s}");
        // A SENTENCE, not a code. The check is on the FIRST sentence rather than the last
        // character, because three variants deliberately end by relaying somebody else's
        // words verbatim — Anthropic's installer, `codesign`, a list of paths — and
        // paraphrasing those to make a period land would lose the instruction the customer
        // needs.
        let first = s.split('.').next().unwrap_or_default();
        assert!(s.contains('.'), "no sentence at all: {s}");
        assert!(first.len() >= 25, "opens with a fragment rather than a sentence: {s}");
        assert!(kinds.insert(e.kind()), "two errors share a kind tag: {}", e.kind());
        // `bool` cannot be "unknown", which is the property being asserted.
        let _: bool = e.machine_unchanged();
    }
    assert_eq!(kinds.len(), 12, "a variant was added without a kind tag");
}
