//! THE READ SEAM, WIRED — company memory reaching a re-prime, and the guard on the way in.
//!
//! `reprime.rs` has carried a `LoroContextCompiler` trait since the continuity foundation
//! landed, and nothing ever implemented it. The compiler itself has been complete and
//! versioned the whole time, one directory away, behind `loro/CONTEXT-CONTRACT.md`. So
//! every re-prime asserted a fresh Rich into existence with **no company memory at all**
//! while the thing that would have supplied it sat there callable. This module is the
//! implementation, and it is the only place in richos-core that knows loro exists.
//!
//! # What crosses the boundary, and what must not
//!
//! `richos` GOES PUBLIC. Loro's content is the CEO's second brain and is private by
//! construction — it is not in this repo and never will be. Everything here is *mechanism*:
//! how to invoke a binary that lives elsewhere, how to parse a documented JSON shape, and
//! what to refuse. **No corpus content, no corrections, no speech.** The corpus root is
//! read from the environment at runtime and is never defaulted — `CONTEXT-CONTRACT.md` §1
//! is explicit that a default root means "a customer's Rich silently answering out of the
//! VENDOR's company memory, and exiting 0 either way", which it correctly calls a larger
//! failure than an error, not a smaller one.
//!
//! # The read-only invariant is not weakened, and could not be from here
//!
//! Loro's compiler is read-only by structural proof: `assertNoSideEffects` scans every
//! module under `loro/lib/**` for a filesystem write (`privacy.js`), which is why a
//! persistent index cannot live in the compiler at all. Nothing in this file can change
//! that — it invokes `bin/loro-context.mjs` as a child process and reads stdout. What it
//! CAN do is smuggle a write in through the same door, so it doesn't: [`CliContextCompiler`]
//! holds no writer, cannot name one, and a test asserts its argv contains no write verb.
//! Writing is a different type reaching a different binary (`correction.rs`), and it only
//! ever runs after the CEO has said yes.

use crate::reprime::{LoroContextCompiler, LoroTier, SliceRequest};
use serde::Deserialize;
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::{Arc, Mutex};

/// The slice schema this build understands. `CONTEXT-CONTRACT.md` §2's forward-compat rule:
/// fields may be ADDED within a version and unknown ones must be ignored (which
/// `#[serde(default)]` + serde's default of ignoring unknown keys does); a REMOVED or
/// retyped field bumps this, and *"a consumer that cares should assert
/// `schemaVersion === 1` and treat anything higher as unsupported — degrade to no slice —
/// rather than mis-parsing it."* This consumer cares.
pub const SUPPORTED_SLICE_SCHEMA: u64 = 1;

/// The memory-scope wall this consumer reads at (`CONTEXT-CONTRACT.md` §4). `rich` is the
/// re-prime's audience by name in the contract's own table — *"Rich is the CEO's own
/// executive function"* — and it is a constant rather than a setting because widening it is
/// a privacy decision and narrowing it silently would hide the CEO's own memory from him.
pub const REPRIME_AUDIENCE: &str = "rich";

#[derive(Debug, thiserror::Error)]
pub enum LoroError {
    #[error("loro tools not found: {0}")]
    ToolsNotFound(String),
    #[error("loro corpus root not configured: {0}")]
    NoRoot(String),
    #[error("loro lane map: {0}")]
    LaneMap(String),
}

// ---------------------------------------------------------------------------
// configuration — all of it explicit, none of it inferred
// ---------------------------------------------------------------------------

/// Where the CEO's memory is. `CONTEXT-CONTRACT.md` §1: *"There is no fallback."*
///
/// Two shapes, and they are not interchangeable. A provisioned [`LoroRoot::Corpus`] is
/// `ceo/` + `companies/<id>/` and is the real thing. A [`LoroRoot::Root`] is the in-repo
/// dogfood layout (`wiki/` + `loro/`) and the slice it produces SAYS SO, carrying
/// `corpus.layout: "repo"` and a note naming it as RichOS's own memory — because, as the
/// contract puts it, the wrong company's memory is byte-honest too and only provenance
/// distinguishes it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum LoroRoot {
    Corpus(PathBuf),
    Root(PathBuf),
}

impl LoroRoot {
    /// Resolve from the environment in the contract's own precedence order: `LORO_CORPUS`,
    /// then `LORO_ROOT`. `None` is a legitimate, common state — an install with no corpus —
    /// and it produces [`LoroTier::NotWired`], never a guess.
    pub fn from_env() -> Option<Self> {
        if let Ok(v) = std::env::var("LORO_CORPUS") {
            let v = v.trim();
            if !v.is_empty() {
                return Some(LoroRoot::Corpus(PathBuf::from(v)));
            }
        }
        if let Ok(v) = std::env::var("LORO_ROOT") {
            let v = v.trim();
            if !v.is_empty() {
                return Some(LoroRoot::Root(PathBuf::from(v)));
            }
        }
        None
    }

    /// The two CLI arguments naming this root.
    pub fn args(&self) -> (&'static str, &Path) {
        match self {
            LoroRoot::Corpus(p) => ("--corpus", p.as_path()),
            LoroRoot::Root(p) => ("--root", p.as_path()),
        }
    }

    pub fn path(&self) -> &Path {
        match self {
            LoroRoot::Corpus(p) | LoroRoot::Root(p) => p.as_path(),
        }
    }
}

/// The loro checkout holding `bin/loro-context.mjs` and `bin/loro-write.mjs`.
///
/// **Deliberately not inferred from this checkout.** richos has no `loro/` directory and
/// never has — the vocabulary and the corpus are the CEO's and live outside a repo that
/// goes public, which is exactly the trap the transcription E2E fell into on 2026-08-29
/// (open-items 3.3e: a precondition a clean checkout can never satisfy). `RICHOS_LORO_DIR`
/// names it, or nothing does.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LoroTools {
    dir: PathBuf,
    node: String,
}

impl LoroTools {
    /// Verify that `dir` really is a loro checkout — BOTH entry points present. A directory
    /// that exists but holds neither is the failure that would otherwise surface as a
    /// non-zero exit on every compile, once per rotation, forever.
    pub fn locate(dir: impl AsRef<Path>) -> Result<Self, LoroError> {
        let dir = dir.as_ref().to_path_buf();
        let ctx = dir.join("bin").join("loro-context.mjs");
        let wri = dir.join("bin").join("loro-write.mjs");
        if !ctx.is_file() {
            return Err(LoroError::ToolsNotFound(format!("{} is not a file", ctx.display())));
        }
        if !wri.is_file() {
            return Err(LoroError::ToolsNotFound(format!("{} is not a file", wri.display())));
        }
        let node = std::env::var("RICHOS_NODE_BIN").ok().filter(|v| !v.trim().is_empty()).unwrap_or_else(|| "node".into());
        Ok(LoroTools { dir, node })
    }

    pub fn from_env() -> Option<Result<Self, LoroError>> {
        let v = std::env::var("RICHOS_LORO_DIR").ok()?;
        let v = v.trim().to_string();
        if v.is_empty() {
            return None;
        }
        Some(LoroTools::locate(v))
    }

    pub fn context_bin(&self) -> PathBuf {
        self.dir.join("bin").join("loro-context.mjs")
    }

    pub fn write_bin(&self) -> PathBuf {
        self.dir.join("bin").join("loro-write.mjs")
    }

