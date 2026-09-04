//! A SECOND PERSON'S FIRST FIVE MINUTES — no configuration, no companies, and a working
//! conversation at the end of it.
//!
//! # The defect this demonstrates the end of
//!
//! Until 2026-09-04 `EntityRegistry::CEOS_COMPANIES` was a `const` table of the app author's
//! six real companies, each bound to an absolute root under his own home directory, and
//! `impl Default for EntityRegistry` returned it — so that table was the SHIPPING registry of
//! every copy of RichOS ever built. On his machine it worked. On anybody else's it did two
//! things at once:
//!
//!   1. it PUBLISHED A PRIVATE LIST — the company picker renders `display_name` and `roots`
//!      for every registered entity, so a second person was shown six companies that are not
//!      his and the absolute path of a home directory that is not his;
//!   2. it LOCKED THE APP — no path a second person works in is a registered root, so
//!      `resolve_root` refused (correctly, ECS §3.3), a Finder launch resolved no entity, and
//!      the picker's only answers were another man's companies.
//!
//! # What this runs, in the order the app runs it
//!
//! | step | what the app does | here |
//! |---|---|---|
//! | boot | `EntityRegistry::load(<app-data>/entities.json)` | the same call, on a scratch config dir |
//! | boot | `boot_entity` -> `resolve_root(cwd)` | the same resolution, on his own folder |
//! | send | `Spine::submit_prompt` with no entity | the same refusal, asserted |
//! | click | `register_entity` -> `EntityRegistry::register` + `save` | the same two calls |
//! | boot | the NEXT launch reads the file back | `load` again, from disk |
//! | send | `ensure_active_thread_in` + `submit_prompt` | the same, and Rich answers |
//!
//! **What it does not cover** is the IPC hop and the button — `register_entity` takes a
//! `State<AppState>` only a running Tauri app can supply. Everything it decides before it
//! touches the app is exercised for real here and unit-tested in `src-tauri/src/main.rs`.
//!
//! The compute lease is `MockCognition`, on purpose: this demonstration is about whether a
//! stranger can REACH a working state, and a demonstration that needed a `claude` binary, a
//! login and a network would go red for reasons that are not the code.
//!
//! ```text
//! cargo run -p richos-core --example fresh_user_first_run
//! ```

use richos_core::cognition::MockCognition;
use richos_core::entity::{
    entity_registry_path, Entity, EntityRegistry, RegistrySource, ENTITY_REGISTRY_FILENAME,
};
use richos_core::ledger::{Ledger, Source};
use richos_core::spine::Spine;

/// The person this demonstration is about. Not the author of RichOS, and not on his Mac.
const HIS_NAME: &str = "Northwind Traders";

