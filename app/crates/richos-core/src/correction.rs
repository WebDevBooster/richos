//! THE CORRECTION DESK — "read what the system believes and correct it", made reachable.
//!
//! `loro-structure.md` calls this the property that must not be lost:
//!
//! > The wiki's essential property is not its content. It is that **a human can read what
//! > the system believes and correct it when it is wrong.**
//!
//! Loro's writer has been complete and demonstrable since 2026-08-29 and reachable only
//! through a CLI — `loro-writer.md` says so in its own words: *"Rich does not call the
//! writer yet… the writer's reachable surface is the CLI."* A capability the CEO can only
//! reach by opening a terminal is not a property of the product he uses. This module is the
//! loop: **propose → show him exactly what would change → he says yes → write.**
//!
//! # Ask, never infer — enforced by the type, not by a paragraph
//!
//! `ceo-decisions.md` §7 governs the write path absolutely: *"Inference cannot tell 'ship
//! Thursday' → 'ship Friday' (a change of mind) from 'deep gram' → 'Deepgram' (a real
//! correction). Asking removes the class of error entirely… **Nothing is ever learned
//! silently.**"* ECS §5.1 draws the same line: a correction is a human statement, an
//! inference is at most a candidate.
//!
//! So there is no function here that writes loro. There is [`CorrectionDesk::propose`],
//! which runs the writer with `--dry-run` and stores what WOULD be written; and there is
//! [`CorrectionDesk::confirm`], which is the only path to a write and refuses anything that
//! is not a proposal the CEO has in front of him. A caller cannot skip the ask, because
//! there is no argument it could pass to do so.
//!
//! §7's three outcomes are the state machine, verbatim: confirm (written), decline (not
//! written, **and still offered again** — a decline is ambiguous: not a record / not now /
//! misclicked), decline permanently (suppressed, and the suppression is inspectable, or a
//! record silently refuses to be correctable with no way to see why).
//!
//! # Durability
//!
//! Same posture as `steering::IntakeLog`, for the same reason: a proposal the CEO has not
//! answered yet must survive a crash, a rotation and a relaunch, or "he confirms after
//! lunch" silently loses the correction. Append-only JSONL, `sync_all` on every record, a
//! torn last line skipped rather than fatal.
//!
//! # What this deliberately does NOT do
//!
//! - **It never widens a scope.** `loro-writer.md`: widening `ceo-private` →
//!   `org-shared`/`external` is refused without `--widen-scope`, *"because that is the one
//!   edit that turns the CEO's private view into something every worker sees, and it must
//!   be a decision rather than the side effect of fixing a typo."* The flag is not reachable
//!   from this module. Narrowing needs no ceremony and is available.
//! - **It never edits prose.** A `wiki:` ref is refused by the writer itself (exit 5) with
//!   the file path to open, and that refusal is surfaced rather than worked around: *"a
//!   machine rewriting the CEO's synthesis is not a correction, it is a substitution."*
//! - **It does not detect corrections.** Nothing here watches for "that's wrong" and files
//!   a proposal on its own. Something has to propose — Rich, in conversation, or the CEO
//!   directly — and that trigger is named as unbuilt rather than faked.

use crate::loro::{LoroRoot, LoroTools};
use serde::{Deserialize, Serialize};
use std::io::{BufRead, BufReader, Write};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};

#[derive(Debug, thiserror::Error)]
pub enum CorrectionError {
    #[error("correction desk io: {0}")]
    Io(String),
    #[error("no proposal {0}")]
    NoSuchProposal(String),
    #[error("proposal {id} is {state:?}, not awaiting the CEO — it cannot be confirmed twice")]
    NotAwaiting { id: String, state: ProposalState },
    #[error("proposal {id} belongs to entity {owner:?}, not {asked:?}")]
    WrongEntity { id: String, owner: String, asked: String },
    #[error("a correction needs the CEO's own words for what was wrong (--why)")]
    NoReason,
    #[error("{0:?} was permanently declined for correction — clear the suppression to propose again")]
    Suppressed(String),
    #[error("the loro writer refused (exit {code}): {message}")]
    WriterRefused { code: i32, message: String },
    #[error("the loro writer could not be run: {0}")]
    WriterUnavailable(String),
}

impl From<std::io::Error> for CorrectionError {
    fn from(e: std::io::Error) -> Self {
        CorrectionError::Io(e.to_string())
    }
}

// ---------------------------------------------------------------------------
// what can be proposed
// ---------------------------------------------------------------------------

