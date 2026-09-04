//! THE REGISTRY BELONGS TO THE PERSON RUNNING THE APP — end to end, on disk.
//!
//! # What this file used to be, and why that was the defect
//!
//! It used to open: *"THE REGISTRY IS THE CEO'S OWN LIST"*, and it pinned six company names
//! bound to six absolute roots under `/Users/alex/ab/`. `EntityRegistry::CEOS_COMPANIES` was
//! a `const` table, `impl Default` returned it, and it was therefore the SHIPPING registry
//! of every copy of RichOS ever built.
//!
//! On the machine it was written on, that worked. On any other machine it did two things at
//! once, and the tests here could not see either because they only ever ran against the
//! table:
//!
//!   1. **It published a private list.** The company picker renders `display_name` and
//!      `roots` for every registered entity, so a second person opening RichOS was shown six
//!      companies that were not his and the absolute path of a home directory that was not
//!      his.
//!   2. **It locked the app.** No path a second person works in is a registered root, so
//!      `resolve_root` refused (correctly — ECS §3.3), a Finder launch resolved no entity at
//!      all, and the only answers the picker offered were another man's companies. The
//!      states available to him were "refuse every send" and "file my work under FemcBoost".
//!
//! # So these tests pin the replacement
//!
//! The registry is read from `entities.json` in the install's own configuration directory,
//! it is EMPTY until its owner puts something in it, and every one of ECS §3.2–3.4's rules
//! still holds over it — including, and especially, the rule that an unknown root fails
//! closed rather than guessing.

use richos_core::entity::{
    entity_registry_path, Entity, EntityError, EntityId, EntityRegistry, EntityResolveError,
    RegistrySource, ENTITY_REGISTRY_FILENAME,
};
use std::path::{Path, PathBuf};

fn scratch(tag: &str) -> PathBuf {
    let d = std::env::temp_dir().join(format!(
        "richos-registry-{tag}-{}-{}",
        std::process::id(),
        richos_core::util::now_millis()
    ));
    let _ = std::fs::remove_dir_all(&d);
    std::fs::create_dir_all(&d).unwrap();
    d
}

fn id_of(reg: &EntityRegistry, p: &str) -> String {
    reg.resolve_root(Path::new(p)).unwrap_or_else(|e| panic!("{p} did not resolve: {e}")).id.to_string()
}

// ---------------------------------------------------------------------------------------
// 1. NOBODY'S COMPANIES SHIP
// ---------------------------------------------------------------------------------------

/// The regression guard for the whole pass. If somebody re-introduces a compiled-in
/// registry, this is the test that fails first.
#[test]
fn the_shipping_default_registry_is_empty() {
    let reg = EntityRegistry::default();
    assert!(reg.is_empty(), "the default registry shipped six real companies; it must ship none");
    assert_eq!(reg.entities().len(), 0);
}

/// An empty registry is a LEGAL state: it answers every question, it never panics, and it
/// never guesses. A first launch is in it and nothing is wrong.
#[test]
fn an_empty_registry_answers_and_never_guesses() {
    let reg = EntityRegistry::empty();
    for p in ["/", "/Users/jordan", "/Users/jordan/code/northwind", "/opt/work"] {
        assert_eq!(
            reg.resolve_root(Path::new(p)).unwrap_err(),
            EntityResolveError::UnknownRoot(PathBuf::from(p)),
            "{p} must fail closed, not fall back to anything"
        );
    }
    assert!(!reg.contains(&EntityId::parse("anything").unwrap()));
    assert!(reg.entities().is_empty());
}

// ---------------------------------------------------------------------------------------
// 2. A PERSON WITH NO CONFIGURATION REACHES A WORKING STATE
// ---------------------------------------------------------------------------------------

/// THE END-TO-END PROOF, at the level of the crate: a fresh configuration directory, no
/// file, a company the person actually has, and a root that resolves afterwards — with a
/// reload from disk in the middle, so nothing is proved by in-memory state alone.
#[test]
fn a_first_run_user_registers_their_own_company_and_their_own_folder_resolves() {
    let config_dir = scratch("first-run");
    let path = entity_registry_path(&config_dir);
    assert_eq!(path.file_name().unwrap(), ENTITY_REGISTRY_FILENAME);

    // 1. Nothing on disk. Empty registry, and the app is told plainly that this is the
    //    "not asked yet" state rather than a broken one.
    let first = EntityRegistry::load(&path);
    assert_eq!(first.source, RegistrySource::Absent);
    assert!(first.registry.is_empty());
    assert!(!first.is_unreadable());

    // 2. He registers HIS company, at HIS path.
    let mut reg = first.registry;
    reg.register(Entity::new("northwind", "Northwind Traders", &["/Users/jordan/code/northwind"]).unwrap())
        .unwrap();
    reg.save(&path).unwrap();
    assert!(path.exists(), "the answer is durable before anything depends on it");

    // 3. A RELOAD FROM DISK — the next launch, in effect.
    let second = EntityRegistry::load(&path);
    assert_eq!(second.source, RegistrySource::File);
    assert_eq!(second.registry, reg);
    assert_eq!(second.registry.len(), 1);

    // 4. And his own folder now resolves, from the root and from deep inside it.
    assert_eq!(id_of(&second.registry, "/Users/jordan/code/northwind"), "northwind");
    assert_eq!(id_of(&second.registry, "/Users/jordan/code/northwind/api/src"), "northwind");
    // Everything else still fails closed. Registering one company did not open a door.
    assert!(matches!(
        second.registry.resolve_root(Path::new("/Users/jordan/code/other")),
        Err(EntityResolveError::UnknownRoot(_))
    ));

    let _ = std::fs::remove_dir_all(&config_dir);
}