    pub fn node(&self) -> &str {
        &self.node
    }

    pub fn dir(&self) -> &Path {
        &self.dir
    }
}

/// ENTITY → loro company lane, stated by an operator and never guessed.
///
/// # Why this is a map and not `entity_id == company_id`
///
/// Because name equality is an inference, and this is the one place an inference costs the
/// most. The re-prime's own identity assertion tells the successor *"do not assume, infer or
/// carry over anything from another entity area, however related a name looks"*; a compiler
/// that binds an entity to a loro partition because the two strings match is doing precisely
/// the thing the sentence forbids, one layer down, in the payload that carries the sentence.
///
/// # It was empty by default until 2026-09-01, and why it no longer is
///
/// `loro-structure.md`'s "one loro, two homes" — the CEO layer plus N company partitions —
/// was READY-FOR-CEO and unratified (open-items 1.6/3.5). Shipping a hard-coded
/// entity-is-a-company rule would have ratified it in code while the register still said
/// OPEN, so the map was empty by default and the seam simply refused to narrow.
///
/// **He ratified it on 2026-09-01** (`wiki/ceo-decisions.md` §5: *"The proposals there make
/// sense… The only thing I'd change is replace `person/` with `ceo/`"*), so the default is
/// now [`LaneMap::ceos_companies`] — his six registered entities, each mapped to a lane of
/// the same name. That is still an enumeration rather than a rule: the map holds six
/// stated pairs, `lane_for` answers `None` for everything else, and no seventh entity
/// acquires a lane by looking like one.
///
/// # And the map is reconciled against the corpus before anything is sent
///
/// A mapping is a claim that a partition exists, and loro refuses a lane it does not have
/// — `exit 2: no such company partition "femcboost" in this corpus. Known: (none).` The
/// CEO's corpus today has **zero** partitions, so a map that were merely filled in would
/// turn every re-prime into `LoroTier::Unavailable`. See
/// [`CliContextCompiler::reconcile_lanes`].
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct LaneMap(BTreeMap<String, String>);

impl LaneMap {
    /// Parse `entity=lane,entity=lane`. An entry with an empty half is a usage error, not a
    /// silently-dropped mapping — a typo that quietly maps nothing would look exactly like
    /// a working configuration until the day it mattered.
    pub fn parse(spec: &str) -> Result<Self, LoroError> {
        let mut map = BTreeMap::new();
        for pair in spec.split(',').map(str::trim).filter(|p| !p.is_empty()) {
            let Some((entity, lane)) = pair.split_once('=') else {
                return Err(LoroError::LaneMap(format!("{pair:?} is not entity=lane")));
            };
            let (entity, lane) = (entity.trim(), lane.trim());
            if entity.is_empty() || lane.is_empty() {
                return Err(LoroError::LaneMap(format!("{pair:?} has an empty half")));
            }
            if map.insert(entity.to_string(), lane.to_string()).is_some() {
                return Err(LoroError::LaneMap(format!("entity {entity:?} is mapped twice")));
            }
        }
        Ok(LaneMap(map))
    }

    /// The ratified default: each of the CEO's six registered entities mapped to a loro
    /// company lane of the same name (`wiki/ceo-decisions.md` §5).
    ///
    /// **Same-name is a STATED pair here, not an inferred rule.** The distinction is the
    /// whole point of this type and it survives: the map is built by enumerating
    /// [`crate::entity::EntityRegistry::CEOS_COMPANIES`], so it holds exactly six pairs and
    /// `lane_for` answers `None` for a seventh id however much it looks like one of the
    /// six. Nothing binds an entity to a partition because two strings match; six pairs
    /// were written down, and they are these.
    ///
    /// It is also inert until his corpus is partitioned — see
    /// [`CliContextCompiler::reconcile_lanes`].
    pub fn ceos_companies() -> Self {
        LaneMap(
            crate::entity::EntityRegistry::CEOS_COMPANIES
                .iter()
                .map(|(id, _, _)| ((*id).to_string(), (*id).to_string()))
                .collect(),
        )
    }

    /// `RICHOS_LORO_LANES` when the operator sets it; [`Self::ceos_companies`] otherwise.
    ///
    /// An explicit setting still wins outright — including an explicitly EMPTY one, which
    /// is how an operator turns lane narrowing off entirely without editing the binary.
    pub fn from_env() -> Result<Self, LoroError> {
        match std::env::var("RICHOS_LORO_LANES") {
            Ok(v) if !v.trim().is_empty() => LaneMap::parse(&v),
            Ok(_) => Ok(LaneMap::default()),
            Err(_) => Ok(LaneMap::ceos_companies()),
        }
    }

    /// Every mapped id must be a REGISTERED entity.
    ///
    /// `femcbost=fb` is one keystroke from a real mapping and, unchecked, maps nothing
    /// while looking exactly like a working configuration — the same failure the
    /// empty-half check in [`Self::parse`] refuses, one level up. The lane half is NOT
    /// checked here: which partitions exist is a fact about the corpus, not about this
    /// process, and it is answered by [`CliContextCompiler::reconcile_lanes`].
    pub fn validate_against(&self, registry: &crate::entity::EntityRegistry) -> Result<(), LoroError> {
        for entity in self.0.keys() {
            let known = crate::entity::EntityId::parse(entity).is_ok_and(|id| registry.contains(&id));
            if !known {
                return Err(LoroError::LaneMap(format!(
                    "{entity:?} is not a registered entity — a lane keyed by a typo maps nothing \
                     and looks like a working configuration"
                )));
            }
        }
        Ok(())
    }

    pub fn lane_for(&self, entity_id: &str) -> Option<&str> {
        self.0.get(entity_id).map(String::as_str)
    }

    /// The entity ids this map carries, in id order.
    pub fn entities(&self) -> impl Iterator<Item = &str> {
        self.0.keys().map(String::as_str)
    }

    pub fn is_empty(&self) -> bool {
        self.0.is_empty()
    }

    pub fn len(&self) -> usize {
        self.0.len()
    }
}

/// The company partitions a corpus ACTUALLY has, read from the corpus rather than assumed.
///
/// `loro-context.mjs corpus --format json` reports `companies` and `retiredCompanies`
/// (`bin/loro-context.mjs`, the `corpus` command). Measured on the CEO's real corpus,
/// three consecutive runs: **0.07 s, 0.06 s, 0.06 s** — cheap enough to run once at boot,
/// and the only thing that can tell a mapping from a wish.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct CorpusLanes {
    companies: Vec<String>,
    retired: Vec<String>,
}

/// The subset of `corpus --format json` this consumer reads. Everything else in that
/// summary — coverage, counts, fingerprint — is an operator diagnostic, not a lane fact.
#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct CorpusSummary {
    #[serde(default)]
    companies: Vec<String>,
    #[serde(default)]
    retired_companies: Vec<String>,
}

impl CorpusLanes {
    pub fn new(companies: &[String], retired: &[String]) -> Self {
        CorpusLanes { companies: companies.to_vec(), retired: retired.to_vec() }
    }