/// The three writer operations the app exposes, and no fourth.
///
/// `append` records a belief, `correct` fixes metadata in place, `supersede` replaces a
/// belief that is wrong. `create-company` is deliberately absent: creating a partition is a
/// structural decision about the corpus layout, which is exactly what CEO decision 1.6
/// ("one loro, two homes") is still open on — see `crate::loro::LaneMap`.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
// `rename_all` names the VARIANTS (the `op` tag); `rename_all_fields` names the fields.
// Both matter because this type crosses the Tauri IPC boundary verbatim — the webview
// sends `{op: "supersede", recordRef: …}` and the rest of that surface is camelCase.
#[serde(tag = "op", rename_all = "kebab-case", rename_all_fields = "camelCase")]
pub enum ProposedWrite {
    /// A new record. `loro-writer.md`: append REFUSES to overwrite — a belief is superseded,
    /// never silently replaced.
    Append {
        id: String,
        kind: String,
        /// Omitted resolves to `ceo-private` on the way IN (`record.js` invariant 1), not
        /// merely filtered as private on the way out. Ambiguity resolves to the more
        /// private reading, always.
        scope: Option<String>,
        title: Option<String>,
        body: String,
        /// `ceo` (default), `unfiled`, or a company id. Filing never blocks a write.
        partition: Option<String>,
    },
    /// Metadata fixed in place. The BODY is never machine-rewritten unless asked.
    Correct {
        record_ref: String,
        title: Option<String>,
        kind: Option<String>,
        confidence: Option<f64>,
        tags: Option<Vec<String>>,
        /// Only ever NARROWING. Widening is unreachable from here on purpose (module doc).
        narrow_scope_to: Option<String>,
        body: Option<String>,
    },
    /// The belief is wrong. The replacement is written, the old record points at it, and
    /// **nothing is deleted** — it stops being current and stays fetchable by ref.
    Supersede { record_ref: String, new_id: String, kind: String, scope: Option<String>, body: String },
}

impl ProposedWrite {
    /// The record this write is ABOUT, when there is one. `None` for an append — there is
    /// no prior belief to suppress or to have declined.
    pub fn target_ref(&self) -> Option<&str> {
        match self {
            ProposedWrite::Append { .. } => None,
            ProposedWrite::Correct { record_ref, .. } | ProposedWrite::Supersede { record_ref, .. } => {
                Some(record_ref)
            }
        }
    }

    pub fn verb(&self) -> &'static str {
        match self {
            ProposedWrite::Append { .. } => "append",
            ProposedWrite::Correct { .. } => "correct",
            ProposedWrite::Supersede { .. } => "supersede",
        }
    }

    /// The argv after the verb, and the body to send on stdin. `--body-stdin` throughout,
    /// for the same reason the compiler takes `--topic-stdin`: a record body is multi-line
    /// prose and must not go through shell quoting.
    fn args(&self) -> (Vec<String>, Option<String>) {
        let mut a: Vec<String> = Vec::new();
        let mut push = |k: &str, v: &str| {
            a.push(k.into());
            a.push(v.into());
        };
        match self {
            ProposedWrite::Append { id, kind, scope, title, body, partition } => {
                push("--id", id);
                push("--kind", kind);
                if let Some(s) = scope {
                    push("--scope", s);
                }
                if let Some(t) = title {
                    push("--title", t);
                }
                if let Some(p) = partition {
                    push("--partition", p);
                }
                a.push("--body-stdin".into());
                (a, Some(body.clone()))
            }
            ProposedWrite::Correct { record_ref, title, kind, confidence, tags, narrow_scope_to, body } => {
                push("--ref", record_ref);
                if let Some(t) = title {
                    push("--title", t);
                }
                if let Some(k) = kind {
                    push("--kind", k);
                }
                if let Some(c) = confidence {
                    push("--confidence", &c.to_string());
                }
                if let Some(t) = tags {
                    push("--tags", &t.join(","));
                }
                if let Some(s) = narrow_scope_to {
                    push("--scope", s);
                }
                match body {
                    Some(b) => {
                        a.push("--body-stdin".into());
                        (a, Some(b.clone()))
                    }
                    None => (a, None),
                }
            }
            ProposedWrite::Supersede { record_ref, new_id, kind, scope, body } => {
                push("--ref", record_ref);
                push("--id", new_id);
                push("--kind", kind);
                if let Some(s) = scope {
                    push("--scope", s);
                }
                a.push("--body-stdin".into());
                (a, Some(body.clone()))
            }
        }
    }
}

/// One `--json` object back from `loro-write`.
#[derive(Debug, Clone, Default, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct WriteOutput {
    #[serde(default)]
    pub op: String,
    #[serde(default)]
    pub dry_run: bool,
    #[serde(default)]
    pub r#ref: String,
    #[serde(default)]
    pub superseded_ref: Option<String>,
    #[serde(default)]
    pub file: String,
    #[serde(default)]
    pub text: String,
    #[serde(default)]
    pub changed: Vec<String>,
}

/// The write side of loro, behind a trait so `cargo test -p richos-core` stays hermetic:
/// richos ships no `loro/` directory and no corpus, so a test that shelled out to the real
/// writer could only run on one machine.
pub trait LoroWriteBackend: Send {
    /// `--dry-run`: return exactly what WOULD be written. Touches nothing.
    fn preview(&self, write: &ProposedWrite, why: &str) -> Result<WriteOutput, CorrectionError>;
    /// The real write. **Only [`CorrectionDesk::confirm`] calls this.**
    fn commit(&self, write: &ProposedWrite, why: &str) -> Result<WriteOutput, CorrectionError>;
    /// The file behind a ref — the answer to "what does loro actually believe?". Read-only.
    fn show(&self, record_ref: &str) -> Result<WriteOutput, CorrectionError>;
}

