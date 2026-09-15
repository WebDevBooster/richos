//! THE WHOLE CORRECTION DESK, ON A LAUNCH WITH NO ENVIRONMENT — proposal, confirmation,
//! and a record on disk.
//!
//! The unit tests prove the resolver; this proves the SEAM. It runs the exact sequence
//! `src-tauri` runs at boot (`LoroInstall::locate` → `CliLoroWriter::from_install` →
//! `CorrectionDesk::open`) and then the exact two calls the Tauri commands
//! `loro_propose_correction` and `loro_confirm_correction` make, and it prints the file that
//! appears.
//!
//! # It cannot touch the CEO's corpus, by construction
//!
//! Every candidate `resolve_corpus` considers hangs off the `$HOME` the process is given, so
//! a run under a scratch `$HOME` can only ever reach a scratch corpus. There is no argument
//! to this program that names a corpus, and none that could.
//!
//! ```text
//! # 1. put a corpus on the scratch machine (a setup act, run from a terminal)
//! cargo run -p richos-core --example loro_gui_correction_e2e -- setup /tmp/e2e-home <loro-checkout>
//!
//! # 2. the thing under test: launchd's environment, nothing else, cwd=/
//! cd / && env -i HOME=/tmp/e2e-home USER="$USER" PATH=/usr/bin:/bin:/usr/sbin:/sbin \
//!   app/target/debug/examples/loro_gui_correction_e2e drive
//! ```
//!
//! # What it does NOT cover
//!
//! The webview. It stops at the Rust functions the `#[tauri::command]`s call, because the
//! commands themselves take a `State<AppState>` that only a running Tauri app can supply,
//! and driving the real window is not available on this machine — `System Events` reports
//! zero windows for every process here, so nobody can honestly claim a hand on the button.
//! The uncovered strip is the IPC hop and the button: `ui/` → `invoke("loro_confirm_correction")`
//! → `desk(&state)?.confirm(...)`. Everything from `confirm` down is exercised here for real.

use richos_core::correction::{CliLoroWriter, CorrectionDesk, ProposedWrite};
use richos_core::entity::EntityRegistry;
use richos_core::loro::{CorpusPaths, LoroInstall};
use richos_core::provision::{provision, ProvisionRequest};
use std::path::{Path, PathBuf};

fn main() {
    let args: Vec<String> = std::env::args().collect();
    match args.get(1).map(String::as_str) {
        Some("setup") => setup(Path::new(&args[2]), args.get(3).map(PathBuf::from)),
        Some("drive") => drive(),
        _ => {
            eprintln!("usage: loro_gui_correction_e2e setup <scratch-home> [loro-checkout] | drive");
            std::process::exit(64);
        }
    }
}

/// A corpus on the scratch machine, created the way first-run provisioning creates one.
fn setup(home: &Path, compiler_source: Option<PathBuf>) {
    let registry = demo_registry(home);
    let companies: Vec<(String, String)> =
        registry.entities().iter().map(|e| (e.id.to_string(), e.display_name.clone())).collect();
    let report = provision(&ProvisionRequest {
        // `~/RichOS/corpus` — the drop-zone candidate, and the one a scratch `$HOME` reaches.
        target: home.join("RichOS").join("corpus"),
        home: Some(home.to_path_buf()),
        companies,
        compiler_source,
    })
    .expect("provisioning the scratch corpus");
    println!("corpus  : {}", report.root.display());
    println!("compiler: {:?}", report.compiler);
}

