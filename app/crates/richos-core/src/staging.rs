//! THE STAGING DESK — where a spoken correction lands, and the only door out of it.
//!
//! [`crate::spoken::detect`] decides that an utterance looked like a correction. This
//! module is what happens next, and what does NOT happen next.
//!
//! # Staged, never committed — and that is not a hedge, it is the ruling
//!
//! `ceo-decisions.md` §7 (DECIDED 2026-08-26) governs this absolutely: *"Whenever the user
//! corrects something from dictation input, just show a mini HUD/tooltip/popup asking for
//! confirmation… **Nothing is ever learned silently.**"* The trigger measured at precision
//! 1.000 on an adversarial corpus (`tests/spoken_precision.rs`) and it *still* only stages,
//! because a precision measured by the author of the corpus is evidence about the shape of
//! the errors, not a license to skip the ask.
//!
//! So there is no function here that learns a term. There is [`CandidateDesk::stage`],
//! which writes down what the CEO appears to have corrected; and there is
//! [`CandidateDesk::confirm`], which is the only path to a vocabulary write and refuses
//! anything that is not a candidate already in front of him. A caller cannot skip the ask,
//! because there is no argument it could pass to do so. Same shape, same reason, as
//! `correction.rs`'s propose/confirm split.
//!
//! # §7's three outcomes are the state machine, verbatim
//!
//! | The CEO does | Here |
//! |---|---|
//! | Confirms | [`CandidateDesk::confirm`] — the pair reaches `richos-service learn-term` |
//! | Declines | [`CandidateDesk::decline`] with `permanent = false` — nothing learned, and the count is kept so the NEXT repeat says *"you corrected this before"* |
//! | Declines permanently | `permanent = true` — suppressed, on a list that [`CandidateDesk::suppressed`] can read back and [`CandidateDesk::unsuppress`] can lift |
//!
//! Re-ask on the very next repeat, with no threshold and no cool-off: §7 is explicit that
//! *"repetition IS the evidence and waiting dilutes it"*.
//!
//! # Durability
//!
//! Append-only JSONL with `sync_all` on every record, a torn last line skipped rather than
//! fatal — the posture `steering::IntakeLog` and `correction::CorrectionDesk` already use,
//! for the same reason. A candidate the CEO has not answered must survive a crash, a
//! rotation and a relaunch, or *"he confirms after lunch"* silently loses the correction.
//!
//! This is a THIRD store beside the ledger and the machinery journal, and deliberately so:
//! an unanswered question is not a conversation event (it never happened in the thread) and
//! it is not machinery (machinery is evictable and this is not). It is also NOT a second
//! source of truth about the vocabulary — `loro/entities.json` remains that, with
//! `learn-term` its one writer.
//!
//! # What this deliberately does NOT do
//!
//! - **It does not write the vocabulary itself.** `bin/richos-service.js` calls `learnTerm`
//!   *"one writer of the vocabulary, one set of rules"*, and this reaches it through the
//!   CLI rather than growing a second implementation.
//! - **It does not silently succeed when the service is absent.** A confirm with no
//!   vocabulary backend attached returns [`StagingError::NoVocabulary`] and the candidate
//!   stays answerable. A confirmation that goes nowhere and says nothing is worse than one
//!   that fails loudly, because the CEO would believe the term was learned.
//! - **It does not decide anything about loro.** A spoken correction of a BELIEF (a date, a
//!   number, a decision) is `correction.rs`'s desk, and which utterance shapes should reach
//!   it is an open CEO decision. Nothing here routes to loro.

use crate::spoken::{Detection, SpokenAsk};
use crate::util::now_millis;
use serde::{Deserialize, Serialize};
use std::io::{BufRead, BufReader, Write};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};

#[derive(Debug, thiserror::Error)]
pub enum StagingError {
    #[error("staging desk io: {0}")]
    Io(String),
    #[error("no candidate {0} is awaiting an answer")]
    NoSuchCandidate(String),
    #[error("no vocabulary backend is attached — RichOS will not report a term as learned when nothing wrote it")]
    NoVocabulary,
    #[error("the vocabulary writer refused (exit {code}): {message}")]
    WriterRefused { code: i32, message: String },
    #[error("the vocabulary writer could not be run: {0}")]
    WriterUnavailable(String),
}

