//! ONE VOCABULARY FOR "A RECORD ON DISK THAT THIS BUILD COULD NOT READ".
//!
//! Extracted from `ledger.rs` on 2026-09-05, behavior unchanged, so that the SECOND reader
//! to need it — `steering.rs`'s intake log, which holds the CEO's own typed words before
//! they become turns — speaks the same dialect instead of growing a parallel one. Two
//! copies of this judgment would drift, and the half that drifted would be the half that
//! decides whether a customer's damaged file is reported as damage or waved through as
//! "the future".
//!
//! **What is shared is the DECISION, not the announcement.** [`classify_line`] decides
//! *which of the three things happened* and composes a per-record sentence for an operator.
//! What the CEO is told about it is composed by each store separately
//! (`Ledger::history_health`, `IntakeLog::health`), because "part of your conversation did
//! not load" and "something you typed never reached Rich" are different statements and no
//! shared helper should be in a position to substitute one for the other.
//!
//! **Nothing in here ever holds the CEO's content.** The serde error is deliberately never
//! consulted or stored: its messages quote the offending value, and that value is his own
//! words. Every sentence below is composed here, from the line's STRUCTURE only.

use serde::{Deserialize, Serialize};

/// THE SCHEMA NUMBER THIS BUILD STAMPS ON EVERY RECORD IT APPENDS.
///
/// Spec point 18 (`richos-hq docs/plans/nightly-channel-spec-2026-09-17.md`): *"Every record
/// carries the version that wrote it."* [`Ledger::history_health`](crate::ledger::Ledger::history_health)
/// asked for exactly this field and declined to write it; the CEO's 2026-09-17 ruling
/// authorizes the change. The precedent for the SHAPE is `LAUNCH_SCHEMA_VERSION` in
/// `launch.rs` — a plain monotonic integer, not a marketing version string, because the only
/// question a reader ever asks of it is *"higher than mine, or not"*.
///
/// **That precedent is named in prose and deliberately NOT linked.** An intra-doc link would
/// spell the launch module's path, and `launch_no_outbound_tests.rs`'s
/// `no_other_module_in_the_crate_consumes_the_launch_record` scans this crate's sources as
/// TEXT for exactly that string. It cannot tell a doc reference from a use, and it should not
/// have to: the guarantee it holds — the CEO's usage history is reachable from the crate root
/// and nowhere else — is worth more than a hyperlink. Measured, not assumed: adding the link
/// turned that test red.
///
/// **It is a WRITER-SCHEMA number, not the app version.** Two builds that write the same
/// record shapes stamp the same number. It goes up when, and only when, a record shape
/// changes — which is the same event that, from point 26, carries a declared migration.
///
/// `1` is the shape every published build through v1.0.2 writes; those builds simply do not
/// say so, and [`classify_line`] treats an absent stamp as exactly that.
pub const WRITER_SCHEMA_VERSION: u32 = 1;

/// The JSON key [`WRITER_SCHEMA_VERSION`] is written under. One constant so a writer and a
/// reader can never disagree about the spelling.
pub const WRITTEN_BY_KEY: &str = "written_by";

/// Serialize one record as the line this build appends: its own JSON, plus
/// [`WRITTEN_BY_KEY`].
///
/// **No trailing newline** — every caller adds its own, next to its own
/// `ensure_line_boundary`.
///
/// **Safe against a reader that predates the field**, which is every published build:
/// serde ignores unknown fields on a known variant, pinned by
/// `ledger_forward_compat_tests.rs`. That is what makes this legal to start writing to
/// customers' disks.
///
/// A record that does not serialize to a JSON OBJECT cannot carry the stamp and is written
/// unstamped rather than refused. Nothing in this crate has that shape (every store's
/// record enum is internally tagged, which serde requires be a map), and a line that is not
/// an object is classified `Damaged` at step 2 of [`classify_line`] regardless — so the
/// fallback costs a stamp on a line no reader would trust anyway.
pub fn stamped_line<T: Serialize>(record: &T) -> Result<String, serde_json::Error> {
    let mut value = serde_json::to_value(record)?;
    if let Some(object) = value.as_object_mut() {
        object.insert(WRITTEN_BY_KEY.to_string(), serde_json::json!(WRITER_SCHEMA_VERSION));
    }
    serde_json::to_string(&value)
}

