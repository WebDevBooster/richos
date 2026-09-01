//! ENTITY — the hard scope and privacy boundary (ECS architecture §3.2–3.4).
//!
//! An entity is a company, division, fund, book or venture. The UX brief §1 is explicit
//! that it is *"also a hard scope and privacy boundary"* rather than a folder, and §22's
//! "Must not be faked" list names **cross-entity context** directly. So this module's job
//! is not to carry a label around; it is to make the ECS scope key
//!
//! ```text
//! person_id + entity_id + thread_id + binding_revision + turn_id + audience
//! ```
//!
//! real rather than advisory. Slice 1 implements every component of that key except
//! `audience`: there is exactly one audience today (the CEO), the worker slice that
//! introduces a second one is a later leg, and a field that never differentiates anything
//! would be decoration, not enforcement. It is named here so nobody has to rediscover the
//! omission.
//!
//! Three rules from ECS §3.2–3.4 are load-bearing here and are enforced, not documented:
//!
//! 1. **Every thread has exactly one home entity, immutable after creation.** Moving a
//!    conversation to another entity creates a NEW thread; it never rebinds. That is why
//!    [`ThreadBinding`] has private fields, no setter and no `&mut` accessor, and why its
//!    constructor is crate-private — the only way to *obtain* one outside this crate is
//!    [`crate::ledger::Ledger::thread_binding`], which fills the entity in from the
//!    durable record. A caller cannot fabricate a binding that says something the ledger
//!    does not.
//! 2. **`entity_id` and `thread_id` are required before retrieval or mutation.** There is
//!    no unscoped read path and no unscoped write path (see `ledger.rs`).
//! 3. **An unknown or ambiguous repository root fails.** [`EntityRegistry::resolve_root`]
//!    never defaults to the last entity, the first entity or all entities.

use serde::{Deserialize, Serialize};
use std::path::{Component, Path, PathBuf};

/// The single CEO layer this app serves (ECS §3.2 `person: id: ceo-default`). RichOS
/// v1 is deliberately one CEO on one machine, so this is a constant rather than a table —
/// but the scope key carries it explicitly so a second person is a data change, not a
/// re-architecture.
///
/// **Why the prose says "CEO layer" while the identifier stays `PERSON_DEFAULT`.** The CEO
/// ruled on 2026-09-01 (`richos-hq/wiki/ceo-decisions.md` §5) that the corpus layer holding
/// his own synthesis is named `ceo/`, and the prose term followed it everywhere. The ECS
/// scope KEY did not, and deliberately: `person_id` is a persisted field in an append-only
/// event store (`ledger.rs`, and femcboost's ECS adapters read it too), so renaming it is a
/// cross-repo data migration rather than a rename. It also still means the right thing —
/// here `person` contrasts with `entity`, naming the human principal rather than the layer.
pub const PERSON_DEFAULT: &str = "ceo-default";

/// Max length of an entity id. Bounded because an entity id reaches the filesystem (the
/// machinery journal shards per thread today, per entity tomorrow) and an unbounded,
/// unvalidated id is a path-traversal seam waiting to happen.
pub const ENTITY_ID_MAX_LEN: usize = 64;

#[derive(Debug, thiserror::Error, PartialEq, Eq)]
pub enum EntityError {
    #[error("invalid entity id {0:?}: must be 1..={max} chars of [a-z0-9-], starting with [a-z0-9]", max = ENTITY_ID_MAX_LEN)]
    InvalidId(String),
    #[error("duplicate entity id in registry: {0}")]
    DuplicateId(String),
}

/// A validated entity identifier (`femcboost`, `deeply`, `prospects`, `richos`).
///
/// Newtype rather than `String` so an entity id can never be confused with a thread id,
/// a title or a display name at a call site — the compiler enforces the distinction that
/// the privacy boundary depends on.
#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(try_from = "String", into = "String")]
pub struct EntityId(String);

impl EntityId {
    /// Validate and construct. The character class is deliberately narrow: lowercase
    /// ASCII, digits and `-`. No `/`, no `.`, no `..`, no whitespace, no uppercase —
    /// so an id is safe as a path component and two ids can never differ only by case.
    pub fn parse(s: &str) -> Result<Self, EntityError> {
        let ok = !s.is_empty()
            && s.len() <= ENTITY_ID_MAX_LEN
            && s.chars().all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '-')
            && s.chars().next().is_some_and(|c| c.is_ascii_lowercase() || c.is_ascii_digit());
        if ok {
            Ok(EntityId(s.to_string()))
        } else {
            Err(EntityError::InvalidId(s.to_string()))
        }
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }
}