/// The shipped backend: `node loro/bin/loro-write.mjs … --json`.
pub struct CliLoroWriter {
    tools: LoroTools,
    root: LoroRoot,
}

impl CliLoroWriter {
    pub fn new(tools: LoroTools, root: LoroRoot) -> Self {
        CliLoroWriter { tools, root }
    }

    /// Build from the environment, exactly as the read side does. `Ok(None)` = no corpus
    /// configured, which is an ordinary install, not an error.
    pub fn from_env() -> Result<Option<Self>, crate::loro::LoroError> {
        let Some(root) = LoroRoot::from_env() else { return Ok(None) };
        let Some(tools) = LoroTools::from_env() else {
            return Err(crate::loro::LoroError::ToolsNotFound(
                "a corpus root is configured but RICHOS_LORO_DIR is not".into(),
            ));
        };
        Ok(Some(CliLoroWriter::new(tools?, root)))
    }

    fn run(&self, verb: &str, extra: &[String], body: Option<&str>, dry_run: bool) -> Result<WriteOutput, CorrectionError> {
        use std::process::{Command, Stdio};
        let (root_flag, root_path) = self.root.args();
        let mut argv = vec![
            self.tools.write_bin().display().to_string(),
            verb.to_string(),
            root_flag.to_string(),
            root_path.display().to_string(),
            "--json".to_string(),
        ];
        if dry_run {
            argv.push("--dry-run".into());
        }
        argv.extend(extra.iter().cloned());

        let mut child = Command::new(self.tools.node())
            .args(&argv)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .map_err(|e| CorrectionError::WriterUnavailable(e.to_string()))?;
        if let Some(mut stdin) = child.stdin.take() {
            if let Some(b) = body {
                let _ = stdin.write_all(b.as_bytes());
            }
        }
        let out = child.wait_with_output().map_err(|e| CorrectionError::WriterUnavailable(e.to_string()))?;
        if !out.status.success() {
            // The exit code IS the contract (0/2/3/5/1) and stderr carries the sentence.
            // It is surfaced verbatim rather than reworded: a refusal like "that is a PROSE
            // section, corrected by editing the page" is an instruction to the CEO, and
            // paraphrasing it would lose the path he needs.
            return Err(CorrectionError::WriterRefused {
                code: out.status.code().unwrap_or(-1),
                message: String::from_utf8_lossy(&out.stderr).trim().to_string(),
            });
        }
        serde_json::from_slice(&out.stdout)
            .map_err(|e| CorrectionError::WriterUnavailable(format!("the writer's --json output did not parse: {e}")))
    }
}

impl LoroWriteBackend for CliLoroWriter {
    fn preview(&self, write: &ProposedWrite, why: &str) -> Result<WriteOutput, CorrectionError> {
        let (mut args, body) = write.args();
        if !matches!(write, ProposedWrite::Append { .. }) {
            args.push("--why".into());
            args.push(why.into());
        }
        self.run(write.verb(), &args, body.as_deref(), true)
    }

    fn commit(&self, write: &ProposedWrite, why: &str) -> Result<WriteOutput, CorrectionError> {
        let (mut args, body) = write.args();
        if !matches!(write, ProposedWrite::Append { .. }) {
            args.push("--why".into());
            args.push(why.into());
        }
        self.run(write.verb(), &args, body.as_deref(), false)
    }

    fn show(&self, record_ref: &str) -> Result<WriteOutput, CorrectionError> {
        self.run("show", &["--ref".to_string(), record_ref.to_string()], None, false)
    }
}

// ---------------------------------------------------------------------------
// the desk
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum ProposalState {
    /// Shown to the CEO, nothing written. The ONLY state `confirm` accepts.
    AwaitingCeo,
    /// He said no. Not written — and §7: still offered again if the same correction comes
    /// up, because a decline is ambiguous and a repeat is evidence.
    Declined,
    /// He said yes and the write landed.
    Written,
    /// He said yes and the writer refused. The reason is kept — a failed write that
    /// disappears is indistinguishable from one that never happened.
    Failed,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Proposal {
    pub id: String,
    pub at: u64,
    pub entity_id: String,
    pub thread_id: String,
    pub write: ProposedWrite,
    /// The CEO's own words for what is wrong. The writer requires it (exit 2 without one)
    /// and so does this desk, before a process is ever started.
    pub why: String,
    /// The writer's OWN `--dry-run` output: exactly what would be written, byte for byte.
    /// This is what the CEO is shown. A preview generated by anything other than the writer
    /// would be a description of a write rather than the write.
    pub preview: String,
    pub state: ProposalState,
    /// Set once the answer is in.
    pub outcome: Option<WriteOutput>,
    pub failure: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "rec", rename_all = "kebab-case")]
