//! STEERING AND STOP — the CEO's two mid-turn controls (UX §9.2, §9.3), and the durable
//! antechamber they need in order to exist at all.
//!
//! # The wall this module exists to get around, measured
//!
//! `Spine::submit_prompt` takes `&mut self` and does not return until the turn is over:
//! `deliver()` borrows `&mut self.ledger` across the whole of `lease.prompt(..)`
//! (`spine.rs`), and the Tauri shell holds the one `Spine` behind a `Mutex`. So for the
//! entire length of a turn — §6.2's own example is `Worked for 2h 17m 50s` — **every path
//! into the spine is blocked**, including the ledger. That is deliberate and it is what
//! makes rotation unable to race a CEO message (`spine.rs`, "Concurrency note").
//!
//! It also means a stop control cannot be implemented by calling the spine. Anything that
//! waits for that lock is a button that does nothing until the work it was meant to
//! interrupt has already finished.
//!
//! # What this module does instead
//!
//! One append-only file — the **intake log** — that the CEO's two mid-turn controls can
//! write to without touching the spine at all:
//!
//! ```text
//!   CEO presses stop   -> IntakeLog::append(Stop{turn_id})   -> fsync -> cancel the lease
//!   CEO steers         -> IntakeLog::append(Steer{text})     -> fsync -> wait for the boundary
//!   spine reaches the turn boundary -> drain into the LEDGER -> append Drained{through}
//! ```
//!
//! **A record here is never dropped in silence.** It is the CEO's own typed words before
//! anything at all has happened to them, so a record this build cannot read is counted,
//! classified and reported ([`IntakeLog::health`]) rather than skipped past — and it is
//! never fatal, because refusing to open the app is not an improvement over dropping one
//! message. The judgment is the ledger's, shared rather than re-derived ([`crate::skip`]).
//!
//! **The intake log is not a second source of truth.** Nothing reads it for display and
//! nothing renders from it. Every record has exactly two fates: it becomes a ledger event,
//! or it is refused and marked drained. The ledger remains the only thing that says what
//! happened. What the intake log adds is the ONE guarantee the ledger cannot give while it
//! is locked inside a running turn: *the CEO's words and the CEO's stop are on disk before
//! anything acts on them* — §9.2's *"persisted before delivery"* and §9.3's step 1,
//! *"persist a stop request"*, in that literal order.
//!
//! # What it deliberately does not do
//!
//! - **It does not inject a steering message into the running turn.** The agent runs one
//!   `session/prompt` at a time and the continuity design's turn-boundary controller is
//!   queue-not-interrupt by construction (§3.1). §25 asks that *"a steering message joins
//!   the active turn in durable order"*; what this build delivers is that the message is
//!   durable and ordered the instant the CEO presses Enter, and reaches Rich at the next
//!   turn boundary. That is a real difference and the UI says so in words rather than
//!   implying the message landed mid-turn.
//! - **It does not model `waiting_for_user`.** Nothing in this system emits it: §22 lists
//!   worker waiting state under "must not be faked", `worker_status.rs` refuses to infer
//!   it, and `TeammateIdle` cannot tell "paused for input" from "finished for good". A
//!   pause with no signal behind it would make §6.3's active-time accounting a guess, so
//!   there is no pause here and `Turn::active_ms` stays exact.

use crate::entity::EntityId;
use crate::skip::{SkipDialect, SkipKind, SkippedRecord};
use crate::util::now_millis;
use serde::{Deserialize, Serialize};
use std::io::{BufRead, BufReader, Write};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};

#[derive(Debug, thiserror::Error)]
pub enum SteeringError {
    #[error("steering intake io: {0}")]
    Io(String),
    /// No durable intake log is attached, so a stop request cannot be written down before
    /// acting on it. Refusing is the point: a stop that is not recorded cannot later be
    /// told apart from a crash, and §6.1's `You stopped after {duration}` would be back to
    /// being an attribution with no evidence.
    #[error("no durable intake log is attached — RichOS will not act on a stop it cannot record")]
    NoDurableIntake,
    /// Steering requires something to steer.
    #[error("nothing is running to steer")]
    NoActiveTurn,
}

impl From<std::io::Error> for SteeringError {
    fn from(e: std::io::Error) -> Self {
        SteeringError::Io(e.to_string())
    }
}

// ---------------------------------------------------------------------------------------
// THE INTAKE LOG
// ---------------------------------------------------------------------------------------

/// One line of the intake log.
///
/// `id` is a per-file monotonic counter, and it is the ORDERING KEY for everything in this
/// module — including the one rule that needs two records compared to each other (a stop
/// cancels the steering that preceded it, and never the steering that followed it).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "record", rename_all = "snake_case")]
pub enum IntakeRecord {
    /// §9.2: words the CEO added while Rich was working.
    Steer {
        id: u64,
        /// The thread the ACTIVE TURN belongs to — captured at write time, never
        /// re-derived at drain time. Same reason `spine::Queued` carries a binding: the
        /// active context can move while a record waits, and a record that is re-scoped to
        /// wherever the CEO happens to be looking has laundered itself across an entity
        /// boundary (ECS §3.4).
        thread_id: String,
        /// The turn that was running when he typed it. Recorded as EVIDENCE of the
        /// "while Rich was working" cue, not as a delivery target — see the module doc.
        steering_turn_id: String,
        entity_id: Option<EntityId>,
        text: String,
        at: u64,
    },
    /// §9.3 step 1: "Persist a stop request."
    Stop { id: u64, turn_id: String, at: u64 },
    /// Everything with `id <= through` has reached the ledger or been refused. Written
    /// AFTER the ledger write, so a crash in between re-presents the record rather than
    /// losing it — at-least-once into a ledger whose turn ids make the replay detectable.
    Drained { through: u64 },
}

