//! THE EVIDENCE LOOKUP, WIRED — the CEO's own files reaching a turn, labeled as files.
//!
//! `loro.rs` is the read seam for what the COMPANY BELIEVES. This is the read seam for what
//! the CEO's DOCUMENTS SAY, and the distance between those two sentences is the entire
//! product of the 2026-09-17 evidence-retrieval ruling
//! (`richos-hq/docs/plans/loro-evidence-retrieval-ruling-2026-09-17.md`, §1 and §4):
//!
//! > `COMPANY MEMORY (loro)` means *the company holds this belief, with provenance and
//! > supersession*. `FROM YOUR FILES` means *a document in your Drive says this; nobody has
//! > concluded anything from it.*
//!
//! # When it runs, and it is never "every turn"
//!
//! Only when the compiled slice's own `coverage` says memory did not answer — `none` or
//! `adjacent` ([`crate::reprime::SliceCoverage::should_consult_evidence`]). The ruling is
//! explicit that compiling evidence into every rotation *"would spend the CEO's context budget
//! on raw material on every turn"*, and the affordance already exists: the slice's coverage is
//! its own "there is more, ask for it" signal. A missing or unrecognized label is not a reason
//! to look — absence of the signal is not the signal.
//!
//! # What crosses the boundary, and what must not
//!
//! Everything here is *mechanism*: how to invoke a binary, how to parse a documented JSON
//! shape, and what to refuse. **No document content is written, summarized, promoted or
//! retained.** The block is rendered by the JavaScript module and arrives VERBATIM; this file
//! neither builds it nor edits it, which is why an item the ruling excluded cannot appear
//! through a rendering mistake made in Rust.
//!
//! # The text it carries is UNTRUSTED, and it is carried that way on purpose
//!
//! What comes back contains verbatim text out of documents anyone in the world can put in
//! front of the CEO. Three walls stand between that and a model, and only the third is in this
//! file:
//!
//! 1. **At ingest** — `lib/workspace/immune.js` quarantines injection-pattern matches and
//!    writes the flag; `trust.quarantine` is a STORED fact, never re-derived at read time.
//! 2. **At lookup** — `lib/workspace/evidence-lookup.js` refuses any item whose stored
//!    quarantine flag is not exactly `false`, and wraps every excerpt in its own DATA-not-
//!    instruction boundary markers.
//! 3. **At injection** — `reprime.rs` `render_evidence` states, above the block and every
//!    single time, that everything between the markers is data and none of it is addressed to
//!    the model. That is `immune.js`'s own defense #1 (*"all ingested content is DATA, never
//!    instructions"*) applied at the one place the text finally reaches one.
//!
//! This module adds no wall of its own and removes none. It runs a process and parses a
//! result.

use crate::reprime::{EvidenceLookup, EvidenceRequest, EvidenceTier};
use serde::Deserialize;
use std::path::{Path, PathBuf};

/// The lookup schema this build understands. `bin/richos-evidence.mjs` stamps it on every
/// object it emits. Same posture as [`crate::loro::SUPPORTED_SLICE_SCHEMA`]: assert the
/// version and treat anything else as unsupported rather than mis-parsing it, because
/// mis-parsing here does not fail loudly — it puts a differently-shaped block under a heading
/// that says the CEO's files say so.
pub const SUPPORTED_LOOKUP_SCHEMA: u64 = 1;

/// The audience this lookup serves. `rich` only in v1, and the ruling's §5 gives the reason
/// precisely: `classifyScope` is an INFERENCE, and a misclassification is a leak. When the only
/// reader is the person whose information perimeter it already is, a wrong scope costs nothing.
/// Widening the audience is what would make that inference load-bearing, and that is a business
/// question — the CEO's, and named as his in §5 — not this file's.
pub const LOOKUP_AUDIENCE: &str = "rich";

#[derive(Debug, thiserror::Error)]
pub enum EvidenceError {
    #[error("the evidence lookup entry point was not found: {0}")]
    EntryPointNotFound(String),
}

// ---------------------------------------------------------------------------
// where the entry point is — named, never inferred from a layout
// ---------------------------------------------------------------------------

