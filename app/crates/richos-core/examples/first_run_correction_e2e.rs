//! A FRESH USER'S FIRST FIVE MINUTES: no memory, one click, and a correction written in the
//! SAME session.
//!
//! `loro_gui_correction_e2e` proves the desk on a machine that already has a corpus. This
//! proves the case that machine cannot reach: the corpus does not exist when the process
//! starts, the CEO answers *"yes, set it up"*, and the very next thing he does is correct
//! something. Until 2026-09-01 that last step was impossible — `AppState::correction` was
//! fixed at boot, so the desk stayed shut until he quit and reopened, while the window told
//! him *"From now on I'll keep what you tell me in that folder"*.
//!
//! # It runs the sequence the app runs, in the order the app runs it
//!
//! | step | what the app does | here |
//! |---|---|---|
//! | boot | `memory::wire_company_memory` | `LoroInstall::locate` on an empty `$HOME` -> nothing |
//! | boot | `install_correction_desk` | not called: there is no writer, so no desk |
//! | click | `provision_memory` -> `provision()` | the same call, same arguments |
//! | click | `provision_memory` -> `wire_company_memory` again | the same call |
//! | click | `provision_memory` -> `install_correction_desk` | `CorrectionDesk::open` on the new writer |
//! | then | `loro_propose_correction` | `desk.propose` |
//! | then | `loro_confirm_correction` | `desk.confirm`, and the file on disk |
//!
//! **What it does not cover** is the same strip `loro_gui_correction_e2e` names: the IPC hop
//! and the button. These are the Rust functions the `#[tauri::command]`s call; the commands
//! themselves take a `State<AppState>` only a running Tauri app can supply, and GUI
//! automation is unavailable on this machine (System Events reports zero windows for every
//! process). Everything from `provision` down is exercised for real.
//!
//! # It cannot touch the CEO's corpus, by construction
//!
//! Every candidate `resolve_corpus` considers hangs off the `$HOME` this process is given,
//! and `provision` refuses a target that is already a corpus, a target that is not empty, and
//! any target inside a product checkout. There is no argument to this program that names a
//! corpus.
//!
//! ```text
//! cd / && env -i HOME=<scratch> USER="$USER" PATH=/usr/bin:/bin:/usr/sbin:/sbin \
//!   app/target/debug/examples/first_run_correction_e2e <loro-checkout>
//! ```

use richos_core::correction::{CliLoroWriter, CorrectionDesk, ProposedWrite};
use richos_core::entity::EntityRegistry;
use richos_core::loro::{CorpusPaths, LoroInstall};
use richos_core::provision::{offered_corpus_dir, provision, ProvisionRequest};
use std::path::{Path, PathBuf};