impl IntakeRecord {
    pub fn id(&self) -> u64 {
        match self {
            IntakeRecord::Steer { id, .. } | IntakeRecord::Stop { id, .. } => *id,
            IntakeRecord::Drained { through } => *through,
        }
    }
}

/// EVERY `record` tag this build knows how to replay.
///
/// It is the only thing that can tell a record written by a NEWER RichOS apart from a
/// damaged one, so it has to stay exactly in step with [`IntakeRecord`]. That is not left
/// to care: `intake_forward_compat_tests.rs` maps every variant through an EXHAUSTIVE
/// match, so adding a variant here without adding its name does not compile.
pub const KNOWN_INTAKE_TAGS: &[&str] = &["steer", "stop", "drained"];

/// How the intake log's records are told apart from a newer build's and from damage.
/// The judgment itself is [`crate::skip::classify_line`] — the same one the ledger uses,
/// deliberately, so the two stores can never disagree about what damage looks like.
const INTAKE_SKIP: SkipDialect = SkipDialect {
    tag_key: "record",
    record_noun: "an intake record",
    known_tags: KNOWN_INTAKE_TAGS,
};

/// **What the app can honestly say about the intake log it has just replayed.**
///
/// The intake log is the ONE file that holds the CEO's own words before anything has
/// happened to them: a steering message he typed while Rich was working, or a stop he
/// pressed, fsync'd the instant he acted and not yet turned into a ledger turn. A record
/// dropped here is not a degraded feature — it is something he said to RichOS that never
/// arrives, and that nobody ever learns was lost.
///
/// So this exists for one reason: **so the drop cannot be silent.** It is deliberately NOT
/// a reason to refuse to start. This is a read path on the CEO's own machine, and refusing
/// to open the app is not an improvement over dropping one message.
///
/// `headline` and `detail` are empty strings when nothing was skipped, which is the
/// ordinary case and the signal to say nothing at all. There is no reassuring "the intake
/// log is fine" state, for the same reason `Ledger::history_health` has none.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct IntakeHealth {
    /// Non-empty lines found in the file.
    pub records_read: usize,
    /// Records replayed into the pending set (or into the drain watermark).
    pub records_applied: usize,
    pub skipped: usize,
    pub from_future: usize,
    pub damaged: usize,
    pub ambiguous: usize,
    /// One short sentence. Empty when nothing was skipped.
    pub headline: String,
    /// The honest explanation, in plain American English, with no stack trace in it.
    /// Empty when nothing was skipped.
    pub detail: String,
}

impl IntakeHealth {
    /// Every record on disk is accounted for. The normal state, and the state of every
    /// intake log in existence today.
    pub fn is_clean(&self) -> bool {
        self.skipped == 0
    }
}

/// The append-only intake file: the CEO's words and the CEO's stop, durable before
/// anything acts on them.
///
/// Same durability posture as the ledger (append + `sync_all`, one JSON object per line,
/// a malformed line skipped-and-REPORTED rather than fatal) and deliberately NOT the same
/// file: the ledger is evidence of what happened, and an intake record is a request that
/// has not happened yet.
pub struct IntakeLog {
    path: PathBuf,
    /// Records written and not yet drained, oldest first.
    pending: Vec<IntakeRecord>,
    next_id: u64,
    /// Lines currently in the file, so a long-lived log can be compacted once it is fully
    /// drained rather than growing for the life of the install.
    lines: usize,
    /// Every record on disk that this build could not replay, with the reason for each.
    /// Empty is the normal state and the state of every intake log in existence today.
    skipped: Vec<SkippedRecord>,
    /// Non-empty lines seen on replay, and how many were folded. Counted rather than
    /// derived, so "3 of 4" is a measurement and not an inference.
    records_read: usize,
    records_applied: usize,
}

/// Compact the file once it is fully drained and has grown past this many lines. Chosen so
/// compaction is rare (a drained log is two lines per CEO action) and never happens while
/// anything is pending.
const COMPACT_AFTER_LINES: usize = 256;