impl From<std::io::Error> for StagingError {
    fn from(e: std::io::Error) -> Self {
        StagingError::Io(e.to_string())
    }
}

// ---------------------------------------------------------------------------------------
// what is staged
// ---------------------------------------------------------------------------------------

/// One correction the CEO appears to have spoken, waiting for a one-keystroke answer.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Candidate {
    /// `askKey(from, to)` — the same identity the service's decline ledger uses, so a pair
    /// suppressed there and a pair suppressed here are the same question.
    pub key: String,
    pub at: u64,
    /// The thread the utterance belonged to. Captured at STAGE time, never re-derived when
    /// he answers — the active thread can move while a question waits, and a candidate
    /// re-scoped to wherever he happens to be looking has laundered itself across an entity
    /// boundary (ECS §3.4, the reason `steering::IntakeRecord::Steer` carries its binding).
    pub thread_id: String,
    pub turn_id: String,
    /// What he said, verbatim, so the confirmation can quote him rather than paraphrase.
    pub utterance: String,
    pub ask: SpokenAsk,
    /// How many times this exact pair has been declined before. §7: a second ask must say
    /// so, *"or it reads as the system having forgotten"*.
    pub declined_before: u32,
    /// The sentence §7 asks for, built here so every surface asks it the same way.
    pub prompt: String,
}

/// A candidate that was detected and then NOT staged, with the reason. §7's suppression
/// list *"must be inspectable, or a term silently refuses to learn with no way to see
/// why"* — so a suppressed repeat is REPORTED rather than dropped.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Withheld {
    pub key: String,
    pub from: String,
    pub to: String,
    pub reason: String,
}

/// The result of one utterance passing the trigger.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Staged {
    pub candidates: Vec<Candidate>,
    pub withheld: Vec<Withheld>,
}

impl Staged {
    pub fn is_empty(&self) -> bool {
        self.candidates.is_empty() && self.withheld.is_empty()
    }
}

/// What `learn-term` reported back. Surfaced verbatim rather than reworded — `changed:
/// false` means the vocabulary already knew the pair, which is a different fact from a
/// refusal and the CEO is entitled to both.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct LearnOutcome {
    #[serde(default)]
    pub file: String,
    #[serde(default)]
    pub changed: bool,
    #[serde(default)]
    pub created: bool,
    #[serde(default)]
    pub version: String,
}

/// The vocabulary's write side, behind a trait so `cargo test -p richos-core` stays
/// hermetic: richos ships no `loro/entities.json`, so a test that shelled out to the real
/// service could only run on one machine.
pub trait VocabularyBackend: Send {
    /// `richos-service learn-term --canonical <to> --mangled <from>`. **Only
    /// [`CandidateDesk::confirm`] calls this.**
    fn learn(&self, canonical: &str, mangled: &str) -> Result<LearnOutcome, StagingError>;
}

/// The shipped backend: `node tools/richos-service/bin/richos-service.js learn-term …`.
pub struct CliVocabulary {
    node: String,
    service_bin: PathBuf,
    entities_file: Option<PathBuf>,
}

impl CliVocabulary {
    pub fn new(node: String, service_bin: PathBuf, entities_file: Option<PathBuf>) -> Self {
        CliVocabulary { node, service_bin, entities_file }
    }

    /// Build from the environment. `None` = no local service configured, which is an
    /// ordinary install and not an error — the same posture as
    /// `correction::CliLoroWriter::from_env`. Detection and staging still work; only the
    /// confirm step has nowhere to go, and it says so.
    pub fn from_env() -> Option<Self> {
        let bin = std::env::var("RICHOS_SERVICE_BIN").ok().filter(|v| !v.trim().is_empty())?;
        let node = std::env::var("RICHOS_NODE_BIN")
            .ok()
            .filter(|v| !v.trim().is_empty())
            .unwrap_or_else(|| "node".into());
        let entities = std::env::var("RICHOS_ENTITIES_FILE")
            .ok()
            .filter(|v| !v.trim().is_empty())
            .map(PathBuf::from);
        Some(CliVocabulary::new(node, PathBuf::from(bin), entities))
    }
}