impl TryFrom<String> for EntityId {
    type Error = EntityError;
    fn try_from(s: String) -> Result<Self, Self::Error> {
        EntityId::parse(&s)
    }
}

impl From<EntityId> for String {
    fn from(e: EntityId) -> String {
        e.0
    }
}

impl std::fmt::Display for EntityId {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.0)
    }
}

/// The person a scope belongs to (ECS §3.4: an aggregate or event must carry either an
/// explicit `person_id` or an `entity_id`; an entity object carries both).
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct PersonId(String);

impl PersonId {
    pub fn new(s: &str) -> Self {
        PersonId(s.to_string())
    }

    pub fn default_ceo() -> Self {
        PersonId(PERSON_DEFAULT.to_string())
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }
}

impl Default for PersonId {
    fn default() -> Self {
        PersonId::default_ceo()
    }
}

impl std::fmt::Display for PersonId {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.0)
    }
}

/// Whether this entity area is SELECTABLE in this install — registration state, and
/// nothing more.
///
/// **It is not the company's lifecycle status.** `loro-structure.md`'s `company.yaml`
/// carries a `status` (and a `role`, and a `startedAt`) describing the venture itself:
/// whether the CEO still runs it, in what capacity, and since when. The CEO has not
/// stated any of those, Rich collects them in conversation, and this enum must never be
/// mistaken for an answer to them — a registry that invented `role: founder` would be
/// asserting a fact about his life from a directory listing, which is the exact defect
/// [`EntityRegistry::ceos_companies`] exists to end.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum EntityStatus {
    Active,
    Archived,
}

/// One entity area and the repository roots that deterministically select it.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Entity {
    pub id: EntityId,
    pub display_name: String,
    pub status: EntityStatus,
    /// Absolute repository roots owned by this entity (ECS §10.2). Empty is legal — an
    /// entity with no root simply cannot be selected by root resolution.
    pub roots: Vec<PathBuf>,
}

impl Entity {
    pub fn new(id: &str, display_name: &str, roots: &[&str]) -> Result<Self, EntityError> {
        Ok(Entity {
            id: EntityId::parse(id)?,
            display_name: display_name.to_string(),
            status: EntityStatus::Active,
            roots: roots.iter().map(PathBuf::from).collect(),
        })
    }
}

#[derive(Debug, thiserror::Error, PartialEq, Eq)]
pub enum EntityResolveError {
    /// ECS §3.3: "An unknown or ambiguous root fails closed. It never defaults to the
    /// last company, the first company or all companies."
    #[error("unknown root {0}: no registered entity owns this path — refusing to guess")]
    UnknownRoot(PathBuf),
    /// ECS §10.2: "A path that maps to two entities blocks the turn."
    #[error("ambiguous root {path}: maps to {candidates:?} — refusing to guess")]
    AmbiguousRoot { path: PathBuf, candidates: Vec<EntityId> },
    /// Resolution is purely lexical (no filesystem access, so it is testable and cannot
    /// be perturbed by a symlink), which requires an absolute, normalized path.
    #[error("root {0} is not absolute — resolution is lexical and requires an absolute path")]
    NotAbsolute(PathBuf),
}

/// The entity registry — the CEO's six companies (see [`EntityRegistry::ceos_companies`]).
///
/// It shipped four, derived from directory names on one Mac rather than from him. He gave
/// the real list on 2026-09-01 and it is now the `const` table on this type.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct EntityRegistry {
    entities: Vec<Entity>,
}

impl EntityRegistry {
    pub fn new(entities: Vec<Entity>) -> Result<Self, EntityError> {
        for (i, e) in entities.iter().enumerate() {
            if entities[..i].iter().any(|prev| prev.id == e.id) {
                return Err(EntityError::DuplicateId(e.id.to_string()));
            }
        }
        Ok(EntityRegistry { entities })
    }

