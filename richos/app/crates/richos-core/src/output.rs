//! THE OUTPUT RECORD — every file a thread produced, written down by a witness.
//!
//! The PRD is richos-hq `docs/prds/2026-10-05-output-side-panel.md` (§3, §4); this module is its
//! slice S1 (§12.1). The panel that shows the list is a view; the thing this module keeps is
//! **one append-only file per thread**, `<app-data>/output/<thread_id>.jsonl`, with one row per
//! WITNESSED WRITE ([`WriteRow`]), projected on read into one [`Entry`] per file.
//!
//! # Witnessed, never inferred
//!
//! A file is listed because something SAW the thread write it, never because Rich said so
//! (§1.6, §4.1). Three witnesses feed the record and nothing else may:
//!
//! - **(a)** the front desk's own completed `Write`/`Edit`/`MultiEdit`/`NotebookEdit` calls,
//!   merged per call from the machinery journal ([`witness_tool_calls`]);
//! - **(b)** the app hook's `PostToolUse` rows for the same four tools, in both leases and every
//!   worker (slice S2);
//! - **(c)** files a shell command made, seen on the disk by the hook (slice S2).
//!
//! # Identity
//!
//! A row is idempotent by its `key` (§4.4): appending a key the file already holds is a no-op,
//! so the live witness, the turn-end projection and convergence can all offer the same write
//! and it is one row. An entry is one CANONICAL path (§4.3): a file written in three turns is one
//! entry under the latest turn with `writes: 3`.
//!
//! # Every read re-stats (§4.6)
//!
//! `exists`, `bytes` and `modifiedAt` are read from the disk at projection time and never stored.
//! A deleted or moved file stays listed with `exists: false`: it is a file the thread produced,
//! and that it is gone is a fact about the Mac, not about the thread. A path that is now a
//! symbolic link, not a regular file, or a different file than the one witnessed is REFUSED at
//! projection ([`Refusal`]): it is listed, and nothing about it is read through the link.
//!
//! # Durability (§4.7)
//!
//! Append + flush, no fsync — the machinery journal's posture (`journal.rs:27`), for the same
//! reason: the sources stay the truth and the record is a converging cache of them, so a lost
//! line costs a re-projection, never a file. A write failure never fails a turn.

use crate::assignment::Assignment;
use crate::journal::MachineryJournal;
use crate::ledger::Turn;
use crate::machinery::{MachineryKind, MachineryRecord, ToolStatus};
use serde::{Deserialize, Serialize};
use std::collections::{HashMap, HashSet};
use std::io::{BufRead, BufReader, Read, Seek, SeekFrom, Write};
use std::path::{Path, PathBuf};

/// The directory under the app's data directory that holds one record per thread.
pub const OUTPUT_DIR: &str = "output";

/// The one row schema this build writes and reads. A row with another number is skipped and
/// counted, never half-understood.
pub const ROW_SCHEMA: u32 = 1;

/// The four write tools — the `Patch` class `timeline.rs` resolves from the same names
/// (`timeline::classify`). Named here rather than re-derived from an `ActivityType` because a
/// Tier-A record whose raw payload was evicted has no payload to classify, and the opening
/// record's title is where its name survives (`machinery.rs`, `content_block_start`).
pub const WRITE_TOOLS: [&str; 4] = ["Write", "Edit", "MultiEdit", "NotebookEdit"];

/// Who wrote it (§4.2).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Actor {
    /// The front-desk Rich, in the conversation.
    Rich,
    /// The back-end Rich, working an assignment for this thread.
    Backend,
    /// A worker under either of them; the row carries its name.
    Worker,
}

/// Which witness saw it (§4.2): (a), (b) or (c).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum WriteSource {
    /// (a) the front desk's own write-tool call, merged from the machinery journal.
    Tool,
    /// (b) a `PostToolUse` callback for a write tool, seen by the app hook.
    Hook,
    /// (c) a file a shell command made, seen on the disk by the app hook.
    Command,
}

/// One witnessed write (§4.2). No file content, no tool input, no command text — paths and
/// attribution only.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct WriteRow {
    pub schema: u32,
    /// The idempotency key (§4.4): `mach:<toolCallId>`, `hook:<session>:<toolUseId>` or
    /// `cmd:<session>:<canonical>:<mtimeNs>`.
    pub key: String,
    pub thread_id: String,
    /// `None` for a write between turns or one no turn could be named for.
    pub turn_id: Option<String>,
    /// Absolute, as witnessed.
    pub path: String,
    /// Canonicalized at witness time when the file existed then.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub canonical: Option<String>,
    pub actor: Actor,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub worker_name: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub agent_id: Option<String>,
    pub source: WriteSource,
    /// Epoch millis. A LABEL; order is append order.
    pub at: u64,
}

impl WriteRow {
    /// A row for a write just witnessed, canonicalizing the path NOW, which is the one moment
    /// the canonical form means "the file that was written" (§4.2).
    pub fn witnessed(
        key: String,
        thread_id: &str,
        turn_id: Option<&str>,
        path: &str,
        actor: Actor,
        source: WriteSource,
        at: u64,
    ) -> WriteRow {
        WriteRow {
            schema: ROW_SCHEMA,
            key,
            thread_id: thread_id.to_string(),
            turn_id: turn_id.map(str::to_string),
            path: path.to_string(),
            canonical: canonical_of(path),
            actor,
            worker_name: None,
            agent_id: None,
            source,
            at,
        }
    }

    /// The projection key: the canonical path, or the path as witnessed when the file did not
    /// exist to canonicalize (§4.3).
    fn file_key(&self) -> &str {
        self.canonical.as_deref().unwrap_or(&self.path)
    }
}

