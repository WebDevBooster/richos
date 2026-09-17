//! The durable ASSIGNMENT register — what he asked for, written down before anything runs.
//!
//! The background-work spec (richos-hq `docs/plans/background-work-spec-2026-09-17.md`
//! revision 5, `9255e71a`) §1: *"An assignment turn ends when the work is registered —
//! intent recorded, receipt written — not when it settles."* This module is the receipt,
//! and nothing in it starts, prepares or waits for anything. `register` writes one file
//! and returns; §7.1's decided boundary — *"registration is the receipt, and `prepare`
//! runs on the work lease after the turn has ended"* — is only true if this path is free
//! of every second that step costs (a measured 3.0–3.8 s of guards and workspace creation
//! per assignment, spec §7.1).
//!
//! **The register is not the receipt store, and the difference is the point.** Mega
//! Lander's own work receipts (`work_status.rs`) are written by the engine and describe
//! what a worker did. This register is written by the app and describes what the CEO
//! ASKED FOR — it exists from the moment he speaks, before a workspace exists, so a crash
//! in the gap leaves a record of the request rather than a gap (spec §0 row 1). The two
//! are partitioned identically (`sha256(json([entity, thread]))`) so one thread's saved
//! work and one thread's assignments can never be read across a company boundary.
//!
//! **Two things are deliberately NOT here.** Recovery (spec row 9 / §6) is the next slice:
//! nothing in this file reconciles a state after a crash, and `Running` on disk after a
//! restart means *"it was running when we last looked"* — spec §6.2's receipt state, not a
//! status. And the window-closed process model (row 5 / §2.4) is the next slice too, so
//! `open()` exists for the update gate and the settle check and is not yet wired to an
//! exit decision.

use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};

#[derive(Debug, thiserror::Error)]
#[error("{0}")]
pub struct AssignmentError(pub String);

/// The states an assignment can be in, and the two that are kept apart on purpose.
///
/// `Blocked` is the state spec §0 row 7 exists for: the work ran to the step that would
/// change his repository, and stopped there because `integrate` is not on the permission
/// desk's allow-list (`permissions.rs:58-59`). It is NOT `Settled`, and the sentence it
/// produces is *"ready for you to approve"*, never *"done"*.
///
/// `Interrupted` is what a stop produces (spec §7.4a) and is never `Settled` either.
/// Nothing in this file ever converts one into the other; that is spec §6.1's rule, and
/// the only reason it holds here is that no transition writes `Settled` except an explicit
/// caller that witnessed a settlement.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum AssignmentState {
    /// Written down. Nothing has been prepared; no workspace exists yet.
    Registered,
    /// On the work lease, inside `richos_work.prepare`.
    Preparing,
    /// Prepared and dispatched. A worker start has been recorded.
    Running,
    /// Stopped at a decision that is his. Waiting, not finished.
    Blocked,
    /// Witnessed finishing. Never inferred, never a timeout, never a process exit.
    Settled,
    /// Registration or preparation failed. Spec §1.4: never softened into "I have started it".
    Failed,
    /// Stopped by him, or by quit. Files retained.
    Interrupted,
}

impl AssignmentState {
    /// Is this assignment still the app's problem? Used by the settle check (spec §2.9)
    /// and, in the next slice, by the update gate (§6.4) and the window-closed exit arm.
    pub fn is_open(self) -> bool {
        matches!(self, Self::Registered | Self::Preparing | Self::Running | Self::Blocked)
    }
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Registered => "registered",
            Self::Preparing => "preparing",
            Self::Running => "running",
            Self::Blocked => "blocked",
            Self::Settled => "settled",
            Self::Failed => "failed",
            Self::Interrupted => "interrupted",
        }
    }
}

/// What a notice is ABOUT, so the surface never has to parse a sentence to decide how to
/// treat it. Spec §3.7: a notice must survive being spoken.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum NoticeKind {
    /// Spec §0 row 7 / §7.8. The one sentence this whole leg exists to keep apart from "done".
    ReadyToApprove,
    Settled,
    Failed,
    Interrupted,
}

