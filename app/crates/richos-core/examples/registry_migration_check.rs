//! DOES AN EXISTING INSTALL LOSE ITS THREADS? Answered against a real ledger, read-only.
//!
//! # The question
//!
//! Before 2026-09-04 the entity registry was `EntityRegistry::CEOS_COMPANIES` — a `const`
//! table compiled into the binary — so every id it named was registered on every machine,
//! for free, forever. It is the person's own file now, and an install that ran under the old
//! build has a ledger full of threads bound to ids that the new build has never heard of.
//!
//! An unregistered id is not a cosmetic problem. `Spine::create_thread` refuses it, every
//! scoped read and write against a thread bound to it fails closed, and the thread is still
//! on disk — which, for the person looking at the screen, is the same as gone.
//!
//! # What this program does, and what it deliberately does not
//!
//! It reads a ledger, collects the DISTINCT ENTITY IDS bound to its threads, runs the exact
//! migration the shell's boot runs ([`EntityRegistry::from_existing_ids`]), writes the
//! registry to a scratch file, READS IT BACK FROM DISK, and checks that every id the ledger
//! uses is registered afterwards.
//!
//! **It never writes to the ledger it is given and never writes near it.** The registry it
//! produces goes to a temp directory, is checked, and is deleted. Pointing this at a live
//! install is safe by construction: the ledger is opened, replayed in memory, and not
//! written back.
//!
//! It also reads NOTHING but thread metadata — ids, titles and bindings. No message body is
//! touched, and none is printed.
//!
//! ```text
//! cargo run -p richos-core --example registry_migration_check -- <path-to-conversation-ledger.jsonl>
//! ```

use richos_core::entity::{entity_registry_path, EntityId, EntityRegistry, RegistrySource};
use richos_core::ledger::Ledger;
use richos_core::spine::Spine;
use std::path::PathBuf;

fn main() {
    let Some(arg) = std::env::args().nth(1) else {
        eprintln!(
            "usage: registry_migration_check <path-to-conversation-ledger.jsonl>\n\
             \n\
             Reads the ledger, runs the no-orphan migration, and reports whether every entity\n\
             it already uses is still registered afterwards. It writes nothing near the ledger."
        );
        std::process::exit(64);
    };
    let ledger_path = PathBuf::from(&arg);
    if !ledger_path.is_file() {
        eprintln!("no ledger at {}", ledger_path.display());
        std::process::exit(2);
    }
    println!("ledger         : {}", ledger_path.display());

    // Replayed in memory. `Ledger::open` appends nothing on its own, and nothing below
    // writes through this handle.
    let ledger = Ledger::open(&ledger_path).expect("replay the ledger");
    let spine = Spine::new(ledger);

    // ---- 1. WHAT THIS INSTALL ALREADY USES ---------------------------------------------
    let summaries = spine.threads();
    let mut existing: Vec<EntityId> = Vec::new();
    let mut unbound = 0usize;
    for s in &summaries {
        match s.entity_id.as_deref().map(EntityId::parse) {
            Some(Ok(id)) => {
                if !existing.contains(&id) {
                    existing.push(id);
                }
            }
            // A pre-entity thread, quarantined by construction. It contributes nothing here
            // and is not migrated by a heuristic — a wrong binding is a privacy violation
            // rather than a cosmetic bug.
            _ => unbound += 1,
        }
    }
    println!("threads        : {} ({unbound} with no entity home)", summaries.len());
    println!(
        "entity ids used: {}",
        if existing.is_empty() {
            "(none)".to_string()
        } else {
            existing.iter().map(|e| e.to_string()).collect::<Vec<_>>().join(", ")
        }
    );

    // ---- 2. WHAT THE NEW BUILD REGISTERS WITHOUT THE MIGRATION -------------------------
    let shipped = EntityRegistry::default();
    println!("\n--- without the migration ---");
    println!("shipped default: {} compan(ies)", shipped.len());
    let orphans: Vec<&EntityId> = existing.iter().filter(|id| !shipped.contains(id)).collect();
    println!(
        "would be unreachable: {}",
        if orphans.is_empty() {
            "(none)".to_string()
        } else {
            orphans.iter().map(|e| e.to_string()).collect::<Vec<_>>().join(", ")
        }
    );

    // ---- 3. THE MIGRATION THE BOOT RUNS -------------------------------------------------
    let scratch = std::env::temp_dir().join(format!(
        "richos-migration-check-{}-{}",
        std::process::id(),
        richos_core::util::now_millis()
    ));
    std::fs::create_dir_all(&scratch).expect("a scratch directory");
    let registry_path = entity_registry_path(&scratch);

    println!("\n--- the migration, and a reload from disk ---");
    let before = EntityRegistry::load(&registry_path);
    assert_eq!(before.source, RegistrySource::Absent, "the scratch registry must start absent");
    let migrated = EntityRegistry::from_existing_ids(&existing);
    migrated.save(&registry_path).expect("write the migrated registry");
    let after = EntityRegistry::load(&registry_path);
    assert_eq!(after.source, RegistrySource::File);
    for note in &after.notes {
        println!("[richos] {note}");
    }

    let mut all_ok = true;
    for id in &existing {
        let ok = after.registry.contains(id);
        all_ok &= ok;
        let e = after.registry.entities().iter().find(|e| &e.id == id);
        println!(
            "  {:<6} {:<20} display_name={:?} roots={}",
            if ok { "OK" } else { "LOST" },
            id.to_string(),
            e.map(|e| e.display_name.clone()).unwrap_or_default(),
            e.map(|e| e.roots.len()).unwrap_or(0)
        );
    }

    // NO ROOT IS INVENTED — the property that keeps the migration honest. It knows which ids
    // own records here; it does not know where those companies live, and a guessed root is a
    // wrong entity waiting to happen.
    assert!(
        after.registry.entities().iter().all(|e| e.roots.is_empty()),
        "the migration invented a root — it must not"
    );

    println!("\n--- what he has to do next ---");
    if existing.is_empty() {
        println!("nothing: this install has filed no work under any company yet.");
    } else {
        println!(
            "nothing, to keep his threads. To have RichOS pick a company automatically again,\n\
             add its folder — in the window, or as a `roots` line in\n\
             <app-data>/entities.json (docs/entity-registry.md)."
        );
    }

    let _ = std::fs::remove_dir_all(&scratch);
    println!("\n{}", if all_ok { "OK — no thread is orphaned." } else { "FAILED — at least one entity was lost." });
    if !all_ok {
        std::process::exit(1);
    }
}
