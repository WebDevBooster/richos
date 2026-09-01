//! THE REGISTRY IS THE CEO'S OWN LIST — not a scrape of this Mac's directory names.
//!
//! `EntityRegistry::dogfood()` shipped four entities derived from four folders that
//! happened to exist under `~/ab`. Two of the CEO's companies were missing entirely, and
//! the sixth — RichOS — had one of its two repositories registered, so half of that
//! venture's work resolved to no entity at all and every send from it was refused.
//!
//! He gave the real list on 2026-09-01 (six companies; `wiki/ceo-decisions.md` §5 is the
//! ruling that made the loro layout real). These tests pin it, and they pin the one
//! property nothing had ever exercised: **two distinct roots resolving to one entity id.**

use richos_core::entity::{Entity, EntityRegistry, EntityResolveError};
use std::path::Path;

fn id_of(reg: &EntityRegistry, p: &str) -> String {
    reg.resolve_root(Path::new(p)).unwrap_or_else(|e| panic!("{p} did not resolve: {e}")).id.to_string()
}

#[test]
fn the_registry_is_the_six_companies_the_ceo_named() {
    let reg = EntityRegistry::ceos_companies();
    let ids: Vec<&str> = reg.entities().iter().map(|e| e.id.as_str()).collect();
    assert_eq!(
        ids,
        vec!["femcboost", "deeply", "prospects", "richos", "gpt-exporter", "webinar-booster"],
        "the list is his, in his order — not four folder names"
    );
    let names: Vec<&str> = reg.entities().iter().map(|e| e.display_name.as_str()).collect();
    assert_eq!(names, vec!["FemcBoost", "Deeply", "Prospects", "RichOS", "GPT Exporter", "Webinar Booster"]);
}

#[test]
fn the_two_companies_that_were_missing_now_resolve() {
    // Neither of these existed in the registry before 2026-09-01, so a launch from either
    // directory resolved to NO entity, could not create a thread, and refused every send.
    let reg = EntityRegistry::ceos_companies();
    assert_eq!(id_of(&reg, "/Users/alex/ab/gpt-exporter"), "gpt-exporter");
    assert_eq!(id_of(&reg, "/Users/alex/ab/webinar-booster"), "webinar-booster");
}

#[test]
fn richos_is_one_entity_with_two_roots_and_both_paths_reach_it() {
    // THE MULTI-ROOT PROOF. `Entity::new` has always taken a list of roots and no shipped
    // entity ever had two, so this path was never exercised. The CEO ruled it directly:
    // the public product repo and the private HQ repo are ONE venture, and Rich holds ONE
    // memory for it.
    let reg = EntityRegistry::ceos_companies();
    assert_eq!(id_of(&reg, "/Users/alex/ab/richos"), "richos");
    assert_eq!(id_of(&reg, "/Users/alex/ab/richos-hq"), "richos");
    // And from deep inside each of them, which is where a launch actually happens.
    assert_eq!(id_of(&reg, "/Users/alex/ab/richos/app/crates/richos-core"), "richos");
    assert_eq!(id_of(&reg, "/Users/alex/ab/richos-hq/loro/records"), "richos");
    // One entity, not two hits: a second root on the SAME entity must not read as
    // ambiguity. This is the assertion that would fail if `resolve_root` counted roots
    // instead of entities.
    let e = reg.resolve_root(Path::new("/Users/alex/ab/richos-hq")).unwrap();
    assert_eq!(e.roots.len(), 2, "richos owns exactly two roots");
    assert_eq!(reg.entities().iter().filter(|x| x.id.as_str() == "richos").count(), 1);
}

#[test]
fn richos_hq_is_not_a_child_of_richos_and_the_component_matcher_is_what_proves_it() {
    // `/Users/alex/ab/richos-hq` is a STRING prefix match against the root
    // `/Users/alex/ab/richos`. It resolves to `richos` because it is registered as its own
    // root — not because the matcher was fooled. Strip the second root and it must fail
    // closed rather than fall into the first.
    let one_root =
        EntityRegistry::new(vec![Entity::new("richos", "RichOS", &["/Users/alex/ab/richos"]).unwrap()]).unwrap();
    assert!(matches!(
        one_root.resolve_root(Path::new("/Users/alex/ab/richos-hq")),
        Err(EntityResolveError::UnknownRoot(_))
    ));
}

#[test]
fn every_registered_root_is_absolute_and_distinct() {
    // A relative root can never match (resolution is lexical and requires an absolute
    // path), so one would be a silently dead entry. A duplicated root across two entities
    // would make every path under it ambiguous and block the turn.
    let reg = EntityRegistry::ceos_companies();
    let mut all: Vec<String> = Vec::new();
    for e in reg.entities() {
        assert!(!e.roots.is_empty(), "{} has no root and could never be resolved", e.id);
        for r in &e.roots {
            assert!(r.is_absolute(), "{} root {} is not absolute", e.id, r.display());
            all.push(r.display().to_string());
        }
    }
    let before = all.len();
    all.sort();
    all.dedup();
    assert_eq!(all.len(), before, "two entities share a root — every path under it would be ambiguous");
}