    /// Ask the corpus what partitions it has.
    ///
    /// A failure here is NOT fatal and must not be treated as "no partitions": those are
    /// different facts, and the caller decides. `Err` carries the reason so a boot line can
    /// print it.
    pub fn probe(tools: &LoroTools, root: &LoroRoot) -> Result<Self, LoroError> {
        let (flag, path) = root.args();
        let out = Command::new(tools.node())
            .arg(tools.context_bin())
            .arg("corpus")
            .arg(flag)
            .arg(path)
            .arg("--format")
            .arg("json")
            .output()
            .map_err(|e| LoroError::LaneMap(format!("could not ask the corpus which lanes it has: {e}")))?;
        if !out.status.success() {
            let code = out.status.code().map(|c| c.to_string()).unwrap_or_else(|| "signal".into());
            let why = String::from_utf8_lossy(&out.stderr);
            return Err(LoroError::LaneMap(format!(
                "loro corpus exited {code}: {}",
                why.lines().next().unwrap_or("").trim()
            )));
        }
        let summary: CorpusSummary = serde_json::from_str(&String::from_utf8_lossy(&out.stdout))
            .map_err(|e| LoroError::LaneMap(format!("the corpus summary did not parse: {e}")))?;
        Ok(CorpusLanes { companies: summary.companies, retired: summary.retired_companies })
    }

    pub fn has(&self, lane: &str) -> bool {
        self.companies.iter().any(|c| c == lane)
    }

    pub fn is_retired(&self, lane: &str) -> bool {
        self.retired.iter().any(|c| c == lane)
    }

    /// True when the corpus has no partitions at all — the CEO's state today, and the one
    /// in which "read everything" and "read the CEO layer" are the same read.
    pub fn is_unpartitioned(&self) -> bool {
        self.companies.is_empty()
    }

    pub fn companies(&self) -> &[String] {
        &self.companies
    }
}

// ---------------------------------------------------------------------------
// the slice — the documented shape, and only the documented shape
// ---------------------------------------------------------------------------

/// The compiled slice, parsed down to the fields `CONTEXT-CONTRACT.md` §2 promises.
///
/// Everything is `#[serde(default)]` and unknown keys are ignored, which is §2's
/// forward-compatibility rule as code: within `schemaVersion: 1` fields may be added, and a
/// consumer that breaks on a new field is a consumer that breaks on the next ranking
/// improvement.
#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Slice {
    #[serde(default)]
    pub schema_version: u64,
    #[serde(default)]
    pub compiler: String,
    #[serde(default)]
    pub thin: bool,
    #[serde(default)]
    pub coverage: String,
    #[serde(default)]
    pub text: String,
    #[serde(default)]
    pub items: Vec<SliceItem>,
    #[serde(default)]
    pub corpus: SliceCorpus,
    #[serde(default)]
    pub budget: SliceBudget,
    #[serde(default)]
    pub notes: Vec<String>,
}

// `rename_all` is REQUIRED here, not cosmetic: the contract's field is `kindInferred` and
// without it serde looks for `kind_inferred`, finds nothing, and silently defaults an
// INFERRED kind to `false` — a guess flattened into a declaration by a missing attribute.
// Every other field on this struct is a single word, so nothing else moves.
#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SliceItem {
    #[serde(default)]
    pub r#ref: String,
    #[serde(default)]
    pub kind: String,
    #[serde(default)]
    pub title: String,
    #[serde(default)]
    pub scope: String,
    /// `true` = the kind was GUESSED from prose rather than declared by a promoted record
    /// (`CONTEXT-CONTRACT.md` §2, `record.js` invariant 2). Read here, not merely ignored,
    /// because a correction desk that proposed `kind: decision` off a guess would be
    /// asserting an adjudicated claim the corpus never made.
    #[serde(default)]
    pub kind_inferred: bool,
    /// The item's LANE. `null` is the CEO layer — `CONTEXT-CONTRACT.md` §6c calls that
    /// "a legitimate permanent state, not an error".
    #[serde(default)]
    pub company: Option<String>,
}

#[derive(Debug, Clone, Default, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SliceCorpus {
    #[serde(default)]
    pub record_count: u64,
    #[serde(default)]
    pub fingerprint: String,
    #[serde(default)]
    pub layout: String,
    #[serde(default)]
    pub root_source: String,
}

#[derive(Debug, Clone, Default, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SliceBudget {
    #[serde(default)]
    pub chars: usize,
    #[serde(default)]
    pub used_chars: usize,
    #[serde(default)]
    pub items_included: usize,
    #[serde(default)]
    pub withheld_by_scope: usize,
}

/// An item in a compiled slice that belongs to a lane this thread is not entitled to read.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ForeignLane {
    pub item_ref: String,
    pub found: String,
    pub expected: Option<String>,
}

impl Slice {
    /// **The cross-entity re-assertion, run on the FINISHED artifact.**
    ///
    /// The same posture loro takes on its own privacy wall — `CONTEXT-CONTRACT.md` §4:
    /// *"compile filters before ranking and re-asserts on the finished slice"* — applied on
    /// this side of the boundary, because a re-prime is the highest-leverage cross-entity
    /// leak in the app (`reprime.rs`: whatever lands there is asserted to a fresh session as
    /// authoritative).
    ///
    /// `expected` is the lane this thread's entity is mapped to, or `None` for a corpus with
    /// no partitions at all. CEO-layer items (`company: null`) are always allowed: ECS
    /// §3.5's default read set is *"the CEO layer plus the active entity"*, and
    /// `loro-structure.md` says the same in loro's own words.
    ///
    /// A violation returns the offending item rather than filtering it. **Filtering would be
    /// worse than useless here**: `items` is only a description of what is in `text`, and
    /// `text` is the string that gets injected — dropping the row would leave the foreign
    /// company's memory in the prompt and remove the only evidence that it was there.
    pub fn foreign_lane(&self, expected: Option<&str>) -> Option<ForeignLane> {
        self.items.iter().find_map(|item| match item.company.as_deref() {
            None => None,
            Some(found) if Some(found) == expected => None,
            Some(found) => Some(ForeignLane {
                item_ref: item.r#ref.clone(),
                found: found.to_string(),
                expected: expected.map(str::to_string),
            }),
        })
    }
}

// ---------------------------------------------------------------------------
// PROVENANCE — which record an assertion came from, retained because nothing else keeps it
// ---------------------------------------------------------------------------

/// One record that was actually PUT IN FRONT OF RICH, kept so a later correction can say
/// which record it is a correction OF.
///
/// # Why this type exists at all
///
/// It closes a gap that was measured rather than assumed. A slice is compiled at re-prime
/// time, `interpret` returns [`LoroTier::Slice`] carrying **only `slice.text`**, and
/// `spine.rs` injects that string and drops it: the ledger records the priming turn as the
/// literal placeholder `"[re-prime]"` (`Spine::prime_lease_if_needed`) precisely so a
/// rotation stays invisible, so the slice survives nowhere. Meanwhile `items[]` — the ref,
/// the kind, the scope of everything in that text — was parsed, used once for the lane
/// re-assertion, and thrown away.
///
/// That is why `correction.rs`'s desk had no proposer. `CorrectionDesk::propose` takes a
/// record reference, and **a proposal against the wrong record is a corruption the CEO
/// would have to catch by reading `--dry-run` bytes.** Nothing in the app could supply that
/// reference honestly, so nothing proposed. This is the minimum provenance the resolution
/// needs and deliberately not one field more: no bodies, no corpus content beyond the line
/// that was already going into the prompt, and nothing retained for a slice that was
/// REFUSED — the recording happens after the lane re-assertion, never before it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SliceRecord {
    /// The stable handle — `rec:…`, `mem:…`, `wiki:…`, `entity:…`. This is what a proposal
    /// is filed against, and it is copied, never derived.
    pub record_ref: String,
    pub kind: String,
    pub kind_inferred: bool,
    pub title: String,
    pub scope: String,
    pub company: Option<String>,
    /// The item AS RENDERED into the prompt — `• [kind] Title — body… (ref: id)`.
    ///
    /// `None` when the ref could not be found in `text`, which is a real state rather than
    /// a defect: `slice.text` is truncated to the budget AS A WHOLE
    /// (`loro/lib/compile.js` truncates the joined heading + lines), so the LAST line can
    /// lose its own `(ref: …)` suffix. `items[]` is authoritative about what is in the
    /// slice; the text is authoritative about what Rich actually read. When they disagree
    /// the honest answer is that this record has no quotable line, and a resolver falls
    /// back to the title rather than inventing one.
    pub line: Option<String>,
}

