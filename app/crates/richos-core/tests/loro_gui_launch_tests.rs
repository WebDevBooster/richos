//! THE LAUNCH NOBODY TESTS ON — a double-clicked `.app`, and what the CORRECTION DESK does
//! there.
//!
//! # The defect these tests exist for
//!
//! `CliLoroWriter::from_env()` read `LORO_CORPUS`, `LORO_ROOT` and `RICHOS_LORO_DIR` and
//! nothing else. `ps eww` on a real Finder double-click of `RichOS.app` on this machine
//! shows `HOME`, `USER` and `PATH=/usr/bin:/bin:/usr/sbin:/sbin` — no `LORO_*` anything —
//! so on the CEO's installed app the writer was `None` on every boot. He could be shown a
//! proposal, press confirm, and reach a writer that could not find the corpus. The read path
//! was given a resolver at `46d8f56`; this file's subject is the twin the write path never
//! got.
//!
//! # Why these are not unit tests inside `loro.rs`
//!
//! Because the property is about a PROCESS, not about a function. The three that matter
//! ([`the_gui_condition_in_a_real_process_reaches_a_writer`] and its two neighbors) re-invoke
//! this very test binary with `env_clear()` and `current_dir("/")` — the GUI condition as a
//! real launch, not as a value someone remembered to pass. The rest are value-level and cover
//! the branches a subprocess cannot conveniently reach.
//!
//! Nothing here touches the CEO's corpus. Every fixture is a directory this file creates
//! under the system temp dir and deletes.

use richos_core::entity::EntityRegistry;
use richos_core::correction::CliLoroWriter;
use richos_core::loro::{CliContextCompiler, CorpusPaths, CorpusSource, LoroInstall, LoroRoot};
use std::path::{Path, PathBuf};

// ---------------------------------------------------------------------------------------
// fixtures
// ---------------------------------------------------------------------------------------

/// launchd's `PATH`, verbatim, as a GUI process receives it. Measured on this machine by
/// `ps eww` against a Finder-launched `RichOS.app`
/// (`docs/verification/installed-app-2026-09-01/raw/first-send-launchd-environment.txt`).
const LAUNCHD_PATH: &str = "/usr/bin:/bin:/usr/sbin:/sbin";

fn scratch(name: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!("richos-gui-launch-{name}"));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).expect("scratch dir");
    dir
}

/// A loro checkout: BOTH entry points, because `LoroTools::locate` requires both and a
/// directory holding only one is not a checkout.
fn compiler_at(dir: &Path) {
    std::fs::create_dir_all(dir.join("bin")).unwrap();
    std::fs::write(dir.join("bin").join("loro-context.mjs"), "// read\n").unwrap();
    std::fs::write(dir.join("bin").join("loro-write.mjs"), "// write\n").unwrap();
}

/// The IN-REPO dogfood shape (`wiki/` + `loro/`) — the one the CEO's own install resolves
/// through, where `~/Library/Application Support/RichOS/loro-root` points at a checkout.
fn repo_shaped_root(at: &Path) {
    std::fs::create_dir_all(at.join("wiki")).unwrap();
    compiler_at(&at.join("loro"));
}

/// A PROVISIONED corpus (`ceo/` + `companies/`), whose compiler cannot live inside it — loro
/// refuses a corpus with a `loro/` ancestor — so it is installed beside it in
/// `Application Support/RichOS/loro-tools`.
fn provisioned_corpus(at: &Path) {
    std::fs::create_dir_all(at.join("ceo")).unwrap();
    std::fs::create_dir_all(at.join("companies")).unwrap();
}

fn app_support(home: &Path) -> PathBuf {
    home.join("Library").join("Application Support").join("RichOS")
}

/// The GUI condition as a VALUE: nothing set, launchd's `PATH`, a `HOME`.
fn gui_paths(home: &Path) -> CorpusPaths {
    CorpusPaths {
        env_corpus: None,
        env_root: None,
        env_tools: None,
        env_node: None,
        home: Some(home.to_path_buf()),
        path_var: Some(LAUNCHD_PATH.to_string()),
    }
}

// ---------------------------------------------------------------------------------------
// 1. A GUI LAUNCH REACHES THE WRITER
// ---------------------------------------------------------------------------------------