/// What a line's [`WRITTEN_BY_KEY`] says about the build that wrote it.
///
/// Only ever consulted on a line that already passed the structural checks — valid JSON, an
/// object, a plain-identifier tag — because a stamp on a line whose structure is not trusted
/// is not evidence.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum WriterStamp {
    /// No `written_by` at all: written by a build from before the field existed, or by one
    /// that is not this app.
    Absent,
    /// `written_by <= WRITER_SCHEMA_VERSION` — a writer whose record shapes this build
    /// already knows.
    AtOrBelowMine,
    /// `written_by > WRITER_SCHEMA_VERSION` — a writer with shapes this build has never
    /// seen.
    AboveMine,
}

fn writer_stamp(object: &serde_json::Map<String, serde_json::Value>) -> WriterStamp {
    match object.get(WRITTEN_BY_KEY).and_then(|v| v.as_u64()) {
        None => WriterStamp::Absent,
        Some(v) if v > u64::from(WRITER_SCHEMA_VERSION) => WriterStamp::AboveMine,
        Some(_) => WriterStamp::AtOrBelowMine,
    }
}

/// Why a record on disk was NOT folded into the projection.
///
/// A record from the future and a damaged record are not the same event and are never
/// reported as the same thing. One is the format working as intended; the other means
/// something went wrong.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum SkipKind {
    /// A well-formed JSON object carrying a type tag this build does not know.
    ///
    /// **Expected and benign.** A newer RichOS wrote a record type that did not exist when
    /// this binary was compiled — which happens the moment a customer installs an update
    /// and then reinstalls an older build, and v1.0.0, v1.0.1 and v1.0.2 are all still
    /// published. Everything else in the file loads; the record stays on disk, and a
    /// build new enough to understand it will read it.
    FromFuture,
    /// The line is not a well-formed record at all: not valid UTF-8, not valid JSON, not a
    /// JSON object, or carrying no usable type tag.
    ///
    /// **Something went wrong.** A torn append, a truncated file, damaged bytes. This is
    /// the loud one.
    Damaged,
    /// Well-formed JSON, a type tag this build KNOWS, and a payload that does not fit that
    /// tag's shape.
    ///
    /// **This build cannot tell which it is**, and says so rather than picking. A newer
    /// RichOS that added a required field to an existing record produces exactly this, and
    /// so does a record whose bytes were mangled in place.
    ///
    /// **Since spec point 18 this is the answer for UNSTAMPED records only.** A line
    /// carrying [`WRITTEN_BY_KEY`] is decided: above this build's
    /// [`WRITER_SCHEMA_VERSION`] it is [`SkipKind::FromFuture`], at or below it is
    /// [`SkipKind::Damaged`]. So this verdict now means precisely *"written before RichOS
    /// stamped its records, and nothing in the line decides it"* — a set that can only
    /// shrink as stamped records replace unstamped ones on disk.
    Ambiguous,
}

impl SkipKind {
    /// The word that goes in front of an operator-facing line. `FromFuture` is deliberately
    /// calm and the other two deliberately are not.
    pub fn label(self) -> &'static str {
        match self {
            SkipKind::FromFuture => "from a newer version",
            SkipKind::Damaged => "DAMAGED",
            SkipKind::Ambiguous => "UNDETERMINED",
        }
    }
}

/// One record that was on disk and is not in the projection.
///
/// **It holds no content.** `tag` is a record TYPE name, checked to be a plain identifier
/// before it is kept; `detail` is composed here, never taken from a parser message, because
/// serde reports the offending value and that value is the CEO's own words. The line number
/// and byte length locate the record for anyone who needs to go look; nothing here reveals
/// what it said.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct SkippedRecord {
    /// 1-based line number in the file.
    pub line: usize,
    pub kind: SkipKind,
    /// The record's type tag — `event` in the ledger, `record` in the intake log — when the
    /// line was well-formed enough to carry one AND that tag is a plain identifier. `None`
    /// otherwise.
    pub tag: Option<String>,
    /// Length of the record in bytes. Useful for spotting a truncation; reveals nothing.
    pub bytes: usize,
    /// A sentence composed by this module. Never a parser message.
    pub detail: String,
}