fn canonical_of(path: &str) -> Option<String> {
    std::fs::canonicalize(path).ok().map(|p| p.to_string_lossy().into_owned())
}

/// Why a listed file is not read through its recorded path (§5.2 steps 2–3, applied at
/// projection). The entry stays listed; nothing is followed.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Refusal {
    /// The recorded path is now a symbolic link.
    Link,
    /// The recorded path is a directory, a socket, a FIFO — not a regular file.
    NotAFile,
    /// The recorded path now resolves to a different file than the one witnessed.
    Swapped,
}

/// One file, as the panel shows it (§4.3).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Entry {
    /// `out_` + the first 16 hex digits of `sha256(threadId + canonical)` — stable, not a counter.
    pub id: String,
    pub thread_id: String,
    /// The LATEST turn that wrote it: the group it sits in.
    pub turn_id: Option<String>,
    pub first_turn_id: Option<String>,
    /// How many witnessed writes.
    pub writes: usize,
    pub path: String,
    pub name: String,
    /// The folder, shown relative to home (`~/…`) when it is under it.
    pub folder: String,
    pub kind: String,
    pub actor: Actor,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub worker_name: Option<String>,
    pub source: WriteSource,
    /// From `lstat` at read time (§4.6). `false` means nothing is at the recorded path now.
    pub exists: bool,
    pub bytes: Option<u64>,
    pub modified_at: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub refused: Option<Refusal>,
    /// The latest witnessed write.
    pub written_at: u64,
}

/// One turn's files, newest first (§6.3).
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Group {
    /// `None` is the *Between turns* group, which is always last.
    pub turn_id: Option<String>,
    pub ids: Vec<String>,
}

/// A thread's projected record.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct OutputList {
    /// Newest first: by the position of each file's latest write in append order.
    pub files: Vec<Entry>,
    /// The number the two buttons show: the number of entries (§4.3).
    pub count: usize,
    /// How many of them are no longer where they were written (§4.6's header line).
    pub missing: usize,
    /// Lines skipped because they would not parse, carried another schema, or named another
    /// thread. Counted, never fatal.
    pub corrupt: usize,
}

impl OutputList {
    /// The files grouped by the turn that last wrote them, groups newest first and the
    /// *Between turns* group last.
    pub fn groups(&self) -> Vec<Group> {
        let mut groups: Vec<Group> = Vec::new();
        let mut between: Option<Group> = None;
        for entry in &self.files {
            match &entry.turn_id {
                None => between.get_or_insert_with(|| Group { turn_id: None, ids: Vec::new() }).ids.push(entry.id.clone()),
                Some(turn) => match groups.iter_mut().find(|g| g.turn_id.as_deref() == Some(turn)) {
                    Some(group) => group.ids.push(entry.id.clone()),
                    None => groups.push(Group { turn_id: Some(turn.clone()), ids: vec![entry.id.clone()] }),
                },
            }
        }
        groups.extend(between);
        groups
    }
}

/// The rows a record file holds, in append order, and how many lines were skipped.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct RecordRead {
    pub rows: Vec<WriteRow>,
    pub corrupt: usize,
}

/// The kind (§4.5): from the extension, lowercased. Decides the preview and nothing else.
pub fn kind_of(path: &str) -> &'static str {
    let ext = Path::new(path)
        .extension()
        .and_then(|e| e.to_str())
        .map(|e| e.to_ascii_lowercase())
        .unwrap_or_default();
    match ext.as_str() {
        "md" | "markdown" => "md",
        "csv" => "csv",
        "xlsx" | "xls" | "numbers" => "xlsx",
        "docx" | "doc" | "pages" | "rtf" => "docx",
        "pptx" | "ppt" | "key" => "pptx",
        "pdf" => "pdf",
        "png" | "jpg" | "jpeg" | "gif" | "webp" | "heic" | "svg" => "png",
        "mp4" | "mov" | "m4v" | "webm" => "mp4",
        "m4a" | "mp3" | "wav" => "audio",
        "txt" | "text" | "log" | "json" | "jsonl" | "yaml" | "yml" | "toml" | "xml" | "html" | "htm" | "css"
        | "js" | "mjs" | "ts" | "tsx" | "jsx" | "rs" | "py" | "rb" | "go" | "java" | "kt" | "swift" | "c"
        | "h" | "cpp" | "hpp" | "sh" | "zsh" | "bash" | "sql" | "ini" | "cfg" | "conf" | "env" | "tsv" => "txt",
        _ => "other",
    }
}

/// The stable entry id (§4.3).
pub fn entry_id(thread_id: &str, file_key: &str) -> String {
    use sha2::{Digest, Sha256};
    let digest = Sha256::digest(format!("{thread_id}{file_key}").as_bytes());
    let hex: String = digest.iter().map(|b| format!("{b:02x}")).collect();
    format!("out_{}", &hex[..16])
}

fn folder_label(path: &str) -> String {
    let parent = Path::new(path).parent().map(|p| p.to_string_lossy().into_owned()).unwrap_or_default();
    match std::env::var("HOME") {
        Ok(home) if !home.is_empty() && (parent == home || parent.starts_with(&format!("{home}/"))) => {
            format!("~{}", &parent[home.len()..])
        }
        _ => parent,
    }
}