impl VocabularyBackend for CliVocabulary {
    fn learn(&self, canonical: &str, mangled: &str) -> Result<LearnOutcome, StagingError> {
        use std::process::{Command, Stdio};
        let mut argv: Vec<String> = vec![
            self.service_bin.display().to_string(),
            "learn-term".into(),
            "--canonical".into(),
            canonical.to_string(),
            "--mangled".into(),
            mangled.to_string(),
        ];
        if let Some(f) = &self.entities_file {
            argv.push("--file".into());
            argv.push(f.display().to_string());
        }
        let out = Command::new(&self.node)
            .args(&argv)
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .output()
            .map_err(|e| StagingError::WriterUnavailable(e.to_string()))?;
        if !out.status.success() {
            return Err(StagingError::WriterRefused {
                code: out.status.code().unwrap_or(-1),
                message: String::from_utf8_lossy(&out.stderr).trim().to_string(),
            });
        }
        // `learn-term` writes a human line to stderr and the JSON object to stdout.
        serde_json::from_slice(&out.stdout).map_err(|e| {
            StagingError::WriterUnavailable(format!("learn-term's output did not parse: {e}"))
        })
    }
}

// ---------------------------------------------------------------------------------------
// the desk
// ---------------------------------------------------------------------------------------

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "rec", rename_all = "kebab-case")]
enum DeskRecord {
    Staged(Box<Candidate>),
    Learned { key: String, at: u64, outcome: LearnOutcome },
    /// Confirmed, and the write did not happen. Kept, because a failed learn that vanishes
    /// is indistinguishable from one that was never asked for.
    LearnFailed { key: String, at: u64, reason: String },
    Declined { key: String, at: u64 },
    Suppressed { key: String, at: u64 },
    Unsuppressed { key: String, at: u64 },
}

/// The one place in the app a spoken correction becomes a record — and it cannot become a
/// vocabulary entry without the CEO having answered first.
pub struct CandidateDesk {
    path: PathBuf,
    vocabulary: Option<Box<dyn VocabularyBackend>>,
    pending: Vec<Candidate>,
    declined: Vec<(String, u32)>,
    suppressed: Vec<String>,
}