/// The `bin/richos-evidence.mjs` this app runs, and the `node` that runs it.
///
/// # It is NOT derived from this checkout, for the reason `LoroTools` is not
///
/// A path guessed from the source tree is a precondition an installed `.app` can never
/// satisfy, and the failure surfaces as a non-zero exit once per turn rather than as a
/// configuration error at boot. So the file is VERIFIED to exist at construction, and
/// construction is from something somebody stated.
///
/// # Two pointers, and the second is a SIBLING rather than a guess
///
/// `RICHOS_EVIDENCE_BIN` names the file outright. Failing that, `RICHOS_SERVICE_BIN` already
/// names `bin/richos-service.js` — the same `bin/` directory of the same package — and
/// `richos-evidence.mjs` beside it is a fact about that directory's contents, checked with
/// `is_file()`, not an inference about what a name means. If it is not there, this resolves to
/// `None` and the app boots with [`EvidenceTier::NotWired`], which the priming prompt states as
/// a fact about the install rather than as a claim about the CEO's files.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct EvidenceTools {
    bin: PathBuf,
    node: String,
}

impl EvidenceTools {
    /// Verify `bin` really is there. A path that does not resolve is refused now rather than
    /// once per turn forever.
    pub fn locate(bin: impl AsRef<Path>) -> Result<Self, EvidenceError> {
        let bin = bin.as_ref().to_path_buf();
        if !bin.is_file() {
            return Err(EvidenceError::EntryPointNotFound(format!("{} is not a file", bin.display())));
        }
        let node = std::env::var("RICHOS_NODE_BIN")
            .ok()
            .filter(|v| !v.trim().is_empty())
            .unwrap_or_else(|| "node".into());
        Ok(EvidenceTools { bin, node })
    }

    /// Resolve from the environment. `None` is an ordinary install with no Workspace source
    /// and is not an error; `Some(Err(_))` is a pointer that was given and is wrong.
    pub fn from_env() -> Option<Result<Self, EvidenceError>> {
        if let Ok(v) = std::env::var("RICHOS_EVIDENCE_BIN") {
            let v = v.trim().to_string();
            if !v.is_empty() {
                return Some(EvidenceTools::locate(v));
            }
        }
        // The sibling of the service entry point. Checked, not assumed — see the type doc.
        let service = std::env::var("RICHOS_SERVICE_BIN").ok()?;
        let service = service.trim();
        if service.is_empty() {
            return None;
        }
        let sibling = Path::new(service).parent()?.join("richos-evidence.mjs");
        if !sibling.is_file() {
            return None;
        }
        Some(EvidenceTools::locate(sibling))
    }

    pub fn bin(&self) -> &Path {
        &self.bin
    }

    pub fn node(&self) -> &str {
        &self.node
    }

    /// Override which `node` runs the lookup. A GUI launch's `PATH` is
    /// `/usr/bin:/bin:/usr/sbin:/sbin` and a bare name is not found there — the same condition
    /// [`crate::loro::resolve_node_bin`] exists for, and the same answer.
    pub fn set_node(&mut self, node: String) {
        self.node = node;
    }
}

// ---------------------------------------------------------------------------
// where the evidence zone is — required, never defaulted
// ---------------------------------------------------------------------------

/// The corpus whose evidence zone is read. **There is no default and there must not be.**
///
/// `tools/richos-service/lib/config.js` `corpusRoot()` falls back to `~/RichOS/corpus` when
/// `LORO_CORPUS` is unset, so a lookup launched with an empty environment would read whichever
/// corpus happens to sit there and exit 0 either way. That is `CONTEXT-CONTRACT.md` §1's
/// refused default — *"a customer's Rich silently answering out of the VENDOR's company
/// memory"* — one layer down, over the CEO's own documents. The entry point refuses it with
/// exit 2, and this type is the Rust half of the same refusal: a lookup is constructed from an
/// explicit corpus, or it is not constructed.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum EvidenceZone {
    /// The corpus root. The zone is derived from it by `config.js`'s own layout, inside the
    /// entry point, so the two cannot disagree about where evidence lives.
    Corpus(PathBuf),
    /// The zone itself, named outright — what a test gives.
    Zone(PathBuf),
}