/// `lstat` the recorded path, never following it (§4.6, §5.2).
fn restat(path: &str, canonical: Option<&str>) -> (bool, Option<u64>, Option<u64>, Option<Refusal>) {
    let Ok(meta) = std::fs::symlink_metadata(path) else {
        return (false, None, None, None);
    };
    if meta.file_type().is_symlink() {
        return (true, None, None, Some(Refusal::Link));
    }
    if !meta.is_file() {
        return (true, None, None, Some(Refusal::NotAFile));
    }
    if let Some(recorded) = canonical {
        if canonical_of(path).as_deref() != Some(recorded) {
            return (true, None, None, Some(Refusal::Swapped));
        }
    }
    let modified = meta
        .modified()
        .ok()
        .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
        .map(|d| d.as_millis() as u64);
    (true, Some(meta.len()), modified, None)
}

/// Fold rows (append order) into entries, newest first. Pure apart from the re-stat.
pub fn project(thread_id: &str, rows: &[WriteRow]) -> Vec<Entry> {
    // file key -> (index of first row, index of latest row, write count)
    let mut order: Vec<&str> = Vec::new();
    let mut spans: HashMap<&str, (usize, usize, usize)> = HashMap::new();
    for (i, row) in rows.iter().enumerate() {
        let key = row.file_key();
        match spans.get_mut(key) {
            Some(span) => {
                span.1 = i;
                span.2 += 1;
            }
            None => {
                order.push(key);
                spans.insert(key, (i, i, 1));
            }
        }
    }
    let mut keyed: Vec<(usize, Entry)> = order
        .into_iter()
        .map(|key| {
            let (first, last, writes) = spans[key];
            let latest = &rows[last];
            let (exists, bytes, modified_at, refused) = restat(&latest.path, latest.canonical.as_deref());
            let name = Path::new(&latest.path)
                .file_name()
                .map(|n| n.to_string_lossy().into_owned())
                .unwrap_or_else(|| latest.path.clone());
            (
                last,
                Entry {
                    id: entry_id(thread_id, key),
                    thread_id: thread_id.to_string(),
                    turn_id: latest.turn_id.clone(),
                    first_turn_id: rows[first].turn_id.clone(),
                    writes,
                    path: latest.path.clone(),
                    name,
                    folder: folder_label(&latest.path),
                    kind: kind_of(&latest.path).to_string(),
                    actor: latest.actor,
                    worker_name: latest.worker_name.clone(),
                    source: latest.source,
                    exists,
                    bytes,
                    modified_at,
                    refused,
                    written_at: latest.at,
                },
            )
        })
        .collect();
    keyed.sort_by_key(|k| std::cmp::Reverse(k.0));
    keyed.into_iter().map(|(_, e)| e).collect()
}

fn usable_thread_id(thread_id: &str) -> bool {
    !thread_id.is_empty()
        && thread_id.len() <= 128
        && thread_id.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_')
}

fn invalid(what: &str) -> std::io::Error {
    std::io::Error::new(std::io::ErrorKind::InvalidInput, what.to_string())
}

/// The record store: `<app-data>/output/`.
#[derive(Debug, Clone)]
pub struct OutputStore {
    root: PathBuf,
}

impl OutputStore {
    /// A store rooted at `root` (normally `<app-data>/output`). Nothing is created until the
    /// first append.
    pub fn new(root: impl AsRef<Path>) -> Self {
        OutputStore { root: root.as_ref().to_path_buf() }
    }

    /// The store for an app data directory: `<data_dir>/output`.
    pub fn for_data_dir(data_dir: &Path) -> Self {
        Self::new(data_dir.join(OUTPUT_DIR))
    }

    pub fn root(&self) -> &Path {
        &self.root
    }

    /// `<root>/<thread_id>.jsonl`. A thread id that could name anything but one file in this
    /// directory is refused.
    pub fn record_path(&self, thread_id: &str) -> std::io::Result<PathBuf> {
        if !usable_thread_id(thread_id) {
            return Err(invalid("that thread cannot be named as an output record"));
        }
        Ok(self.root.join(format!("{thread_id}.jsonl")))
    }

    /// Append every row whose key the record does not already hold, and return the rows that
    /// were written. Idempotent by key (§4.4); a row for another thread is refused.
    ///
    /// The read of the keys and the append happen under one exclusive `flock` on the record,
    /// because two writers reach the same thread's record — the spine for the front desk and
    /// the work host for the back end — and a key checked by one and appended by both would
    /// be a duplicate row.
    pub fn append(&self, thread_id: &str, rows: &[WriteRow]) -> std::io::Result<Vec<WriteRow>> {
        if rows.iter().any(|r| r.thread_id != thread_id || r.schema != ROW_SCHEMA) {
            return Err(invalid("a row for another thread or schema cannot enter this record"));
        }
        if rows.is_empty() {
            return Ok(Vec::new());
        }
        let path = self.record_path(thread_id)?;
        std::fs::create_dir_all(&self.root)?;
        let mut file = std::fs::OpenOptions::new().create(true).read(true).append(true).open(&path)?;
        let _lock = Exclusive::take(&file)?;
        let mut existing = String::new();
        file.seek(SeekFrom::Start(0))?;
        file.read_to_string(&mut existing)?;
        let mut held: HashSet<String> = existing
            .lines()
            .filter_map(|l| serde_json::from_str::<WriteRow>(l).ok())
            .map(|r| r.key)
            .collect();
        let mut added = Vec::new();
        let mut text = String::new();
        for row in rows {
            if held.insert(row.key.clone()) {
                let line = serde_json::to_string(row)
                    .map_err(|e| std::io::Error::new(std::io::ErrorKind::InvalidData, e))?;
                text.push_str(&line);
                text.push('\n');
                added.push(row.clone());
            }
        }
        if !text.is_empty() {
            crate::util::ensure_line_boundary(&mut file)?;
            file.write_all(text.as_bytes())?;
            // flush, NOT sync_data — the machinery journal's posture (§4.7).
            file.flush()?;
        }
        Ok(added)
    }