enum DeskRecord {
    Proposed(Proposal),
    Confirmed { id: String, at: u64 },
    Written { id: String, at: u64, outcome: WriteOutput },
    Failed { id: String, at: u64, reason: String },
    Declined { id: String, at: u64, permanent: bool },
    /// A permanent decline, keyed by REF rather than by proposal, so the suppression
    /// survives the proposal being forgotten. §7: the suppression list must be inspectable,
    /// "or a term silently refuses to learn with no way to see why".
    Suppressed { record_ref: String, at: u64 },
    Unsuppressed { record_ref: String, at: u64 },
}

/// The one place in the app that can change what loro believes — and it cannot do it
/// without the CEO having said yes first.
pub struct CorrectionDesk {
    path: PathBuf,
    writer: Box<dyn LoroWriteBackend>,
    proposals: Vec<Proposal>,
    suppressed: Vec<String>,
    next: u64,
}

impl CorrectionDesk {
    pub fn open(path: impl AsRef<Path>, writer: Box<dyn LoroWriteBackend>) -> Result<Self, CorrectionError> {
        let path = path.as_ref().to_path_buf();
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent)?;
        }
        let mut desk = CorrectionDesk { path, writer, proposals: Vec::new(), suppressed: Vec::new(), next: 1 };
        desk.replay()?;
        Ok(desk)
    }

    fn replay(&mut self) -> Result<(), CorrectionError> {
        if !self.path.exists() {
            return Ok(());
        }
        let file = std::fs::File::open(&self.path)?;
        for line in BufReader::new(file).lines().map_while(Result::ok) {
            let line = line.trim();
            if line.is_empty() {
                continue;
            }
            // A torn last line (killed mid-write) is skipped, exactly as the ledger and the
            // intake log skip one: a half-written proposal was never shown to anybody.
            let Ok(rec) = serde_json::from_str::<DeskRecord>(line) else { continue };
            self.apply(rec);
        }
        self.next = self
            .proposals
            .iter()
            .filter_map(|p| p.id.strip_prefix("prop-").and_then(|n| n.parse::<u64>().ok()))
            .max()
            .unwrap_or(0)
            + 1;
        Ok(())
    }

    fn apply(&mut self, rec: DeskRecord) {
        match rec {
            DeskRecord::Proposed(p) => self.proposals.push(p),
            DeskRecord::Confirmed { .. } => {}
            DeskRecord::Written { id, outcome, .. } => {
                if let Some(p) = self.find_mut(&id) {
                    p.state = ProposalState::Written;
                    p.outcome = Some(outcome);
                }
            }
            DeskRecord::Failed { id, reason, .. } => {
                if let Some(p) = self.find_mut(&id) {
                    p.state = ProposalState::Failed;
                    p.failure = Some(reason);
                }
            }
            DeskRecord::Declined { id, .. } => {
                if let Some(p) = self.find_mut(&id) {
                    p.state = ProposalState::Declined;
                }
            }
            DeskRecord::Suppressed { record_ref, .. } => {
                if !self.suppressed.contains(&record_ref) {
                    self.suppressed.push(record_ref);
                }
            }
            DeskRecord::Unsuppressed { record_ref, .. } => self.suppressed.retain(|r| r != &record_ref),
        }
    }

    fn find_mut(&mut self, id: &str) -> Option<&mut Proposal> {
        self.proposals.iter_mut().find(|p| p.id == id)
    }

    fn write_record(&mut self, rec: &DeskRecord) -> Result<(), CorrectionError> {
        let mut line = serde_json::to_string(rec).map_err(|e| CorrectionError::Io(e.to_string()))?;
        line.push('\n');
        let mut f = std::fs::OpenOptions::new().create(true).append(true).open(&self.path)?;
        f.write_all(line.as_bytes())?;
        // fsync, not flush. A proposal the CEO has not answered must survive the power
        // going out — same reason `steering::IntakeLog` fsyncs, and a page cache is not disk.
        f.sync_all()?;
        Ok(())
    }

    // -- the loop ----------------------------------------------------------

    /// Stage a change and show the CEO exactly what it would do. **Writes nothing.**
    ///
    /// The preview comes from the writer's own `--dry-run`, so what he approves is the
    /// bytes that will land, not a description of them.
    pub fn propose(
        &mut self,
        entity_id: &str,
        thread_id: &str,
        write: ProposedWrite,
        why: &str,
    ) -> Result<Proposal, CorrectionError> {
        let why = why.trim();
        if why.is_empty() {
            // Refused here rather than at exit 2, because a proposal with no stated reason
            // is the shape an INFERRED correction takes. The reason is the human statement.
            return Err(CorrectionError::NoReason);
        }
        if let Some(target) = write.target_ref() {
            if self.suppressed.iter().any(|r| r == target) {
                return Err(CorrectionError::Suppressed(target.to_string()));
            }
        }
        let preview = self.writer.preview(&write, why)?;
        let id = format!("prop-{}", self.next);
        self.next += 1;
        let proposal = Proposal {
            id,
            at: crate::util::now_millis(),
            entity_id: entity_id.to_string(),
            thread_id: thread_id.to_string(),
            write,
            why: why.to_string(),
            preview: preview.text,
            state: ProposalState::AwaitingCeo,
            outcome: None,
            failure: None,
        };
        self.write_record(&DeskRecord::Proposed(proposal.clone()))?;
        self.proposals.push(proposal.clone());
        Ok(proposal)
    }

    /// **The only path to a loro write in this application.**
    ///
    /// `entity_id` is the entity the CEO is looking at when he says yes, and it must match
    /// the proposal's own. A confirmation that crossed entities would let a click in one
    /// company's window change another company's memory — the write-path twin of the
    /// cross-entity leak the read seam re-asserts against.
    pub fn confirm(&mut self, entity_id: &str, id: &str) -> Result<Proposal, CorrectionError> {
        let p = self.proposals.iter().find(|p| p.id == id).ok_or_else(|| CorrectionError::NoSuchProposal(id.into()))?;
        if p.entity_id != entity_id {
            return Err(CorrectionError::WrongEntity {
                id: id.into(),
                owner: p.entity_id.clone(),
                asked: entity_id.into(),
            });
        }
        if p.state != ProposalState::AwaitingCeo {
            return Err(CorrectionError::NotAwaiting { id: id.into(), state: p.state });
        }
        let (write, why) = (p.write.clone(), p.why.clone());
        let at = crate::util::now_millis();
        // The confirmation is durable BEFORE the write, so a crash between the two leaves
        // evidence that the CEO said yes rather than losing his answer.
        self.write_record(&DeskRecord::Confirmed { id: id.into(), at })?;
        match self.writer.commit(&write, &why) {
            Ok(outcome) => {
                self.write_record(&DeskRecord::Written { id: id.into(), at, outcome: outcome.clone() })?;
                self.apply(DeskRecord::Written { id: id.into(), at, outcome });
            }
            Err(e) => {
                let reason = e.to_string();
                self.write_record(&DeskRecord::Failed { id: id.into(), at, reason: reason.clone() })?;
                self.apply(DeskRecord::Failed { id: id.into(), at, reason });
            }
        }
        Ok(self.proposals.iter().find(|p| p.id == id).cloned().expect("just applied"))
    }

    /// He said no. §7: a decline is NOT permanent unless he says so, because it is
    /// ambiguous — not a record / not now / misclicked — while a repeat is evidence.
    pub fn decline(&mut self, id: &str, permanent: bool) -> Result<(), CorrectionError> {
        let p = self.proposals.iter().find(|p| p.id == id).ok_or_else(|| CorrectionError::NoSuchProposal(id.into()))?;
        if p.state != ProposalState::AwaitingCeo {
            return Err(CorrectionError::NotAwaiting { id: id.into(), state: p.state });
        }
        let target = p.write.target_ref().map(str::to_string);
        let at = crate::util::now_millis();
        self.write_record(&DeskRecord::Declined { id: id.into(), at, permanent })?;
        self.apply(DeskRecord::Declined { id: id.into(), at, permanent });
        if permanent {
            if let Some(target) = target {
                self.write_record(&DeskRecord::Suppressed { record_ref: target.clone(), at })?;
                self.apply(DeskRecord::Suppressed { record_ref: target, at });
            }
        }
        Ok(())
    }

    /// Lift a permanent decline. §7 requires the suppression list to be inspectable; a list
    /// you can see and cannot clear is only half of that.
    pub fn unsuppress(&mut self, record_ref: &str) -> Result<(), CorrectionError> {
        let at = crate::util::now_millis();
        self.write_record(&DeskRecord::Unsuppressed { record_ref: record_ref.into(), at })?;
        self.apply(DeskRecord::Unsuppressed { record_ref: record_ref.into(), at });
        Ok(())
    }

    /// What does loro actually believe? The answer is a file. Read-only, no proposal needed.
    pub fn show(&self, record_ref: &str) -> Result<WriteOutput, CorrectionError> {
        self.writer.show(record_ref)
    }

    /// Proposals in front of the CEO for one entity, oldest first.
    pub fn pending_for(&self, entity_id: &str) -> Vec<&Proposal> {
        self.proposals
            .iter()
            .filter(|p| p.state == ProposalState::AwaitingCeo && p.entity_id == entity_id)
            .collect()
    }

    pub fn get(&self, id: &str) -> Option<&Proposal> {
        self.proposals.iter().find(|p| p.id == id)
    }

    pub fn suppressed(&self) -> &[String] {
        &self.suppressed
    }

    pub fn path(&self) -> &Path {
        &self.path
    }

    /// Behind an `Arc<Mutex<_>>`, so the SAME desk is reachable from the turn path (where
    /// `belief.rs`'s trigger files a proposal) and from the answer path (where the CEO
    /// confirms one) without either waiting on the other. The posture
    /// `staging::CandidateDesk::shared` already takes, for the same reason: `send_message`
    /// holds the spine lock for a whole turn, and a correction panel that froze until Rich
    /// finished would not be used.
    pub fn shared(self) -> SharedCorrectionDesk {
        Arc::new(Mutex::new(self))
    }
}