impl CandidateDesk {
    pub fn open(path: impl AsRef<Path>) -> Result<Self, StagingError> {
        let path = path.as_ref().to_path_buf();
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent)?;
        }
        let mut desk = CandidateDesk {
            path,
            vocabulary: None,
            pending: Vec::new(),
            declined: Vec::new(),
            suppressed: Vec::new(),
        };
        desk.replay()?;
        Ok(desk)
    }

    /// Attach the vocabulary writer. Optional on purpose: an install with no local service
    /// still detects and still stages, and only the confirm step reports that it has
    /// nowhere to go.
    pub fn set_vocabulary(&mut self, backend: Box<dyn VocabularyBackend>) {
        self.vocabulary = Some(backend);
    }

    fn replay(&mut self) -> Result<(), StagingError> {
        if !self.path.exists() {
            return Ok(());
        }
        let file = std::fs::File::open(&self.path)?;
        for line in BufReader::new(file).lines().map_while(Result::ok) {
            let line = line.trim();
            if line.is_empty() {
                continue;
            }
            // A torn last line (a crash mid-write) is skipped, never fatal: one lost
            // question must not make the whole desk unreadable.
            let Ok(rec) = serde_json::from_str::<DeskRecord>(line) else { continue };
            self.apply(rec);
        }
        Ok(())
    }

    fn apply(&mut self, rec: DeskRecord) {
        match rec {
            DeskRecord::Staged(c) => {
                self.pending.retain(|p| p.key != c.key);
                self.pending.push(*c);
            }
            DeskRecord::Learned { key, .. } | DeskRecord::LearnFailed { key, .. } => {
                self.pending.retain(|p| p.key != key);
                self.declined.retain(|(k, _)| *k != key);
            }
            DeskRecord::Declined { key, .. } => {
                self.pending.retain(|p| p.key != key);
                match self.declined.iter_mut().find(|(k, _)| *k == key) {
                    Some((_, n)) => *n += 1,
                    None => self.declined.push((key, 1)),
                }
            }
            DeskRecord::Suppressed { key, .. } => {
                self.pending.retain(|p| p.key != key);
                self.declined.retain(|(k, _)| *k != key);
                if !self.suppressed.contains(&key) {
                    self.suppressed.push(key);
                }
            }
            DeskRecord::Unsuppressed { key, .. } => self.suppressed.retain(|k| *k != key),
        }
    }

    fn append(&mut self, rec: DeskRecord) -> Result<(), StagingError> {
        let line = serde_json::to_string(&rec)
            .map_err(|e| StagingError::Io(format!("staging record did not serialize: {e}")))?;
        let mut f = std::fs::OpenOptions::new().create(true).append(true).open(&self.path)?;
        f.write_all(line.as_bytes())?;
        f.write_all(b"\n")?;
        // fsync every record: an unanswered question that a crash erases is a correction
        // the CEO made and the system forgot, which is the exact failure this whole
        // feature exists to stop.
        f.sync_all()?;
        self.apply(rec);
        Ok(())
    }

    /// Stage everything the trigger found for one utterance. Durable before it is shown.
    ///
    /// Suppressed pairs are WITHHELD rather than dropped, and a previously declined pair is
    /// staged again with its count, because §7 says a repeat is evidence.
    pub fn stage(
        &mut self,
        detection: &Detection,
        thread_id: &str,
        turn_id: &str,
        utterance: &str,
    ) -> Result<Staged, StagingError> {
        let mut out = Staged::default();
        for ask in &detection.asks {
            if self.suppressed.contains(&ask.key) {
                out.withheld.push(Withheld {
                    key: ask.key.clone(),
                    from: ask.from.clone(),
                    to: ask.to.clone(),
                    reason: "permanently suppressed by the CEO (\"don't ask for this term again\")"
                        .into(),
                });
                continue;
            }
            let declined_before =
                self.declined.iter().find(|(k, _)| *k == ask.key).map(|(_, n)| *n).unwrap_or(0);
            let candidate = Candidate {
                key: ask.key.clone(),
                at: now_millis(),
                thread_id: thread_id.to_string(),
                turn_id: turn_id.to_string(),
                utterance: utterance.to_string(),
                ask: ask.clone(),
                declined_before,
                prompt: prompt_for(&ask.to, declined_before),
            };
            self.append(DeskRecord::Staged(Box::new(candidate.clone())))?;
            out.candidates.push(candidate);
        }
        Ok(out)
    }

    /// **The only path to a vocabulary write.** Refuses anything that is not a candidate
    /// currently in front of the CEO, so a caller cannot confirm a pair he never saw.
    pub fn confirm(&mut self, key: &str) -> Result<LearnOutcome, StagingError> {
        let candidate = self
            .pending
            .iter()
            .find(|c| c.key == key)
            .cloned()
            .ok_or_else(|| StagingError::NoSuchCandidate(key.to_string()))?;
        let Some(vocab) = self.vocabulary.as_ref() else {
            // Deliberately BEFORE any record is written: the candidate stays pending and
            // answerable rather than being consumed by an answer that went nowhere.
            return Err(StagingError::NoVocabulary);
        };
        match vocab.learn(&candidate.ask.to, &candidate.ask.from) {
            Ok(outcome) => {
                self.append(DeskRecord::Learned {
                    key: key.to_string(),
                    at: now_millis(),
                    outcome: outcome.clone(),
                })?;
                Ok(outcome)
            }
            Err(e) => {
                self.append(DeskRecord::LearnFailed {
                    key: key.to_string(),
                    at: now_millis(),
                    reason: e.to_string(),
                })?;
                Err(e)
            }
        }
    }

    /// §7's other two outcomes. `permanent = false` keeps the pair askable on its very next
    /// repeat; `permanent = true` suppresses it until [`Self::unsuppress`] lifts it.
    pub fn decline(&mut self, key: &str, permanent: bool) -> Result<(), StagingError> {
        if !self.pending.iter().any(|c| c.key == key) {
            return Err(StagingError::NoSuchCandidate(key.to_string()));
        }
        let at = now_millis();
        if permanent {
            self.append(DeskRecord::Suppressed { key: key.to_string(), at })
        } else {
            self.append(DeskRecord::Declined { key: key.to_string(), at })
        }
    }

    /// Lift a permanent decline. §7: the suppression list must be inspectable — and a list
    /// that cannot be undone is a trap rather than a setting.
    pub fn unsuppress(&mut self, key: &str) -> Result<(), StagingError> {
        self.append(DeskRecord::Unsuppressed { key: key.to_string(), at: now_millis() })
    }

    /// Everything awaiting an answer, oldest first.
    pub fn pending(&self) -> &[Candidate] {
        &self.pending
    }

    pub fn pending_for(&self, thread_id: &str) -> Vec<&Candidate> {
        self.pending.iter().filter(|c| c.thread_id == thread_id).collect()
    }

    /// §7: *"The suppression list must be inspectable, or a term silently refuses to learn
    /// with no way to see why."*
    pub fn suppressed(&self) -> &[String] {
        &self.suppressed
    }

    /// How many times a pair has been declined. Zero for a pair nobody has answered.
    pub fn declined_count(&self, key: &str) -> u32 {
        self.declined.iter().find(|(k, _)| k == key).map(|(_, n)| *n).unwrap_or(0)
    }

    pub fn path(&self) -> &Path {
        &self.path
    }

    /// Hand the desk to the spine and to the shell as one shared object.
    pub fn shared(self) -> SharedCandidateDesk {
        Arc::new(Mutex::new(self))
    }
}