impl EvidenceZone {
    /// The CLI flag and path naming this zone.
    pub fn args(&self) -> (&'static str, &Path) {
        match self {
            EvidenceZone::Corpus(p) => ("--corpus", p.as_path()),
            EvidenceZone::Zone(p) => ("--zone", p.as_path()),
        }
    }

    pub fn path(&self) -> &Path {
        match self {
            EvidenceZone::Corpus(p) | EvidenceZone::Zone(p) => p.as_path(),
        }
    }

    /// From the loro root the app already resolved. **Only a provisioned corpus has an
    /// evidence zone**: [`crate::loro::LoroRoot::Root`] is the in-repo dogfood layout
    /// (`wiki/` + `loro/`), which has no `ceo/evidence/` and never will — pointing the lookup
    /// at one would ask it to read the product repository. `None` there, and `None` means the
    /// lookup is simply not wired, which the prompt states honestly.
    pub fn from_loro_root(root: &crate::loro::LoroRoot) -> Option<Self> {
        match root {
            crate::loro::LoroRoot::Corpus(p) => Some(EvidenceZone::Corpus(p.clone())),
            crate::loro::LoroRoot::Root(_) => None,
        }
    }
}

// ---------------------------------------------------------------------------
// the wire shape — the documented shape, and only the documented shape
// ---------------------------------------------------------------------------

/// One lookup result, parsed down to the fields `bin/richos-evidence.mjs` promises.
///
/// Everything is `#[serde(default)]` and unknown keys are ignored, so a field added on the
/// JavaScript side within schema 1 does not break this consumer. A REMOVED or retyped field
/// bumps [`SUPPORTED_LOOKUP_SCHEMA`].
#[derive(Debug, Clone, Default, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct LookupResult {
    #[serde(default)]
    pub schema_version: u64,
    #[serde(default)]
    pub lookup: String,
    #[serde(default)]
    pub consulted: bool,
    #[serde(default)]
    pub available: bool,
    #[serde(default)]
    pub reason: Option<String>,
    #[serde(default)]
    pub detail: Option<String>,
    #[serde(default)]
    pub heading: String,
    /// THE BLOCK. Rendered by the module, injected verbatim, edited by nobody.
    #[serde(default)]
    pub text: String,
    /// The same finding as a sentence that can be said out loud — no link, no excerpt.
    #[serde(default)]
    pub spoken_text: String,
    #[serde(default)]
    pub chars: usize,
    #[serde(default)]
    pub considered: usize,
    #[serde(default)]
    pub items: Vec<LookupItem>,
    #[serde(default)]
    pub budget: LookupBudget,
}

/// One item, as the wire carries it. **No excerpt field, by construction** — the excerpt lives
/// inside [`LookupResult::text`] within its boundary markers and nowhere else, so nothing in
/// the app can render document text outside the boundary that says it is data.
#[derive(Debug, Clone, Default, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct LookupItem {
    #[serde(default)]
    pub title: String,
    #[serde(default)]
    pub source_label: String,
    #[serde(default)]
    pub vendor: Option<String>,
    #[serde(default)]
    pub source: Option<String>,
    #[serde(default)]
    pub when: Option<String>,
    /// The deep link back into the CEO's own cloud. The UI keeps it; the spoken form never
    /// reads it aloud.
    #[serde(default)]
    pub deep_link: Option<String>,
    #[serde(default)]
    pub evidence_path: Option<String>,
    #[serde(default)]
    pub has_excerpt: bool,
}

#[derive(Debug, Clone, Default, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct LookupBudget {
    #[serde(default)]
    pub chars: usize,
    /// `false`, always, and asserted rather than assumed. The memory lanes' budget belongs to
    /// memory (the ruling §1: *"no `budgetChars` participation in the memory lanes"*).
    #[serde(default)]
    pub taken_from_memory_budget: bool,
}

// ---------------------------------------------------------------------------
// the shipped implementation
// ---------------------------------------------------------------------------