#[test]
fn a_launch_with_no_environment_resolves_a_writer_and_not_only_a_reader() {
    let home = scratch("writer-reached");
    let root = app_support(&home).join("loro-root");
    repo_shaped_root(&root);

    let (writer, tried) = CliLoroWriter::locate(&gui_paths(&home)).expect("resolution must not error");
    let writer = writer.unwrap_or_else(|| {
        panic!(
            "a GUI launch with a loro-root pointer must reach a writer; it looked in: {}",
            tried.join("; ")
        )
    });
    assert_eq!(writer.root(), &LoroRoot::Root(root.clone()));
    // AND IT CAN ACTUALLY RUN SOMETHING. A resolved root with an unresolvable `node` fails
    // once per confirmation forever, which is the same dead desk wearing a different message.
    assert_eq!(writer.tools().write_bin(), root.join("loro").join("bin").join("loro-write.mjs"));
    assert!(
        Path::new(writer.tools().node()).is_absolute() || writer.tools().node() == "node",
        "node must be resolved to something a launchd PATH can execute, got {:?}",
        writer.tools().node()
    );
    let _ = std::fs::remove_dir_all(&home);
}

#[test]
fn a_provisioned_corpus_reaches_the_writer_through_the_tools_install_beside_it() {
    // The shape a first-run provisioning produces: `ceo/` + `companies/` under the corpus
    // pointer, and the compiler in `loro-tools` NEXT to it — never inside, because a `loro/`
    // ancestor makes loro refuse the corpus outright.
    let home = scratch("writer-provisioned");
    let corpus = app_support(&home).join("corpus");
    provisioned_corpus(&corpus);
    compiler_at(&app_support(&home).join("loro-tools"));

    let (writer, _) = CliLoroWriter::locate(&gui_paths(&home)).expect("resolution must not error");
    let writer = writer.expect("a provisioned corpus plus an installed compiler is a writer");
    assert_eq!(writer.root(), &LoroRoot::Corpus(corpus));
    let _ = std::fs::remove_dir_all(&home);
}

// ---------------------------------------------------------------------------------------
// 2. EXPLICIT STILL WINS, AND IS EXCLUSIVE — a dogfood launch must not change behavior
// ---------------------------------------------------------------------------------------

#[test]
fn an_explicit_root_wins_over_a_valid_pointer_and_is_never_validated() {
    // `resolve_corpus`'s governing rule, applied to the write half: if the operator named a
    // root, that root is used and resolution never falls through to one nobody named. A bad
    // explicit path is loro's error to report, not this resolver's reason to guess — so the
    // named root here does not exist and is still what comes back.
    let home = scratch("writer-explicit");
    repo_shaped_root(&app_support(&home).join("loro-root"));
    let tools = home.join("named-tools");
    compiler_at(&tools);

    let mut p = gui_paths(&home);
    p.env_root = Some("/nowhere/the/operator/named".into());
    p.env_tools = Some(tools.display().to_string());

    let (writer, _) = CliLoroWriter::locate(&p).expect("an explicit root is not validated here");
    let writer = writer.expect("an explicit root always resolves");
    assert_eq!(writer.root(), &LoroRoot::Root(PathBuf::from("/nowhere/the/operator/named")));
    assert_eq!(writer.tools().dir(), tools.as_path());
    let _ = std::fs::remove_dir_all(&home);
}

#[test]
fn loro_corpus_outranks_loro_root_for_the_writer_exactly_as_it_does_for_the_reader() {
    // CONTEXT-CONTRACT.md §1's own precedence order. The two halves must agree about
    // precedence as well as about the answer, or a terminal launch with both set would read
    // one corpus and write the other.
    let home = scratch("writer-precedence");
    let tools = home.join("tools");
    compiler_at(&tools);
    let mut p = gui_paths(&home);
    p.env_corpus = Some("/named/corpus".into());
    p.env_root = Some("/named/root".into());
    p.env_tools = Some(tools.display().to_string());

    let (writer, _) = CliLoroWriter::locate(&p).unwrap();
    assert_eq!(writer.unwrap().root(), &LoroRoot::Corpus(PathBuf::from("/named/corpus")));

    let (reader, _) = CliContextCompiler::locate(&p, &EntityRegistry::empty()).unwrap();
    let (reader, source) = reader.unwrap();
    assert_eq!(reader.root(), &LoroRoot::Corpus(PathBuf::from("/named/corpus")));
    assert_eq!(source, CorpusSource::EnvCorpus);
    let _ = std::fs::remove_dir_all(&home);
}