    /// Every row the record holds, in append order. A line that will not parse, carries
    /// another schema or names another thread is skipped and counted; a key seen twice keeps
    /// its first row. A record that does not exist yet is empty, not an error.
    pub fn read(&self, thread_id: &str) -> std::io::Result<RecordRead> {
        let path = self.record_path(thread_id)?;
        let file = match std::fs::File::open(&path) {
            Ok(f) => f,
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(RecordRead::default()),
            Err(e) => return Err(e),
        };
        let mut out = RecordRead::default();
        let mut seen = HashSet::new();
        for line in BufReader::new(file).lines() {
            let line = line?;
            if line.trim().is_empty() {
                continue;
            }
            match serde_json::from_str::<WriteRow>(&line) {
                Ok(row) if row.schema == ROW_SCHEMA && row.thread_id == thread_id => {
                    if seen.insert(row.key.clone()) {
                        out.rows.push(row);
                    }
                }
                _ => out.corrupt += 1,
            }
        }
        Ok(out)
    }

    /// The record, projected and re-stated (§4.3, §4.6). No convergence: this is exactly what
    /// the file holds.
    pub fn project(&self, thread_id: &str) -> std::io::Result<OutputList> {
        let read = self.read(thread_id)?;
        let files = project(thread_id, &read.rows);
        Ok(OutputList {
            count: files.len(),
            missing: files.iter().filter(|e| !e.exists).count(),
            files,
            corrupt: read.corrupt,
        })
    }

    /// Converge the record with its sources (§4.7): append every witnessed write the sources
    /// hold that the record does not. Returns the rows appended.
    pub fn converge(&self, thread_id: &str, sources: &Sources) -> std::io::Result<Vec<WriteRow>> {
        let mut rows = Vec::new();
        if let Some(journal) = sources.machinery {
            rows.extend(witness_tool_calls(&journal.read_thread(thread_id)));
        }
        rows.retain(|r| r.thread_id == thread_id);
        self.append(thread_id, &rows)
    }

    /// `list(thread)`: converge, then project. What `list_output` answers (§5.4).
    pub fn list(&self, thread_id: &str, sources: &Sources) -> std::io::Result<OutputList> {
        // A convergence that could not write is not a list that cannot be read: the record
        // still says what it holds, and the next list tries again.
        if let Err(e) = self.converge(thread_id, sources) {
            eprintln!("[richos] output: could not converge this thread's record: {e}");
        }
        self.project(thread_id)
    }
}

/// An exclusive `flock` held for one append, released on drop.
struct Exclusive {
    #[cfg(unix)]
    fd: std::os::fd::RawFd,
}

impl Exclusive {
    fn take(file: &std::fs::File) -> std::io::Result<Exclusive> {
        #[cfg(unix)]
        {
            use std::os::fd::AsRawFd;
            let fd = file.as_raw_fd();
            if unsafe { libc::flock(fd, libc::LOCK_EX) } != 0 {
                return Err(std::io::Error::last_os_error());
            }
            Ok(Exclusive { fd })
        }
        #[cfg(not(unix))]
        {
            let _ = file;
            Ok(Exclusive {})
        }
    }
}

impl Drop for Exclusive {
    fn drop(&mut self) {
        #[cfg(unix)]
        unsafe {
            libc::flock(self.fd, libc::LOCK_UN);
        }
    }
}

/// What convergence reads (§4.7). Every source is optional: a store with none attached
/// projects exactly what its file holds.
#[derive(Default, Clone, Copy)]
pub struct Sources<'a> {
    /// The machinery journal: witness (a), from Tier A, which is never evicted.
    pub machinery: Option<&'a MachineryJournal>,
    /// The ledger's turns (the thread's, or all of them: the join filters).
    pub turns: &'a [Turn],
    /// The thread's assignments.
    pub assignments: &'a [Assignment],
    /// `<app-data>/engine-state/evidence`: witnesses (b) and (c).
    pub evidence_root: Option<&'a Path>,
}

// ---- witness (a): the front desk's own write-tool calls ---------------------

/// Witness (a) over machinery records (§4.1 (a)): every MERGED tool call whose name is one of
/// the four write tools, whose status is `Completed` and whose merged locations are non-empty.
///
/// **Evaluated on the merged call, never on one record** (Frank's minor 1): on the native wire
/// the name is on the opening `content_block_start`, the arguments on the `assistant` frame and
/// `Completed` on the `tool_result`, so no single record is a completed write. The merge is
/// `machinery::merge_into`, the one the journal's projection and the live path use.
///
/// The name is read from a record's payload where the raw payload survives
/// (`timeline::tool_name_of`), else from the OPENING record's title, which is the tool name by
/// construction (`machinery.rs`, `content_block_start`) and is kept in Tier A after the raw
/// payload is evicted. Internal records (re-prime, rotation) are not the thread's work.
pub fn witness_tool_calls(records: &[MachineryRecord]) -> Vec<WriteRow> {
    let mut order: Vec<String> = Vec::new();
    let mut merged: HashMap<String, MachineryRecord> = HashMap::new();
    let mut names: HashMap<String, String> = HashMap::new();
    for record in records {
        if record.internal || record.kind != MachineryKind::ToolCall {
            continue;
        }
        let Some(id) = record.tool_call_id.clone() else { continue };
        if !names.contains_key(&id) {
            let from_payload = record.payload.as_ref().and_then(crate::timeline::tool_name_of);
            let from_open = (record.status == Some(ToolStatus::Pending) && !record.title.is_empty())
                .then_some(record.title.as_str());
            if let Some(name) = from_payload.or(from_open) {
                names.insert(id.clone(), name.to_string());
            }
        }
        match merged.get_mut(&id) {
            Some(base) => crate::machinery::merge_into(base, record.clone()),
            None => {
                order.push(id.clone());
                merged.insert(id, record.clone());
            }
        }
    }
    let mut rows = Vec::new();
    for id in order {
        let call = &merged[&id];
        let is_write = names.get(&id).is_some_and(|n| WRITE_TOOLS.contains(&n.as_str()));
        if !is_write || call.status != Some(ToolStatus::Completed) || call.locations.is_empty() {
            continue;
        }
        rows.extend(tool_call_rows(call));
    }
    rows
}