impl IntakeLog {
    /// Open (creating if absent) and replay. Undrained records survive a crash and are
    /// returned by [`pending`](Self::pending) for the spine to reconcile at startup.
    ///
    /// # A dropped record here is the CEO's own words, so it is never dropped in silence
    ///
    /// Until 2026-09-05 this loop was `let Ok(rec) = .. else { continue }` with a comment
    /// explaining that a torn LAST line was never acknowledged to anybody. That reasoning
    /// is sound for the case it names and wrong for every other case: the same `continue`
    /// fired for a record written by a newer RichOS, for a record damaged in the MIDDLE of
    /// the file, and for a record shaped differently — and every one of them went with no
    /// count, no log line and no trace. This file holds what he typed BEFORE it becomes a
    /// turn, so that silence is a message he sent that never arrives and that nobody ever
    /// learns was lost.
    ///
    /// Three things changed, and none of them makes the read fatal:
    ///
    ///   1. **Every skipped record is classified and counted** ([`crate::skip`] — the same
    ///      judgment `Ledger::replay` uses). A torn final record and a record from a newer
    ///      build are benign and are labeled as such; a record damaged mid-file is not.
    ///   2. **The read no longer stops at a bad byte.** `lines().map_while(Result::ok)`
    ///      ends the ITERATOR at the first non-UTF-8 line, so one bad byte silently
    ///      discarded every record AFTER it, not just its own. `read_until` classifies that
    ///      line and carries on.
    ///   3. **A skipped record can no longer collide with a fresh one** — see the `next_id`
    ///      derivation below.
    ///
    /// Nothing is deleted and nothing is rewritten. A record this build cannot read stays
    /// exactly where it is, so a build new enough to understand it will read it — which is
    /// also why [`compact`](Self::compact) refuses to run while anything was skipped.
    pub fn open(path: impl AsRef<Path>) -> Result<Self, SteeringError> {
        let path = path.as_ref().to_path_buf();
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent)?;
        }
        let mut records: Vec<IntakeRecord> = Vec::new();
        let mut drained_through: u64 = 0;
        let mut lines = 0usize;
        let mut skipped: Vec<SkippedRecord> = Vec::new();
        let mut records_read = 0usize;
        let mut records_applied = 0usize;
        // The highest id seen on a record this build could NOT fold. It is not in
        // `records`, so without it the counter can hand the same id out twice.
        let mut salvaged_id: u64 = 0;
        if path.exists() {
            let file = std::fs::File::open(&path)?;
            let mut reader = BufReader::new(file);
            let mut raw: Vec<u8> = Vec::new();
            let mut line_no = 0usize;
            loop {
                raw.clear();
                // `read_until`, not `lines()`: `lines()` yields `Err` for a line that is
                // not valid UTF-8 and `map_while(Result::ok)` STOPS THERE, so one bad byte
                // used to take every request after it with it. A real IO error still
                // propagates from here; a bad byte is classified below.
                let n = reader.read_until(b'\n', &mut raw)?;
                if n == 0 {
                    break;
                }
                line_no += 1;
                let body = raw.strip_suffix(b"\n").unwrap_or(&raw);
                let text = match std::str::from_utf8(body) {
                    Ok(t) => t,
                    Err(_) => {
                        lines += 1;
                        records_read += 1;
                        skipped.push(crate::skip::not_utf8(line_no, body.len()));
                        continue;
                    }
                };
                let line = text.trim();
                if line.is_empty() {
                    continue;
                }
                lines += 1;
                records_read += 1;
                match serde_json::from_str::<IntakeRecord>(line) {
                    Ok(rec) => {
                        records_applied += 1;
                        match rec {
                            IntakeRecord::Drained { through } => {
                                drained_through = drained_through.max(through)
                            }
                            other => records.push(other),
                        }
                    }
                    Err(_) => {
                        let record = crate::skip::classify_line(line_no, line, &INTAKE_SKIP);
                        // SALVAGE THE ID, AND FROM ONE MORE KIND THAN THE LEDGER DOES.
                        //
                        // `Ledger::replay` salvages a fencing revision from `FromFuture`
                        // only, on the rule that a damaged line's numbers are not facts.
                        // That rule holds; the LINE is drawn differently here because the
                        // stakes are not symmetric. An intake id is a de-duplication key —
                        // `Spine::drain_intake` treats "the ledger already holds a turn for
                        // this id" as proof the record was handled — so a COLLISION
                        // discards a real message, while an inflated counter costs nothing
                        // at all (ids are opaque and monotonic, and `u64` does not run
                        // out). `Ambiguous` and `FromFuture` are both well-formed JSON
                        // objects carrying a plain-identifier tag, which is structure this
                        // build trusts; `Damaged` is not, and nothing is salvaged from it.
                        if record.kind != SkipKind::Damaged {
                            if let Some(id) = crate::skip::salvage_u64(line, "id") {
                                salvaged_id = salvaged_id.max(id);
                            }
                            if let Some(through) = crate::skip::salvage_u64(line, "through") {
                                salvaged_id = salvaged_id.max(through);
                            }
                        }
                        skipped.push(record);
                    }
                }
            }
        }
        // THE HIGH-WATER MARK OF EVERY ID THIS FILE HAS EVER USED, taken from all three
        // places one can appear. The old derivation was
        // `max(parsed ids).unwrap_or(drained_through) + 1`, which DROPS `drained_through`
        // the moment any record at all parses: a file holding `Steer{1}, Steer{2},
        // Drained{2}` whose `Steer{2}` is unreadable re-issued id 2, and two records with
        // one id make `Ledger::turn_for_intake` match the wrong turn and throw a real
        // message away as already handled.
        let highest = records
            .iter()
            .map(|r| r.id())
            .max()
            .unwrap_or(0)
            .max(drained_through)
            .max(salvaged_id);
        let next_id = highest.saturating_add(1);
        records.retain(|r| r.id() > drained_through);
        let log =
            IntakeLog { path, pending: records, next_id, lines, skipped, records_read, records_applied };
        log.report_skipped();
        Ok(log)
    }

    /// **Skipping is never silent.** One line per skipped record, capped, then a summary
    /// line printed whenever anything at all was skipped.
    ///
    /// The cap exists because a badly damaged file could hold a hundred thousand
    /// unreadable lines, and a hundred thousand log lines is its own kind of silence. The
    /// COUNT is never capped — it is in the summary and in [`IntakeLog::health`].
    fn report_skipped(&self) {
        if self.skipped.is_empty() {
            return;
        }
        const CAP: usize = 20;
        for r in self.skipped.iter().take(CAP) {
            eprintln!(
                "[richos] INTAKE RECORD SKIPPED ({}): line {} ({} bytes) — {}",
                r.kind.label(),
                r.line,
                r.bytes,
                r.detail
            );
        }
        if self.skipped.len() > CAP {
            eprintln!(
                "[richos] INTAKE: {} further skipped records not listed individually",
                self.skipped.len() - CAP
            );
        }
        let h = self.health();
        eprintln!(
            "[richos] INTAKE SUMMARY for {}: {} records read, {} applied, {} skipped \
             ({} from a newer version, {} damaged, {} undetermined). These are things the \
             CEO asked for that Rich has not acted on yet. Nothing was deleted or rewritten.",
            self.path.display(),
            h.records_read,
            h.records_applied,
            h.skipped,
            h.from_future,
            h.damaged,
            h.ambiguous
        );
    }

    /// Every record on disk this build could not replay, with the reason for each.
    pub fn skipped_records(&self) -> &[SkippedRecord] {
        &self.skipped
    }

    /// **What the app can honestly say about the intake log it just replayed.**
    ///
    /// `headline`/`detail` are empty when nothing was skipped — the signal to say nothing
    /// at all, not to say something reassuring about a check that found nothing to report.
    ///
    /// The sentences are composed HERE and deliberately not shared with
    /// `Ledger::history_health`, because they are not the same statement: that one is about
    /// messages that are on screen and did not load, and this one is about something the
    /// CEO said that never reached Rich at all. Nothing should be in a position to
    /// substitute one for the other.
    pub fn health(&self) -> IntakeHealth {
        let count = |k: SkipKind| self.skipped.iter().filter(|r| r.kind == k).count();
        let from_future = count(SkipKind::FromFuture);
        let damaged = count(SkipKind::Damaged);
        let ambiguous = count(SkipKind::Ambiguous);
        let skipped = self.skipped.len();

        let (headline, detail) = if skipped == 0 {
            (String::new(), String::new())
        } else {
            let plural =
                |n: usize, one: &str, many: &str| if n == 1 { one.to_string() } else { many.to_string() };
            let headline = if damaged > 0 || ambiguous > 0 {
                plural(
                    damaged + ambiguous,
                    "Something you typed while Rich was working could not be read.",
                    "Some things you typed while Rich was working could not be read.",
                )
            } else {
                "Something you typed while Rich was working was written by a newer version of \
                 RichOS."
                    .to_string()
            };
            let mut parts: Vec<String> = Vec::new();
            if from_future > 0 {
                parts.push(format!(
                    "{} {} written by a newer version of RichOS than the one you are running, \
                     so this version does not know how to read {}. Updating will bring {} back.",
                    from_future,
                    plural(from_future, "request was", "requests were"),
                    plural(from_future, "it", "them"),
                    plural(from_future, "it", "them"),
                ));
            }
            if damaged > 0 {
                parts.push(format!(
                    "{} {} damaged and could not be read. If you were waiting on Rich to act on \
                     {}, {} never reached him — please ask again.",
                    damaged,
                    plural(damaged, "request is", "requests are"),
                    plural(damaged, "it", "them"),
                    plural(damaged, "it", "they"),
                ));
            }
            if ambiguous > 0 {
                parts.push(format!(
                    "{} {} not match any shape this version knows. That is either a newer \
                     version of RichOS or damage, and this version cannot tell which.",
                    ambiguous,
                    plural(ambiguous, "request does", "requests do"),
                ));
            }
            parts.push(format!(
                "Everything else was read: {} of {} requests. Nothing was deleted and nothing \
                 was rewritten — every record is still exactly where it was on disk.",
                self.records_applied, self.records_read,
            ));
            (headline, parts.join(" "))
        };

        IntakeHealth {
            records_read: self.records_read,
            records_applied: self.records_applied,
            skipped,
            from_future,
            damaged,
            ambiguous,
            headline,
            detail,
        }
    }

    pub fn path(&self) -> &Path {
        &self.path
    }

    /// Undrained records, oldest first.
    pub fn pending(&self) -> &[IntakeRecord] {
        &self.pending
    }

    fn write(&mut self, rec: &IntakeRecord) -> Result<(), SteeringError> {
        let mut line = serde_json::to_string(rec).map_err(|e| SteeringError::Io(e.to_string()))?;
        line.push('\n');
        let mut f = std::fs::OpenOptions::new().create(true).append(true).open(&self.path)?;
        f.write_all(line.as_bytes())?;
        // fsync, not flush. §9.2's "persisted before delivery" and §9.3's "persist a stop
        // request" are both statements about surviving the power going out, and a page
        // cache is not disk.
        f.sync_all()?;
        self.lines += 1;
        Ok(())
    }

    /// Durably record one steering message. Returns its id.
    pub fn steer(
        &mut self,
        thread_id: &str,
        steering_turn_id: &str,
        entity_id: Option<EntityId>,
        text: &str,
    ) -> Result<IntakeRecord, SteeringError> {
        let rec = IntakeRecord::Steer {
            id: self.next_id,
            thread_id: thread_id.to_string(),
            steering_turn_id: steering_turn_id.to_string(),
            entity_id,
            text: text.to_string(),
            at: now_millis(),
        };
        self.write(&rec)?;
        self.next_id += 1;
        self.pending.push(rec.clone());
        Ok(rec)
    }

    /// Durably record one stop request. Returns it, carrying the timestamp that
    /// `Ledger::stop_turn` will quote.
    pub fn stop(&mut self, turn_id: &str) -> Result<IntakeRecord, SteeringError> {
        let rec = IntakeRecord::Stop { id: self.next_id, turn_id: turn_id.to_string(), at: now_millis() };
        self.write(&rec)?;
        self.next_id += 1;
        self.pending.push(rec.clone());
        Ok(rec)
    }

    /// Mark everything up to and including `through` as handled. Called AFTER the ledger
    /// write, never before.
    pub fn mark_drained(&mut self, through: u64) -> Result<(), SteeringError> {
        self.write(&IntakeRecord::Drained { through })?;
        self.pending.retain(|r| r.id() > through);
        // COMPACTION IS REFUSED WHILE ANYTHING WAS SKIPPED, and this is the difference
        // between "an older build cannot read your steering message" and "an older build
        // DELETED your steering message". `compact` replaces the whole file with a single
        // marker; a record this build could not parse is not in `pending`, so without this
        // clause a record written by a newer RichOS — the benign, recoverable case, the one
        // an update is supposed to bring back — would be destroyed by the next compaction
        // and would never come back at all. An uncompacted log costs some lines on disk.
        if self.pending.is_empty() && self.skipped.is_empty() && self.lines >= COMPACT_AFTER_LINES {
            self.compact(through)?;
        }
        Ok(())
    }

    /// Replace a fully-drained file with a single marker.
    ///
    /// Write-new-then-rename, so a crash mid-compaction leaves the ORIGINAL file intact:
    /// truncating in place would put the one file that records un-acted-on CEO requests
    /// into a window where it is empty and the requests are gone.
    fn compact(&mut self, through: u64) -> Result<(), SteeringError> {
        debug_assert!(self.pending.is_empty());
        debug_assert!(self.skipped.is_empty(), "compaction would delete a record nothing could read");
        let tmp = self.path.with_extension("compacting");
        let mut line =
            serde_json::to_string(&IntakeRecord::Drained { through }).map_err(|e| SteeringError::Io(e.to_string()))?;
        line.push('\n');
        {
            let mut f = std::fs::File::create(&tmp)?;
            f.write_all(line.as_bytes())?;
            f.sync_all()?;
        }
        std::fs::rename(&tmp, &self.path)?;
        self.lines = 1;
        Ok(())
    }
}