// ---------------------------------------------------------------------------------------
// 3. NO CORPUS IS NOT A CRASH AND NOT A SILENT NO-OP
// ---------------------------------------------------------------------------------------

#[test]
fn no_corpus_is_a_named_state_that_says_what_it_looked_for() {
    let home = scratch("writer-nothing");
    let (writer, tried) = CliLoroWriter::locate(&gui_paths(&home)).expect("nothing found is not an error");
    assert!(writer.is_none(), "nothing was created, so nothing may resolve");
    // The list is the whole point. "No corpus configured" without it is what sends an
    // operator hunting; with it, the next step is on the line.
    assert_eq!(tried.len(), 3, "every candidate must be reported: {tried:?}");
    assert!(tried.iter().any(|t| t.contains("Application Support/RichOS/corpus")), "{tried:?}");
    assert!(tried.iter().any(|t| t.contains("Application Support/RichOS/loro-root")), "{tried:?}");
    assert!(tried.iter().any(|t| t.contains("RichOS/corpus") && t.contains(home.to_str().unwrap())), "{tried:?}");
    assert!(tried.iter().all(|t| t.contains("not present")), "{tried:?}");
    let _ = std::fs::remove_dir_all(&home);
}

#[test]
fn a_corpus_with_no_compiler_refuses_the_writer_by_name_rather_than_half_wiring_it() {
    // A resolved corpus whose `loro-write.mjs` does not exist must NOT produce a writer that
    // fails at the moment the CEO presses confirm. It is a named state, and the desk is
    // closed with a sentence.
    let home = scratch("writer-no-compiler");
    provisioned_corpus(&app_support(&home).join("corpus"));

    let err = CliLoroWriter::locate(&gui_paths(&home)).expect_err("a corpus with no compiler is its own error");
    let msg = err.to_string();
    assert!(msg.contains("the memory compiler is not installed"), "{msg}");
    assert!(msg.contains("loro-tools"), "the message must name where it looked: {msg}");
    let _ = std::fs::remove_dir_all(&home);
}

#[test]
fn half_a_checkout_is_not_a_checkout_because_the_writer_is_the_half_that_would_be_missing() {
    // `LoroTools::locate` demands BOTH entry points. This is the case that matters for this
    // file: a directory holding only `loro-context.mjs` would give a working reader and a
    // writer with nothing to run — the disagreement in its most quietly damaging form.
    let home = scratch("writer-half-checkout");
    let root = app_support(&home).join("loro-root");
    std::fs::create_dir_all(root.join("wiki")).unwrap();
    std::fs::create_dir_all(root.join("loro").join("bin")).unwrap();
    std::fs::write(root.join("loro").join("bin").join("loro-context.mjs"), "// read\n").unwrap();

    let err = CliLoroWriter::locate(&gui_paths(&home)).expect_err("half a checkout must not resolve");
    assert!(err.to_string().contains("loro-write.mjs"), "{err}");
    let _ = std::fs::remove_dir_all(&home);
}

// ---------------------------------------------------------------------------------------
// 4. THE READER AND THE WRITER AGREE — the property that actually matters
// ---------------------------------------------------------------------------------------

#[test]
fn the_reader_and_the_writer_resolve_the_same_corpus_and_the_same_binary_directory() {
    // A build where these two disagreed would show the CEO a proposal computed against one
    // record and write his confirmation into another — a failure that SUCCEEDS, which is
    // strictly worse than the dead desk it replaced.
    //
    // Both plausible pointers exist here, in the opposite shapes, so a resolver that walked
    // the candidates in a different order would land on a different root and this test would
    // catch it rather than both halves happening to agree on the only option available.
    let home = scratch("agreement");
    let corpus = app_support(&home).join("corpus");
    provisioned_corpus(&corpus);
    compiler_at(&app_support(&home).join("loro-tools"));
    repo_shaped_root(&app_support(&home).join("loro-root"));

    let p = gui_paths(&home);
    let (reader, _) = CliContextCompiler::locate(&p, &EntityRegistry::empty()).unwrap();
    let (reader, _source) = reader.expect("the reader resolves");
    let (writer, _) = CliLoroWriter::locate(&p).unwrap();
    let writer = writer.expect("the writer resolves");

    assert_eq!(
        reader.root(),
        writer.root(),
        "the reader compiles from {:?} and the writer would write to {:?}",
        reader.root(),
        writer.root()
    );
    assert_eq!(
        reader.tools().dir(),
        writer.tools().dir(),
        "both halves must run out of one loro checkout"
    );
    assert_eq!(reader.tools().node(), writer.tools().node(), "both halves must run under one node");
    // ...and the pair really did have a choice: the OTHER pointer is valid too.
    assert_eq!(reader.root(), &LoroRoot::Corpus(corpus));
    let _ = std::fs::remove_dir_all(&home);
}