fn main() {
    // A scratch config directory and a scratch ledger: a profile that has never run RichOS.
    let tag = format!("{}-{}", std::process::id(), richos_core::util::now_millis());
    let config_dir = std::env::temp_dir().join(format!("richos-fresh-user-{tag}"));
    std::fs::create_dir_all(&config_dir).expect("a scratch config directory");
    let ledger_path = config_dir.join("conversation-ledger.jsonl");
    let registry_path = entity_registry_path(&config_dir);
    let his_folder = config_dir.join("Projects").join("northwind");
    std::fs::create_dir_all(&his_folder).expect("his own project folder");

    println!("config dir     : {}", config_dir.display());
    println!("registry file  : {} ({ENTITY_REGISTRY_FILENAME})", registry_path.display());
    println!("his folder     : {}\n", his_folder.display());

    // ---- 0. WHAT SHIPS -----------------------------------------------------------------
    //
    // The regression this whole pass exists to prevent, checked first because it is the one
    // that can silently come back.
    let shipped = EntityRegistry::default();
    println!("--- 0. what the binary ships ---");
    println!("EntityRegistry::default() holds {} compan(ies)", shipped.entities().len());
    assert!(shipped.is_empty(), "THE DEFECT IS BACK: the binary ships somebody's company list");
    for e in shipped.entities() {
        println!("  LEAKED: {} {:?} {:?}", e.id, e.display_name, e.roots);
    }
    println!("  -> nobody's companies, and nobody's home directory, in the shipping default\n");

    // ---- 1. BOOT, on a profile that has never run RichOS --------------------------------
    let mut spine = Spine::new(Ledger::open(&ledger_path).expect("open ledger"));
    let first = EntityRegistry::load(&registry_path);
    println!("--- 1. first launch ---");
    for note in &first.notes {
        println!("[richos] {note}");
    }
    assert_eq!(first.source, RegistrySource::Absent);
    assert!(first.registry.is_empty());
    assert!(!first.is_unreadable(), "absent is the ordinary first-run state, not a fault");
    spine.set_entity_registry(first.registry.clone());
    println!("registry       : {} compan(ies), source={}", first.registry.len(), first.source.as_str());

    // ---- 2. AND HIS OWN FOLDER RESOLVES TO NOTHING, WHICH IS CORRECT --------------------
    let refused = first
        .registry
        .resolve_root(&his_folder)
        .expect_err("an unregistered root MUST fail closed — ECS §3.3");
    println!("resolve_root   : {refused}");
    // The Finder-launch condition, which is how he will actually start it.
    println!("resolve_root(/): {}", first.registry.resolve_root(std::path::Path::new("/")).unwrap_err());

    // ---- 3. SO THE SEND IS REFUSED, AND NOTHING IS FILED SOMEWHERE ----------------------
    let blocked = spine
        .submit_prompt("Can you hear me?", Source::Text)
        .expect_err("a send with no company must be refused, not filed under a guess");
    println!("send           : REFUSED — {blocked}");
    assert!(spine.active_thread().is_none(), "boot must not conjure a thread out of nowhere");
    println!("               (this is the state the app was PERMANENTLY in for anyone but its author)\n");

    // ---- 4. HE ADDS HIS OWN COMPANY -----------------------------------------------------
    //
    // The two calls `register_entity` makes, in its order: register on a CLONE, write the
    // clone, and only then let anything in memory move.
    println!("--- 2. he adds his own company ---");
    let mut next = first.registry.clone();
    next.register(Entity::try_new("northwind", HIS_NAME, vec![his_folder.clone()]).expect("a valid company"))
        .expect("the first registration cannot conflict with anything");
    next.save(&registry_path).expect("the answer is durable before anything depends on it");
    println!("registered     : {HIS_NAME} -> {}", his_folder.display());
    println!("wrote          : {}", registry_path.display());
    println!("--- {} ---", ENTITY_REGISTRY_FILENAME);
    print!("{}", std::fs::read_to_string(&registry_path).expect("the file on disk"));
    println!("--- end of file ---\n");

    // ---- 5. THE NEXT LAUNCH READS IT BACK OFF DISK --------------------------------------
    println!("--- 3. the next launch ---");
    let second = EntityRegistry::load(&registry_path);
    for note in &second.notes {
        println!("[richos] {note}");
    }
    assert_eq!(second.source, RegistrySource::File);
    assert_eq!(second.registry, next, "what comes back is what went in");
    spine.set_entity_registry(second.registry.clone());

    // ---- 6. AND HIS OWN FOLDER RESOLVES --------------------------------------------------
    let owner = second.registry.resolve_root(&his_folder).expect("his own folder is his");
    println!("resolve_root   : {} -> {} ({})", his_folder.display(), owner.id, owner.display_name);
    let deep = his_folder.join("api").join("src");
    assert_eq!(second.registry.resolve_root(&deep).unwrap().id, owner.id);
    println!("               and from deep inside it: {} -> {}", deep.display(), owner.id);
    // Registering one company did not open a door. Everything else still fails closed.
    let elsewhere = config_dir.join("Projects").join("something-else");
    println!("still closed   : {}", second.registry.resolve_root(&elsewhere).unwrap_err());

    // ---- 7. A THREAD, AND THE SEND THAT WAS REFUSED A MOMENT AGO --------------------------
    println!("\n--- 4. a thread in his own company, and a send ---");
    let binding = spine.ensure_active_thread_in(&owner.id.clone()).expect("a thread in his company");
    println!("active         : {}", binding.scope_key(None));
    spine.attach_lease(Box::new(MockCognition::new(
        "sess_fresh_user",
        vec!["Yes — I can hear you, and I'm filing this under Northwind Traders."],
    )));
    let message = "Can you hear me?";
    println!("\nCEO> {message}");
    let turn_id = spine.submit_prompt(message, Source::Text).expect("the send must now land");
    let thread_id = spine.active_thread().expect("a thread").to_string();
    for m in spine.messages(&thread_id).expect("scoped read") {
        if m.role == "assistant" {
            println!("Rich> {}", m.text);
        }
    }

    // ---- 8. AND IT IS DURABLE, UNDER HIS COMPANY AND NOBODY ELSE'S -----------------------
    let turn = spine.ledger().turn(&turn_id).expect("the turn is in the ledger");
    println!("\nturn           : state={:?} stop={:?}", turn.state, turn.stop_reason);
    println!("scope          : {}", spine.active_binding().unwrap().scope_key(Some(&turn_id)));
    let entity_of_thread = spine.ledger().thread_binding(&thread_id).expect("a binding");
    assert_eq!(entity_of_thread.entity_id().as_str(), "northwind");
    println!("thread home    : {} (immutable — ECS §3.2)", entity_of_thread.entity_id());

    // THE PRIVACY ASSERTION, made against the bytes rather than against a memory of them.
    let on_disk = std::fs::read_to_string(&registry_path).expect("the registry file");
    let ledger_bytes = std::fs::read_to_string(&ledger_path).expect("the ledger");
    for (what, body) in [("entities.json", &on_disk), ("the ledger", &ledger_bytes)] {
        for leak in ["femcboost", "deeply", "prospects", "gpt-exporter", "webinar-booster"] {
            assert!(!body.contains(leak), "{what} mentions {leak} — somebody else's company leaked in");
        }
    }
    println!("\nnothing in {ENTITY_REGISTRY_FILENAME} or the ledger names a company he did not enter.");

    let _ = std::fs::remove_dir_all(&config_dir);
    println!("\nOK — a profile with no configuration reached a working conversation.");
}