/// One thing to say to him, held on disk until he has been told.
///
/// **`delivered_at_ms` is why this is a record and not an event.** Spec §3.4: a result that
/// lands while he is away must be shown when he comes back, and §2.4a makes that survive a
/// relaunch — so the flag that says "he has seen this" has to be as durable as the notice.
/// A notice held in memory is lost in exactly the case the spec was written for.
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Notice {
    pub kind: NoticeKind,
    /// The sentence itself. Spoken-safe, no identifiers, no counts he cannot act on.
    pub text: String,
    pub raised_at_ms: u64,
    #[serde(default)]
    pub delivered_at_ms: Option<u64>,
}

/// The persisted assignment. `schema` is checked on every read: a record written by a
/// newer RichOS is refused, never half-understood.
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Assignment {
    pub schema: u32,
    pub id: String,
    /// The ECS seat this assignment's work runs on — spec §5.8c, one seat per assignment,
    /// created with it and revoked with it. Derived from the id here, never chosen by the
    /// model, and never the CEO's own seat.
    pub seat: String,
    pub entity_id: String,
    pub thread_id: String,
    /// The turn in which he gave it. Frozen for the life of the assignment (spec §3.6):
    /// the engine's completion gate wants an instruction that really was his and visible,
    /// not one that is live this second.
    pub instruction_ledger_ref: String,
    pub instruction_sha256: String,
    /// His assignment in his own terms. Bounded and single-line; see [`sanitize_title`].
    pub title: String,
    pub repositories: Vec<String>,
    pub state: AssignmentState,
    /// What the state is waiting on or stopped by. Never a stack trace.
    pub detail: String,
    pub registered_at_ms: u64,
    pub updated_at_ms: u64,
    #[serde(default)]
    pub notices: Vec<Notice>,
}

/// What a caller must supply to register. Everything else is derived here, so a model
/// cannot choose an id, a seat, a turn or a company.
#[derive(Clone, Debug)]
pub struct Registration {
    pub entity_id: String,
    pub thread_id: String,
    pub turn_id: String,
    /// The exact CEO text this assignment was taken from, for the instruction digest.
    pub instruction_text: String,
    pub title: String,
    pub repositories: Vec<String>,
}

/// What the turn ends with.
pub struct Receipt {
    pub id: String,
    pub title: String,
}

impl Receipt {
    /// Spec §1.2: names the assignment in his own terms, says it is running, says where it
    /// will show up, claims nothing about the outcome, carries no identifiers, and means
    /// the same read or spoken.
    ///
    /// **"Taken down" and not "started".** §1.3 is precise about what the receipt
    /// guarantees — the assignment is on disk — and §7.1 moved preparation off this turn,
    /// so at the moment this sentence is said no workspace exists yet. A sentence claiming
    /// one would be false for the 3.0–3.8 seconds that matter most.
    pub fn sentence(&self) -> String {
        format!(
            "I've taken down your assignment: {}. It's running now, and you'll find it \
             with your saved work. I'll tell you when there's something for you to look at.",
            self.title
        )
    }
}

/// Spec §1.4: *"A failed registration is never softened into 'I have started it'."*
pub fn failed_registration_sentence(why: &str) -> String {
    format!("I could not take that assignment down: {why} Nothing is running.")
}

/// One line, bounded, no control characters — a title travels into a spoken sentence and
/// onto his timeline, and it comes from the model.
///
/// The cap is 160 characters because the sentence it lands in is read aloud; a title that
/// has to be truncated is truncated on a word boundary and ends in a period, so the spoken
/// form never trails off mid-word.
pub fn sanitize_title(raw: &str) -> Result<String, AssignmentError> {
    let flattened: String = raw
        .chars()
        .map(|c| if c.is_control() { ' ' } else { c })
        .collect::<String>()
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ");
    if flattened.is_empty() {
        return Err(AssignmentError("an assignment needs a title in the CEO's own terms".into()));
    }
    if flattened.chars().count() <= 160 {
        return Ok(flattened);
    }
    let mut cut: String = flattened.chars().take(160).collect();
    if let Some(space) = cut.rfind(' ') {
        cut.truncate(space);
    }
    Ok(format!("{}…", cut.trim_end_matches(['.', ',', ';', ':', ' '])))
}