#[test]
fn one_install_builds_both_halves_so_a_second_resolution_cannot_disagree() {
    // The structural half of the same property. `LoroInstall::locate` walks the candidates
    // ONCE; the reader and the writer are constructed from that value. Two resolutions of the
    // same paths can differ — a corpus can be created between them by the very provisioning
    // flow that runs in this process — and one value cannot.
    let home = scratch("one-install");
    let root = app_support(&home).join("loro-root");
    repo_shaped_root(&root);

    let (install, _) = LoroInstall::locate(&gui_paths(&home)).unwrap();
    let install = install.expect("resolves");
    let reader = CliContextCompiler::from_install(&install, &EntityRegistry::empty()).expect("the read half");
    let writer = CliLoroWriter::from_install(&install);

    assert_eq!(reader.root(), install.root());
    assert_eq!(writer.root(), install.root());
    assert_eq!(reader.tools().dir(), writer.tools().dir());
    assert_eq!(install.source(), CorpusSource::AppSupportRoot);
    let _ = std::fs::remove_dir_all(&home);
}

// ---------------------------------------------------------------------------------------
// 5. NEVER THE PRODUCT REPO — no candidate is derived from this checkout
// ---------------------------------------------------------------------------------------

#[test]
fn nothing_is_ever_inferred_from_the_checkout_this_binary_was_built_in() {
    // `loro-write.mjs` refuses a corpus root inside the product repo, loudly and with no
    // permissive fallback (`loro/lib/layout.js:441`), and richos goes public. So the resolver
    // must never OFFER it one: every candidate hangs off `$HOME` or off a variable an
    // operator set, and none is derived from the executable, the working directory, or the
    // checkout.
    //
    // This test runs from inside the product repo — `CARGO_MANIFEST_DIR` is
    // `app/crates/richos-core` — and asserts that no candidate mentions it.
    let repo = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .ancestors()
        .nth(3)
        .expect("app/crates/richos-core has three ancestors up to the repo root")
        .to_path_buf();
    assert!(repo.join("app").join("crates").join("richos-core").join("Cargo.toml").is_file(), "{repo:?} must be the checkout");

    let home = scratch("never-the-repo");
    let (writer, tried) = CliLoroWriter::locate(&gui_paths(&home)).unwrap();
    assert!(writer.is_none());
    for candidate in &tried {
        assert!(
            !candidate.contains(repo.to_str().unwrap()),
            "a candidate inside the product repo would be refused by loro on every write: {candidate}"
        );
    }
    let _ = std::fs::remove_dir_all(&home);
}

#[test]
fn with_no_home_there_is_no_candidate_and_the_resolver_says_so_instead_of_guessing() {
    let p = CorpusPaths { path_var: Some(LAUNCHD_PATH.into()), ..Default::default() };
    let (writer, tried) = CliLoroWriter::locate(&p).unwrap();
    assert!(writer.is_none());
    assert_eq!(tried, vec!["no HOME, so no per-user candidate could be formed".to_string()]);
}

// ---------------------------------------------------------------------------------------
// THE GUI CONDITION AS A REAL PROCESS — no environment, cwd `/`
// ---------------------------------------------------------------------------------------
//
// Everything above passes a `CorpusPaths` VALUE, which is the right shape for a unit test and
// proves nothing about what the process actually reads. These two re-invoke this test binary
// with `env_clear()`, exactly two variables (`HOME` and launchd's `PATH` — the ones a Finder
// launch really carries), and `current_dir("/")`, then run one `#[ignore]`d child test inside
// it. The child calls `CorpusPaths::from_process()`, which is the function `src-tauri` calls
// at boot.
//
// This is the condition that killed three components in one day, and it is the only one no
// developer's shell ever produces.