/// A second company joins the first rather than replacing it, and the file keeps its order.
#[test]
fn a_second_company_joins_the_first_and_file_order_is_preserved() {
    let config_dir = scratch("second");
    let path = entity_registry_path(&config_dir);

    let mut reg = EntityRegistry::empty();
    reg.register(Entity::new("northwind", "Northwind Traders", &["/Users/jordan/code/northwind"]).unwrap())
        .unwrap();
    reg.save(&path).unwrap();

    let mut reloaded = EntityRegistry::load(&path).registry;
    reloaded.register(Entity::new("lumen", "Lumen Labs", &["/Users/jordan/code/lumen"]).unwrap()).unwrap();
    reloaded.save(&path).unwrap();

    let ids: Vec<String> =
        EntityRegistry::load(&path).registry.entities().iter().map(|e| e.id.to_string()).collect();
    assert_eq!(ids, vec!["northwind", "lumen"]);
    let _ = std::fs::remove_dir_all(&config_dir);
}

// ---------------------------------------------------------------------------------------
// 3. ECS §3.2–3.4 STILL HOLDS OVER A FILE-BACKED REGISTRY
// ---------------------------------------------------------------------------------------

/// Two roots, one entity — the property that had never been exercised until the CEO's
/// `richos`/`richos-hq` pair needed it, pinned here against data that belongs to nobody.
#[test]
fn one_entity_may_own_two_roots_and_both_paths_reach_it_after_a_reload() {
    let config_dir = scratch("multi-root");
    let path = entity_registry_path(&config_dir);

    let mut reg = EntityRegistry::empty();
    reg.register(
        Entity::new(
            "harbor",
            "Harbor Analytics",
            &["/Users/example/Projects/harbor", "/Users/example/Projects/harbor-private"],
        )
        .unwrap(),
    )
    .unwrap();
    reg.save(&path).unwrap();

    let reg = EntityRegistry::load(&path).registry;
    assert_eq!(id_of(&reg, "/Users/example/Projects/harbor"), "harbor");
    assert_eq!(id_of(&reg, "/Users/example/Projects/harbor-private"), "harbor");
    assert_eq!(id_of(&reg, "/Users/example/Projects/harbor/etl/src"), "harbor");
    assert_eq!(id_of(&reg, "/Users/example/Projects/harbor-private/notes"), "harbor");
    // ONE entity, not two hits: a second root on the SAME entity must not read as ambiguity.
    // This is the assertion that fails if `resolve_root` ever counts roots instead of
    // entities.
    let e = reg.resolve_root(Path::new("/Users/example/Projects/harbor-private")).unwrap();
    assert_eq!(e.roots.len(), 2);
    assert_eq!(reg.entities().iter().filter(|x| x.id.as_str() == "harbor").count(), 1);
    let _ = std::fs::remove_dir_all(&config_dir);
}

/// `harbor-private` is a STRING prefix match of `harbor`'s root. It resolves because it is
/// registered as its own root — not because the matcher was fooled. Strip it and the same
/// path must fail closed.
#[test]
fn the_component_matcher_is_what_makes_the_prefix_case_safe() {
    let one_root =
        EntityRegistry::new(vec![Entity::new("harbor", "Harbor", &["/Users/example/Projects/harbor"]).unwrap()])
            .unwrap();
    assert!(matches!(
        one_root.resolve_root(Path::new("/Users/example/Projects/harbor-private")),
        Err(EntityResolveError::UnknownRoot(_))
    ));
}

/// A registry that came off disk is still refused an id it does not hold — the property
/// `Spine::create_thread` leans on so an unregistered entity can never become a thread's
/// immutable home.
#[test]
fn a_loaded_registry_still_refuses_an_id_it_does_not_hold() {
    let config_dir = scratch("refuse");
    let path = entity_registry_path(&config_dir);
    let mut reg = EntityRegistry::empty();
    reg.register(Entity::new("northwind", "Northwind", &["/Users/jordan/code/northwind"]).unwrap()).unwrap();
    reg.save(&path).unwrap();

    let reg = EntityRegistry::load(&path).registry;
    assert!(reg.contains(&EntityId::parse("northwind").unwrap()));
    assert!(!reg.contains(&EntityId::parse("acme-holdings").unwrap()));
    let _ = std::fs::remove_dir_all(&config_dir);
}