// ---------------------------------------------------------------------------------------
// THE CANCEL SEAM
// ---------------------------------------------------------------------------------------

/// A handle that can interrupt the CURRENTLY RUNNING turn from outside the spine lock.
///
/// `Send + Sync` and cheap to clone-by-`Arc` because that is the whole requirement: the
/// stop control runs on a different thread from the turn, and by construction it can never
/// take the lock the turn is holding.
pub trait TurnCancel: Send + Sync {
    /// Ask the lease to stop. Returns whether the signal was actually delivered — `false`
    /// means the lease had nothing to cancel (no prompt in flight, or the child is gone),
    /// which the caller reports rather than hides.
    fn cancel(&self) -> bool;
}

// ---------------------------------------------------------------------------------------
// THE CONTROL HANDLE
// ---------------------------------------------------------------------------------------

/// The turn that is running RIGHT NOW, as far as anything outside the spine lock can see.
///
/// Maintained by the spine at exactly the two points that already exist —
/// `mark_turn_started` and the terminal event — so this is a mirror of `turn_in_progress`
/// rather than a second opinion about it. It is not inferred from silence, from timers, or
/// from the absence of events (continuity §5.2).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ActiveTurn {
    pub turn_id: String,
    pub thread_id: String,
    pub entity_id: Option<EntityId>,
    /// `None` for a turn that is journaled but not yet handed to a lease (§11 `queued`) —
    /// never `now()`, so nothing downstream can compute a duration that was not measured.
    pub started_at: Option<u64>,
}

