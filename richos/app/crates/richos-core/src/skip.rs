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
    /// so does a record whose bytes were mangled in place. Neither file format carries a
    /// writer version on a record, so there is nothing in the file to decide it with — see
    /// `Ledger::history_health` for the one-field change that would.
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
///   4. **A tag this build KNOWS, payload that does not fit** — `Ambiguous`. A newer
///      version that added a required field to an existing record looks exactly like a
///      record whose bytes were mangled, and nothing in the file distinguishes them.
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
        return make(
            SkipKind::Ambiguous,
            Some(tag.clone()),
            format!(
                "the record says it is a `{tag}`, which this build knows, but its fields do \
                 not fit that shape. This build cannot tell whether a newer version of \
                 RichOS changed that record or the bytes were damaged — {} carries no \
                 writer version to decide it with",
                dialect.record_noun
            ),
        );
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