// ---------------------------------------------------------------------------------------
// 4. THE FILE IS HAND-EDITABLE, SO IT IS HAND-EDITED WRONG
// ---------------------------------------------------------------------------------------

/// Every root a file names must be absolute — a relative one can never match, so an entity
/// holding one is registered, listed, pickable and permanently unresolvable. The file is
/// refused whole rather than loaded minus one company.
#[test]
fn a_relative_root_in_the_file_refuses_the_file_rather_than_creating_a_dead_entry() {
    let config_dir = scratch("relative");
    let path = entity_registry_path(&config_dir);
    std::fs::write(
        &path,
        r#"{"version":1,"entities":[
             {"id":"northwind","display_name":"Northwind","roots":["/Users/jordan/code/northwind"]},
             {"id":"lumen","display_name":"Lumen","roots":["code/lumen"]}]}"#,
    )
    .unwrap();
    let load = EntityRegistry::load(&path);
    assert_eq!(load.source, RegistrySource::Unreadable);
    assert!(load.registry.is_empty(), "a partial load would make `lumen` silently vanish");
    assert!(load.notes.iter().any(|n| n.contains("not absolute")), "{:?}", load.notes);
    let _ = std::fs::remove_dir_all(&config_dir);
}

/// A file MAY describe overlapping roots and resolution must keep failing closed on them
/// (ECS §10.2: "A path that maps to two entities blocks the turn"). What `register` must not
/// do is let somebody CREATE that state from the window by accident.
#[test]
fn overlap_is_refused_at_registration_and_still_fails_closed_when_a_file_carries_it() {
    let config_dir = scratch("overlap");
    let path = entity_registry_path(&config_dir);
    std::fs::write(
        &path,
        r#"{"version":1,"entities":[
             {"id":"outer","display_name":"Outer","roots":["/Users/jordan/code"]},
             {"id":"inner","display_name":"Inner","roots":["/Users/jordan/code/northwind"]}]}"#,
    )
    .unwrap();
    let reg = EntityRegistry::load(&path).registry;
    assert_eq!(reg.len(), 2, "the file is loadable — it is not malformed, it is ambiguous");
    match reg.resolve_root(Path::new("/Users/jordan/code/northwind/api")) {
        Err(EntityResolveError::AmbiguousRoot { candidates, .. }) => assert_eq!(candidates.len(), 2),
        other => panic!("an overlapping registry must block the turn, got {other:?}"),
    }

    // And the door refuses to create it.
    let mut fresh = EntityRegistry::empty();
    fresh.register(Entity::new("outer", "Outer", &["/Users/jordan/code"]).unwrap()).unwrap();
    assert!(matches!(
        fresh.register(Entity::new("inner", "Inner", &["/Users/jordan/code/northwind"]).unwrap()),
        Err(EntityError::OverlappingRoot { .. })
    ));
    let _ = std::fs::remove_dir_all(&config_dir);
}

// ---------------------------------------------------------------------------------------
// 5. NOBODY'S EXISTING THREADS ARE ORPHANED
// ---------------------------------------------------------------------------------------

/// THE MIGRATION, at the level this crate owns it.
///
/// An install that ran while the registry was compiled in has a ledger full of threads bound
/// to ids that would stop being registered the moment the table left the binary — and an
/// unregistered id means every scoped read and write against those threads fails closed.
/// The threads would still be on disk and would be unreachable, which for the person reading
/// the screen is the same thing.
///
/// So the ids that already own records are restored, and NOTHING ELSE IS. No root is
/// invented, because nothing on this machine knows where those companies live and a guessed
/// root is a wrong entity waiting to happen.
#[test]
fn ids_that_already_own_records_survive_the_registry_leaving_the_binary() {
    let config_dir = scratch("migration");
    let path = entity_registry_path(&config_dir);

    let existing: Vec<EntityId> = ["femcboost", "deeply", "prospects", "richos", "gpt-exporter", "webinar-booster"]
        .iter()
        .map(|s| EntityId::parse(s).unwrap())
        .collect();

    let migrated = EntityRegistry::from_existing_ids(&existing);
    migrated.save(&path).unwrap();

    let reg = EntityRegistry::load(&path).registry;
    for id in &existing {
        assert!(reg.contains(id), "{id} owns threads on this machine and must stay registered");
    }
    assert_eq!(reg.len(), existing.len());
    // No root is invented — root resolution stays honest about knowing nothing.
    assert!(reg.entities().iter().all(|e| e.roots.is_empty()));
    assert!(matches!(
        reg.resolve_root(Path::new("/Users/jordan/anywhere")),
        Err(EntityResolveError::UnknownRoot(_))
    ));
    let _ = std::fs::remove_dir_all(&config_dir);
}