pub type SharedCorrectionDesk = Arc<Mutex<CorrectionDesk>>;

/// The event a filed loro proposal is announced on.
///
/// A separate name from `staging::EVENT_CORRECTION_STAGED` because the two carry different
/// payloads and a surface's subscription list is the proof of what it renders — but the
/// same JOB: the proposal is already durable on the desk's own log before this fires, so a
/// webview that missed it loses a badge update and never a record.
pub const EVENT_LORO_PROPOSED: &str = "rich://loro-proposed";

/// A sink for filed proposals — whatever renders the desk.
pub trait ProposalObserver: Send {
    /// MUST be non-blocking and infallible from the spine's view, for the reason
    /// `staging::CorrectionObserver` must: a UI that is not listening never stalls a turn.
    fn on_correction_proposed(&self, proposal: &Proposal);
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::{Arc, Mutex};

    /// A backend that reports every call and, on a real commit, actually touches a file —
    /// so "propose wrote nothing" is checked against the disk rather than against a flag.
    #[derive(Clone)]
    struct FakeWriter {
        dir: PathBuf,
        calls: Arc<Mutex<Vec<String>>>,
        refuse_commit: Option<(i32, String)>,
    }

    impl FakeWriter {
        fn new(tag: &str) -> Self {
            let dir = std::env::temp_dir().join(format!("richos-desk-{tag}-{}-{}", std::process::id(), crate::util::now_millis()));
            let _ = std::fs::remove_dir_all(&dir);
            std::fs::create_dir_all(&dir).unwrap();
            FakeWriter { dir, calls: Arc::new(Mutex::new(Vec::new())), refuse_commit: None }
        }
        fn corpus_files(&self) -> Vec<String> {
            let mut v: Vec<String> = std::fs::read_dir(&self.dir)
                .unwrap()
                .filter_map(|e| e.ok().map(|e| e.file_name().to_string_lossy().to_string()))
                .collect();
            v.sort();
            v
        }
    }