/// The desk as the SHELL holds it — and as the spine holds it, which is the same object.
///
/// **It is deliberately NOT inside the spine's mutex.** `Spine::submit_prompt` takes
/// `&mut self` and does not return until the turn is over, so anything behind that lock is
/// unreachable for the length of a turn (`steering.rs` opens with the measurement:
/// §6.2's own example is `Worked for 2h 17m 50s`). Answering §7's question is something the
/// CEO does WHILE Rich is working — that is the entire point of a non-activating HUD — so a
/// desk behind the turn lock would be a prompt he cannot answer until the work it
/// interrupted has already finished. Same `Arc`-beside-the-lock shape as `TurnControl`, and
/// for the same measured reason.
///
/// The lock ordering is one-way and trivial: the trigger takes the spine lock and then this
/// one, briefly; the answer commands take only this one. Nothing takes the spine lock while
/// holding this.
pub type SharedCandidateDesk = Arc<Mutex<CandidateDesk>>;

/// The event a staged correction is announced on. A FOURTH family beside `stream.rs`,
/// `live.rs` and `machinery.rs`, and separate from all three for the reason
/// `MachineryObserver` is separate: a subscription list is the proof of what a surface
/// carries. §13 lists eleven live events and this is none of them, so it does not go in
/// that family — inventing a twelfth §13 event would misrepresent the brief.
pub const EVENT_CORRECTION_STAGED: &str = "rich://correction-staged";

/// A sink for staged corrections — the mini-HUD §7 describes, whatever renders it.
pub trait CorrectionObserver: Send {
    /// MUST be non-blocking and infallible from the spine's view. A UI that is not
    /// listening never stalls or fails a turn: the question is already durable on disk
    /// before this is called, so a dropped notification costs a prompt, never a record.
    fn on_correction_staged(&self, staged: &Staged);
}

/// §7's sentence, plus the memory that keeps a second ask from reading as amnesia.
fn prompt_for(canonical: &str, declined_before: u32) -> String {
    if declined_before > 0 {
        format!("Add \"{canonical}\" to your vocabulary? (you corrected this before)")
    } else {
        format!("Add \"{canonical}\" to your vocabulary?")
    }
}