/// The three things that differ between one JSONL store and another.
///
/// Deliberately tiny. Everything else about the judgment — the ORDER of the checks, what
/// counts as a plain identifier, what is never salvaged — is identical for both stores and
/// is not configurable, because the moment it is configurable the two stores can disagree
/// about whether a customer's file is damaged.
pub struct SkipDialect {
    /// The JSON key that names a record's type. `"event"` in the ledger; `"record"` in the
    /// intake log.
    pub tag_key: &'static str,
    /// How one line of this file is named in a sentence, e.g. `"a ledger record"`. Used
    /// only in the `Ambiguous` sentence, where the absence of a writer version is the whole
    /// reason the build cannot decide.
    pub record_noun: &'static str,
    /// Every type tag this build knows how to fold. It is the only thing that can tell a
    /// record written by a NEWER RichOS apart from a damaged one, so each store pins it
    /// against its own record type with an exhaustive match in a test.
    pub known_tags: &'static [&'static str],
}

/// A line that is not valid UTF-8 at all — classified before it can be turned into a `&str`.
///
/// Split out because the caller has to reach this verdict from the RAW BYTES: `lines()`
/// yields `Err` for a line that is not valid UTF-8, and a `?` on that error aborts the
/// whole read over one bad byte.
pub fn not_utf8(line_no: usize, bytes: usize) -> SkippedRecord {
    SkippedRecord {
        line: line_no,
        kind: SkipKind::Damaged,
        tag: None,
        bytes,
        detail: "the line is not valid UTF-8 text, so it is not a record any version of \
                 RichOS wrote — the bytes are damaged"
            .to_string(),
    }
}