/// Runs `node bin/richos-evidence.mjs lookup …` and reads stdout.
///
/// | it sees | it returns |
/// |---|---|
/// | coverage is not a consult signal | [`EvidenceTier::NotConsulted`] — no process is spawned |
/// | exit 0, `available` | [`EvidenceTier::Block`] with the module's text verbatim |
/// | exit 0, `!available` | [`EvidenceTier::NothingFound`] carrying the module's own reason |
/// | exit != 0, unparseable, wrong schema | [`EvidenceTier::Unavailable`] carrying the reason |
///
/// It holds no writer, names none, and a test asserts its argv carries no verb but `lookup`.
pub struct CliEvidenceLookup {
    tools: EvidenceTools,
    zone: EvidenceZone,
    audience: String,
}

impl CliEvidenceLookup {
    pub fn new(tools: EvidenceTools, zone: EvidenceZone) -> Self {
        CliEvidenceLookup { tools, zone, audience: LOOKUP_AUDIENCE.to_string() }
    }

    /// Build from the environment plus the corpus the app already resolved.
    ///
    /// `Ok(None)` = nothing configured, which is the ordinary state of an install with no
    /// Workspace source and is not an error. The corpus is PASSED IN rather than read again
    /// here, for the reason `memory.rs` carries one `LoroInstall` rather than resolving twice:
    /// a second answer to an answered question is how a read path and a write path came to
    /// disagree about where the CEO's memory is.
    pub fn from_env(root: &crate::loro::LoroRoot) -> Result<Option<Self>, EvidenceError> {
        let Some(zone) = EvidenceZone::from_loro_root(root) else { return Ok(None) };
        let Some(tools) = EvidenceTools::from_env() else { return Ok(None) };
        Ok(Some(CliEvidenceLookup::new(tools?, zone)))
    }

    pub fn tools(&self) -> &EvidenceTools {
        &self.tools
    }

    pub fn zone(&self) -> &EvidenceZone {
        &self.zone
    }

    /// The argv for one lookup, exposed so a test can assert what this type is capable of
    /// asking for.
    ///
    /// The topic goes on STDIN for the reason `CONTEXT-CONTRACT.md` §1 gives for the compiler:
    /// it is multi-line natural language and *"must not go through shell quoting"*. `Command`
    /// uses no shell, and obeying anyway costs nothing and survives somebody later adding one.
    pub fn argv(&self, req: &EvidenceRequest<'_>) -> Vec<String> {
        let (zone_flag, zone_path) = self.zone.args();
        let mut argv = vec![
            self.tools.bin.display().to_string(),
            "lookup".into(),
            zone_flag.into(),
            zone_path.display().to_string(),
            "--topic-stdin".into(),
            "--audience".into(),
            self.audience.clone(),
            "--format".into(),
            "json".into(),
        ];
        // The label the compiler emitted, passed through unchanged. `Unknown` has no string
        // and never reaches here — `look_up` refuses before building argv — so there is no
        // case in which this invents a coverage claim the compiler did not make.
        if let Some(label) = req.coverage.as_str() {
            argv.push("--coverage".into());
            argv.push(label.into());
        }
        argv
    }

    fn run(&self, req: &EvidenceRequest<'_>) -> EvidenceTier {
        use std::io::Write;
        use std::process::Stdio;

        let argv = self.argv(req);
        let mut child = match crate::runtime::interpreter_command(self.tools.node())
            .args(&argv)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
        {
            Ok(c) => c,
            Err(e) => return EvidenceTier::Unavailable(format!("could not start the evidence lookup: {e}")),
        };
        if let Some(mut stdin) = child.stdin.take() {
            let _ = stdin.write_all(req.topic.as_bytes());
        }
        let out = match child.wait_with_output() {
            Ok(o) => o,
            Err(e) => return EvidenceTier::Unavailable(format!("the evidence lookup did not complete: {e}")),
        };
        if !out.status.success() {
            let code = out.status.code().map(|c| c.to_string()).unwrap_or_else(|| "signal".into());
            let why = String::from_utf8_lossy(&out.stderr);
            let why = why.lines().next().unwrap_or("").trim();
            // EXIT 3 IS A CRASH, AND A CRASH IS NOT AN ANSWER. Reading "nothing in your files"
            // out of a non-zero exit would have Rich tell the CEO a falsehood on behalf of a
            // bug — the same reason the entry point refuses to emit an empty block on a throw.
            return EvidenceTier::Unavailable(format!("the evidence lookup exited {code}: {why}"));
        }
        self.interpret(&String::from_utf8_lossy(&out.stdout))
    }