impl SliceRecord {
    /// The text a correction is matched against: the rendered line if there is one, the
    /// title if there is not. Never both concatenated — a match must be attributable.
    ///
    /// **The machine furniture is stripped**, and that is not tidiness. `renderItem` writes
    /// `• [kind] Title — body… (ref: id)`, so leaving it in would put the kind name and
    /// every word of the record's own id into the text a correction resolves against: a
    /// record filed at `rec:ceo/records/ship-date` would answer to the word "date", and
    /// two records could collide on nothing but their storage paths. Rich asserts the
    /// title and the body; he does not assert the ref.
    pub fn matchable(&self) -> &str {
        let Some(line) = self.line.as_deref() else { return &self.title };
        let body = match line.find("] ") {
            Some(i) if line.trim_start().starts_with('•') => &line[i + 2..],
            _ => line,
        };
        match body.rfind(" (ref: ") {
            Some(i) if body.ends_with(')') => body[..i].trim_end(),
            _ => body.trim_end(),
        }
    }

    /// The line AS RICH READ IT, machine furniture and all. This is what a surface quotes
    /// back to the CEO, and it is deliberately not the same string as [`Self::matchable`]:
    /// the ref is exactly what makes the evidence checkable by hand.
    pub fn evidence(&self) -> &str {
        self.line.as_deref().unwrap_or(&self.title)
    }

    /// Can the loro writer supersede this ref at all?
    ///
    /// `wiki:` and `entity:` cannot be written (`loro-writer.md`, "Which refs the writer
    /// can address": a `wiki:` ref exits 5 — *"a machine rewriting the CEO's synthesis is
    /// not a correction, it is a substitution"* — and `entity:` is generated vocabulary,
    /// not a belief). A detector that proposed against one would produce a proposal
    /// guaranteed to be refused at `--dry-run`, which is a false proposal with extra steps.
    pub fn is_supersedable(&self) -> bool {
        self.record_ref.starts_with("rec:") || self.record_ref.starts_with("mem:")
    }
}