/// The rows one completed write-tool call produces: one per location, keyed `mach:<id>` (and
/// `mach:<id>#<n>` for a second and later location, which no observed write tool produces).
pub(crate) fn tool_call_rows(call: &MachineryRecord) -> Vec<WriteRow> {
    let Some(id) = call.tool_call_id.as_deref() else { return Vec::new() };
    call.locations
        .iter()
        .filter(|p| Path::new(p).is_absolute())
        .enumerate()
        .map(|(n, path)| {
            let key = if n == 0 { format!("mach:{id}") } else { format!("mach:{id}#{n}") };
            WriteRow::witnessed(key, &call.thread_id, call.turn_id.as_deref(), path, Actor::Rich, WriteSource::Tool, call.at)
        })
        .collect()
}

// ---- the session join (§4.1 (b)) ------------------------------------------------

/// Which lease a session is.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Lease {
    /// A front-desk lease: one serves one thread (`spine.rs`, the pinned `(entity, thread)`).
    FrontDesk,
    /// A back-end lease: one per thread (`work_host.rs`, `backends`).
    Backend,
}

/// A session joined to a thread.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Joined {
    pub thread_id: String,
    pub turn_id: Option<String>,
    pub lease: Lease,
}

/// One front-desk turn the ledger started on a session.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FrontDeskTurn {
    pub session_id: String,
    pub thread_id: String,
    pub turn_id: String,
    pub started_at: u64,
}

/// One assignment a back-end session worked.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BackendWork {
    pub session_id: String,
    pub thread_id: String,
    /// The turn in which he gave it (`instruction_ledger_ref`), the group its files sit in.
    pub turn_id: Option<String>,
    pub registered_at: u64,
}

/// The session → thread join (§4.1 (b)): a pure function over the ledger's turns and the
/// assignments. A session no thread names, or one that names more than one thread, joins
/// nothing — a misattributed row is worse than a missing one (`worker_events.rs`'s rule).
#[derive(Debug, Clone, Default)]
pub struct SessionJoin {
    front: HashMap<String, Vec<FrontDeskTurn>>,
    back: HashMap<String, Vec<BackendWork>>,
}

impl SessionJoin {
    /// Built from the ledger's turns (every turn with a session is a `TurnStarted` the ledger
    /// recorded; a quarantined turn is excluded, as from every scoped projection) and the
    /// assignments' `work_session`s.
    pub fn new(turns: &[Turn], assignments: &[Assignment]) -> Self {
        let front = turns
            .iter()
            .filter(|t| !t.quarantined)
            .filter_map(|t| {
                let session = t.session_id.as_deref().filter(|s| !s.is_empty())?;
                Some(FrontDeskTurn {
                    session_id: session.to_string(),
                    thread_id: t.thread_id.clone(),
                    turn_id: t.id.clone(),
                    started_at: t.started_at.unwrap_or(t.created_at),
                })
            })
            .collect();
        let back = assignments
            .iter()
            .filter_map(|a| {
                let session = a.work_session.as_deref().filter(|s| !s.is_empty())?;
                let turn = a
                    .instruction_ledger_ref
                    .strip_prefix(&format!("ledger:{}:", a.thread_id))
                    .filter(|t| !t.is_empty())
                    .map(str::to_string);
                Some(BackendWork {
                    session_id: session.to_string(),
                    thread_id: a.thread_id.clone(),
                    turn_id: turn,
                    registered_at: a.registered_at_ms,
                })
            })
            .collect();
        Self::from_parts(front, back)
    }

    pub fn from_parts(front: Vec<FrontDeskTurn>, back: Vec<BackendWork>) -> Self {
        let mut join = SessionJoin::default();
        for t in front {
            join.front.entry(t.session_id.clone()).or_default().push(t);
        }
        for w in back {
            join.back.entry(w.session_id.clone()).or_default().push(w);
        }
        for turns in join.front.values_mut() {
            turns.sort_by_key(|t| t.started_at);
        }
        for works in join.back.values_mut() {
            works.sort_by_key(|w| w.registered_at);
        }
        join
    }

    /// Every session this join names.
    pub fn sessions(&self) -> Vec<String> {
        let mut out: Vec<String> = self.front.keys().chain(self.back.keys()).cloned().collect();
        out.sort();
        out.dedup();
        out
    }