fn partition(entity: &str, thread: &str) -> Result<String, AssignmentError> {
    use sha2::{Digest, Sha256};
    let identity = serde_json::to_vec(&[entity, thread]).map_err(|e| AssignmentError(e.to_string()))?;
    Ok(format!("{:x}", Sha256::digest(identity)))
}

fn folder(state: &Path, entity: &str, thread: &str) -> Result<PathBuf, AssignmentError> {
    let parent = state.join("assignments");
    let root = parent.join(partition(entity, thread)?);
    if parent.is_symlink() || root.is_symlink() {
        return Err(AssignmentError("Assignment records have been redirected.".into()));
    }
    Ok(root)
}

/// Atomic, fsynced, 0600. Same shape as `ecs::write_scope`, and for the same reason: a
/// half-written assignment is a request the app cannot honor and cannot report.
fn write(path: &Path, value: &Assignment) -> Result<(), AssignmentError> {
    use std::io::Write;
    let bytes = serde_json::to_vec(value).map_err(|e| AssignmentError(e.to_string()))?;
    let parent = path.parent().ok_or_else(|| AssignmentError("assignment has no parent".into()))?;
    std::fs::create_dir_all(parent).map_err(|e| AssignmentError(e.to_string()))?;
    let temporary = parent.join(format!(".assignment-{}.incoming", uuid::Uuid::new_v4()));
    let mut options = std::fs::OpenOptions::new();
    options.create_new(true).write(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }
    let result = (|| -> std::io::Result<()> {
        let mut file = options.open(&temporary)?;
        file.write_all(&bytes)?;
        file.sync_all()?;
        std::fs::rename(&temporary, path)?;
        std::fs::File::open(parent)?.sync_all()
    })();
    if result.is_err() {
        let _ = std::fs::remove_file(&temporary);
    }
    result.map_err(|e| AssignmentError(e.to_string()))
}

pub fn now_ms() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0)
}

/// Bounded, ascii-safe identity — the same alphabet `app_workers::status` demands of a
/// session id, so a seat can never be a path component with a surprise in it.
fn usable_identity(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= 128
        && value.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_')
}

/// **The whole of the turn boundary.** One validation pass, one file, one fsync.
///
/// Nothing here spawns, prepares, binds or waits. The caller gets a [`Receipt`] and ends
/// the turn with it (spec §1.1); the work host picks the assignment up afterwards.
pub fn register(state: &Path, request: &Registration) -> Result<Receipt, AssignmentError> {
    use sha2::{Digest, Sha256};
    if !usable_identity(&request.thread_id) {
        return Err(AssignmentError("this conversation cannot be identified".into()));
    }
    if request.entity_id.is_empty() || request.entity_id.len() > 128 {
        return Err(AssignmentError("this conversation has no company binding".into()));
    }
    if request.turn_id.is_empty() || request.turn_id.len() > 128 {
        return Err(AssignmentError("this assignment has no visible turn behind it".into()));
    }
    if request.instruction_text.trim().is_empty() {
        return Err(AssignmentError("an assignment must quote what the CEO actually asked for".into()));
    }
    if request.repositories.len() > 32 {
        return Err(AssignmentError("that is more repositories than one assignment can name".into()));
    }
    for repository in &request.repositories {
        if repository.is_empty() || repository.len() > 4096 || repository.contains(['\n', '\0']) {
            return Err(AssignmentError("a named repository is not usable".into()));
        }
    }
    let title = sanitize_title(&request.title)?;
    let id = uuid::Uuid::new_v4().to_string();
    let at = now_ms();
    let record = Assignment {
        schema: 1,
        seat: format!("work-seat-{id}"),
        id: id.clone(),
        entity_id: request.entity_id.clone(),
        thread_id: request.thread_id.clone(),
        instruction_ledger_ref: format!("ledger:{}:{}", request.thread_id, request.turn_id),
        instruction_sha256: format!("{:x}", Sha256::digest(request.instruction_text.as_bytes())),
        title: title.clone(),
        repositories: request.repositories.clone(),
        state: AssignmentState::Registered,
        detail: "Written down. Preparation has not started.".into(),
        registered_at_ms: at,
        updated_at_ms: at,
        notices: Vec::new(),
    };
    let root = folder(state, &request.entity_id, &request.thread_id)?;
    write(&root.join(format!("{id}.json")), &record)?;
    Ok(Receipt { id, title })
}