/// The launch. Everything below runs with launchd's environment and `cwd=/`.
fn drive() {
    println!("cwd  : {}", std::env::current_dir().unwrap().display());
    println!("HOME : {:?}", std::env::var("HOME").ok());
    println!("PATH : {:?}", std::env::var("PATH").ok());
    for k in ["LORO_CORPUS", "LORO_ROOT", "RICHOS_LORO_DIR", "RICHOS_NODE_BIN"] {
        assert!(std::env::var_os(k).is_none(), "{k} must be unset — this is meant to be a GUI launch");
    }

    // --- BOOT, as `src-tauri/src/memory.rs` runs it ------------------------------------
    let (install, tried) = LoroInstall::locate(&CorpusPaths::from_process()).expect("resolution");
    let install = install.unwrap_or_else(|| panic!("no corpus resolved; looked in: {}", tried.join("; ")));
    println!("INSTALL: root={} via {}", install.root().path().display(), install.source().as_str());
    println!("         tools={} via {}", install.tools().dir().display(), install.tools_source().as_str());
    println!("         node={}", install.tools().node());

    let writer = CliLoroWriter::from_install(&install);
    let data_dir =
        PathBuf::from(std::env::var("HOME").unwrap()).join("Library/Application Support/com.richos.e2e");
    std::fs::create_dir_all(&data_dir).unwrap();
    let mut desk = CorrectionDesk::open(data_dir.join("loro-corrections.jsonl"), Box::new(writer))
        .expect("the desk opens");
    println!("DESK   : open at {}", desk.path().display());

    // --- HE IS SHOWN A PROPOSAL (`loro_propose_correction`) ----------------------------
    let write = ProposedWrite::Append {
        id: "gui-launch-write-path-2026-09-01".into(),
        kind: "decision".into(),
        scope: None,
        title: Some("The correction desk works on a Finder launch".into()),
        body: "Written by the app's own write path under launchd's environment with cwd=/, \
               which is the condition that left this desk dead at c6cf4ea."
            .into(),
        partition: None,
    };
    let why = "proving the write path resolves a corpus on a launch with no environment";
    let proposal = desk.propose("richos", "thr_e2e", write, why).expect("the dry run");
    // The preview is the WRITER'S OWN `--dry-run` text, so what he is shown is the bytes that
    // would land rather than a description of them.
    println!("PROPOSE: state={:?}", proposal.state);
    println!("--- preview (the writer's own --dry-run) ---");
    print!("{}", proposal.preview);
    if !proposal.preview.ends_with('\n') {
        println!();
    }
    println!("--- end of preview ---");
    let expected_file = install
        .root()
        .path()
        .join("ceo")
        .join("records")
        .join("gui-launch-write-path-2026-09-01.md");
    assert!(!expected_file.exists(), "nothing may exist before he says yes");
    println!("BEFORE : {} exists={}", expected_file.display(), expected_file.exists());

    // --- HE SAYS YES (`loro_confirm_correction`) ---------------------------------------
    let done = desk.confirm("richos", &proposal.id).expect("the write");
    let out = done.outcome.as_ref().expect("an outcome");
    println!("CONFIRM: state={:?} ref={}", done.state, out.r#ref);
    println!("AFTER  : exists={} at {}", Path::new(&out.file).exists(), out.file);
    let body = std::fs::read_to_string(&out.file).expect("THE RECORD ON DISK");
    println!("--- {} ---", out.file);
    print!("{body}");
    if !body.ends_with('\n') {
        println!();
    }
    println!("--- end of record ---");

    // --- AND THE READ HALF FINDS IT, because it is the same corpus ----------------------
    let shown = desk.show(&out.r#ref).expect("show");
    println!("SHOW   : ref={} file={}", shown.r#ref, shown.file);
    assert_eq!(shown.file, out.file, "the reader and the writer must name one file");
    println!("AGREE  : yes");
}

/// THE COMPANY THIS DEMO REGISTERS — invented, and belonging to nobody.
///
/// Before 2026-09-04 this was `EntityRegistry::ceos_companies()`: a `const` table of the
/// CEO's six real companies that shipped inside the binary and was the registry of every
/// install. The registry is per-user now (`entity.rs` rule 4) and a fresh machine has none,
/// so a demo that needs a company to exist REGISTERS one, exactly as a first-run user does.
fn demo_registry(home: &std::path::Path) -> EntityRegistry {
    let mut registry = EntityRegistry::empty();
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