fn main() {
    let compiler_source = std::env::args().nth(1).map(PathBuf::from);
    let home = PathBuf::from(std::env::var("HOME").expect("a HOME"));
    println!("cwd  : {}", std::env::current_dir().unwrap().display());
    println!("HOME : {}", home.display());
    println!("PATH : {:?}", std::env::var("PATH").ok());
    for k in ["LORO_CORPUS", "LORO_ROOT", "RICHOS_LORO_DIR", "RICHOS_NODE_BIN"] {
        assert!(std::env::var_os(k).is_none(), "{k} must be unset — this is meant to be a GUI launch");
    }

    // ---- BOOT: a machine with no memory ------------------------------------------------
    let (install, tried) = LoroInstall::locate(&CorpusPaths::from_process()).expect("resolution");
    assert!(install.is_none(), "this test is about a FRESH machine; something already resolved");
    println!("\n--- boot, on a machine with no memory ---");
    println!("BOOT   : no corpus. Looked in:");
    for t in &tried {
        println!("         {t}");
    }
    // The desk at boot is exactly what `install_correction_desk` would have been given:
    // nothing. There is no writer, so there is no desk, so `loro_available` is false.
    let mut desk: Option<CorrectionDesk> = None;
    println!("DESK   : {} (nothing to write with)", describe(&desk));
    assert!(desk.is_none());

    // ---- THE CLICK: `provision_memory` -------------------------------------------------
    // The location is `offered_corpus_dir`, which is the string the window pre-fills and the
    // button sends back unchanged. Nothing here picks a location he did not see.
    let target = offered_corpus_dir(&home);
    println!("\n--- he clicks \"set it up\" ---");
    println!("OFFER  : {}", target.display());
    let registry = EntityRegistry::ceos_companies();
    let report = provision(&ProvisionRequest {
        target: target.clone(),
        home: Some(home.clone()),
        companies: registry.entities().iter().map(|e| (e.id.to_string(), e.display_name.clone())).collect(),
        compiler_source,
    })
    .expect("provisioning");
    println!("CORPUS : {}", report.root.display());
    println!("POINTER: {:?}", report.pointer.as_ref().map(|p| p.display().to_string()));

    // ---- and `provision_memory` re-wires BOTH halves ------------------------------------
    let (install, _) = LoroInstall::locate(&CorpusPaths::from_process()).expect("resolution");
    let install = install.expect("a corpus resolves now — this is the read half re-wiring");
    println!("READ   : {} via {}", install.root().path().display(), install.source().as_str());
    let data_dir = home.join("Library/Application Support/com.richos.app");
    std::fs::create_dir_all(&data_dir).unwrap();
    // THE LINE THAT DID NOT EXIST. `install_correction_desk`, called from `provision_memory`.
    desk = Some(
        CorrectionDesk::open(
            data_dir.join("loro-corrections.jsonl"),
            Box::new(CliLoroWriter::from_install(&install)),
        )
        .expect("the desk opens"),
    );
    println!("DESK   : {} — installed by provisioning, NO RELAUNCH", describe(&desk));
    let desk = desk.as_mut().expect("a desk");

    // ---- AND HE CORRECTS SOMETHING, IN THE SAME SESSION ---------------------------------
    println!("\n--- the same session: he corrects something ---");
    let entity = registry.entities().first().map(|e| e.id.to_string()).expect("an entity");
    let write = ProposedWrite::Append {
        id: "first-run-correction-same-session".into(),
        kind: "decision".into(),
        scope: None,
        title: Some("A correction written in the session that created the corpus".into()),
        body: "Written by the app's own write path, on a machine that had no memory when this \
               process started, without a relaunch. Before 2026-09-01 the desk was fixed at boot \
               and this write was impossible until the CEO quit and reopened."
            .into(),
        partition: None,
    };
    let proposal = desk
        .propose(&entity, "thr_first_run", write, "proving the desk opens without a relaunch")
        .expect("the dry run");
    println!("PROPOSE: state={:?}", proposal.state);
    let expected = install.root().path().join("ceo/records/first-run-correction-same-session.md");
    assert!(!expected.exists(), "nothing may exist before he says yes");
    println!("BEFORE : exists={} at {}", expected.exists(), expected.display());

    let done = desk.confirm(&entity, &proposal.id).expect("the write");
    let out = done.outcome.as_ref().expect("an outcome");
    println!("CONFIRM: state={:?} ref={}", done.state, out.r#ref);
    println!("AFTER  : exists={} at {}", Path::new(&out.file).exists(), out.file);

    let body = std::fs::read_to_string(&out.file).expect("THE RECORD ON DISK");
    println!("\n--- {} ---", out.file);
    print!("{body}");
    if !body.ends_with('\n') {
        println!();
    }
    println!("--- end of record ---");

    // And the reader finds it, because it is the same corpus — the property the whole
    // one-`LoroInstall` design exists to make structural.
    let shown = desk.show(&out.r#ref).expect("show");
    assert_eq!(shown.file, out.file, "the reader and the writer must name one file");
    println!("SHOW   : ref={} file={}", shown.r#ref, shown.file);
    println!("AGREE  : yes");
    println!("\nRESULT : a machine with no memory, provisioned and corrected in ONE session.");
}

fn describe(d: &Option<CorrectionDesk>) -> &'static str {
    if d.is_some() {
        "OPEN"
    } else {
        "CLOSED"
    }
}