fn read_one(path: &Path, entity: &str, thread: &str) -> Result<Assignment, AssignmentError> {
    let size = std::fs::symlink_metadata(path)
        .map_err(|_| AssignmentError("An assignment record could not be read.".into()))?;
    if !size.is_file() || size.len() > 256 * 1024 {
        return Err(AssignmentError("An assignment record is too large or redirected.".into()));
    }
    let bytes =
        std::fs::read(path).map_err(|_| AssignmentError("An assignment record could not be read.".into()))?;
    let record: Assignment = serde_json::from_slice(&bytes)
        .map_err(|_| AssignmentError("An assignment record is damaged or was written by a newer RichOS.".into()))?;
    if record.schema != 1 || record.entity_id != entity || record.thread_id != thread {
        return Err(AssignmentError("An assignment record has an unsupported schema or different scope.".into()));
    }
    Ok(record)
}

/// Every assignment on this thread, oldest first. A damaged record is an error, never an
/// omission — spec §6.1's rule that unreadable evidence is reported, not counted as zero.
pub fn read_all(state: &Path, entity: &str, thread: &str) -> Result<Vec<Assignment>, AssignmentError> {
    let root = folder(state, entity, thread)?;
    let entries = match std::fs::read_dir(&root) {
        Ok(entries) => entries,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(Vec::new()),
        Err(_) => return Err(AssignmentError("Assignments could not be read.".into())),
    };
    let mut paths = Vec::new();
    for entry in entries {
        let path = entry.map_err(|_| AssignmentError("Assignments could not be listed.".into()))?.path();
        if path.extension().is_some_and(|e| e == "json") {
            paths.push(path);
        }
        if paths.len() > 10000 {
            return Err(AssignmentError(
                "There are too many assignments on this conversation to read at once.".into(),
            ));
        }
    }
    paths.sort();
    let mut rows: Vec<Assignment> = Vec::new();
    for path in paths {
        rows.push(read_one(&path, entity, thread)?);
    }
    rows.sort_by_key(|row| (row.registered_at_ms, row.id.clone()));
    Ok(rows)
}

pub fn read(state: &Path, entity: &str, thread: &str, id: &str) -> Result<Assignment, AssignmentError> {
    if !usable_identity(id) {
        return Err(AssignmentError("that assignment cannot be identified".into()));
    }
    read_one(&folder(state, entity, thread)?.join(format!("{id}.json")), entity, thread)
}

/// Read, change, write — the one mutation path, so every state change goes through the
/// schema and scope checks on the way in.
fn update(
    state: &Path,
    entity: &str,
    thread: &str,
    id: &str,
    change: impl FnOnce(&mut Assignment),
) -> Result<Assignment, AssignmentError> {
    let mut record = read(state, entity, thread, id)?;
    change(&mut record);
    record.updated_at_ms = now_ms();
    write(&folder(state, entity, thread)?.join(format!("{id}.json")), &record)?;
    Ok(record)
}

/// Move an assignment's state and say what it is waiting on.
///
/// **There is no transition table here on purpose.** The one rule a table would have to
/// encode — that nothing invents a completion — is enforced at the only place that can
/// know: the caller that witnessed the settlement. A table would let this file decide that
/// `Running` "must" become `Settled`, which is spec §6.1's forbidden inference wearing a
/// state machine.
pub fn advance(
    state: &Path,
    entity: &str,
    thread: &str,
    id: &str,
    to: AssignmentState,
    detail: &str,
) -> Result<Assignment, AssignmentError> {
    let detail = sanitize_title(detail).unwrap_or_else(|_| "No detail was recorded.".into());
    update(state, entity, thread, id, |record| {
        record.state = to;
        record.detail = detail;
    })
}