/// A stop the CEO asked for, and the moment the request hit the disk.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct StopClaim {
    pub turn_id: String,
    /// The intake record's id — the ordering key that decides which steering messages this
    /// stop cancels.
    pub intake_id: u64,
    /// When the request became durable. This is what `Ledger::stop_turn` quotes.
    pub requested_at: u64,
}

/// What actually happened when the CEO pressed stop.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum StopOutcome {
    /// Nothing was running. Not an error and not a failure — the honest answer, and the
    /// UI's cue to leave the composer exactly as it was.
    NothingRunning,
    /// The request is on disk and the lease was told.
    Requested {
        turn_id: String,
        requested_at: u64,
        /// Whether the cancel signal reached a lease at all. `false` is a real and
        /// reportable state: the request is still durable and the turn will still be
        /// recorded as stopped when it ends, but nothing was there to interrupt it, so it
        /// may run to completion first. Never smoothed over into `true`.
        reached_lease: bool,
    },
}

struct Inner {
    intake: Mutex<Option<IntakeLog>>,
    active: Mutex<Option<ActiveTurn>>,
    stop: Mutex<Option<StopClaim>>,
    cancel: Mutex<Option<Arc<dyn TurnCancel>>>,
    /// The CURRENT compute lease's session id, published by the spine at the same three
    /// points as `cancel` (attach, rotation, crash recovery).
    ///
    /// Here rather than behind the spine's mutex for the same reason `active` and `cancel`
    /// are: `send_message` holds that mutex for the whole turn, and `get_worker_status` is
    /// polled by the UI ON TURN START. Reading the session id through the spine would make
    /// the worker chip block until Rich finished — so the one datum the worker path needs
    /// travels the channel that was built to bypass the lock.
    ///
    /// A MIRROR, not a second opinion: it is only ever written next to `self.lease`.
    lease_session: Mutex<Option<String>>,
}