    /// **The CEO's own companies, stated by him** (2026-09-01), and the repository roots
    /// that select each one.
    ///
    /// This table is the whole registry. It is `const` DATA rather than a body of
    /// constructor calls because that is the cheap half of "the registry is data": a row
    /// is a row, the shape is checkable at a glance, and adding a company is one line
    /// that cannot forget a field. It is deliberately **not** a config file — see
    /// [`EntityRegistry::ceos_companies`].
    ///
    /// A row is `(id, display name, roots)`. Nothing else. There is no `role`, no
    /// `status`, no `startedAt` — see [`EntityStatus`].
    pub const CEOS_COMPANIES: &'static [(&'static str, &'static str, &'static [&'static str])] = &[
        ("femcboost", "FemcBoost", &["/Users/alex/ab/femcboost"]),
        ("deeply", "Deeply", &["/Users/alex/ab/deeply"]),
        ("prospects", "Prospects", &["/Users/alex/ab/prospects"]),
        // ONE ENTITY, TWO ROOTS — the CEO's own ruling, asked and answered directly on
        // 2026-09-01. `richos` is the public product repository and `richos-hq` is the
        // private HQ repository of a single venture; Rich must hold one memory for it,
        // not two that cannot see each other. `docs/plans/richos-seat-architecture-2026-08-28.md`
        // anticipated this as "Step 8 — multi-root richos", gated on `richos-hq` being
        // cloned locally, which it now is.
        ("richos", "RichOS", &["/Users/alex/ab/richos", "/Users/alex/ab/richos-hq"]),
        ("gpt-exporter", "GPT Exporter", &["/Users/alex/ab/gpt-exporter"]),
        ("webinar-booster", "Webinar Booster", &["/Users/alex/ab/webinar-booster"]),
    ];

    /// The registered entity areas: [`Self::CEOS_COMPANIES`], validated.
    ///
    /// # Why this is not called `dogfood()` any more
    ///
    /// Because it never was one. `dogfood()` shipped four entities whose ids and roots
    /// were *four directory names that happened to exist under `~/ab`* — a scrape of one
    /// Mac presented as the CEO's list of companies. It was wrong in both directions:
    /// **`gpt-exporter` and `webinar-booster` were missing entirely**, so a launch from
    /// either resolved to no entity, could not create a thread, and refused every send;
    /// and `richos` carried one of its two repositories, so half of that venture's work
    /// resolved to nothing. The name said "test data", which is exactly why nobody
    /// noticed it was being used as the shipping registry.
    ///
    /// He gave the real list on 2026-09-01. This function is that list.
    ///
    /// # Why there is still no config-file loader
    ///
    /// Unchanged, and the reason is stronger now than when it was four rows: a registry
    /// is a **privacy boundary**, and a file that can be missing, empty, stale or edited
    /// is a boundary that can move without anybody deciding to move it. An unprovisioned
    /// config is a new failure mode on every machine that has never had one — which, for
    /// a v1 with one install, is all of them. The seam that exists is the `const` table
    /// above; it is data, it is one line per company, and it cannot be absent at runtime.
    /// When a second CEO exists, the loader is a small change against a shape that is
    /// already a list.
    pub fn ceos_companies() -> Self {
        EntityRegistry::new(
            Self::CEOS_COMPANIES
                .iter()
                .map(|(id, name, roots)| Entity::new(id, name, roots).expect("a registered entity id is valid"))
                .collect(),
        )
        .expect("registered entity ids are distinct")
    }

    pub fn entities(&self) -> &[Entity] {
        &self.entities
    }

    pub fn get(&self, id: &EntityId) -> Option<&Entity> {
        self.entities.iter().find(|e| &e.id == id)
    }

    pub fn contains(&self, id: &EntityId) -> bool {
        self.get(id).is_some()
    }

    /// Deterministically select the entity that owns `path` (ECS §3.3/§10.2).
    ///
    /// Matching is by PATH COMPONENT, never by string prefix — `/Users/alex/ab/rich` must
    /// not match the root `/Users/alex/ab/richos`, and a naive `starts_with` on the string
    /// would say it does. Zero matches is [`EntityResolveError::UnknownRoot`]; matches
    /// spanning more than one entity is [`EntityResolveError::AmbiguousRoot`]. Neither
    /// falls back to anything.
    ///
    /// A worktree must be resolved by the CALLER through its Git common directory before
    /// arriving here (ECS §10.2: "Worktrees resolve through their Git common directory or
    /// registered parent repo, never by path-name guessing"). A worktree path that happens
    /// to sit under a registered root resolves correctly by containment; one that does not
    /// fails closed rather than guessing, which is the intended behavior.
    pub fn resolve_root(&self, path: &Path) -> Result<&Entity, EntityResolveError> {
        if !path.is_absolute() {
            return Err(EntityResolveError::NotAbsolute(path.to_path_buf()));
        }
        let target: Vec<Component> = path.components().collect();
        let mut hits: Vec<&Entity> = Vec::new();
        for entity in &self.entities {
            let owns = entity.roots.iter().any(|root| {
                let root_parts: Vec<Component> = root.components().collect();
                root.is_absolute()
                    && root_parts.len() <= target.len()
                    && root_parts.iter().zip(target.iter()).all(|(a, b)| a == b)
            });
            if owns {
                hits.push(entity);
            }
        }
        match hits.len() {
            0 => Err(EntityResolveError::UnknownRoot(path.to_path_buf())),
            1 => Ok(hits[0]),
            _ => Err(EntityResolveError::AmbiguousRoot {
                path: path.to_path_buf(),
                candidates: hits.iter().map(|e| e.id.clone()).collect(),
            }),
        }
    }
}