/// Raise the one thing to say to him about this assignment. Held until delivered.
pub fn raise_notice(
    state: &Path,
    entity: &str,
    thread: &str,
    id: &str,
    kind: NoticeKind,
    text: &str,
) -> Result<Notice, AssignmentError> {
    let notice = Notice { kind, text: text.to_string(), raised_at_ms: now_ms(), delivered_at_ms: None };
    let held = notice.clone();
    update(state, entity, thread, id, move |record| {
        // Bounded: an assignment that somehow raised thousands of notices is a defect, and
        // the newest are the ones he needs.
        if record.notices.len() >= 64 {
            record.notices.remove(0);
        }
        record.notices.push(held);
    })?;
    Ok(notice)
}

/// One notice, with the assignment it belongs to, on its way to his screen.
#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PendingNotice {
    pub assignment_id: String,
    pub title: String,
    pub kind: NoticeKind,
    pub text: String,
    pub raised_at_ms: u64,
}

/// Everything he has not been told yet, oldest first — **and it marks them delivered.**
///
/// This is the half of spec §3.4 that makes a notice survive a relaunch: the surface reads
/// this on launch as well as on a live event, and the durable flag is what stops him being
/// told the same thing twice. It is deliberately a single call that both reads and marks,
/// because a read that leaves the marking to the caller loses the notice the moment the
/// caller is the process that exits.
pub fn take_pending_notices(
    state: &Path,
    entity: &str,
    thread: &str,
) -> Result<Vec<PendingNotice>, AssignmentError> {
    let rows = read_all(state, entity, thread)?;
    let at = now_ms();
    let mut pending = Vec::new();
    for row in rows {
        if row.notices.iter().all(|n| n.delivered_at_ms.is_some()) {
            continue;
        }
        let title = row.title.clone();
        let id = row.id.clone();
        let updated = update(state, entity, thread, &row.id, |record| {
            for notice in record.notices.iter_mut().filter(|n| n.delivered_at_ms.is_none()) {
                notice.delivered_at_ms = Some(at);
            }
        })?;
        for notice in updated.notices.iter().filter(|n| n.delivered_at_ms == Some(at)) {
            pending.push(PendingNotice {
                assignment_id: id.clone(),
                title: title.clone(),
                kind: notice.kind,
                text: notice.text.clone(),
                raised_at_ms: notice.raised_at_ms,
            });
        }
    }
    pending.sort_by_key(|n| n.raised_at_ms);
    Ok(pending)
}

/// Assignments that are still the app's problem, on every thread this state root knows.
///
/// Used by the settle check (spec §2.9) and by the work host's stop-everything path. It
/// walks partitions rather than one thread because quit does not know which conversation
/// is open, and an assignment on another thread is still running work.
pub fn open(state: &Path) -> Result<Vec<Assignment>, AssignmentError> {
    let parent = state.join("assignments");
    if parent.is_symlink() {
        return Err(AssignmentError("Assignment records have been redirected.".into()));
    }
    let partitions = match std::fs::read_dir(&parent) {
        Ok(entries) => entries,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(Vec::new()),
        Err(_) => return Err(AssignmentError("Assignments could not be read.".into())),
    };
    let mut rows = Vec::new();
    for partition in partitions {
        let directory = partition.map_err(|_| AssignmentError("Assignments could not be listed.".into()))?.path();
        if !directory.is_dir() || directory.is_symlink() {
            continue;
        }
        let files = std::fs::read_dir(&directory)
            .map_err(|_| AssignmentError("Assignments could not be read.".into()))?;
        for file in files {
            let path = file.map_err(|_| AssignmentError("Assignments could not be listed.".into()))?.path();
            if path.extension().is_some_and(|e| e == "json") {
                let bytes = std::fs::read(&path)
                    .map_err(|_| AssignmentError("An assignment record could not be read.".into()))?;
                let record: Assignment = serde_json::from_slice(&bytes).map_err(|_| {
                    AssignmentError("An assignment record is damaged or was written by a newer RichOS.".into())
                })?;
                if record.schema == 1 && record.state.is_open() {
                    rows.push(record);
                }
            }
        }
    }
    rows.sort_by_key(|row| (row.registered_at_ms, row.id.clone()));
    Ok(rows)
}