// ---------------------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;
    use crate::spoken::detect;

    struct Recording {
        calls: std::sync::Arc<std::sync::Mutex<Vec<(String, String)>>>,
        fail: bool,
    }

    impl VocabularyBackend for Recording {
        fn learn(&self, canonical: &str, mangled: &str) -> Result<LearnOutcome, StagingError> {
            self.calls.lock().unwrap().push((canonical.into(), mangled.into()));
            if self.fail {
                return Err(StagingError::WriterRefused {
                    code: 2,
                    message: "entities.json is not writable".into(),
                });
            }
            Ok(LearnOutcome {
                file: "entities.json".into(),
                changed: true,
                created: true,
                version: "2".into(),
            })
        }
    }

    fn tmp(name: &str) -> PathBuf {
        let p = std::env::temp_dir().join(format!(
            "richos-staging-{name}-{}-{}",
            std::process::id(),
            now_millis()
        ));
        let _ = std::fs::remove_dir_all(&p);
        p.join("candidates.jsonl")
    }

    fn desk_with(path: &Path) -> (CandidateDesk, std::sync::Arc<std::sync::Mutex<Vec<(String, String)>>>) {
        let calls = std::sync::Arc::new(std::sync::Mutex::new(Vec::new()));
        let mut d = CandidateDesk::open(path).unwrap();
        d.set_vocabulary(Box::new(Recording { calls: calls.clone(), fail: false }));
        (d, calls)
    }

    fn stage_one(d: &mut CandidateDesk, utterance: &str) -> Staged {
        let det = detect(utterance, &[]);
        d.stage(&det, "thread-1", "turn-1", utterance).unwrap()
    }

    /// INVARIANT: staging writes NOTHING to the vocabulary. This is §7 as a test — if the
    /// detector ever gained a write path, this is what fails.
    #[test]
    fn staging_never_writes_a_vocabulary() {
        let path = tmp("never-writes");
        let (mut d, calls) = desk_with(&path);
        let out = stage_one(&mut d, "It's Kestrel, not Kestral.");
        assert_eq!(out.candidates.len(), 1);
        assert!(calls.lock().unwrap().is_empty(), "staging called the vocabulary writer");
    }

    /// INVARIANT: confirm is the ONLY path to a write, and it passes canonical/mangled the
    /// right way round. Backwards, the flywheel would teach the mishearing.
    #[test]
    fn only_confirm_writes_and_it_writes_the_pair_the_right_way_round() {
        let path = tmp("confirm");
        let (mut d, calls) = desk_with(&path);
        let out = stage_one(&mut d, "It's Kestrel, not Kestral.");
        let key = out.candidates[0].key.clone();

        let outcome = d.confirm(&key).unwrap();
        assert!(outcome.changed);
        assert_eq!(calls.lock().unwrap().as_slice(), &[("Kestrel".to_string(), "Kestral".to_string())]);
        assert!(d.pending().is_empty(), "a confirmed candidate is still pending");
    }

    /// INVARIANT: a candidate the CEO never saw cannot be confirmed.
    #[test]
    fn a_candidate_that_was_never_staged_cannot_be_confirmed() {
        let path = tmp("unknown");
        let (mut d, calls) = desk_with(&path);
        assert!(matches!(
            d.confirm("kestral=>kestrel"),
            Err(StagingError::NoSuchCandidate(_))
        ));
        assert!(calls.lock().unwrap().is_empty());
    }

    /// INVARIANT (§7): a decline is NOT permanent, and the re-ask happens on the very next
    /// repeat with no threshold — and it SAYS it has been corrected before.
    #[test]
    fn a_decline_is_re_asked_on_the_very_next_repeat_and_says_so() {
        let path = tmp("decline");
        let (mut d, _) = desk_with(&path);
        let first = stage_one(&mut d, "It's Kestrel, not Kestral.");
        let key = first.candidates[0].key.clone();
        assert_eq!(first.candidates[0].declined_before, 0);
        assert_eq!(first.candidates[0].prompt, "Add \"Kestrel\" to your vocabulary?");

        d.decline(&key, false).unwrap();
        assert!(d.pending().is_empty());

        let second = stage_one(&mut d, "It's Kestrel, not Kestral.");
        assert_eq!(second.candidates.len(), 1, "the pair was not asked again");
        assert_eq!(second.candidates[0].declined_before, 1);
        assert_eq!(
            second.candidates[0].prompt,
            "Add \"Kestrel\" to your vocabulary? (you corrected this before)"
        );
    }

    /// INVARIANT (§7): a permanent decline suppresses the pair, the suppression is
    /// INSPECTABLE, and it can be lifted. A withheld repeat is reported, never dropped
    /// silently — "or a term silently refuses to learn with no way to see why".
    #[test]
    fn a_permanent_decline_is_inspectable_reported_and_liftable() {
        let path = tmp("never");
        let (mut d, _) = desk_with(&path);
        let first = stage_one(&mut d, "It's Kestrel, not Kestral.");
        let key = first.candidates[0].key.clone();
        d.decline(&key, true).unwrap();
        assert_eq!(d.suppressed(), &[key.clone()]);

        let second = stage_one(&mut d, "It's Kestrel, not Kestral.");
        assert!(second.candidates.is_empty(), "a suppressed pair was staged");
        assert_eq!(second.withheld.len(), 1);
        assert!(second.withheld[0].reason.contains("permanently suppressed"));

        d.unsuppress(&key).unwrap();
        assert!(d.suppressed().is_empty());
        let third = stage_one(&mut d, "It's Kestrel, not Kestral.");
        assert_eq!(third.candidates.len(), 1, "lifting the suppression did not restore the ask");
    }

    /// INVARIANT: an unanswered question survives a crash. Everything the desk knows is
    /// rebuilt from the file alone — there is no in-memory-only state.
    #[test]
    fn an_unanswered_candidate_survives_a_relaunch() {
        let path = tmp("durable");
        {
            let (mut d, _) = desk_with(&path);
            stage_one(&mut d, "It's Kestrel, not Kestral.");
            stage_one(&mut d, "It's Ravencrest, not Raven Crest.");
            let key = d.pending()[1].key.clone();
            d.decline(&key, true).unwrap();
        }
        let reopened = CandidateDesk::open(&path).unwrap();
        assert_eq!(reopened.pending().len(), 1);
        assert_eq!(reopened.pending()[0].ask.to, "Kestrel");
        assert_eq!(reopened.suppressed().len(), 1);
    }

    /// INVARIANT: a torn last line — a crash mid-append — costs that one record and never
    /// the whole desk.
    #[test]
    fn a_torn_last_line_is_skipped_not_fatal() {
        let path = tmp("torn");
        {
            let (mut d, _) = desk_with(&path);
            stage_one(&mut d, "It's Kestrel, not Kestral.");
        }
        let mut raw = std::fs::read_to_string(&path).unwrap();
        raw.push_str("{\"rec\":\"staged\",\"candi");
        std::fs::write(&path, raw).unwrap();

        let reopened = CandidateDesk::open(&path).unwrap();
        assert_eq!(reopened.pending().len(), 1);
    }

    /// INVARIANT: with no vocabulary attached, a confirm FAILS LOUDLY and the candidate
    /// stays answerable. Reporting "learned" when nothing wrote would be the worst outcome
    /// available — the CEO would stop correcting it.
    #[test]
    fn a_confirm_with_no_vocabulary_fails_loudly_and_keeps_the_candidate() {
        let path = tmp("no-vocab");
        let mut d = CandidateDesk::open(&path).unwrap();
        let out = stage_one(&mut d, "It's Kestrel, not Kestral.");
        let key = out.candidates[0].key.clone();
        assert!(matches!(d.confirm(&key), Err(StagingError::NoVocabulary)));
        assert_eq!(d.pending().len(), 1, "the candidate was consumed by a failed confirm");
    }

    /// INVARIANT: a writer that refuses is RECORDED, and the candidate is not left looking
    /// unanswered. A failed learn that vanishes is indistinguishable from one never asked.
    #[test]
    fn a_refused_write_is_recorded_rather_than_lost() {
        let path = tmp("refused");
        let calls = std::sync::Arc::new(std::sync::Mutex::new(Vec::new()));
        let mut d = CandidateDesk::open(&path).unwrap();
        d.set_vocabulary(Box::new(Recording { calls, fail: true }));
        let out = stage_one(&mut d, "It's Kestrel, not Kestral.");
        let key = out.candidates[0].key.clone();
        assert!(matches!(d.confirm(&key), Err(StagingError::WriterRefused { code: 2, .. })));

        let raw = std::fs::read_to_string(&path).unwrap();
        assert!(raw.contains("learn-failed"), "the failure was not journalled: {raw}");
        let reopened = CandidateDesk::open(&path).unwrap();
        assert!(reopened.pending().is_empty());
    }

    /// INVARIANT: the thread is captured when the correction is STAGED. A candidate that
    /// re-scoped itself to wherever the CEO is now looking has crossed an entity boundary.
    #[test]
    fn the_candidate_keeps_the_thread_it_was_spoken_in() {
        let path = tmp("scope");
        let (mut d, _) = desk_with(&path);
        let det = detect("It's Kestrel, not Kestral.", &[]);
        d.stage(&det, "thread-A", "turn-9", "It's Kestrel, not Kestral.").unwrap();
        let det2 = detect("It's Ravencrest, not Raven Crest.", &[]);
        d.stage(&det2, "thread-B", "turn-10", "It's Ravencrest, not Raven Crest.").unwrap();

        assert_eq!(d.pending_for("thread-A").len(), 1);
        assert_eq!(d.pending_for("thread-A")[0].turn_id, "turn-9");
        assert_eq!(d.pending_for("thread-B").len(), 1);
    }
}
