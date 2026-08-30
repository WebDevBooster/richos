//! The in-app feedback channel — **the local half, and only the local half.**
//!
//! # What the CEO asked for
//!
//! RichOS asks, at some moment, *"How is RichOS doing this session?"* and offers four
//! keys: `1` Bad, `2` OK but could be better, `3` Good, `0` Dismiss. On `1` or `2` it
//! asks whether the user will let his Rich tell the RichOS developers — **fully
//! anonymized and generically** — what annoyed him and why it happened. And before any
//! of that could ever travel, **the user gets to see exactly what his RichOS would
//! say.**
//!
//! # What this version is, stated so it cannot be over-read
//!
//! **NOTHING HERE SENDS ANYTHING.** There is no transport, no endpoint, no address, no
//! background job and — deliberately — **no queue that a later version could quietly
//! flush.** An approval recorded by this module is a recorded *answer*, not a pending
//! *task*: nothing in the stored shape marks a record as owed to anybody, because a
//! field like that is exactly the seam a future "just wire it up" commit would reach
//! for. The `no_outbound_path` tests in this module assert that mechanically rather
//! than trusting this paragraph.
//!
//! # Why the prompt is not the interesting half
//!
//! The reference case this feature is built and tested against (`cs-001`, held in the
//! private record) contains five moments of real annoyance, and **all five were
//! volunteered mid-work, unprompted. None arrived at session end.** So a prompt fired at
//! a chosen moment would have caught none of them at the moment they were felt. The
//! prompt is the fallback for users who do not volunteer; catching what is already being
//! said is a later, larger piece of work. This module builds the fallback and says so.

use serde::{Deserialize, Serialize};
use std::fs::OpenOptions;
use std::io::{self, Write};
use std::path::{Path, PathBuf};

// ---------------------------------------------------------------------------
// THE PROMPT — one place, so the wording cannot drift
// ---------------------------------------------------------------------------

/// The question, verbatim.
pub const PROMPT_QUESTION: &str = "How is RichOS doing this session?";

/// The four keys, verbatim, in the CEO's order and his wording.
pub const PROMPT_OPTIONS: &str = "1: Bad | 2: OK, but could be better | 3: Good | 0: Dismiss";

/// The follow-up, offered **only** after `1` or `2` — see [`Rating::invites_report`].
pub const REPORT_OFFER: &str = "Will you let your Rich tell the RichOS developers \
— fully anonymized and generically — what annoyed you and why it happened?";

// ---------------------------------------------------------------------------
// THE RATING
// ---------------------------------------------------------------------------

/// What the user pressed, when he pressed one of the three ratings.
///
/// `0` is **not** a variant here. Dismissing is the absence of a rating, not a fourth
/// value of one, and modelling it as a variant would let "he dismissed" be counted,
/// averaged and reported as though it were an opinion. See [`PromptOutcome`].
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum Rating {
    /// `1`
    Bad,
    /// `2`
    OkButCouldBeBetter,
    /// `3`
    Good,
}

impl Rating {
    /// The digit the user actually pressed, as it appears in [`PROMPT_OPTIONS`].
    pub fn key(&self) -> char {
        match self {
            Rating::Bad => '1',
            Rating::OkButCouldBeBetter => '2',
            Rating::Good => '3',
        }
    }

    /// The label beside that digit, verbatim.
    pub fn label(&self) -> &'static str {
        match self {
            Rating::Bad => "Bad",
            Rating::OkButCouldBeBetter => "OK, but could be better",
            Rating::Good => "Good",
        }
    }

    /// Whether this rating triggers the offer to report. The CEO's design: `1` or `2`.
    ///
    /// This is the *only* place that rule is written down. A caller that wants to know
    /// whether to show [`REPORT_OFFER`] asks the rating, and cannot get it wrong by
    /// re-deriving it.
    pub fn invites_report(&self) -> bool {
        matches!(self, Rating::Bad | Rating::OkButCouldBeBetter)
    }
}

/// What the prompt returned: a rating, or a dismissal.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case", tag = "kind", content = "value")]
pub enum PromptOutcome {
    Rated(Rating),
    /// `0` — and also what a prompt closed without an answer records. Both are "the user
    /// did not rate this session", and the product has no reason to tell them apart.
    Dismissed,
}

impl PromptOutcome {
    /// Map a keypress to an outcome. Anything that is not one of the four keys is
    /// `None` — an unrecognised key is not a dismissal, it is not an answer at all, and
    /// silently recording it as one would put invented data in the store.
    pub fn from_key(key: char) -> Option<PromptOutcome> {
        match key {
            '1' => Some(PromptOutcome::Rated(Rating::Bad)),
            '2' => Some(PromptOutcome::Rated(Rating::OkButCouldBeBetter)),
            '3' => Some(PromptOutcome::Rated(Rating::Good)),
            '0' => Some(PromptOutcome::Dismissed),
            _ => None,
        }
    }