/// The sentences. They live together so the one distinction the CEO is most likely to be
/// surprised by — spec §0 row 7 — is visible in one place rather than spread across the
/// callers that raise it.
///
/// **American English, spoken-safe, comparative rather than absolute, no identifiers.**
pub mod says {
    /// Spec §0 row 7 / §7.8: *"you hear 'ready for you to approve', never 'done'."*
    pub fn ready_to_approve(title: &str) -> String {
        format!(
            "{title} is ready for you to approve. Nothing has been changed in your \
             repository yet — the last step is yours."
        )
    }
    pub fn settled(title: &str) -> String {
        format!("{title} is finished, and I've kept everything it produced with your saved work.")
    }
    /// Spec §3.7: *"A failure says what stopped and what it is waiting on."*
    pub fn failed(title: &str, waiting_on: &str) -> String {
        format!("{title} stopped before it finished. {waiting_on}")
    }
    pub fn interrupted(title: &str) -> String {
        format!("{title} was stopped. Everything it had done is kept, and nothing was landed.")
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn root() -> PathBuf {
        let path = std::env::temp_dir().join(format!("assignment-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&path).unwrap();
        path
    }

    fn registration() -> Registration {
        Registration {
            entity_id: "depot".into(),
            thread_id: "thread-one".into(),
            turn_id: "turn-7".into(),
            instruction_text: "land these three branches".into(),
            title: "landing the three branches".into(),
            repositories: vec!["/fictional/project".into()],
        }
    }

    /// Spec §1.1/§7.1: the turn boundary is the receipt, so registration must be a write
    /// and nothing else. The number is the point of the test — 3.0-3.8 s is the cost
    /// §7.1 moved OFF this turn, so a registration path that drifted into seconds would
    /// have silently undone the decision the whole ask rests on.
    ///
    /// The ceiling is 1.5 s for TEN registrations — 150 ms each against the 3.0–3.8 s one
    /// `prepare` costs, a margin of roughly twenty. It is deliberately not tighter: ten
    /// fsynced writes on a machine running the rest of this suite in parallel measured
    /// 253 ms once while this test's first ceiling was 250 ms, and a timing test that
    /// fails on load teaches people to ignore timing tests. It still fails, by an order of
    /// magnitude, the regression it exists for — a registration path that starts spawning
    /// a lease or preparing a workspace.
    #[test]
    fn registration_is_a_write_and_never_pays_for_preparation() {
        let state = root();
        let started = std::time::Instant::now();
        for _ in 0..10 {
            register(&state, &registration()).unwrap();
        }
        let elapsed = started.elapsed();
        assert!(
            elapsed < std::time::Duration::from_millis(1_500),
            "ten registrations took {elapsed:?}; registration has started paying for something"
        );
        assert_eq!(read_all(&state, "depot", "thread-one").unwrap().len(), 10);
        std::fs::remove_dir_all(state).unwrap();
    }

    #[test]
    fn a_receipt_says_it_was_taken_down_and_claims_no_outcome() {
        let state = root();
        let receipt = register(&state, &registration()).unwrap();
        let sentence = receipt.sentence();
        assert!(sentence.contains("landing the three branches"));
        assert!(sentence.contains("taken down"));
        // §1.3: the receipt does not guarantee success, and no wording may imply it.
        for forbidden in ["done", "finished", "complete", "landed", "succeeded"] {
            assert!(!sentence.to_lowercase().contains(forbidden), "receipt implied an outcome: {sentence}");
        }
        // §1.2: no identifiers.
        assert!(!sentence.contains(&receipt.id));
        // §1.4 says the opposite sentence out loud.
        let refusal = failed_registration_sentence("the work connection could not be opened.");
        assert!(refusal.contains("Nothing is running."));
        assert!(!refusal.to_lowercase().contains("started"));
        std::fs::remove_dir_all(state).unwrap();
    }

    /// Spec §5.8c: one seat per assignment. Two assignments sharing a seat is the tenth
    /// gate reproduced inside the work lease, so the seats must differ by construction.
    #[test]
    fn every_assignment_gets_its_own_seat_and_no_assignment_gets_the_ceo_seat() {
        let state = root();
        let first = register(&state, &registration()).unwrap();
        let second = register(&state, &registration()).unwrap();
        let rows = read_all(&state, "depot", "thread-one").unwrap();
        let seats: Vec<_> = rows.iter().map(|r| r.seat.clone()).collect();
        assert_eq!(seats.len(), 2);
        assert_ne!(seats[0], seats[1]);
        assert_ne!(first.id, second.id);
        for seat in &seats {
            assert!(seat.starts_with("work-seat-"), "{seat}");
            assert_ne!(seat, "ceo-default");
        }
        std::fs::remove_dir_all(state).unwrap();
    }

    /// Spec §3.6: the instruction reference is frozen at registration, and the digest is
    /// of the CEO's own words. A later turn does not move it.
    #[test]
    fn the_instruction_reference_is_frozen_at_the_turn_he_gave_it_in() {
        let state = root();
        let receipt = register(&state, &registration()).unwrap();
        let row = read(&state, "depot", "thread-one", &receipt.id).unwrap();
        assert_eq!(row.instruction_ledger_ref, "ledger:thread-one:turn-7");
        use sha2::{Digest, Sha256};
        assert_eq!(row.instruction_sha256, format!("{:x}", Sha256::digest(b"land these three branches")));
        advance(&state, "depot", "thread-one", &receipt.id, AssignmentState::Running, "Worker start recorded.")
            .unwrap();
        let later = read(&state, "depot", "thread-one", &receipt.id).unwrap();
        assert_eq!(later.instruction_ledger_ref, "ledger:thread-one:turn-7");
        std::fs::remove_dir_all(state).unwrap();
    }

    /// Spec §0 row 7 and §7.8: "ready for you to approve", never "done". The wording IS
    /// the test, and the negative half has a positive control — the same assertion run
    /// against the settled sentence, which DOES speak of finishing, so a check that passed
    /// because the assertion was vacuous would fail here.
    #[test]
    fn a_blocked_assignment_is_ready_to_approve_and_is_never_called_done() {
        let ready = says::ready_to_approve("landing the three branches");
        assert!(ready.contains("ready for you to approve"));
        for forbidden in ["done", "finished", "complete", "landed"] {
            assert!(!ready.to_lowercase().contains(forbidden), "approval notice implied completion: {ready}");
        }
        // Positive control: the forbidden-word scan can fail.
        let settled = says::settled("landing the three branches");
        assert!(settled.to_lowercase().contains("finished"));
        assert!(AssignmentState::Blocked.is_open(), "blocked is waiting for him, not settled");
        assert!(!AssignmentState::Settled.is_open());
        assert!(!AssignmentState::Interrupted.is_open());
    }

    /// Spec §3.4: a notice is held until he has been told, and taking it marks it. The
    /// second read returns nothing — that is what stops him hearing it twice after a
    /// relaunch, and the durable flag is the only reason it survives one.
    #[test]
    fn a_notice_is_held_until_he_is_told_and_is_only_told_once() {
        let state = root();
        let receipt = register(&state, &registration()).unwrap();
        advance(&state, "depot", "thread-one", &receipt.id, AssignmentState::Blocked, "Waiting for your approval.")
            .unwrap();
        raise_notice(
            &state,
            "depot",
            "thread-one",
            &receipt.id,
            NoticeKind::ReadyToApprove,
            &says::ready_to_approve(&receipt.title),
        )
        .unwrap();
        let first = take_pending_notices(&state, "depot", "thread-one").unwrap();
        assert_eq!(first.len(), 1);
        assert_eq!(first[0].kind, NoticeKind::ReadyToApprove);
        assert!(first[0].text.contains("ready for you to approve"));
        // The flag is on disk, not in memory: re-read from the path a relaunch would use.
        let second = take_pending_notices(&state, "depot", "thread-one").unwrap();
        assert!(second.is_empty(), "a notice was delivered twice: {second:?}");
        let row = read(&state, "depot", "thread-one", &receipt.id).unwrap();
        assert!(row.notices[0].delivered_at_ms.is_some());
        std::fs::remove_dir_all(state).unwrap();
    }

    /// Scope is a boundary, not a filter: a record belonging to another company is an
    /// error, never an empty list that reads as "nothing is running".
    #[test]
    fn a_record_from_another_scope_is_refused_rather_than_omitted() {
        let state = root();
        let receipt = register(&state, &registration()).unwrap();
        assert!(read_all(&state, "other", "thread-one").unwrap().is_empty());
        let path = folder(&state, "depot", "thread-one").unwrap().join(format!("{}.json", receipt.id));
        let mut row: serde_json::Value = serde_json::from_slice(&std::fs::read(&path).unwrap()).unwrap();
        row["entity_id"] = "other".into();
        std::fs::write(&path, serde_json::to_vec(&row).unwrap()).unwrap();
        assert!(read_all(&state, "depot", "thread-one").is_err());
        // And a newer schema is refused rather than half-understood.
        row["entity_id"] = "depot".into();
        row["schema"] = 2.into();
        std::fs::write(&path, serde_json::to_vec(&row).unwrap()).unwrap();
        assert!(read_all(&state, "depot", "thread-one").is_err());
        std::fs::write(&path, b"partial").unwrap();
        assert!(read_all(&state, "depot", "thread-one").is_err());
        std::fs::remove_dir_all(state).unwrap();
    }

    #[test]
    fn open_walks_every_thread_because_quit_does_not_know_which_one_is_on_screen() {
        let state = root();
        let mine = register(&state, &registration()).unwrap();
        let elsewhere = register(
            &state,
            &Registration { thread_id: "thread-two".into(), ..registration() },
        )
        .unwrap();
        assert_eq!(open(&state).unwrap().len(), 2);
        advance(&state, "depot", "thread-one", &mine.id, AssignmentState::Settled, "Witnessed finishing.").unwrap();
        let still_open = open(&state).unwrap();
        assert_eq!(still_open.len(), 1);
        assert_eq!(still_open[0].id, elsewhere.id);
        // Blocked is OPEN: it is waiting for him, and quit must still stop it and say so.
        advance(&state, "depot", "thread-two", &elsewhere.id, AssignmentState::Blocked, "Waiting for your approval.")
            .unwrap();
        assert_eq!(open(&state).unwrap().len(), 1);
        std::fs::remove_dir_all(state).unwrap();
    }

    #[test]
    fn a_title_from_the_model_is_flattened_bounded_and_never_empty() {
        assert_eq!(sanitize_title("  land   these\nthree  branches ").unwrap(), "land these three branches");
        assert!(sanitize_title("   \n\t ").is_err());
        let long = "branch ".repeat(60);
        let cut = sanitize_title(&long).unwrap();
        assert!(cut.chars().count() <= 161, "{}", cut.chars().count());
        assert!(cut.ends_with('…'));
        assert!(!cut.contains('\n'));
    }

    #[test]
    fn registration_refuses_what_it_cannot_scope_or_attest() {
        let state = root();
        let bad_thread = Registration { thread_id: "thread one".into(), ..registration() };
        assert!(register(&state, &bad_thread).is_err());
        let no_entity = Registration { entity_id: String::new(), ..registration() };
        assert!(register(&state, &no_entity).is_err());
        let no_turn = Registration { turn_id: String::new(), ..registration() };
        assert!(register(&state, &no_turn).is_err());
        let no_instruction = Registration { instruction_text: "   ".into(), ..registration() };
        assert!(register(&state, &no_instruction).is_err());
        let too_many = Registration { repositories: vec!["/r".to_string(); 33], ..registration() };
        assert!(register(&state, &too_many).is_err());
        // Positive control: the same shape with all four fixed does register.
        assert!(register(&state, &registration()).is_ok());
        std::fs::remove_dir_all(state).unwrap();
    }
}