impl Default for EntityRegistry {
    fn default() -> Self {
        EntityRegistry::ceos_companies()
    }
}

/// The durable scope of one thread: person + entity + thread + the binding revision that
/// fences it (ECS §3.3/§3.4).
///
/// **Immutability is structural, not documentary.** Every field is private, there is no
/// setter, no `&mut` accessor and no public constructor. Outside this crate the only way
/// to obtain a `ThreadBinding` is [`crate::ledger::Ledger::thread_binding`], which reads
/// the entity out of the immutable durable record. That is what makes "a thread has
/// exactly one home entity, immutable after creation" a property of the type system
/// rather than a comment somebody can violate next quarter.
///
/// A binding carries a REVISION because it is a fencing token, not a UI hint (§3.4): a
/// command captured at revision N is refused once the active context has moved on.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct ThreadBinding {
    person_id: PersonId,
    entity_id: EntityId,
    thread_id: String,
    binding_revision: u64,
}

impl ThreadBinding {
    /// Crate-private on purpose — see the type doc. `Ledger` is the only authority
    /// allowed to say which entity a thread belongs to.
    pub(crate) fn new(person_id: PersonId, entity_id: EntityId, thread_id: &str, binding_revision: u64) -> Self {
        ThreadBinding { person_id, entity_id, thread_id: thread_id.to_string(), binding_revision }
    }

    pub fn person_id(&self) -> &PersonId {
        &self.person_id
    }

    pub fn entity_id(&self) -> &EntityId {
        &self.entity_id
    }

    pub fn thread_id(&self) -> &str {
        &self.thread_id
    }

    pub fn binding_revision(&self) -> u64 {
        self.binding_revision
    }

    /// The ECS scope key as a single string, for logs and violation records. `audience`
    /// is absent because slice 1 does not implement it (see the module doc); `turn_id` is
    /// supplied by the caller when one exists.
    pub fn scope_key(&self, turn_id: Option<&str>) -> String {
        format!(
            "{}+{}+{}+r{}+{}",
            self.person_id,
            self.entity_id,
            self.thread_id,
            self.binding_revision,
            turn_id.unwrap_or("-")
        )
    }
}

/// A thread's entity home. `Unbound` exists ONLY for threads written before entity
/// binding existed — the app can never create one (see `Ledger::create_thread`).
///
/// This is the deliberate answer to "existing threads have no `entity_id`": they are not
/// migrated by a heuristic, because §22 names cross-entity context as something that must
/// not be faked and a wrong binding is a privacy-boundary violation rather than a
/// cosmetic bug. They are quarantined in this state and every scoped read and write
/// against them fails closed.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(tag = "state", rename_all = "snake_case")]
pub enum ThreadEntity {
    Bound { person_id: PersonId, entity_id: EntityId, binding_revision: u64 },
    /// Pre-entity record. Listable (so an operator can see it and adopt it), never
    /// readable and never writable.
    Unbound,
}

impl ThreadEntity {
    pub fn entity_id(&self) -> Option<&EntityId> {
        match self {
            ThreadEntity::Bound { entity_id, .. } => Some(entity_id),
            ThreadEntity::Unbound => None,
        }
    }