/// The shared, lock-free-with-respect-to-the-spine control surface for §9.2 and §9.3.
///
/// Cloning clones the `Arc`: the Tauri shell keeps one handle beside the `Mutex<Spine>`
/// and the spine holds the same one, so a stop command never queues behind a turn.
#[derive(Clone)]
pub struct TurnControl {
    inner: Arc<Inner>,
}

impl std::fmt::Debug for TurnControl {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("TurnControl").field("active", &self.active_turn()).finish_non_exhaustive()
    }
}

impl TurnControl {
    /// A control with a durable intake log — the only shape the shipping app uses.
    pub fn open(path: impl AsRef<Path>) -> Result<Self, SteeringError> {
        let log = IntakeLog::open(path)?;
        Ok(TurnControl {
            inner: Arc::new(Inner {
                intake: Mutex::new(Some(log)),
                active: Mutex::new(None),
                stop: Mutex::new(None),
                cancel: Mutex::new(None),
                lease_session: Mutex::new(None),
            }),
        })
    }

    /// A control with NOWHERE DURABLE TO WRITE. Turn bookkeeping still works, so headless
    /// runs and every existing test keep behaving exactly as before, but `request_stop`
    /// and `steer` refuse with [`SteeringError::NoDurableIntake`] instead of quietly
    /// acting on a request that was never recorded.
    pub fn detached() -> Self {
        TurnControl {
            inner: Arc::new(Inner {
                intake: Mutex::new(None),
                active: Mutex::new(None),
                stop: Mutex::new(None),
                cancel: Mutex::new(None),
                lease_session: Mutex::new(None),
            }),
        }
    }

    pub fn is_durable(&self) -> bool {
        self.inner.intake.lock().unwrap().is_some()
    }

    pub fn intake_path(&self) -> Option<PathBuf> {
        self.inner.intake.lock().unwrap().as_ref().map(|l| l.path().to_path_buf())
    }

    // --- written by the spine, at the points that already exist -------------------------

    /// The spine has handed (or journaled) this turn. Mirrors `turn_in_progress`.
    pub fn begin_turn(&self, turn: ActiveTurn) {
        *self.inner.active.lock().unwrap() = Some(turn);
    }

    /// The spine has recorded a terminal event for `turn_id`. Idempotent, and it will not
    /// clear a DIFFERENT turn's claim on the active slot.
    pub fn end_turn(&self, turn_id: &str) {
        let mut active = self.inner.active.lock().unwrap();
        if active.as_ref().map(|a| a.turn_id == turn_id).unwrap_or(false) {
            *active = None;
        }
    }

    /// Install the lease's cancel seam. Called when a lease is attached, rotated or
    /// recovered; `None` when there is no lease, so a stop reports `reached_lease: false`
    /// rather than pretending.
    pub fn set_cancel(&self, cancel: Option<Arc<dyn TurnCancel>>) {
        *self.inner.cancel.lock().unwrap() = cancel;
    }

    /// Publish the current lease's session id. Written by the spine beside `set_cancel`,
    /// at every point where `self.lease` changes — `None` when there is no lease, so the
    /// worker path reports "no compute lease is attached" rather than reading a directory
    /// belonging to a session that ended.
    pub fn set_lease_session(&self, session_id: Option<String>) {
        *self.inner.lease_session.lock().unwrap() = session_id;
    }

    // --- read/written by the shell, WITHOUT the spine lock ------------------------------

    pub fn active_turn(&self) -> Option<ActiveTurn> {
        self.inner.active.lock().unwrap().clone()
    }

    /// The session id of the lease the app is serving RIGHT NOW, readable without the
    /// spine lock. `None` = no lease; the caller must not substitute anything for it.
    pub fn lease_session(&self) -> Option<String> {
        self.inner.lease_session.lock().unwrap().clone()
    }

    /// §9.3 steps 1 and 2, in that order and never the other way round: persist the stop
    /// request, then interrupt the active turn.
    pub fn request_stop(&self) -> Result<StopOutcome, SteeringError> {
        let Some(active) = self.active_turn() else {
            return Ok(StopOutcome::NothingRunning);
        };
        let rec = {
            let mut guard = self.inner.intake.lock().unwrap();
            let log = guard.as_mut().ok_or(SteeringError::NoDurableIntake)?;
            log.stop(&active.turn_id)?
        };
        let IntakeRecord::Stop { id, at, .. } = rec else { unreachable!("IntakeLog::stop returns Stop") };
        *self.inner.stop.lock().unwrap() =
            Some(StopClaim { turn_id: active.turn_id.clone(), intake_id: id, requested_at: at });

        // Only now — the request is on disk, so however this goes the ledger can say what
        // the CEO asked for.
        let cancel = self.inner.cancel.lock().unwrap().clone();
        let reached_lease = cancel.map(|c| c.cancel()).unwrap_or(false);
        Ok(StopOutcome::Requested { turn_id: active.turn_id, requested_at: at, reached_lease })
    }