/// Decide WHY a line did not parse, using only the line's own structure.
///
/// The order of the checks is the argument:
///
///   1. **Not valid JSON at all** — a torn append or damaged bytes. `Damaged`.
///   2. **Valid JSON, not an object** — no version of RichOS has written a bare array
///      or scalar as a record. `Damaged`.
///   3. **No type tag, or a tag that is not a plain identifier** — `Damaged`. A variant
///      name is `[A-Za-z_][A-Za-z0-9_]*`, so a tag that is not one did not come out of a
///      newer RichOS; it came out of damage. This is what stops corruption from being
///      waved through as "the future".
///   4. **A tag this build KNOWS, payload that does not fit** — decided by the record's
///      own [`WRITTEN_BY_KEY`] stamp (spec point 18): above this build's
///      [`WRITER_SCHEMA_VERSION`] is `FromFuture`, at or below it is `Damaged`, and ABSENT
///      is `Ambiguous` — a newer version that added a required field to an existing record
///      looks exactly like a record whose bytes were mangled, and on an unstamped line
///      nothing in the file distinguishes them.
///
///      **The stamp is read only here, after checks 1-3 have passed**, so it is only ever
///      trusted on a line whose structure is already trusted. The residual limit, stated
///      rather than left to be discovered: damage that rewrites the stamp itself into a
///      larger integer reads as `FromFuture`. That is strictly better than today, where
///      the same line reads as `Ambiguous` and decides nothing, and it is the reason the
///      stamp never overrides checks 1-3.
///   5. **A tag this build does not know** — `FromFuture`. The benign case.
///
/// Nothing derived from the line's CONTENT is kept. The serde error is deliberately not
/// consulted or stored: its messages quote the offending value, and that value is the
/// CEO's own words.
pub fn classify_line(line_no: usize, line: &str, dialect: &SkipDialect) -> SkippedRecord {
    let bytes = line.len();
    let make = |kind: SkipKind, tag: Option<String>, detail: String| SkippedRecord {
        line: line_no,
        kind,
        tag,
        bytes,
        detail,
    };

    let value: serde_json::Value = match serde_json::from_str(line) {
        Ok(v) => v,
        Err(e) => {
            return make(
                SkipKind::Damaged,
                None,
                format!(
                    "the line is not valid JSON (it stops making sense at column {}) — \
                     a torn write or damaged bytes",
                    e.column()
                ),
            );
        }
    };
    let object = match value.as_object() {
        Some(o) => o,
        None => {
            return make(
                SkipKind::Damaged,
                None,
                "the line is valid JSON but not an object — no version of RichOS has ever \
                 written a record in that shape"
                    .to_string(),
            );
        }
    };
    let tag = match object.get(dialect.tag_key).and_then(|v| v.as_str()) {
        Some(t) if is_plain_identifier(t) => t.to_string(),
        _ => {
            return make(
                SkipKind::Damaged,
                None,
                format!(
                    "the line carries no usable `{}` tag — every record RichOS writes \
                     names its own type, so this one is damaged",
                    dialect.tag_key
                ),
            );
        }
    };
    if dialect.known_tags.contains(&tag.as_str()) {
        // THE ONE PLACE `written_by` EARNS ITS BYTES (spec point 18).
        //
        // A known tag whose fields do not fit is the case `Ambiguous` exists for: a newer
        // RichOS that added a required field, and a record whose bytes were mangled in
        // place, produce byte-identical evidence. The stamp decides it — above mine and it
        // is the future, at or below mine and it is damage — and only where the line
        // actually carries one.
        return match writer_stamp(object) {
            WriterStamp::AboveMine => make(
                SkipKind::FromFuture,
                Some(tag.clone()),
                format!(
                    "the record is a `{tag}`, a type this build knows, in a shape it does \
                     not — and it says it was written by a newer version of RichOS \
                     (`{WRITTEN_BY_KEY}` is higher than this build's {WRITER_SCHEMA_VERSION}). \
                     Everything else in the file still loads and the record is untouched on \
                     disk"
                ),
            ),
            WriterStamp::AtOrBelowMine => make(
                SkipKind::Damaged,
                Some(tag.clone()),
                format!(
                    "the record says it is a `{tag}`, which this build knows, and that it \
                     was written at a schema this build also knows \
                     (`{WRITTEN_BY_KEY}` is not above {WRITER_SCHEMA_VERSION}) — so its \
                     fields not fitting means the bytes are damaged, not that the format \
                     moved on"
                ),
            ),
            // The whole existing corpus: every record written before this field existed.
            // Nothing in the file decides it, so this build still refuses to guess.
            WriterStamp::Absent => make(
                SkipKind::Ambiguous,
                Some(tag.clone()),
                format!(
                    "the record says it is a `{tag}`, which this build knows, but its \
                     fields do not fit that shape. This build cannot tell whether a newer \
                     version of RichOS changed that record or the bytes were damaged — \
                     {} carries no writer version (`{WRITTEN_BY_KEY}`) to decide it with",
                    dialect.record_noun
                ),
            ),
        };
    }
    make(
        SkipKind::FromFuture,
        Some(tag.clone()),
        format!(
            "the record is a `{tag}`, a type this build does not know. It was written by a \
             newer version of RichOS; everything else in the file still loads and the \
             record is untouched on disk"
        ),
    )
}

/// A Rust variant name, and therefore every type tag RichOS can ever emit.
/// Length-capped so a damaged line cannot put an arbitrarily long string into a log.
pub fn is_plain_identifier(s: &str) -> bool {
    !s.is_empty()
        && s.len() <= 64
        && s.starts_with(|c: char| c.is_ascii_alphabetic() || c == '_')
        && s.chars().all(|c| c.is_ascii_alphanumeric() || c == '_')
}

/// Pull one unsigned number off a record this build could not fold.
///
/// Callers decide WHICH skipped records this may be used on. The rule both stores follow is
/// that a `Damaged` line's numbers are not facts, so nothing is ever salvaged from one.
pub fn salvage_u64(line: &str, key: &str) -> Option<u64> {
    serde_json::from_str::<serde_json::Value>(line).ok()?.get(key)?.as_u64()
}