    /// The rating, if one was given.
    pub fn rating(&self) -> Option<Rating> {
        match self {
            PromptOutcome::Rated(r) => Some(*r),
            PromptOutcome::Dismissed => None,
        }
    }
}

// ---------------------------------------------------------------------------
// THE LOCAL RECORD
// ---------------------------------------------------------------------------

/// One answered (or dismissed) prompt, as it sits on this machine.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct FeedbackEntry {
    /// Ordering and labelling only — never a durability or identity signal (the
    /// append-and-flush is), per the engine's freshness doctrine.
    pub recorded_at_millis: u64,
    pub outcome: PromptOutcome,
}

impl FeedbackEntry {
    /// A record of what the user pressed, stamped now.
    pub fn new(outcome: PromptOutcome) -> Self {
        FeedbackEntry { recorded_at_millis: crate::util::now_millis(), outcome }
    }
}

/// The append-only local store: **one file, on this machine, and that is the whole
/// storage layer.**
///
/// One file rather than a directory is a deliberate, testable property. A directory
/// invites a second file beside the first — a spool, an "unsent" shard, a marker — and
/// the test suite asserts that recording produces exactly one file and nothing else.
pub struct FeedbackStore {
    path: PathBuf,
}

impl FeedbackStore {
    /// Open (creating the parent directory if needed) the store at `path`.
    pub fn open(path: impl AsRef<Path>) -> io::Result<Self> {
        let path = path.as_ref().to_path_buf();
        if let Some(dir) = path.parent() {
            std::fs::create_dir_all(dir)?;
        }
        Ok(FeedbackStore { path })
    }

    /// Where the one file is. Exposed so a caller (and the tests) can state the whole
    /// footprint of this feature on disk in one expression.
    pub fn path(&self) -> &Path {
        &self.path
    }

    /// Append one entry. Append + `flush` — the same durability posture as the machinery
    /// journal, and for the same reason: losing the last rating to a crash costs a
    /// keypress, not a message.
    ///
    /// **The unterminated-tail repair is not incidental.** A crash mid-append leaves a
    /// half-written line with no newline on it; the next append then lands on that same
    /// line and the torn record takes the *following* record down with it. That was
    /// observed, not theorised — `a_torn_line_costs_that_line_and_not_the_history`
    /// failed 1-of-2 before this existed. So a write that finds an unterminated tail
    /// closes it first, and the damage stays bounded to the one interrupted record.
    pub fn record(&self, entry: &FeedbackEntry) -> io::Result<()> {
        let line = serde_json::to_string(entry)
            .map_err(|e| io::Error::new(io::ErrorKind::InvalidData, e))?;
        let mut f = OpenOptions::new().create(true).append(true).open(&self.path)?;
        if Self::ends_mid_line(&self.path)? {
            writeln!(f)?;
        }
        writeln!(f, "{line}")?;
        f.flush()
    }

    /// Whether the file's last byte is something other than a newline — i.e. a previous
    /// write was interrupted.
    fn ends_mid_line(path: &Path) -> io::Result<bool> {
        use std::io::{Read, Seek, SeekFrom};
        let mut f = match std::fs::File::open(path) {
            Ok(f) => f,
            Err(e) if e.kind() == io::ErrorKind::NotFound => return Ok(false),
            Err(e) => return Err(e),
        };
        let len = f.metadata()?.len();
        if len == 0 {
            return Ok(false);
        }
        f.seek(SeekFrom::End(-1))?;
        let mut last = [0u8; 1];
        f.read_exact(&mut last)?;
        Ok(last[0] != b'\n')
    }