    /// §9.2: the CEO added words while Rich was working. Durable on return; delivered at
    /// the next turn boundary (see the module doc — this does not join the running turn).
    pub fn steer(&self, text: &str) -> Result<IntakeRecord, SteeringError> {
        let active = self.active_turn().ok_or(SteeringError::NoActiveTurn)?;
        let mut guard = self.inner.intake.lock().unwrap();
        let log = guard.as_mut().ok_or(SteeringError::NoDurableIntake)?;
        log.steer(&active.thread_id, &active.turn_id, active.entity_id.clone(), text)
    }

    // --- read by the spine, at the turn boundary ----------------------------------------

    /// The live stop claim, if it names this exact turn. Any other turn id returns `None`:
    /// a stop is a statement about ONE turn, and letting it fall through onto whatever ran
    /// next would attribute a stop the CEO never asked for.
    pub fn stop_claim_for(&self, turn_id: &str) -> Option<StopClaim> {
        let guard = self.inner.stop.lock().unwrap();
        guard.as_ref().filter(|c| c.turn_id == turn_id).cloned()
    }

    pub fn stop_claim(&self) -> Option<StopClaim> {
        self.inner.stop.lock().unwrap().clone()
    }

    pub fn clear_stop_claim(&self) {
        *self.inner.stop.lock().unwrap() = None;
    }

    /// Undrained intake records, oldest first.
    pub fn pending_intake(&self) -> Vec<IntakeRecord> {
        self.inner.intake.lock().unwrap().as_ref().map(|l| l.pending().to_vec()).unwrap_or_default()
    }

    /// **What could not be read out of the intake log at boot**, in a form a caller can act
    /// on and a surface can render.
    ///
    /// `None` for a [`detached`](Self::detached) control: there is no file, so there is no
    /// answer — which is a different statement from "nothing was skipped" and is never
    /// collapsed into it.
    ///
    /// The counts describe the LOAD, not the running session. They are taken at replay and
    /// do not move as this session appends, which is exactly the question being asked: what
    /// did the app fail to pick up from the last time it ran?
    pub fn intake_health(&self) -> Option<IntakeHealth> {
        self.inner.intake.lock().unwrap().as_ref().map(|l| l.health())
    }

    /// Every intake record on disk this build could not replay, with the reason for each.
    /// Empty for a detached control, which has no file to read.
    pub fn skipped_intake(&self) -> Vec<SkippedRecord> {
        self.inner.intake.lock().unwrap().as_ref().map(|l| l.skipped_records().to_vec()).unwrap_or_default()
    }

    /// Mark everything up to `through` handled. Called only after the corresponding ledger
    /// write has returned.
    pub fn mark_drained(&self, through: u64) -> Result<(), SteeringError> {
        let mut guard = self.inner.intake.lock().unwrap();
        match guard.as_mut() {
            Some(log) => log.mark_drained(through),
            None => Ok(()),
        }
    }
}