    /// The thread (and turn) a write on `session_id` at `at` belongs to, or `None`.
    ///
    /// The THREAD is a ledger fact and needs no clock. The TURN is the latest one that started
    /// on this session at or before the write (front desk), or the latest assignment
    /// registered at or before it (back end) — a label for grouping, inside a thread that is
    /// already certain.
    pub fn resolve(&self, session_id: &str, at: u64) -> Option<Joined> {
        let front = self.front.get(session_id);
        let back = self.back.get(session_id);
        match (front, back) {
            (Some(_), Some(_)) | (None, None) => None,
            (Some(turns), None) => {
                let thread = single_thread(turns.iter().map(|t| t.thread_id.as_str()))?;
                let turn = turns.iter().rev().find(|t| t.started_at <= at).map(|t| t.turn_id.clone());
                Some(Joined { thread_id: thread, turn_id: turn, lease: Lease::FrontDesk })
            }
            (None, Some(works)) => {
                let thread = single_thread(works.iter().map(|w| w.thread_id.as_str()))?;
                let work = works.iter().rev().find(|w| w.registered_at <= at).or_else(|| works.first());
                Some(Joined { thread_id: thread, turn_id: work.and_then(|w| w.turn_id.clone()), lease: Lease::Backend })
            }
        }
    }
}