impl Slice {
    /// The slice's items paired with the lines they were rendered as.
    ///
    /// The pairing key is the `(ref: …)` suffix `loro/lib/compile.js:renderItem` writes,
    /// and it is exact rather than approximate: that function emits `rec.id`, and
    /// `items[].ref` is the same `rec.id`, so the two agree by construction.
    pub fn records(&self) -> Vec<SliceRecord> {
        let lines: Vec<&str> = self.text.lines().collect();
        self.items
            .iter()
            .map(|item| SliceRecord {
                line: lines
                    .iter()
                    .find(|l| l.trim_end().ends_with(&format!("(ref: {})", item.r#ref)))
                    .map(|l| l.trim().to_string()),
                record_ref: item.r#ref.clone(),
                kind: item.kind.clone(),
                kind_inferred: item.kind_inferred,
                title: item.title.clone(),
                scope: item.scope.clone(),
                company: item.company.clone(),
            })
            .collect()
    }
}

/// The slice that was injected into one thread's session, and what it was compiled from.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct InjectedSlice {
    pub thread_id: String,
    pub entity_id: String,
    /// The topic the slice was compiled for. Kept so a provenance can be recognized as
    /// belonging to a different conversation rather than silently answering about one.
    pub topic: String,
    /// `corpus.fingerprint` and `compiler` — the two things `CONTEXT-CONTRACT.md` §2 says
    /// to cache on, kept for the same reason: together they identify WHICH loro, compiled
    /// by WHICH ranker, this memory came from.
    pub fingerprint: String,
    pub compiler: String,
    pub at: u64,
    pub records: Vec<SliceRecord>,
}

/// What memory Rich was actually given, per thread. One entry per thread, replaced whole on
/// each compile — a slice is a snapshot, and two snapshots are not additive.
#[derive(Debug, Clone, Default)]
pub struct SliceProvenance {
    by_thread: BTreeMap<String, InjectedSlice>,
}

impl SliceProvenance {
    pub fn new() -> Self {
        Self::default()
    }

    /// Record what was injected. **Deliberately in-memory only.** This describes the
    /// CURRENT session's prompt; a resolution made against a slice from a session that no
    /// longer exists would attribute to Rich an assertion he was never given the memory to
    /// make. It dies with the process, exactly like the priming payload it describes.
    pub fn record(&mut self, injected: InjectedSlice) {
        self.by_thread.insert(injected.thread_id.clone(), injected);
    }

    pub fn for_thread(&self, thread_id: &str) -> Option<&InjectedSlice> {
        self.by_thread.get(thread_id)
    }

    /// The records currently resolvable for a thread — empty when nothing has been compiled
    /// for it, which is the ordinary state of an install with no corpus.
    pub fn records_for(&self, thread_id: &str) -> &[SliceRecord] {
        self.by_thread.get(thread_id).map(|s| s.records.as_slice()).unwrap_or(&[])
    }

    pub fn threads(&self) -> usize {
        self.by_thread.len()
    }
}

/// Shared the way `staging::SharedCandidateDesk` is, and for the same reason: the spine
/// writes it during a re-prime and the correction trigger reads it during a turn.
pub type SharedSliceProvenance = Arc<Mutex<SliceProvenance>>;

// ---------------------------------------------------------------------------
// the compiler
// ---------------------------------------------------------------------------

/// The shipped [`LoroContextCompiler`]: invokes `loro-context.mjs compile` and maps its
/// documented exit codes onto the four [`LoroTier`] states.
///
/// The mapping is `CONTEXT-CONTRACT.md` §3's own table, with one addition the contract
/// leaves to the caller:
///
/// | | contract | here |
/// |---|---|---|
/// | exit 0, `!thin` | use the slice | [`LoroTier::Slice`] — after the lane re-assertion |
/// | exit 0, `thin` | no slice | [`LoroTier::NothingRecorded`], carrying loro's OWN honest line |
/// | exit != 0 | no slice, never fail the turn | [`LoroTier::Unavailable`], carrying the code |
///
/// The contract maps a thin slice to "no slice, keep today's pull-loro-live line". That is
/// right about the injectable text and wrong about the honesty: a checked "loro holds
/// nothing on this" and an unconsulted loro are different facts and this build keeps them
/// different (see [`LoroTier`]). Loro already writes the correct sentence for the first case
/// — §5 — so the fix is to inject its sentence rather than to invent one.
pub struct CliContextCompiler {
    tools: LoroTools,
    root: LoroRoot,
    lanes: LaneMap,
    audience: String,
    /// Where the ITEMS of an accepted slice are retained, so a later correction can name
    /// the record it corrects (see [`SliceProvenance`]). Absent by default: a build with no
    /// correction trigger keeps nothing, and the read path is byte-identical either way.
    provenance: Option<SharedSliceProvenance>,
}

impl CliContextCompiler {
    pub fn new(tools: LoroTools, root: LoroRoot, lanes: LaneMap) -> Self {
        CliContextCompiler {
            tools,
            root,
            lanes,
            audience: REPRIME_AUDIENCE.to_string(),
            provenance: None,
        }
    }

    /// Retain the items of every ACCEPTED slice here, keyed by thread.
    ///
    /// Attaching this changes nothing about what is compiled, what is injected or what is
    /// refused — it only stops the answer to *"which record did that come from?"* being
    /// thrown away one line after it was parsed.
    pub fn set_provenance_sink(&mut self, sink: SharedSliceProvenance) {
        self.provenance = Some(sink);
    }

    /// Build from the environment, or explain why not. `Ok(None)` = nothing configured,
    /// which is the ordinary state of an install with no corpus and is not an error.
    ///
    /// The lane map is validated against the registry here — a lane keyed by a typo is a
    /// configuration error worth refusing at boot, not a mapping that silently does
    /// nothing. It is NOT reconciled here: that needs the corpus, which is a child process
    /// away, and the caller decides what to do when the probe itself fails
    /// ([`Self::reconcile_lanes`]).
    pub fn from_env() -> Result<Option<Self>, LoroError> {
        let Some(root) = LoroRoot::from_env() else { return Ok(None) };
        let Some(tools) = LoroTools::from_env() else {
            return Err(LoroError::ToolsNotFound(
                "a corpus root is configured but RICHOS_LORO_DIR is not — richos ships no loro/ \
                 directory, so the tools cannot be inferred from this checkout"
                    .into(),
            ));
        };
        let lanes = LaneMap::from_env()?;
        lanes.validate_against(&crate::entity::EntityRegistry::ceos_companies())?;
        Ok(Some(CliContextCompiler::new(tools?, root, lanes)))
    }

    pub fn root(&self) -> &LoroRoot {
        &self.root
    }

    /// The loro checkout this compiler drives — exposed so a caller can run the same
    /// tools' `corpus` command for [`CorpusLanes::probe`] without configuring them twice
    /// and risking two different answers.
    pub fn tools(&self) -> &LoroTools {
        &self.tools
    }

    pub fn lanes(&self) -> &LaneMap {
        &self.lanes
    }

    /// Drop every mapping whose lane the corpus does not have, and return one sentence per
    /// drop.
    ///
    /// # Why this exists, measured rather than argued
    ///
    /// A `--company` loro cannot satisfy is not degraded, it is refused:
    ///
    /// ```text
    /// exit 2 — loro --company: no such company partition "femcboost" in this corpus.
    /// Known: (none). Refusing to compile an empty lane and call it an answer.
    /// ```
    ///
    /// That is the correct posture on loro's side and it is fatal on this one, because
    /// exit 2 maps to [`LoroTier::Unavailable`] on **every rotation**. The CEO's corpus
    /// today is the repo-layout dogfood corpus — 573 records, zero partitions — so a lane
    /// map that were merely filled in would trade a working 890-char slice for a permanent
    /// "loro could not be consulted". Reconciling makes the map real *and* inert until his
    /// corpus is actually partitioned, at which point the same map narrows with no
    /// configuration change at all.
    ///
    /// # What dropping a lane does NOT do
    ///
    /// It does not widen what may be READ. `--company` is an attention control, not a
    /// privacy control (`loro-structure.md`, "`--company` is NOT a privacy control"); the
    /// wall is [`Slice::foreign_lane`], re-asserted on the finished slice, and with no lane
    /// it allows the CEO layer and refuses every company item. A dropped lane compiles
    /// wider and reads no wider.
    pub fn reconcile_lanes(&mut self, corpus: &CorpusLanes) -> Vec<String> {
        let mut dropped = Vec::new();
        let mut kept = BTreeMap::new();
        for (entity, lane) in std::mem::take(&mut self.lanes).0 {
            if corpus.has(&lane) {
                kept.insert(entity, lane);
            } else {
                let why = if corpus.is_retired(&lane) {
                    format!("lane {lane:?} is retired in this corpus")
                } else if corpus.is_unpartitioned() {
                    "this corpus has no company partitions at all".to_string()
                } else {
                    format!("this corpus has no lane {lane:?} (it has: {})", corpus.companies().join(", "))
                };
                dropped.push(format!(
                    "entity {entity:?} -> lane {lane:?} dropped: {why}; {entity:?} reads the CEO layer"
                ));
            }
        }
        self.lanes = LaneMap(kept);
        dropped
    }

    /// Registered entities that will compile with NO lane against a corpus that HAS lanes.
    ///
    /// This is the one genuinely ambiguous state and it must not be silent. The compile
    /// widens (no `--company`), loro returns items from every partition, and the lane
    /// re-assertion refuses the slice whole — fail-closed and correct, but it reaches the
    /// CEO as "loro could not be consulted" every single turn. An operator needs to see it
    /// at boot, before he does.
    ///
    /// Empty when the corpus is unpartitioned: there, no lane IS the CEO layer, and
    /// reporting it would be noise on the only configuration that exists today.
    pub fn entities_with_no_lane(
        &self,
        registry: &crate::entity::EntityRegistry,
        corpus: &CorpusLanes,
    ) -> Vec<String> {
        if corpus.is_unpartitioned() {
            return Vec::new();
        }
        registry
            .entities()
            .iter()
            .filter(|e| self.lanes.lane_for(e.id.as_str()).is_none())
            .map(|e| e.id.to_string())
            .collect()
    }

    /// The argv for one compile, exposed so a test can assert what this type is capable of
    /// asking for — in particular that it names the READ entry point and carries no write
    /// verb (see the module doc).
    pub fn argv(&self, req: &SliceRequest<'_>) -> Vec<String> {
        let (root_flag, root_path) = self.root.args();
        let mut argv = vec![
            self.tools.context_bin().display().to_string(),
            "compile".into(),
            root_flag.into(),
            root_path.display().to_string(),
            // §1: the topic is multi-line natural language and "must not go through shell
            // quoting" — stdin, not a flag. Command does not use a shell, but the contract's
            // own instruction for Rust callers is --topic-stdin and it costs nothing to obey.
            "--topic-stdin".into(),
            "--budget-chars".into(),
            req.budget_chars.to_string(),
            "--audience".into(),
            self.audience.clone(),
            "--format".into(),
            "json".into(),
        ];
        if let Some(lane) = self.lanes.lane_for(req.entity_id) {
            argv.push("--company".into());
            argv.push(lane.to_string());
        }
        argv
    }

    fn run(&self, req: &SliceRequest<'_>) -> LoroTier {
        use std::io::Write;
        use std::process::Stdio;

        let argv = self.argv(req);
        let mut child = match Command::new(self.tools.node())
            .args(&argv)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
        {
            Ok(c) => c,
            Err(e) => return LoroTier::Unavailable(format!("could not start the loro compiler: {e}")),
        };
        if let Some(mut stdin) = child.stdin.take() {
            // A broken pipe here is not fatal on its own — the exit code below decides.
            let _ = stdin.write_all(req.topic.as_bytes());
        }
        let out = match child.wait_with_output() {
            Ok(o) => o,
            Err(e) => return LoroTier::Unavailable(format!("the loro compiler did not complete: {e}")),
        };
        if !out.status.success() {
            let code = out.status.code().map(|c| c.to_string()).unwrap_or_else(|| "signal".into());
            let why = String::from_utf8_lossy(&out.stderr);
            let why = why.lines().next().unwrap_or("").trim();
            return LoroTier::Unavailable(format!("the loro compiler exited {code}: {why}"));
        }
        self.interpret(&String::from_utf8_lossy(&out.stdout), req)
    }

    /// Parse + judge one compiler stdout. Split out from [`Self::run`] so every branch is
    /// testable without a corpus, a child process or a byte of the CEO's memory.
    pub fn interpret(&self, stdout: &str, req: &SliceRequest<'_>) -> LoroTier {
        let slice: Slice = match serde_json::from_str(stdout) {
            Ok(s) => s,
            Err(e) => return LoroTier::Unavailable(format!("the loro slice did not parse: {e}")),
        };
        if slice.schema_version != SUPPORTED_SLICE_SCHEMA {
            // §2: assert the version and treat anything else as unsupported rather than
            // mis-parsing it. Mis-parsing a memory slice does not fail loudly — it injects
            // subtly wrong company memory under a header calling it authoritative.
            return LoroTier::Unavailable(format!(
                "slice schemaVersion {} is not supported (this build reads {SUPPORTED_SLICE_SCHEMA})",
                slice.schema_version
            ));
        }
        // THE LANE RE-ASSERTION. Before anything is injected, and before `thin` is even
        // consulted — a thin slice cannot carry a foreign item, but the guard must not
        // depend on that being true tomorrow.
        let expected = self.lanes.lane_for(req.entity_id);
        if let Some(bad) = slice.foreign_lane(expected) {
            return LoroTier::Unavailable(format!(
                "the compiled slice carried company {:?} memory ({}) into entity {:?}{} — refused \
                 whole rather than filtered, because `items` only describes what is already in \
                 `text`",
                bad.found,
                bad.item_ref,
                req.entity_id,
                match &bad.expected {
                    Some(lane) => format!(", whose lane is {lane:?}"),
                    None => ", which is mapped to no lane".into(),
                }
            ));
        }
        // §7 guarantee 1 — `text.length <= budgetChars`, at every budget. Verified rather
        // than trusted: this string goes into a prompt the CEO is billed for on every
        // rotation, and the guarantee is cheap to check and expensive to assume.
        if slice.text.chars().count() > req.budget_chars {
            return LoroTier::Unavailable(format!(
                "the slice broke its own budget guarantee: {} chars against a {}-char cap",
                slice.text.chars().count(),
                req.budget_chars
            ));
        }
        if slice.thin || slice.text.trim().is_empty() {
            // §5: loro's own thin line already says the honest thing, ending "Do not assume
            // company facts — ask the CEO or check a live system." Injecting that sentence
            // IS the empty-corpus answer. A blank text with thin unset would be a compiler
            // defect, so it degrades to the same honest state rather than to silence.
            let text = if slice.text.trim().is_empty() {
                format!(
                    "COMPANY MEMORY (loro): nothing recorded bears on \"{}\". Do not assume company \
                     facts — ask the CEO or check a live system.",
                    req.topic
                )
            } else {
                slice.text.clone()
            };
            return LoroTier::NothingRecorded(text);
        }
        // PROVENANCE, recorded LAST — after the schema check, after the lane re-assertion,
        // after the budget check. Everything above this line is a reason a slice must not be
        // trusted, and a record retained from a slice that was refused could be resolved
        // against later, which would file a proposal citing memory the CEO was never shown.
        if let Some(sink) = self.provenance.as_ref() {
            if let Ok(mut p) = sink.lock() {
                p.record(InjectedSlice {
                    thread_id: req.thread_id.to_string(),
                    entity_id: req.entity_id.to_string(),
                    topic: req.topic.to_string(),
                    fingerprint: slice.corpus.fingerprint.clone(),
                    compiler: slice.compiler.clone(),
                    at: crate::util::now_millis(),
                    records: slice.records(),
                });
            }
        }
        LoroTier::Slice(slice.text)
    }
}

impl LoroContextCompiler for CliContextCompiler {
    fn compile_slice(&self, req: &SliceRequest<'_>) -> LoroTier {
        if req.topic.trim().is_empty() {
            // §1: "A slice is always TOPICAL — there is no compile all of loro." An empty
            // topic is a caller bug, and asking anyway would exit 2 on every rotation.
            return LoroTier::Unavailable("no topic — the thread has nothing the CEO has said yet".into());
        }
        self.run(req)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn req<'a>(entity: &'a str, topic: &'a str) -> SliceRequest<'a> {
        SliceRequest { thread_id: "t1", entity_id: entity, topic, budget_chars: 1200 }
    }

    fn compiler(lanes: &str) -> CliContextCompiler {
        CliContextCompiler::new(
            LoroTools { dir: PathBuf::from("/nowhere/loro"), node: "node".into() },
            LoroRoot::Corpus(PathBuf::from("/nowhere/corpus")),
            LaneMap::parse(lanes).unwrap(),
        )
    }

    fn slice_json(items: &str, thin: bool, text: &str) -> String {
        format!(
            r#"{{"schemaVersion":1,"compiler":"loro-context-compiler/1.2.0","thin":{thin},
                "coverage":"direct","text":{text:?},"items":[{items}],
                "corpus":{{"recordCount":3,"fingerprint":"sha256:abc","layout":"corpus","rootSource":"--corpus"}},
                "budget":{{"chars":1200,"usedChars":10,"itemsIncluded":1,"withheldByScope":0}},
                "notes":[]}}"#
        )
    }

    #[test]
    fn a_lane_map_is_explicit_and_a_typo_is_refused_rather_than_dropped() {
        let m = LaneMap::parse("femcboost=fb, richos=richos").unwrap();
        assert_eq!(m.lane_for("femcboost"), Some("fb"));
        assert_eq!(m.lane_for("richos"), Some("richos"));
        // Name equality is NOT a mapping. "deeply" is unmapped even though a `deeply`
        // partition might well exist — inferring it is the thing this type refuses to do.
        assert_eq!(m.lane_for("deeply"), None);
        assert!(LaneMap::parse("femcboost").is_err());
        assert!(LaneMap::parse("femcboost=").is_err());
        assert!(LaneMap::parse("=fb").is_err());
        assert!(LaneMap::parse("a=1,a=2").is_err(), "a doubly-mapped entity is ambiguous, not last-wins");
        assert!(LaneMap::parse("").unwrap().is_empty());
    }

    #[test]
    fn the_compilers_argv_names_the_read_entry_point_and_carries_no_write_verb() {
        // The module's structural claim, asserted rather than promised: this type cannot
        // reach the writer, so wiring the read seam creates no write path through it.
        let c = compiler("femcboost=fb");
        let argv = c.argv(&req("femcboost", "how does pricing work"));
        assert!(argv[0].ends_with("bin/loro-context.mjs"), "{argv:?}");
        assert!(!argv.iter().any(|a| a.contains("loro-write")), "{argv:?}");
        for verb in ["append", "supersede", "correct", "create-company"] {
            assert!(!argv.iter().any(|a| a == verb), "argv must carry no write verb, found {verb}: {argv:?}");
        }
        assert!(argv.contains(&"--topic-stdin".to_string()), "the topic never goes through shell quoting");
        assert_eq!(argv.iter().filter(|a| *a == "--audience").count(), 1);
        assert!(argv.contains(&"rich".to_string()));
        // The mapped entity narrows to its lane...
        assert_eq!(argv.iter().position(|a| a == "--company").map(|i| argv[i + 1].clone()), Some("fb".into()));
        // ...and an UNMAPPED one never widens to "every company" by omission-plus-default.
        // It sends no --company at all, and the lane re-assertion below is what catches
        // anything the corpus then hands back.
        let wide = c.argv(&req("prospects", "how does pricing work"));
        assert!(!wide.contains(&"--company".to_string()), "{wide:?}");
    }

    /// A slice with two items, one of them the LAST line — the one the budget can truncate.
    fn two_item_slice(last_line_intact: bool) -> String {
        let items = concat!(
            r#"{"ref":"rec:ceo/records/ship-date","kind":"decision","kindInferred":false,"#,
            r#""title":"Ship date","scope":"org-shared","company":"fb"},"#,
            r#"{"ref":"mem:company:renewal","kind":"commitment","kindInferred":true,"#,
            r#""title":"Halstead renewal","scope":"ceo-private","company":"fb"}"#
        );
        let tail = if last_line_intact {
            "• [commitment?] Halstead renewal — renews in February. (ref: mem:company:renewal)"
        } else {
            "• [commitment?] Halstead renewal — renews in Feb"
        };
        slice_json(
            items,
            false,
            &format!(
                "COMPANY MEMORY (loro) — bearing on: \"the quarter\"\n\
                 • [decision] Ship date — We ship on Thursday. (ref: rec:ceo/records/ship-date)\n{tail}"
            ),
        )
    }

    /// INVARIANT: the provenance sink retains the ITEMS of an accepted slice, paired with
    /// the lines they were rendered as. This is the whole of what makes a proposal able to
    /// name a record, and every field it keeps is one `CorrectionDesk::propose` or the §7
    /// gate actually needs.
    #[test]
    fn an_accepted_slice_leaves_provenance_a_correction_can_resolve_against() {
        let mut c = compiler("femcboost=fb");
        let sink: SharedSliceProvenance = Arc::new(Mutex::new(SliceProvenance::new()));
        c.set_provenance_sink(Arc::clone(&sink));
        assert!(matches!(
            c.interpret(&two_item_slice(true), &req("femcboost", "the quarter")),
            LoroTier::Slice(_)
        ));

        let held = sink.lock().unwrap();
        let recs = held.records_for("t1");
        assert_eq!(recs.len(), 2, "{recs:?}");
        assert_eq!(recs[0].record_ref, "rec:ceo/records/ship-date");
        assert_eq!(recs[0].scope, "org-shared", "the scope a correction must carry through");
        assert!(!recs[0].kind_inferred);
        assert_eq!(
            recs[0].matchable(),
            "Ship date — We ship on Thursday.",
            "the kind label and the ref must not be matchable text"
        );
        assert!(recs[0].evidence().contains("(ref: rec:ceo/records/ship-date)"), "{:?}", recs[0].line);
        // A GUESSED kind is carried as a guess, never flattened into a declaration.
        assert!(recs[1].kind_inferred, "kindInferred was dropped");
        assert!(recs[1].is_supersedable(), "a mem: ref is supersedable");
        let injected = held.for_thread("t1").expect("recorded");
        assert_eq!(injected.topic, "the quarter");
        assert_eq!(injected.fingerprint, "sha256:abc");
    }

    /// INVARIANT: a slice REFUSED for any reason leaves NO provenance. A record retained
    /// from a refused slice could be resolved against later, filing a proposal that cites
    /// memory the CEO was never shown — which is the corruption this whole seam exists to
    /// avoid. Checked on the lane refusal, because that is the one a foreign company's
    /// memory arrives through.
    #[test]
    fn a_refused_slice_leaves_no_provenance_at_all() {
        let mut c = compiler("femcboost=fb");
        let sink: SharedSliceProvenance = Arc::new(Mutex::new(SliceProvenance::new()));
        c.set_provenance_sink(Arc::clone(&sink));
        let foreign = slice_json(
            r#"{"ref":"rec:y","kind":"decision","title":"t","scope":"org-shared","company":"northwind"}"#,
            false,
            "COMPANY MEMORY (loro) — bearing on: \"x\"\n• [decision] t (ref: rec:y)",
        );
        assert!(matches!(c.interpret(&foreign, &req("femcboost", "x")), LoroTier::Unavailable(_)));
        assert_eq!(sink.lock().unwrap().threads(), 0, "a refused slice was retained");

        // ...and so does an unsupported schema, which never reaches the lane guard at all.
        let future = two_item_slice(true).replace("\"schemaVersion\":1", "\"schemaVersion\":2");
        assert!(matches!(c.interpret(&future, &req("femcboost", "x")), LoroTier::Unavailable(_)));
        assert_eq!(sink.lock().unwrap().threads(), 0);
    }

    /// INVARIANT: an item whose rendered line lost its `(ref: …)` suffix to the budget cut
    /// keeps NO line rather than borrowing a neighbor's. `items[]` says what is in the
    /// slice; the text says what Rich read; when they disagree the resolver falls back to
    /// the title, which is a weaker match and not a wrong one.
    #[test]
    fn a_truncated_last_line_loses_its_line_and_never_borrows_another() {
        let mut c = compiler("femcboost=fb");
        let sink: SharedSliceProvenance = Arc::new(Mutex::new(SliceProvenance::new()));
        c.set_provenance_sink(Arc::clone(&sink));
        assert!(matches!(
            c.interpret(&two_item_slice(false), &req("femcboost", "the quarter")),
            LoroTier::Slice(_)
        ));
        let held = sink.lock().unwrap();
        let recs = held.records_for("t1");
        assert_eq!(recs[1].line, None, "a truncated line must not resolve to one");
        assert_eq!(recs[1].matchable(), "Halstead renewal", "and falls back to the title");
        assert!(recs[0].line.is_some(), "the intact line is unaffected");
    }

    /// INVARIANT: the writer cannot address `wiki:` or `entity:` refs, so neither may ever
    /// be proposed against. Asserted on the type rather than at the call site, because the
    /// call site is where it would be forgotten.
    #[test]
    fn only_the_refs_the_writer_can_address_are_supersedable() {
        let r = |rf: &str| SliceRecord {
            record_ref: rf.into(),
            kind: "decision".into(),
            kind_inferred: false,
            title: "t".into(),
            scope: "ceo-private".into(),
            company: None,
            line: None,
        };
        assert!(r("rec:ceo/records/x").is_supersedable());
        assert!(r("mem:company:x").is_supersedable());
        assert!(!r("wiki:loro-structure.md#the-human-surface").is_supersedable());
        assert!(!r("entity:halstead-group").is_supersedable());
    }

    #[test]
    fn a_slice_with_content_is_injected_verbatim() {
        let c = compiler("femcboost=fb");
        let json = slice_json(r#"{"ref":"rec:x","kind":"decision","title":"t","scope":"org-shared","company":"fb"}"#, false, "COMPANY MEMORY (loro) — bearing on: \"pricing\"\n• [decision] per seat");
        match c.interpret(&json, &req("femcboost", "pricing")) {
            LoroTier::Slice(t) => {
                assert!(t.starts_with("COMPANY MEMORY (loro)"), "{t}");
                assert!(!t.contains("RELEVANT COMPANY MEMORY"), "the heading must not be doubled");
            }
            other => panic!("expected a slice, got {other:?}"),
        }
    }

    #[test]
    fn the_ceo_layer_is_always_readable_because_ecs_says_it_is_in_the_default_read_set() {
        let c = compiler("femcboost=fb");
        let json = slice_json(r#"{"ref":"rec:p","kind":"principle","title":"t","scope":"ceo-private","company":null}"#, false, "COMPANY MEMORY (loro) — bearing on: \"x\"\n• [principle] p");
        assert!(c.interpret(&json, &req("femcboost", "x")).is_slice());
        // ...and it is readable from an entity that is mapped to no lane at all, which is
        // what makes an unratified decision 1.6 survivable rather than blocking.
        assert!(c.interpret(&json, &req("prospects", "x")).is_slice());
    }

    // ---- THE CROSS-ENTITY NEGATIVE CONTROL -------------------------------
    //
    // Remove the `foreign_lane` check in `interpret` and this test fails: the slice is
    // well-formed, exit 0, non-thin, inside budget, and carries another company's memory.

    #[test]
    fn a_slice_carrying_another_companys_memory_is_refused_whole() {
        let c = compiler("femcboost=fb,richos=rx");
        let json = slice_json(
            r#"{"ref":"rec:companies/rx/records/margin","kind":"decision","title":"margins","scope":"org-shared","company":"rx"}"#,
            false,
            "COMPANY MEMORY (loro) — bearing on: \"pricing\"\n• [decision] rx margins are 40%",
        );
        match c.interpret(&json, &req("femcboost", "pricing")) {
            LoroTier::Unavailable(why) => {
                assert!(why.contains("\"rx\""), "{why}");
                assert!(why.contains("rec:companies/rx/records/margin"), "{why}");
                assert!(why.contains("femcboost"), "{why}");
            }
            other => panic!("a cross-entity slice must be REFUSED, got {other:?}"),
        }
    }

    #[test]
    fn an_unmapped_entity_refuses_every_company_item_rather_than_accepting_all_of_them() {
        // The failure mode this guards: "no lane configured" must not read as "no
        // restriction". An unmapped entity may read the CEO layer and nothing else.
        let c = compiler("");
        let json = slice_json(
            r#"{"ref":"rec:companies/anything/records/x","kind":"fact","title":"t","scope":"org-shared","company":"anything"}"#,
            false,
            "COMPANY MEMORY (loro) — bearing on: \"x\"\n• [fact] t",
        );
        match c.interpret(&json, &req("femcboost", "x")) {
            LoroTier::Unavailable(why) => assert!(why.contains("mapped to no lane"), "{why}"),
            other => panic!("expected a refusal, got {other:?}"),
        }
    }

    #[test]
    fn an_empty_corpus_yields_loros_own_honest_line_and_never_a_fabricated_slice() {
        let c = compiler("femcboost=fb");
        let thin = "COMPANY MEMORY (loro): nothing recorded bears on \"pricing\". Do not assume company facts — ask the CEO or check a live system.";
        let json = slice_json("", true, thin);
        match c.interpret(&json, &req("femcboost", "pricing")) {
            LoroTier::NothingRecorded(t) => {
                assert_eq!(t, thin);
                assert!(t.contains("Do not assume company facts"));
            }
            other => panic!("expected NothingRecorded, got {other:?}"),
        }
    }

    #[test]
    fn a_thin_slice_with_no_text_still_says_something_honest_rather_than_falling_silent() {
        let c = compiler("femcboost=fb");
        match c.interpret(&slice_json("", true, ""), &req("femcboost", "pricing")) {
            LoroTier::NothingRecorded(t) => assert!(t.contains("nothing recorded bears on \"pricing\"")),
            other => panic!("expected NothingRecorded, got {other:?}"),
        }
    }

    #[test]
    fn an_unsupported_schema_version_degrades_rather_than_mis_parsing() {
        let c = compiler("femcboost=fb");
        let json = slice_json("", false, "text").replace("\"schemaVersion\":1", "\"schemaVersion\":2");
        match c.interpret(&json, &req("femcboost", "x")) {
            LoroTier::Unavailable(why) => assert!(why.contains("schemaVersion 2"), "{why}"),
            other => panic!("expected Unavailable, got {other:?}"),
        }
    }

    #[test]
    fn a_slice_over_its_own_budget_is_refused_because_the_ceo_pays_for_this_string() {
        let c = compiler("femcboost=fb");
        let long = "x".repeat(1201);
        let json = slice_json(r#"{"ref":"r","kind":"fact","title":"t","scope":"org-shared","company":null}"#, false, &long);
        match c.interpret(&json, &req("femcboost", "x")) {
            LoroTier::Unavailable(why) => assert!(why.contains("1201 chars against a 1200-char cap"), "{why}"),
            other => panic!("expected Unavailable, got {other:?}"),
        }
    }

    #[test]
    fn unknown_fields_are_ignored_so_a_ranking_change_does_not_break_this_consumer() {
        // §2's forward-compatibility rule, exercised: 1.2.0 ADDED five fields inside
        // schemaVersion 1, and the next ranker may add more.
        let c = compiler("femcboost=fb");
        let json = slice_json(r#"{"ref":"r","kind":"fact","title":"t","scope":"org-shared","company":null,"somethingNew":42}"#, false, "COMPANY MEMORY (loro) — bearing on: \"x\"\n• [fact] t")
            .replace("\"notes\":[]", "\"notes\":[],\"laneDiagnostics\":{\"whatever\":true}");
        assert!(c.interpret(&json, &req("femcboost", "x")).is_slice());
    }

    #[test]
    fn unparseable_stdout_never_fails_the_turn() {
        let c = compiler("femcboost=fb");
        assert!(matches!(c.interpret("not json at all", &req("femcboost", "x")), LoroTier::Unavailable(_)));
    }

    #[test]
    fn an_empty_topic_is_refused_before_a_process_is_ever_started() {
        // Not a corpus question — a caller bug. Asking anyway exits 2 on every rotation.
        let c = compiler("femcboost=fb");
        match c.compile_slice(&req("femcboost", "   ")) {
            LoroTier::Unavailable(why) => assert!(why.contains("no topic"), "{why}"),
            other => panic!("expected Unavailable, got {other:?}"),
        }
    }

    #[test]
    fn tools_must_hold_both_entry_points_or_they_are_not_a_loro_checkout() {
        let dir = std::env::temp_dir().join(format!("loro-tools-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(dir.join("bin")).unwrap();
        assert!(LoroTools::locate(&dir).is_err(), "an empty bin/ is not a loro checkout");
        std::fs::write(dir.join("bin").join("loro-context.mjs"), "//").unwrap();
        assert!(LoroTools::locate(&dir).is_err(), "the read half alone is not enough to be sure");
        std::fs::write(dir.join("bin").join("loro-write.mjs"), "//").unwrap();
        assert!(LoroTools::locate(&dir).is_ok());
        let _ = std::fs::remove_dir_all(&dir);
    }
}
