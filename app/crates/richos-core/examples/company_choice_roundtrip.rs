//! THE FIRST SUCCESSFUL SEND, from the state a double-clicked RichOS actually boots into.
//!
//! `native_roundtrip` beside this file proves the turn works. It proves it from a thread it
//! creates itself, with the company hard-coded — so it says nothing about the condition that
//! kept the CEO from talking to Rich at all: a Finder launch has working directory `/`, that
//! owns no entity, `EntityRegistry::resolve_root` refuses to guess (ECS §3.3 — correctly),
//! and with no entity there is no thread, and with no thread every send is refused.
//!
//! This runs the whole sequence, in order, against real compute:
//!
//!   1. a fresh config and a fresh ledger — a machine nobody has answered on;
//!   2. the send is REFUSED, and the refusal is asserted rather than hoped for;
//!   3. the company is written the way the picker writes it (`ConfigStore::set_entity`);
//!   4. the store is DROPPED and reopened — the next boot, reading its own bytes off disk;
//!   5. a thread is activated in the remembered company, no relaunch;
//!  5b. company memory is resolved THE WAY THE SHIPPED APP RESOLVES IT, so a run under
//!      `env -i` proves the double-click's Tier C rather than a configured shell's;
//!   6. a real `claude` lease is attached and the same sentence is sent, and Rich answers.
//!
//! It is an example and not a test on purpose: it needs the `claude` binary, the customer's
//! own login and a network, and a suite that needs those is a suite that goes red for
//! reasons that are not the code. The four steps that do NOT need compute are also tests
//! (`src-tauri/src/main.rs` `entity_choice_tests`, `config.rs`).
//!
//! Run:
//!   cargo run -p richos-core --example company_choice_roundtrip -- <engine_dir> [company]

use richos_core::config::ConfigStore;
use richos_core::entity::EntityId;
use richos_core::ledger::{Ledger, Source};
use richos_core::loro::{CliContextCompiler, CorpusPaths};
use richos_core::native::{resolve_claude_bin, NativeCognition};
use richos_core::spine::Spine;
use richos_core::Cognition;
use std::path::PathBuf;

fn main() {
    let mut args = std::env::args().skip(1);
    let engine_dir = args.next().map(PathBuf::from).unwrap_or_else(|| PathBuf::from("../../engine"));
    let company = args.next().unwrap_or_else(|| "richos".to_string());
    let entity = EntityId::parse(&company).expect("a valid entity id");

    let tag = format!("{}-{}", std::process::id(), richos_core::util::now_millis());
    let ledger_path = std::env::temp_dir().join(format!("richos-company-roundtrip-{tag}.jsonl"));
    let config_path = std::env::temp_dir().join(format!("richos-company-roundtrip-{tag}.json"));

    // ---- 1. a machine nobody has answered on ------------------------------------------
    let mut spine = Spine::new(Ledger::open(&ledger_path).expect("open ledger"));
    {
        let store = ConfigStore::open(&config_path).expect("open config");
        assert_eq!(store.entity(), None, "a fresh install must have chosen nothing");
    }
    println!("1. fresh install: no company chosen, no thread active");

    // ---- 2. and the send is refused ---------------------------------------------------
    let refused = spine
        .submit_prompt("Can you hear me?", Source::Text)
        .expect_err("a send with no company MUST be refused, not filed somewhere");
    println!("2. send refused, as it must be: {refused}");

    // ---- 3. he answers the picker ------------------------------------------------------
    {
        let mut store = ConfigStore::open(&config_path).expect("open config");
        store.set_entity(&entity).expect("write the answer");
    }
    println!("3. answered: {company} written to {}", config_path.display());

    // ---- 4. the next boot reads it off disk --------------------------------------------
    let reopened = ConfigStore::open(&config_path).expect("reopen config");
    let remembered = reopened.entity().expect("the next boot must still know the answer");
    assert_eq!(remembered, entity);
    println!("4. next boot reads it back: {remembered}");

    // ---- 5. a thread in the remembered company, without a relaunch ----------------------
    let binding = spine.ensure_active_thread_in(&remembered).expect("activate");
    println!("5. active: {}", binding.scope_key(None));

    // ---- 5b. COMPANY MEMORY, resolved the way the shipped app resolves it ---------------
    //
    // Added 2026-09-01. Steps 1-5 above were written against a build whose Tier C was
    // dead on a Finder launch, so this example proved a first send that reached Rich with
    // no company memory in it and could not have noticed. `locate` is the app's own
    // resolver: run this under `env -i` and it answers the same way the double-click does.
    match CliContextCompiler::locate(&CorpusPaths::from_process()) {
        Ok((Some((compiler, source)), _)) => {
            println!(
                "5b. company memory: {} (via {}), node {}",
                compiler.root().path().display(),
                source.as_str(),
                compiler.tools().node()
            );
            spine.set_loro_context_compiler(Box::new(compiler));
        }
        Ok((None, tried)) => {
            println!("5b. company memory: NONE resolved — the re-prime below carries none");
            for t in tried {
                println!("    tried {t}");
            }
        }
        Err(e) => println!("5b. company memory: configured but unusable: {e}"),
    }

    // ---- 6. and the send that was refused a moment ago lands ---------------------------
    let claude_bin = resolve_claude_bin();
    eprintln!("[roundtrip] claude     = {}", claude_bin.display());
    eprintln!("[roundtrip] engine cwd = {}", engine_dir.display());
    let cognition = NativeCognition::start(&claude_bin, &engine_dir).expect("start the native claude session");
    eprintln!("[roundtrip] session    = {}", cognition.session_id());
    spine.attach_lease(Box::new(cognition));

    let message = "In one sentence: are you there?";
    println!("\nCEO> {message}\n");
    let turn_id = spine.submit_prompt(message, Source::Text).expect("the send must now land");
    let thread_id = spine.active_thread().unwrap().to_string();
    print!("Rich> ");
    for m in spine.messages(&thread_id).expect("scoped read") {
        if m.role == "assistant" {
            println!("{}", m.text);
        }
    }

    let turn = spine.ledger().turn(&turn_id).expect("turn");
    eprintln!("\n[roundtrip] turn state = {:?}, stop = {:?}", turn.state, turn.stop_reason);
    // The size of what a fresh Rich was primed with, read from the ledger's own record
    // rather than from a variable this file kept. Run it twice — once with the corpus
    // reachable and once with HOME pointing somewhere that has no pointer — and the
    // difference between the two `priming_chars` IS the compiled slice.
    for a in spine.ledger().actions().iter().filter(|a| a.kind == "session_reprime") {
        eprintln!("[roundtrip] {}", a.detail);
    }
    eprintln!("[roundtrip] scope      = {}", spine.active_binding().unwrap().scope_key(Some(&turn_id)));
    let _ = std::fs::remove_file(&ledger_path);
    let _ = std::fs::remove_file(&config_path);
    eprintln!("[roundtrip] OK");
}