    /// Every entry, in the order they were recorded. A torn or unparsable line is
    /// skipped rather than fatal: a crash mid-append must not cost the whole history.
    pub fn entries(&self) -> io::Result<Vec<FeedbackEntry>> {
        let text = match std::fs::read_to_string(&self.path) {
            Ok(t) => t,
            Err(e) if e.kind() == io::ErrorKind::NotFound => return Ok(Vec::new()),
            Err(e) => return Err(e),
        };
        Ok(text
            .lines()
            .filter(|l| !l.trim().is_empty())
            .filter_map(|l| serde_json::from_str::<FeedbackEntry>(l).ok())
            .collect())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tmp_path(tag: &str) -> PathBuf {
        std::env::temp_dir().join(format!(
            "richos-feedback-test-{tag}-{}-{}/feedback.jsonl",
            std::process::id(),
            crate::util::now_millis()
        ))
    }

    #[test]
    fn the_four_keys_are_the_four_the_prompt_offers_and_nothing_else() {
        assert_eq!(PromptOutcome::from_key('1'), Some(PromptOutcome::Rated(Rating::Bad)));
        assert_eq!(
            PromptOutcome::from_key('2'),
            Some(PromptOutcome::Rated(Rating::OkButCouldBeBetter))
        );
        assert_eq!(PromptOutcome::from_key('3'), Some(PromptOutcome::Rated(Rating::Good)));
        assert_eq!(PromptOutcome::from_key('0'), Some(PromptOutcome::Dismissed));
        // Not a dismissal. Not anything.
        for k in ['4', '9', 'x', ' ', '\n'] {
            assert_eq!(PromptOutcome::from_key(k), None, "key {k:?} invented an answer");
        }
    }

    #[test]
    fn the_prompt_text_is_the_ceos_wording_and_the_keys_agree_with_it() {
        assert_eq!(PROMPT_QUESTION, "How is RichOS doing this session?");
        assert_eq!(PROMPT_OPTIONS, "1: Bad | 2: OK, but could be better | 3: Good | 0: Dismiss");
        // The rendered options line and the enum cannot drift: every rating's own
        // key+label must appear in it, in that form.
        for r in [Rating::Bad, Rating::OkButCouldBeBetter, Rating::Good] {
            let fragment = format!("{}: {}", r.key(), r.label());
            assert!(PROMPT_OPTIONS.contains(&fragment), "options line is missing {fragment:?}");
        }
        assert!(PROMPT_OPTIONS.contains("0: Dismiss"));
    }

    #[test]
    fn only_one_and_two_invite_the_report_offer() {
        assert!(Rating::Bad.invites_report());
        assert!(Rating::OkButCouldBeBetter.invites_report());
        assert!(!Rating::Good.invites_report(), "a good rating must not trigger the offer");
    }

    #[test]
    fn a_rating_survives_a_restart_because_it_is_read_back_off_disk() {
        let path = tmp_path("persist");
        let store = FeedbackStore::open(&path).unwrap();
        store.record(&FeedbackEntry::new(PromptOutcome::Rated(Rating::Bad))).unwrap();
        store.record(&FeedbackEntry::new(PromptOutcome::Dismissed)).unwrap();

        // A whole new handle — nothing is carried in memory.
        let reopened = FeedbackStore::open(&path).unwrap();
        let entries = reopened.entries().unwrap();
        assert_eq!(entries.len(), 2);
        assert_eq!(entries[0].outcome, PromptOutcome::Rated(Rating::Bad));
        assert_eq!(entries[1].outcome, PromptOutcome::Dismissed);

        std::fs::remove_dir_all(path.parent().unwrap()).ok();
    }

    #[test]
    fn an_unwritten_store_reads_as_empty_rather_than_failing() {
        let path = tmp_path("absent");
        let store = FeedbackStore::open(&path).unwrap();
        assert_eq!(store.entries().unwrap(), Vec::new());
        std::fs::remove_dir_all(path.parent().unwrap()).ok();
    }

    #[test]
    fn a_torn_line_costs_that_line_and_not_the_history() {
        let path = tmp_path("torn");
        let store = FeedbackStore::open(&path).unwrap();
        store.record(&FeedbackEntry::new(PromptOutcome::Rated(Rating::Good))).unwrap();
        // Simulate a crash mid-append.
        let mut f = OpenOptions::new().append(true).open(&path).unwrap();
        write!(f, "{{\"recorded_at_millis\": 1, \"outc").unwrap();
        f.flush().unwrap();
        drop(f);
        store.record(&FeedbackEntry::new(PromptOutcome::Dismissed)).unwrap();

        let entries = store.entries().unwrap();
        assert_eq!(entries.len(), 2, "the torn line should cost only itself");
        assert_eq!(entries[0].outcome, PromptOutcome::Rated(Rating::Good));
        assert_eq!(entries[1].outcome, PromptOutcome::Dismissed);
        std::fs::remove_dir_all(path.parent().unwrap()).ok();
    }

    #[test]
    fn recording_produces_exactly_one_file_and_no_second_thing_beside_it() {
        // The anti-spool assertion. If a later change adds an "unsent" shard, a marker
        // file or a lock beside the store, this test names it.
        let path = tmp_path("footprint");
        let store = FeedbackStore::open(&path).unwrap();
        store.record(&FeedbackEntry::new(PromptOutcome::Rated(Rating::Bad))).unwrap();

        let dir = path.parent().unwrap();
        let found: Vec<String> = std::fs::read_dir(dir)
            .unwrap()
            .map(|e| e.unwrap().file_name().to_string_lossy().into_owned())
            .collect();
        assert_eq!(found, vec!["feedback.jsonl".to_string()], "the store grew a second file");
        std::fs::remove_dir_all(dir).ok();
    }
}