    impl LoroWriteBackend for FakeWriter {
        fn preview(&self, write: &ProposedWrite, why: &str) -> Result<WriteOutput, CorrectionError> {
            self.calls.lock().unwrap().push(format!("preview:{}:{why}", write.verb()));
            Ok(WriteOutput {
                op: write.verb().into(),
                dry_run: true,
                r#ref: "rec:ceo/records/x".into(),
                file: self.dir.join("x.md").display().to_string(),
                text: "---\nkind: decision\n---\n\nWhat would be written.\n".into(),
                ..Default::default()
            })
        }
        fn commit(&self, write: &ProposedWrite, why: &str) -> Result<WriteOutput, CorrectionError> {
            self.calls.lock().unwrap().push(format!("commit:{}:{why}", write.verb()));
            if let Some((code, message)) = &self.refuse_commit {
                return Err(CorrectionError::WriterRefused { code: *code, message: message.clone() });
            }
            std::fs::write(self.dir.join("x.md"), "written\n").unwrap();
            Ok(WriteOutput {
                op: write.verb().into(),
                dry_run: false,
                r#ref: "rec:ceo/records/x".into(),
                file: self.dir.join("x.md").display().to_string(),
                text: "written\n".into(),
                ..Default::default()
            })
        }
        fn show(&self, record_ref: &str) -> Result<WriteOutput, CorrectionError> {
            self.calls.lock().unwrap().push(format!("show:{record_ref}"));
            Ok(WriteOutput { op: "show".into(), r#ref: record_ref.into(), ..Default::default() })
        }
    }

    fn desk(tag: &str) -> (CorrectionDesk, FakeWriter, PathBuf) {
        let w = FakeWriter::new(tag);
        let log = std::env::temp_dir().join(format!("richos-desk-log-{tag}-{}-{}.jsonl", std::process::id(), crate::util::now_millis()));
        let _ = std::fs::remove_file(&log);
        let d = CorrectionDesk::open(&log, Box::new(w.clone())).unwrap();
        (d, w, log)
    }

    fn a_supersede() -> ProposedWrite {
        ProposedWrite::Supersede {
            record_ref: "rec:ceo/records/old".into(),
            new_id: "new".into(),
            kind: "decision".into(),
            scope: Some("org-shared".into()),
            body: "What is actually true.".into(),
        }
    }

    #[test]
    fn proposing_shows_the_writers_own_dry_run_and_touches_nothing() {
        let (mut d, w, log) = desk("propose");
        let before = w.corpus_files();
        let p = d.propose("femcboost", "thr-1", a_supersede(), "we never decided that").unwrap();
        assert_eq!(p.state, ProposalState::AwaitingCeo);
        assert!(p.preview.contains("What would be written"), "the PREVIEW is the writer's own bytes");
        assert_eq!(w.corpus_files(), before, "propose must not write a single file");
        assert_eq!(*w.calls.lock().unwrap(), vec!["preview:supersede:we never decided that"]);
        let _ = std::fs::remove_file(&log);
    }

    #[test]
    fn nothing_is_written_until_the_ceo_says_yes_and_then_exactly_once() {
        let (mut d, w, log) = desk("confirm");
        let p = d.propose("femcboost", "thr-1", a_supersede(), "wrong").unwrap();
        assert!(w.corpus_files().is_empty());
        let done = d.confirm("femcboost", &p.id).unwrap();
        assert_eq!(done.state, ProposalState::Written);
        assert_eq!(w.corpus_files(), vec!["x.md".to_string()]);
        // A second confirm is refused — a double-click must not write twice.
        assert!(matches!(d.confirm("femcboost", &p.id), Err(CorrectionError::NotAwaiting { .. })));
        assert_eq!(w.calls.lock().unwrap().iter().filter(|c| c.starts_with("commit")).count(), 1);
        let _ = std::fs::remove_file(&log);
    }

    #[test]
    fn a_crash_between_the_ask_and_the_answer_keeps_the_proposal_and_writes_nothing() {
        // The whole reason this log fsyncs. "He confirms after lunch" must survive a
        // rotation, a relaunch and a power cut.
        let (mut d, w, log) = desk("crash");
        let p = d.propose("femcboost", "thr-1", a_supersede(), "wrong").unwrap();
        drop(d);
        let reopened = CorrectionDesk::open(&log, Box::new(w.clone())).unwrap();
        let back = reopened.get(&p.id).expect("the proposal survived");
        assert_eq!(back.state, ProposalState::AwaitingCeo);
        assert_eq!(back.why, "wrong");
        assert!(back.preview.contains("What would be written"));
        assert!(w.corpus_files().is_empty(), "and still nothing was written");
        assert_eq!(reopened.pending_for("femcboost").len(), 1);
        let _ = std::fs::remove_file(&log);
    }

    #[test]
    fn a_decline_writes_nothing_and_is_still_offered_again() {
        // ceo-decisions.md §7: a decline is ambiguous (not a record / not now / misclicked)
        // and a REPEAT is the evidence. So declining must not suppress by itself.
        let (mut d, w, log) = desk("decline");
        let p = d.propose("femcboost", "thr-1", a_supersede(), "wrong").unwrap();
        d.decline(&p.id, false).unwrap();
        assert_eq!(d.get(&p.id).unwrap().state, ProposalState::Declined);
        assert!(w.corpus_files().is_empty());
        assert!(matches!(d.confirm("femcboost", &p.id), Err(CorrectionError::NotAwaiting { .. })));
        // ...and the same correction can be raised again.
        let again = d.propose("femcboost", "thr-1", a_supersede(), "wrong, again").unwrap();
        assert_eq!(again.state, ProposalState::AwaitingCeo);
        let _ = std::fs::remove_file(&log);
    }

    #[test]
    fn a_permanent_decline_suppresses_the_ref_and_the_suppression_is_inspectable_and_liftable() {
        let (mut d, _w, log) = desk("suppress");
        let p = d.propose("femcboost", "thr-1", a_supersede(), "wrong").unwrap();
        d.decline(&p.id, true).unwrap();
        assert_eq!(d.suppressed(), ["rec:ceo/records/old".to_string()]);
        match d.propose("femcboost", "thr-1", a_supersede(), "wrong again") {
            Err(CorrectionError::Suppressed(r)) => assert_eq!(r, "rec:ceo/records/old"),
            other => panic!("expected a suppression refusal, got {other:?}"),
        }
        d.unsuppress("rec:ceo/records/old").unwrap();
        assert!(d.suppressed().is_empty());
        assert!(d.propose("femcboost", "thr-1", a_supersede(), "wrong again").is_ok());
        let _ = std::fs::remove_file(&log);
    }

    #[test]
    fn a_proposal_with_no_stated_reason_is_refused_before_a_process_is_started() {
        // A correction with no reason is the shape an INFERRED one takes. The writer also
        // exits 2 on it; refusing here means nothing is even spawned.
        let (mut d, w, log) = desk("noreason");
        assert!(matches!(d.propose("femcboost", "thr-1", a_supersede(), "   "), Err(CorrectionError::NoReason)));
        assert!(w.calls.lock().unwrap().is_empty(), "not even a dry run was attempted");
        let _ = std::fs::remove_file(&log);
    }

    // ---- THE CROSS-ENTITY NEGATIVE CONTROL, WRITE SIDE -------------------
    #[test]
    fn a_confirmation_from_another_entity_is_refused_and_writes_nothing() {
        let (mut d, w, log) = desk("entity");
        let p = d.propose("femcboost", "thr-1", a_supersede(), "wrong").unwrap();
        match d.confirm("deeply", &p.id) {
            Err(CorrectionError::WrongEntity { owner, asked, .. }) => {
                assert_eq!(owner, "femcboost");
                assert_eq!(asked, "deeply");
            }
            other => panic!("a cross-entity confirmation must be refused, got {other:?}"),
        }
        assert!(w.corpus_files().is_empty(), "and nothing was written");
        assert!(w.calls.lock().unwrap().iter().all(|c| !c.starts_with("commit")));
        // The rightful entity still can.
        assert_eq!(d.confirm("femcboost", &p.id).unwrap().state, ProposalState::Written);
        assert_eq!(d.pending_for("deeply").len(), 0, "and it was never in the other entity's queue");
        let _ = std::fs::remove_file(&log);
    }

    #[test]
    fn a_writer_refusal_is_recorded_rather_than_swallowed() {
        // "would edit prose" (exit 5) is an INSTRUCTION to the CEO — it names the file to
        // open. A failed write that disappears is indistinguishable from one never made.
        let mut w = FakeWriter::new("refuse");
        w.refuse_commit = Some((5, "loro write: \"wiki:x.md#y\" is a PROSE section — edit the page".into()));
        let log = std::env::temp_dir().join(format!("richos-desk-refuse-{}.jsonl", std::process::id()));
        let _ = std::fs::remove_file(&log);
        let mut d = CorrectionDesk::open(&log, Box::new(w.clone())).unwrap();
        let p = d.propose("femcboost", "thr-1", a_supersede(), "wrong").unwrap();
        let after = d.confirm("femcboost", &p.id).unwrap();
        assert_eq!(after.state, ProposalState::Failed);
        assert!(after.failure.as_deref().unwrap().contains("PROSE section"), "{:?}", after.failure);
        assert!(w.corpus_files().is_empty());
        // Reopening keeps the failure — it is not a transient in-memory note.
        let reopened = CorrectionDesk::open(&log, Box::new(w)).unwrap();
        assert_eq!(reopened.get(&p.id).unwrap().state, ProposalState::Failed);
        let _ = std::fs::remove_file(&log);
    }

    #[test]
    fn showing_a_record_needs_no_proposal_because_reading_is_not_correcting() {
        let (d, w, log) = desk("show");
        d.show("rec:ceo/records/old").unwrap();
        assert_eq!(*w.calls.lock().unwrap(), vec!["show:rec:ceo/records/old"]);
        assert!(w.corpus_files().is_empty());
        let _ = std::fs::remove_file(&log);
    }

    #[test]
    fn scope_widening_is_not_reachable_from_this_module() {
        // loro-writer.md: widening ceo-private -> org-shared/external is the one edit that
        // turns the CEO's private view into something every worker sees, and it must be a
        // decision rather than the side effect of fixing a typo. The writer refuses it
        // without --widen-scope; this module never emits that flag, so the app cannot
        // widen at all. Narrowing is available and needs no ceremony.
        let src = include_str!("correction.rs");
        // The SHIPPING half only. The scan must not read its own assertion, which names the
        // flag it is looking for — that is how a self-referential source scan passes or
        // fails for the wrong reason.
        let shipping = &src[..src.find("\n#[cfg(test)]").unwrap_or(src.len())];
        let code: String = shipping.lines().filter(|l| !l.trim_start().starts_with("//")).collect::<Vec<_>>().join("\n");
        assert!(!code.contains("--widen-scope"), "the widening flag must not be reachable from the app");
        // Positive probe: the scan is looking at real argv-building code, not at nothing.
        assert!(code.contains("--body-stdin"), "the scan must be reading the argv builder");
    }

    #[test]
    fn confirm_is_the_only_desk_method_that_reaches_a_write() {
        // The module's central claim, checked structurally rather than promised — the same
        // posture loro takes with `assertNoSideEffects` over its own compiler modules.
        let src = include_str!("correction.rs");
        let impl_start = src.find("impl CorrectionDesk {").expect("the desk impl");
        let impl_src = &src[impl_start..src.find("\n#[cfg(test)]").unwrap_or(src.len())];
        let mut current = String::new();
        let mut offenders: Vec<String> = Vec::new();
        let mut commit_sites = 0usize;
        for line in impl_src.lines() {
            let t = line.trim_start();
            if t.starts_with("pub fn ") || t.starts_with("fn ") {
                current = t.trim_start_matches("pub ").trim_start_matches("fn ").split('(').next().unwrap_or("").to_string();
            }
            if t.contains("self.writer.commit(") {
                commit_sites += 1;
                if current != "confirm" {
                    offenders.push(current.clone());
                }
            }
        }
        assert_eq!(commit_sites, 1, "the scan must find the write it is guarding — it found {commit_sites}");
        assert!(offenders.is_empty(), "these desk methods reach a loro write without a confirmation: {offenders:?}");
    }
}