impl Default for TurnControl {
    fn default() -> Self {
        TurnControl::detached()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tmp(tag: &str) -> PathBuf {
        std::env::temp_dir().join(format!("richos-intake-{tag}-{}-{}.jsonl", std::process::id(), now_millis()))
    }

    struct RecordingCancel(Arc<Mutex<usize>>, bool);
    impl TurnCancel for RecordingCancel {
        fn cancel(&self) -> bool {
            *self.0.lock().unwrap() += 1;
            self.1
        }
    }

    fn active() -> ActiveTurn {
        ActiveTurn {
            turn_id: "turn_1".into(),
            thread_id: "thr_1".into(),
            entity_id: None,
            started_at: Some(1_000),
        }
    }

    #[test]
    fn a_stop_request_is_on_disk_before_the_lease_is_ever_touched() {
        // §9.3's step ORDER, proven by making the cancel seam read the file it must not be
        // able to beat: if the write happened after the cancel, this read finds nothing.
        struct ReadsTheLog(PathBuf, Arc<Mutex<bool>>);
        impl TurnCancel for ReadsTheLog {
            fn cancel(&self) -> bool {
                let text = std::fs::read_to_string(&self.0).unwrap_or_default();
                *self.1.lock().unwrap() = text.contains("\"record\":\"stop\"");
                true
            }
        }
        let path = tmp("order");
        let ctl = TurnControl::open(&path).unwrap();
        ctl.begin_turn(active());
        let saw = Arc::new(Mutex::new(false));
        ctl.set_cancel(Some(Arc::new(ReadsTheLog(path.clone(), saw.clone()))));

        ctl.request_stop().unwrap();
        assert!(*saw.lock().unwrap(), "the stop request must be durable BEFORE the lease is cancelled");
        let _ = std::fs::remove_file(&path);
    }

    #[test]
    fn stopping_nothing_is_an_answer_not_an_error() {
        let path = tmp("nothing");
        let ctl = TurnControl::open(&path).unwrap();
        let calls = Arc::new(Mutex::new(0));
        ctl.set_cancel(Some(Arc::new(RecordingCancel(calls.clone(), true))));
        assert_eq!(ctl.request_stop().unwrap(), StopOutcome::NothingRunning);
        assert_eq!(*calls.lock().unwrap(), 0, "nothing was running, so nothing was cancelled");
        let _ = std::fs::remove_file(&path);
    }

    #[test]
    fn a_cancel_that_reached_nothing_is_reported_as_reaching_nothing() {
        let path = tmp("unreached");
        let ctl = TurnControl::open(&path).unwrap();
        ctl.begin_turn(active());
        // No cancel seam installed at all — the honest degrade.
        match ctl.request_stop().unwrap() {
            StopOutcome::Requested { reached_lease, .. } => assert!(!reached_lease),
            other => panic!("expected Requested, got {other:?}"),
        }
        // And with a seam that says it delivered nothing.
        let calls = Arc::new(Mutex::new(0));
        ctl.set_cancel(Some(Arc::new(RecordingCancel(calls.clone(), false))));
        ctl.begin_turn(active());
        match ctl.request_stop().unwrap() {
            StopOutcome::Requested { reached_lease, .. } => assert!(!reached_lease),
            other => panic!("expected Requested, got {other:?}"),
        }
        assert_eq!(*calls.lock().unwrap(), 1);
        let _ = std::fs::remove_file(&path);
    }

    #[test]
    fn without_a_durable_intake_a_stop_is_refused_rather_than_faked() {
        let ctl = TurnControl::detached();
        ctl.begin_turn(active());
        assert!(matches!(ctl.request_stop(), Err(SteeringError::NoDurableIntake)));
        assert!(matches!(ctl.steer("go on then"), Err(SteeringError::NoDurableIntake)));
    }

    #[test]
    fn steering_with_nothing_running_is_refused_so_it_never_becomes_a_second_send_path() {
        let path = tmp("nosteer");
        let ctl = TurnControl::open(&path).unwrap();
        assert!(matches!(ctl.steer("hello"), Err(SteeringError::NoActiveTurn)));
        let _ = std::fs::remove_file(&path);
    }

    #[test]
    fn undrained_records_survive_a_reopen_and_drained_ones_do_not() {
        let path = tmp("replay");
        {
            let ctl = TurnControl::open(&path).unwrap();
            ctl.begin_turn(active());
            let a = ctl.steer("first").unwrap();
            ctl.steer("second").unwrap();
            ctl.mark_drained(a.id()).unwrap();
        }
        let reopened = TurnControl::open(&path).unwrap();
        let pending = reopened.pending_intake();
        assert_eq!(pending.len(), 1);
        match &pending[0] {
            IntakeRecord::Steer { text, .. } => assert_eq!(text, "second"),
            other => panic!("expected the undrained steer, got {other:?}"),
        }
        // And ids keep climbing past the drained ones, so a replayed record can never
        // collide with a fresh one.
        reopened.begin_turn(active());
        assert!(reopened.steer("third").unwrap().id() > pending[0].id());
        let _ = std::fs::remove_file(&path);
    }

    #[test]
    fn a_torn_final_line_is_skipped_and_the_rest_of_the_log_still_replays() {
        let path = tmp("torn");
        {
            let ctl = TurnControl::open(&path).unwrap();
            ctl.begin_turn(active());
            ctl.steer("intact").unwrap();
        }
        // Simulate the power going out mid-write.
        let mut f = std::fs::OpenOptions::new().append(true).open(&path).unwrap();
        f.write_all(b"{\"record\":\"steer\",\"id\":9,\"thre").unwrap();
        drop(f);

        let reopened = TurnControl::open(&path).unwrap();
        assert_eq!(reopened.pending_intake().len(), 1);
        let _ = std::fs::remove_file(&path);
    }

    #[test]
    fn a_stop_claim_belongs_to_one_turn_and_never_falls_through_onto_the_next() {
        let path = tmp("claim");
        let ctl = TurnControl::open(&path).unwrap();
        ctl.begin_turn(active());
        ctl.request_stop().unwrap();
        assert!(ctl.stop_claim_for("turn_1").is_some());
        assert!(ctl.stop_claim_for("turn_2").is_none(), "a stop is a statement about ONE turn");
        let _ = std::fs::remove_file(&path);
    }

    #[test]
    fn a_full_drain_compacts_the_file_without_ever_emptying_it() {
        let path = tmp("compact");
        let ctl = TurnControl::open(&path).unwrap();
        ctl.begin_turn(active());
        // Two lines per action (the steer, then its drain marker), so this crosses
        // COMPACT_AFTER_LINES = 256 with room to spare.
        for i in 0..200 {
            let r = ctl.steer(&format!("msg {i}")).unwrap();
            ctl.mark_drained(r.id()).unwrap();
        }
        let text = std::fs::read_to_string(&path).unwrap();
        let lines: Vec<&str> = text.lines().filter(|l| !l.trim().is_empty()).collect();
        assert!(lines.len() < 256, "a fully drained log compacts; got {} lines", lines.len());
        assert!(!lines.is_empty(), "compaction must never leave the file empty");

        // And it still replays to the same place.
        let reopened = TurnControl::open(&path).unwrap();
        assert!(reopened.pending_intake().is_empty());
        let _ = std::fs::remove_file(&path);
    }
}