    /// Parse + judge one lookup stdout. Split out from [`Self::run`] so every branch is
    /// testable without a corpus, a child process or one of the CEO's documents.
    pub fn interpret(&self, stdout: &str) -> EvidenceTier {
        let res: LookupResult = match serde_json::from_str(stdout) {
            Ok(r) => r,
            Err(e) => return EvidenceTier::Unavailable(format!("the evidence lookup's output did not parse: {e}")),
        };
        if res.schema_version != SUPPORTED_LOOKUP_SCHEMA {
            return EvidenceTier::Unavailable(format!(
                "lookup schemaVersion {} is not supported (this build reads {SUPPORTED_LOOKUP_SCHEMA})",
                res.schema_version
            ));
        }
        // THE BUDGET RE-ASSERTION. The ruling says the block takes nothing from the memory
        // lanes' budget and the module reports `takenFromMemoryBudget: false` *"to be
        // asserted"*. A `true` here would mean the two sides disagree about whose characters
        // these are, and the honest response to that is to inject nothing rather than to pick
        // a side.
        if res.budget.taken_from_memory_budget {
            return EvidenceTier::Unavailable(
                "the lookup reported that its block takes characters from the memory lanes' budget; \
                 it never may, so the block was refused rather than injected"
                    .into(),
            );
        }
        if !res.consulted {
            return EvidenceTier::NotConsulted(
                res.detail.or(res.reason).unwrap_or_else(|| "memory covered this".into()),
            );
        }
        if !res.available || res.text.trim().is_empty() {
            // AN EMPTY BLOCK IS NEVER RENDERED. The module's contract is explicit: an
            // unavailable result renders nothing at all, *"never a heading with an empty body,
            // which reads as 'your files say nothing about this' when the truth is 'I did not
            // look'."* A `text` that is blank while `available` is true would be a module
            // defect, and it degrades to the same honest state rather than to a bare heading.
            let why = res
                .detail
                .or(res.reason)
                .unwrap_or_else(|| "nothing in your files matches".into());
            return EvidenceTier::NothingFound(why);
        }
        // THE BLOCK, VERBATIM. Heading, standing warning, boundary markers, deep links — all
        // of it rendered by `evidence-lookup.js`. Nothing is added, nothing is trimmed, and
        // no item is re-rendered from `res.items`: the reduced item list exists for a UI to
        // put a link beside the answer, never to rebuild the block.
        EvidenceTier::Block { text: res.text, spoken: res.spoken_text }
    }
}

impl EvidenceLookup for CliEvidenceLookup {
    fn look_up(&self, req: &EvidenceRequest<'_>) -> EvidenceTier {
        // THE GATE, BEFORE A PROCESS IS SPENT. The entry point asks the JavaScript module the
        // same question on the other side of the boundary and would refuse too; this is the
        // cheap half. The two ARE checked against each other on all four labels rather than
        // assumed to agree — not here, because a unit test that shelled out to `node` would
        // make this crate's suite need a toolchain it deliberately does not need, but in the
        // end-to-end run recorded under `docs/verification/`, which drives both sides.
        if !req.coverage.should_consult_evidence() {
            return EvidenceTier::NotConsulted(match req.coverage.as_str() {
                Some(label) => format!("the compiled slice reported coverage {label:?}"),
                None => "the compiler did not report a coverage label, and absence of the signal is \
                         not the signal"
                    .into(),
            });
        }
        if req.topic.trim().is_empty() {
            return EvidenceTier::Unavailable(
                "no topic — there is nothing to look up, and looking anyway would return whatever \
                 ranks highest out of nothing"
                    .into(),
            );
        }
        self.run(req)
    }
}