    pub fn is_bound(&self) -> bool {
        matches!(self, ThreadEntity::Bound { .. })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn entity_id_rejects_everything_that_could_escape_a_path_component() {
        assert!(EntityId::parse("femcboost").is_ok());
        assert!(EntityId::parse("richos-2").is_ok());
        assert!(EntityId::parse("9lives").is_ok());
        for bad in ["", "FemcBoost", "fem cboost", "../etc", "a/b", ".hidden", "-lead", "femcboost\n"] {
            assert!(EntityId::parse(bad).is_err(), "{bad:?} should be rejected");
        }
        // Bounded: 64 ok, 65 rejected.
        assert!(EntityId::parse(&"a".repeat(ENTITY_ID_MAX_LEN)).is_ok());
        assert!(EntityId::parse(&"a".repeat(ENTITY_ID_MAX_LEN + 1)).is_err());
    }

    #[test]
    fn the_registry_is_exactly_the_const_table_and_the_table_is_the_ceos_list() {
        let reg = EntityRegistry::ceos_companies();
        let ids: Vec<&str> = reg.entities().iter().map(|e| e.id.as_str()).collect();
        assert_eq!(ids, vec!["femcboost", "deeply", "prospects", "richos", "gpt-exporter", "webinar-booster"]);
        // The function is a projection of the DATA, with nothing added and nothing
        // dropped — which is the whole claim the `const` table makes.
        assert_eq!(reg.entities().len(), EntityRegistry::CEOS_COMPANIES.len());
        for (row, e) in EntityRegistry::CEOS_COMPANIES.iter().zip(reg.entities()) {
            assert_eq!(row.0, e.id.as_str());
            assert_eq!(row.1, e.display_name);
            assert_eq!(row.2.len(), e.roots.len());
        }
    }

    #[test]
    fn root_resolution_is_by_component_not_string_prefix() {
        let reg = EntityRegistry::ceos_companies();
        // Exact root, and a path deep inside it.
        assert_eq!(reg.resolve_root(Path::new("/Users/alex/ab/richos")).unwrap().id.as_str(), "richos");
        assert_eq!(
            reg.resolve_root(Path::new("/Users/alex/ab/richos/app/crates/richos-core")).unwrap().id.as_str(),
            "richos"
        );
        // THE STRING-PREFIX TRAP: "/Users/alex/ab/rich" is a string prefix of the richos
        // root but is NOT inside it. A `starts_with` implementation would bind this to
        // richos; component matching correctly refuses.
        assert_eq!(
            reg.resolve_root(Path::new("/Users/alex/ab/rich")).unwrap_err(),
            EntityResolveError::UnknownRoot(PathBuf::from("/Users/alex/ab/rich"))
        );
    }

    #[test]
    fn unknown_and_ambiguous_roots_fail_closed_and_never_default() {
        let reg = EntityRegistry::ceos_companies();
        assert!(matches!(
            reg.resolve_root(Path::new("/tmp/somewhere-else")),
            Err(EntityResolveError::UnknownRoot(_))
        ));
        assert!(matches!(reg.resolve_root(Path::new("relative/path")), Err(EntityResolveError::NotAbsolute(_))));

        // ECS §10.2: "A path that maps to two entities blocks the turn."
        let overlapping = EntityRegistry::new(vec![
            Entity::new("alpha", "Alpha", &["/Users/alex/ab"]).unwrap(),
            Entity::new("beta", "Beta", &["/Users/alex/ab/shared"]).unwrap(),
        ])
        .unwrap();
        match overlapping.resolve_root(Path::new("/Users/alex/ab/shared/pkg")) {
            Err(EntityResolveError::AmbiguousRoot { candidates, .. }) => {
                assert_eq!(candidates.len(), 2);
            }
            other => panic!("expected AmbiguousRoot, got {other:?}"),
        }
    }

    #[test]
    fn registry_rejects_duplicate_ids() {
        let dup = EntityRegistry::new(vec![
            Entity::new("femcboost", "One", &[]).unwrap(),
            Entity::new("femcboost", "Two", &[]).unwrap(),
        ]);
        assert_eq!(dup.unwrap_err(), EntityError::DuplicateId("femcboost".into()));
    }

    #[test]
    fn thread_binding_exposes_the_scope_key_and_has_no_mutator() {
        let b = ThreadBinding::new(PersonId::default_ceo(), EntityId::parse("femcboost").unwrap(), "thr_1", 7);
        assert_eq!(b.scope_key(Some("turn_9")), "ceo-default+femcboost+thr_1+r7+turn_9");
        assert_eq!(b.scope_key(None), "ceo-default+femcboost+thr_1+r7+-");
        assert_eq!(b.entity_id().as_str(), "femcboost");
        assert_eq!(b.binding_revision(), 7);
    }
}