fn single_thread<'a>(mut threads: impl Iterator<Item = &'a str>) -> Option<String> {
    let first = threads.next()?;
    threads.all(|t| t == first).then(|| first.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    struct Dir(PathBuf);
    impl Dir {
        fn new(tag: &str) -> Dir {
            let p = std::env::temp_dir().join(crate::util::new_id(tag));
            std::fs::create_dir_all(&p).unwrap();
            // Canonical from the start, so `/var` → `/private/var` on macOS never makes a
            // recorded path and a compared path two spellings of one file.
            Dir(std::fs::canonicalize(&p).unwrap())
        }
        fn file(&self, name: &str, body: &str) -> String {
            let p = self.0.join(name);
            std::fs::write(&p, body).unwrap();
            p.to_string_lossy().into_owned()
        }
    }
    impl Drop for Dir {
        fn drop(&mut self) {
            if let Err(e) = std::fs::remove_dir_all(&self.0) {
                eprintln!("test scratch {} was not removed: {e}", self.0.display());
            }
        }
    }

    fn row(key: &str, turn: Option<&str>, path: &str) -> WriteRow {
        WriteRow::witnessed(key.into(), "thr_out", turn, path, Actor::Rich, WriteSource::Tool, 1)
    }

    /// The three wire frames of one native `Write` call, in the shape `machinery.rs`'s own tests
    /// use (`run9-rust-driven.jsonl`): the streamed open, the `assistant` arguments, the
    /// `tool_result` close carrying `tool_use_result.filePath`.
    fn write_call(id: &str, path: &str, turn: &str) -> Vec<MachineryRecord> {
        let frames = [
            json!({"type":"stream_event","event":{"type":"content_block_start","index":0,
                   "content_block":{"type":"tool_use","id":id,"name":"Write","input":{}}},
                   "session_id":"sess","parent_tool_use_id":null}),
            json!({"type":"assistant","message":{"content":[{"type":"tool_use","id":id,"name":"Write",
                   "input":{"file_path":path,"content":"x"}}]},"session_id":"sess","parent_tool_use_id":null}),
            json!({"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":id,
                   "content":"File created successfully"}]},
                   "tool_use_result":{"type":"create","filePath":path},"session_id":"sess","parent_tool_use_id":null}),
        ];
        frames
            .iter()
            .enumerate()
            .flat_map(|(i, f)| MachineryRecord::from_native_event(f, "sess", i as u64))
            .map(|r| r.stamp("thr_out", Some(turn), false))
            .collect()
    }

    #[test]
    fn output_append_is_idempotent_by_key() {
        let dir = Dir::new("output-idem");
        let file = dir.file("a.md", "a");
        let store = OutputStore::new(dir.0.join("output"));
        let r = row("mach:toolu_1", Some("turn_1"), &file);
        assert_eq!(store.append("thr_out", std::slice::from_ref(&r)).unwrap().len(), 1);
        assert_eq!(store.append("thr_out", &[r.clone(), r.clone()]).unwrap().len(), 0);
        let read = store.read("thr_out").unwrap();
        assert_eq!(read.rows, vec![r]);
        assert_eq!(read.corrupt, 0);
    }

    #[test]
    fn output_three_writes_to_one_path_across_two_turns_are_one_entry_under_the_latest_turn() {
        let dir = Dir::new("output-three");
        let file = dir.file("brief.md", "v3");
        let store = OutputStore::new(dir.0.join("output"));
        store
            .append(
                "thr_out",
                &[row("mach:a", Some("turn_1"), &file), row("mach:b", Some("turn_1"), &file), row("mach:c", Some("turn_2"), &file)],
            )
            .unwrap();
        let list = store.project("thr_out").unwrap();
        assert_eq!(list.count, 1);
        let entry = &list.files[0];
        assert_eq!(entry.writes, 3);
        assert_eq!(entry.turn_id.as_deref(), Some("turn_2"));
        assert_eq!(entry.first_turn_id.as_deref(), Some("turn_1"));
        assert_eq!(entry.name, "brief.md");
        assert_eq!(entry.kind, "md");
        assert_eq!(entry.bytes, Some(2));
        assert!(entry.exists);
        assert_eq!(entry.id, entry_id("thr_out", &file));
    }

    #[test]
    fn output_a_missing_file_stats_exists_false_and_stays_listed() {
        let dir = Dir::new("output-missing");
        let file = dir.file("gone.csv", "a,b");
        let store = OutputStore::new(dir.0.join("output"));
        store.append("thr_out", &[row("mach:a", Some("turn_1"), &file)]).unwrap();
        std::fs::remove_file(&file).unwrap();
        let list = store.project("thr_out").unwrap();
        assert_eq!((list.count, list.missing), (1, 1));
        assert!(!list.files[0].exists);
        assert_eq!(list.files[0].bytes, None);
        assert_eq!(list.files[0].path, file);
    }

    #[test]
    fn output_a_symlinked_path_is_refused_at_project_time() {
        let dir = Dir::new("output-link");
        let target = dir.file("secret.txt", "do not follow");
        let link = dir.0.join("innocent.md");
        std::os::unix::fs::symlink(&target, &link).unwrap();
        let link = link.to_string_lossy().into_owned();
        let store = OutputStore::new(dir.0.join("output"));
        // Witnessed as a regular file, then swapped for a link: both spellings refuse.
        let plain = dir.file("plain.md", "x");
        store.append("thr_out", &[row("mach:link", Some("turn_1"), &link), row("mach:plain", Some("turn_1"), &plain)]).unwrap();
        std::fs::remove_file(&plain).unwrap();
        std::os::unix::fs::symlink(&target, &plain).unwrap();
        let list = store.project("thr_out").unwrap();
        assert_eq!(list.count, 2);
        for entry in &list.files {
            assert_eq!(entry.refused, Some(Refusal::Link), "{entry:?}");
            assert_eq!(entry.bytes, None, "nothing is read through a link: {entry:?}");
        }
        // A directory where a file was is not a file.
        let was_file = dir.file("now-a-dir.md", "x");
        store.append("thr_out", &[row("mach:dir", Some("turn_1"), &was_file)]).unwrap();
        std::fs::remove_file(&was_file).unwrap();
        std::fs::create_dir(&was_file).unwrap();
        let list = store.project("thr_out").unwrap();
        assert_eq!(list.files[0].refused, Some(Refusal::NotAFile));
    }

    #[test]
    fn output_a_corrupt_line_is_skipped_and_counted() {
        let dir = Dir::new("output-corrupt");
        let file = dir.file("ok.md", "x");
        let store = OutputStore::new(dir.0.join("output"));
        store.append("thr_out", &[row("mach:1", Some("turn_1"), &file)]).unwrap();
        let path = store.record_path("thr_out").unwrap();
        let mut f = std::fs::OpenOptions::new().append(true).open(&path).unwrap();
        // A torn line, a row of a schema this build does not know, and a row for another thread.
        let mut other_schema = serde_json::to_value(row("mach:2", None, &file)).unwrap();
        other_schema["schema"] = json!(2);
        let other_thread = serde_json::to_string(&WriteRow { thread_id: "thr_else".into(), ..row("mach:3", None, &file) }).unwrap();
        write!(f, "{{\"schema\":1,\"key\":\n{other_schema}\n{other_thread}\n").unwrap();
        drop(f);
        // The next append starts on a line boundary and is read.
        let second = dir.file("two.md", "y");
        assert_eq!(store.append("thr_out", &[row("mach:4", Some("turn_2"), &second)]).unwrap().len(), 1);
        let list = store.project("thr_out").unwrap();
        assert_eq!(list.corrupt, 3);
        assert_eq!(list.count, 2);
    }

    #[test]
    fn output_a_row_for_another_thread_or_a_crafted_thread_id_is_refused() {
        let dir = Dir::new("output-refuse");
        let store = OutputStore::new(dir.0.join("output"));
        let r = WriteRow { thread_id: "thr_else".into(), ..row("mach:1", None, "/x") };
        assert!(store.append("thr_out", &[r]).is_err());
        assert!(store.record_path("../escape").is_err());
        assert!(store.record_path("").is_err());
    }

    #[test]
    fn output_kind_follows_the_extension() {
        for (path, kind) in [
            ("/a/b.MD", "md"), ("/a/b.numbers", "xlsx"), ("/a/b.pages", "docx"), ("/a/b.rtf", "docx"),
            ("/a/b.key", "pptx"), ("/a/b.pdf", "pdf"), ("/a/b.HEIC", "png"), ("/a/b.mov", "mp4"),
            ("/a/b.m4a", "audio"), ("/a/b.json", "txt"), ("/a/b.csv", "csv"), ("/a/b", "other"), ("/a/b.zip", "other"),
        ] {
            assert_eq!(kind_of(path), kind, "{path}");
        }
    }

    #[test]
    fn output_the_join_maps_a_work_session_and_a_turn_started_session_and_refuses_the_rest() {
        let join = SessionJoin::from_parts(
            vec![
                FrontDeskTurn { session_id: "desk-1".into(), thread_id: "thr_a".into(), turn_id: "turn_1".into(), started_at: 100 },
                FrontDeskTurn { session_id: "desk-1".into(), thread_id: "thr_a".into(), turn_id: "turn_2".into(), started_at: 200 },
                // One session claimed by two threads is ambiguous, and joins nothing.
                FrontDeskTurn { session_id: "desk-x".into(), thread_id: "thr_a".into(), turn_id: "turn_3".into(), started_at: 100 },
                FrontDeskTurn { session_id: "desk-x".into(), thread_id: "thr_b".into(), turn_id: "turn_4".into(), started_at: 100 },
            ],
            vec![BackendWork { session_id: "work-1".into(), thread_id: "thr_a".into(), turn_id: Some("turn_1".into()), registered_at: 150 }],
        );
        assert_eq!(
            join.resolve("desk-1", 250),
            Some(Joined { thread_id: "thr_a".into(), turn_id: Some("turn_2".into()), lease: Lease::FrontDesk })
        );
        assert_eq!(join.resolve("desk-1", 150).unwrap().turn_id.as_deref(), Some("turn_1"));
        assert_eq!(join.resolve("desk-1", 50).unwrap().turn_id, None, "before any turn is between turns");
        assert_eq!(
            join.resolve("work-1", 400),
            Some(Joined { thread_id: "thr_a".into(), turn_id: Some("turn_1".into()), lease: Lease::Backend })
        );
        assert_eq!(join.resolve("desk-x", 150), None);
        assert_eq!(join.resolve("nobody", 150), None);
    }

    #[test]
    fn output_the_join_reads_the_real_ledger_and_assignment_records() {
        let dir = Dir::new("output-join");
        let mut ledger = crate::ledger::Ledger::open(dir.0.join("ledger.jsonl")).unwrap();
        let entity = crate::entity::EntityId::parse("femcboost").unwrap();
        let thread = ledger.create_thread("acme", &entity).unwrap();
        let binding = ledger.thread_binding(&thread).unwrap();
        let turn = ledger.record_prompt_received(&binding, "write the brief", crate::ledger::Source::Text).unwrap();
        ledger.mark_turn_started(&turn, "desk-session").unwrap();
        let assignment: Assignment = serde_json::from_value(json!({
            "schema":1,"id":"asg-1","obligation_id":"obl-1","seat":"work-seat:obl-1","entity_id":"femcboost",
            "thread_id":thread,"instruction_ledger_ref":format!("ledger:{thread}:{turn}"),"instruction_sha256":"a",
            "title":"the brief","repositories":[],"state":"registered","detail":"","registered_at_ms":5,
            "updated_at_ms":5,"work_session":"work-session"}))
        .unwrap();
        let join = SessionJoin::new(ledger.turns(), &[assignment]);
        let desk = join.resolve("desk-session", u64::MAX).unwrap();
        assert_eq!((desk.thread_id.as_str(), desk.turn_id.as_deref(), desk.lease), (thread.as_str(), Some(turn.as_str()), Lease::FrontDesk));
        let work = join.resolve("work-session", u64::MAX).unwrap();
        assert_eq!((work.thread_id.as_str(), work.turn_id.as_deref(), work.lease), (thread.as_str(), Some(turn.as_str()), Lease::Backend));
        assert_eq!(join.resolve("someone-else", u64::MAX), None);
    }

    /// S1's "Done when" (§12.1): a fixture Tier A shard with three write calls across two turns
    /// — three frames each, the wire's shape — lists as three entries in two groups, newest
    /// first; the record file exists at `<app-data>/output/<thread>.jsonl`; and a fresh store
    /// over the same directory (the process restarted) replays to the same list.
    #[test]
    fn output_done_when_a_tier_a_shard_lists_three_entries_in_two_groups_and_replays() {
        let dir = Dir::new("output-done");
        let (a, b, c) = (dir.file("plan.md", "a"), dir.file("sheet.csv", "b,c"), dir.file("deck.pdf", "%PDF"));
        let journal = MachineryJournal::new(dir.0.join("machinery"));
        let mut records = write_call("toolu_A", &a, "turn_1");
        records.extend(write_call("toolu_B", &b, "turn_1"));
        records.extend(write_call("toolu_C", &c, "turn_2"));
        for r in &records {
            journal.append(r).unwrap();
        }
        // Tier B evicted: the names must survive on Tier A alone.
        for shard in std::fs::read_dir(dir.0.join("machinery/thr_out")).unwrap() {
            let p = shard.unwrap().path();
            if p.to_string_lossy().ends_with(".raw.jsonl") {
                std::fs::remove_file(p).unwrap();
            }
        }

        let data = dir.0.clone();
        let store = OutputStore::for_data_dir(&data);
        let sources = Sources { machinery: Some(&journal), ..Sources::default() };
        let list = store.list("thr_out", &sources).unwrap();
        let names: Vec<&str> = list.files.iter().map(|e| e.name.as_str()).collect();
        assert_eq!(names, ["deck.pdf", "sheet.csv", "plan.md"], "newest first");
        let groups = list.groups();
        assert_eq!(groups.len(), 2);
        assert_eq!(groups[0].turn_id.as_deref(), Some("turn_2"));
        assert_eq!(groups[0].ids.len(), 1);
        assert_eq!(groups[1].turn_id.as_deref(), Some("turn_1"));
        assert_eq!(groups[1].ids.len(), 2);
        assert!(list.files.iter().all(|e| e.actor == Actor::Rich && e.source == WriteSource::Tool));
        assert!(data.join("output/thr_out.jsonl").is_file());

        // Converging again adds nothing; a fresh store replays the same list.
        assert!(store.converge("thr_out", &sources).unwrap().is_empty());
        let replayed = OutputStore::for_data_dir(&data).project("thr_out").unwrap();
        assert_eq!(replayed, list);
    }

    #[test]
    fn output_a_write_that_did_not_complete_or_a_read_is_not_a_witnessed_write() {
        let dir = Dir::new("output-incomplete");
        let a = dir.file("a.md", "a");
        let mut records = write_call("toolu_A", &a, "turn_1");
        records.pop(); // no tool_result: never completed
        let read: Vec<MachineryRecord> = [
            json!({"type":"stream_event","event":{"type":"content_block_start","index":0,
                   "content_block":{"type":"tool_use","id":"toolu_R","name":"Read","input":{}}}}),
            json!({"type":"assistant","message":{"content":[{"type":"tool_use","id":"toolu_R","name":"Read","input":{"file_path":a}}]}}),
            json!({"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"toolu_R","content":"a"}]},
                   "tool_use_result":{"type":"text","file":{"filePath":a}}}),
        ]
        .iter()
        .flat_map(|f| MachineryRecord::from_native_event(f, "sess", 0))
        .map(|r| r.stamp("thr_out", Some("turn_1"), false))
        .collect();
        records.extend(read);
        assert!(witness_tool_calls(&records).is_empty());
    }
}