fn run_child(test_name: &str, home: &Path) -> std::process::Output {
    std::process::Command::new(std::env::current_exe().expect("the test binary"))
        .args(["--exact", test_name, "--ignored", "--nocapture", "--test-threads=1"])
        .env_clear()
        .env("HOME", home)
        .env("PATH", LAUNCHD_PATH)
        .current_dir("/")
        .output()
        .expect("re-invoking this test binary")
}

#[test]
fn the_gui_condition_in_a_real_process_reaches_a_writer() {
    let home = scratch("gui-real-process");
    let root = app_support(&home).join("loro-root");
    repo_shaped_root(&root);

    let out = run_child("gui_child_resolves_a_writer_from_the_real_process", &home);
    let stdout = String::from_utf8_lossy(&out.stdout);
    let stderr = String::from_utf8_lossy(&out.stderr);
    assert!(
        out.status.success(),
        "a GUI launch (no environment, cwd=/) must reach the writer.\n--- stdout ---\n{stdout}\n--- stderr ---\n{stderr}"
    );
    assert!(
        stdout.contains(&format!("WRITER ROOT: {}", root.display())),
        "the child must report the resolved root:\n{stdout}"
    );
    assert!(stdout.contains("READER AGREES: yes"), "{stdout}");
    let _ = std::fs::remove_dir_all(&home);
}

/// The child. Runs ONLY when re-invoked by the test above — `#[ignore]` keeps it out of the
/// ordinary run, where it would see the developer's own environment and prove nothing.
#[test]
#[ignore]
fn gui_child_resolves_a_writer_from_the_real_process() {
    // The three facts that make this the GUI condition rather than a shell.
    assert!(std::env::var_os("LORO_CORPUS").is_none(), "the child must have no LORO_CORPUS");
    assert!(std::env::var_os("LORO_ROOT").is_none(), "the child must have no LORO_ROOT");
    assert!(std::env::var_os("RICHOS_LORO_DIR").is_none(), "the child must have no RICHOS_LORO_DIR");
    assert_eq!(std::env::var("PATH").as_deref(), Ok(LAUNCHD_PATH));
    assert_eq!(std::env::current_dir().unwrap(), Path::new("/"));

    // The exact call `src-tauri/src/memory.rs` makes at boot.
    let paths = CorpusPaths::from_process();
    let (install, tried) = LoroInstall::locate(&paths).expect("resolution must not error");
    let install = install.unwrap_or_else(|| panic!("no corpus resolved; looked in: {}", tried.join("; ")));

    let writer = CliLoroWriter::from_install(&install);
    let reader = CliContextCompiler::from_install(&install, &EntityRegistry::empty()).expect("the read half");
    println!("WRITER ROOT: {}", writer.root().path().display());
    println!("WRITE BIN: {}", writer.tools().write_bin().display());
    println!("NODE: {}", writer.tools().node());
    println!("READER AGREES: {}", if reader.root() == writer.root() { "yes" } else { "NO" });
    assert_eq!(reader.root(), writer.root());
}

#[test]
fn the_gui_condition_with_no_corpus_says_what_it_looked_for_and_does_not_panic() {
    // The other half of "not a crash and not a silent no-op", in a real process: an install
    // with nothing set up must exit cleanly having NAMED the candidates.
    let home = scratch("gui-real-process-empty");
    let out = run_child("gui_child_reports_every_candidate_it_tried", &home);
    let stdout = String::from_utf8_lossy(&out.stdout);
    assert!(out.status.success(), "an install with no corpus is not a failure:\n{stdout}");
    assert!(stdout.contains("NO CORPUS"), "{stdout}");
    assert!(stdout.contains("Application Support/RichOS/loro-root"), "{stdout}");
    let _ = std::fs::remove_dir_all(&home);
}

/// The child for the empty case.
#[test]
#[ignore]
fn gui_child_reports_every_candidate_it_tried() {
    let paths = CorpusPaths::from_process();
    let (install, tried) = LoroInstall::locate(&paths).expect("nothing found is not an error");
    assert!(install.is_none(), "this child runs against a HOME with nothing in it");
    println!("NO CORPUS. Looked in:");
    for t in &tried {
        println!("  {t}");
    }
    assert!(!tried.is_empty(), "a refusal that cannot say where it looked is barely better than silence");
}
