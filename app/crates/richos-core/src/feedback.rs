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

// ---------------------------------------------------------------------------
// THE TAXONOMY — a closed vocabulary, versioned
// ---------------------------------------------------------------------------
//
// THIS IS A TYPE PROBLEM, NOT A FILTER PROBLEM, and the difference is the whole
// feature. A filter reads free text and tries to decide whether it is safe. This
// makes free text UNREPRESENTABLE: a report is assembled from terms that were
// authored once, reviewed once and compiled in, so there is no field for the user's
// specifics to occupy. It is the same move as `Timeline` refusing to implement
// `Serialize` one module over — the unsafe thing does not exist rather than being
// caught.
//
// WHY A FILTER WOULD NOT HAVE WORKED, on this feature's own reference case. The
// second negative control in `cs-001` §6 contains no proper nouns at all and is still
// disqualifying, because it discloses what the user does for a living. It reads
// "generic" to the model that wrote it and to the human who approves it. Nothing that
// inspects prose reliably catches that class; a vocabulary that has no term for it
// cannot express it at any level of care.

/// Which vocabulary a payload was assembled from.
///
/// Versioned because the vocabulary is the contract: a term added, removed or
/// re-worded changes what a payload MEANS, and a reader that guessed would silently
/// mis-read old reports. There is exactly one variant today, and a payload claiming
/// any other version fails to parse rather than being read hopefully.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum TaxonomyVersion {
    #[serde(rename = "v1")]
    V1,
}

impl TaxonomyVersion {
    pub fn wire(&self) -> &'static str {
        match self {
            TaxonomyVersion::V1 => "v1",
        }
    }
}

/// The vocabulary this build assembles reports from.
pub const TAXONOMY_VERSION: TaxonomyVersion = TaxonomyVersion::V1;

/// What kind of failure this was. Five terms, each one a way of handing the user work
/// that was not the user's work — the five distinguished by the reference case.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum FailureClass {
    #[serde(rename = "unprepared-task-handed-to-user")]
    UnpreparedTaskHandedToUser,
    #[serde(rename = "checking-handed-to-user")]
    CheckingHandedToUser,
    #[serde(rename = "assurance-handed-to-user")]
    AssuranceHandedToUser,
    #[serde(rename = "decision-handed-to-user")]
    DecisionHandedToUser,
    #[serde(rename = "scheduling-handed-to-user")]
    SchedulingHandedToUser,
}

impl FailureClass {
    /// Every term. Iterated by the UI that offers the choice and by the tests that pin
    /// the vocabulary — never typed out a second time anywhere.
    pub const ALL: &'static [FailureClass] = &[
        FailureClass::UnpreparedTaskHandedToUser,
        FailureClass::CheckingHandedToUser,
        FailureClass::AssuranceHandedToUser,
        FailureClass::DecisionHandedToUser,
        FailureClass::SchedulingHandedToUser,
    ];

    pub fn wire(&self) -> &'static str {
        match self {
            FailureClass::UnpreparedTaskHandedToUser => "unprepared-task-handed-to-user",
            FailureClass::CheckingHandedToUser => "checking-handed-to-user",
            FailureClass::AssuranceHandedToUser => "assurance-handed-to-user",
            FailureClass::DecisionHandedToUser => "decision-handed-to-user",
            FailureClass::SchedulingHandedToUser => "scheduling-handed-to-user",
        }
    }

    /// The plain sentence a user picks from, and the one a developer reads.
    pub fn label(&self) -> &'static str {
        match self {
            FailureClass::UnpreparedTaskHandedToUser => {
                "The assistant handed the user a task it had not prepared."
            }
            FailureClass::CheckingHandedToUser => {
                "The assistant left the user to notice a failure that machinery should have caught."
            }
            FailureClass::AssuranceHandedToUser => {
                "The assistant left the user to ask whether a class of failure would recur."
            }
            FailureClass::DecisionHandedToUser => {
                "The assistant asked the user a question whose answer was already determined."
            }
            FailureClass::SchedulingHandedToUser => {
                "The assistant left the user to sequence work it should have sequenced itself."
            }
        }
    }
}

/// How often it happened in the session.
///
/// **Closed, not an integer.** An unbounded number is an unbounded channel, and this
/// payload keeps every field's cardinality finite so the whole of what a report can say
/// is enumerable and reviewable. Above five the term stops counting, which is also the
/// honest resolution of a user's memory.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
pub enum Occurrences {
    #[serde(rename = "1")]
    Once,
    #[serde(rename = "2")]
    Twice,
    #[serde(rename = "3")]
    ThreeTimes,
    #[serde(rename = "4")]
    FourTimes,
    #[serde(rename = "5")]
    FiveTimes,
    #[serde(rename = "more-than-5")]
    MoreThanFiveTimes,
}

impl Occurrences {
    pub const ALL: &'static [Occurrences] = &[
        Occurrences::Once,
        Occurrences::Twice,
        Occurrences::ThreeTimes,
        Occurrences::FourTimes,
        Occurrences::FiveTimes,
        Occurrences::MoreThanFiveTimes,
    ];

    pub fn wire(&self) -> &'static str {
        match self {
            Occurrences::Once => "1",
            Occurrences::Twice => "2",
            Occurrences::ThreeTimes => "3",
            Occurrences::FourTimes => "4",
            Occurrences::FiveTimes => "5",
            Occurrences::MoreThanFiveTimes => "more-than-5",
        }
    }

    pub fn label(&self) -> &'static str {
        match self {
            Occurrences::Once => "once",
            Occurrences::Twice => "twice",
            Occurrences::ThreeTimes => "three times",
            Occurrences::FourTimes => "four times",
            Occurrences::FiveTimes => "five times",
            Occurrences::MoreThanFiveTimes => "more than five times",
        }
    }
}

/// One statement a report can make about what went wrong.
///
/// There is deliberately **no `Other(String)`**, no `Custom`, no free-text escape. A
/// user with something to say that no term covers is telling the vocabulary it is
/// incomplete, and the fix for that is a reviewed diff here — not a text box whose
/// contents nobody can vet before they travel.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum DiagnosisTerm {
    RequestRepeatedWithoutPreparation,
    NoInputArtifactNamed,
    NoLocationWithinInputSpecified,
    NoMethodGiven,
    NoAcceptanceCriterionStated,
    AutomatedExecutorsReceivedSelfContainedBriefs,
    HumanExecutorReceivedTheLeastPreparedInstruction,
}

impl DiagnosisTerm {
    pub const ALL: &'static [DiagnosisTerm] = &[
        DiagnosisTerm::RequestRepeatedWithoutPreparation,
        DiagnosisTerm::NoInputArtifactNamed,
        DiagnosisTerm::NoLocationWithinInputSpecified,
        DiagnosisTerm::NoMethodGiven,
        DiagnosisTerm::NoAcceptanceCriterionStated,
        DiagnosisTerm::AutomatedExecutorsReceivedSelfContainedBriefs,
        DiagnosisTerm::HumanExecutorReceivedTheLeastPreparedInstruction,
    ];

    pub fn wire(&self) -> &'static str {
        match self {
            DiagnosisTerm::RequestRepeatedWithoutPreparation => {
                "request-repeated-without-preparation"
            }
            DiagnosisTerm::NoInputArtifactNamed => "no-input-artifact-named",
            DiagnosisTerm::NoLocationWithinInputSpecified => "no-location-within-input-specified",
            DiagnosisTerm::NoMethodGiven => "no-method-given",
            DiagnosisTerm::NoAcceptanceCriterionStated => "no-acceptance-criterion-stated",
            DiagnosisTerm::AutomatedExecutorsReceivedSelfContainedBriefs => {
                "automated-executors-received-self-contained-briefs"
            }
            DiagnosisTerm::HumanExecutorReceivedTheLeastPreparedInstruction => {
                "human-executor-received-the-least-prepared-instruction"
            }
        }
    }

    /// The exact sentence this term contributes to a report. Authored here, once, and
    /// shipped in the binary — never generated, never interpolated, never derived from
    /// anything the user typed or said.
    pub fn sentence(&self) -> &'static str {
        match self {
            DiagnosisTerm::RequestRepeatedWithoutPreparation => {
                "The assistant asked the user to carry out a manual verification task more \
                 than once in a single session without preparing the artifact the task \
                 required."
            }
            DiagnosisTerm::NoInputArtifactNamed => "No input file was named.",
            DiagnosisTerm::NoLocationWithinInputSpecified => {
                "No locations within it were specified."
            }
            DiagnosisTerm::NoMethodGiven => "No method was given.",
            DiagnosisTerm::NoAcceptanceCriterionStated => "No acceptance criterion was stated.",
            DiagnosisTerm::AutomatedExecutorsReceivedSelfContainedBriefs => {
                "In the same session the assistant produced detailed, self-contained briefs \
                 for its automated sub-agents."
            }
            DiagnosisTerm::HumanExecutorReceivedTheLeastPreparedInstruction => {
                "The asymmetry is the defect: the human executor received the least prepared \
                 instruction."
            }
        }
    }
}

/// A condition that let the failure survive rather than causing it.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum ContributingCondition {
    RecordSectionForItemsAwaitingTheUser,
    NoUserFacingItemCarriedAnAcceptanceCriterion,
    RuleEnforcedByAttentionRatherThanMachinery,
}

impl ContributingCondition {
    pub const ALL: &'static [ContributingCondition] = &[
        ContributingCondition::RecordSectionForItemsAwaitingTheUser,
        ContributingCondition::NoUserFacingItemCarriedAnAcceptanceCriterion,
        ContributingCondition::RuleEnforcedByAttentionRatherThanMachinery,
    ];

    pub fn wire(&self) -> &'static str {
        match self {
            ContributingCondition::RecordSectionForItemsAwaitingTheUser => {
                "record-section-for-items-awaiting-the-user"
            }
            ContributingCondition::NoUserFacingItemCarriedAnAcceptanceCriterion => {
                "no-user-facing-item-carried-an-acceptance-criterion"
            }
            ContributingCondition::RuleEnforcedByAttentionRatherThanMachinery => {
                "rule-enforced-by-attention-rather-than-machinery"
            }
        }
    }

    pub fn sentence(&self) -> &'static str {
        match self {
            ContributingCondition::RecordSectionForItemsAwaitingTheUser => {
                "The durable task record contained a section for items awaiting the user, \
                 which made relaying an item feel equivalent to preparing it."
            }
            ContributingCondition::NoUserFacingItemCarriedAnAcceptanceCriterion => {
                "No user-facing item carried an acceptance criterion."
            }
            ContributingCondition::RuleEnforcedByAttentionRatherThanMachinery => {
                "The rule that would have prevented this was enforced by attention rather \
                 than by machinery."
            }
        }
    }
}

/// What can go wrong when assembling or reading a report.
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum TaxonomyError {
    /// A report with no diagnosis says nothing, and "nothing" is not worth a user's
    /// consent to disclose.
    #[error("a report needs at least one diagnosis term")]
    NoDiagnosisSelected,
    /// The offer to report is made on `1` and `2`. A payload attached to `3` would be a
    /// complaint the user never made.
    #[error("rating '{0}' does not invite a report — the offer is made on 1 and 2 only")]
    RatingDoesNotInviteReport(char),
    /// The text presented is not a payload in this vocabulary. Carries serde's reason,
    /// which for an out-of-vocabulary term enumerates the terms that DO exist.
    #[error("not expressible in taxonomy {version}: {detail}")]
    OutsideVocabulary { version: &'static str, detail: String },
}

/// **The report.** Every field is a term drawn from the vocabulary above; there is no
/// `String` anywhere in it, at any depth, and therefore nothing a user's specifics could
/// occupy.
///
/// The wire names match the reference case's target payload exactly
/// (`failure_class`, `occurrences_this_session`, `generic_diagnosis`,
/// `contributing_condition`), so the fixture and the type are compared field for field
/// rather than by eye.
///
/// ## The negative control, pinned by the compiler
///
/// There is no constructor that accepts prose. The reference case's second negative
/// control — the hard one, no proper nouns, still disqualifying — cannot be passed in
/// because there is no parameter for it:
///
/// ```compile_fail
/// # use richos_core::feedback::*;
/// let payload = FeedbackPayload::assemble(
///     Rating::Bad,
///     FailureClass::UnpreparedTaskHandedToUser,
///     Occurrences::ThreeTimes,
///     vec![DiagnosisTerm::NoMethodGiven],
///     vec![],
///     // Population-narrowing, no proper nouns, and there is nowhere to put it.
///     "the user's own recordings of the sessions he hosts for his club",
/// );
/// ```
///
/// Nor is there a free-text variant to smuggle it through as a term:
///
/// ```compile_fail
/// # use richos_core::feedback::DiagnosisTerm;
/// let term = DiagnosisTerm::Other("the sessions he hosts for his club".to_string());
/// ```
///
/// The positive control for both of those — same import, same call, the shape that IS
/// expressible. If a `compile_fail` block above ever starts failing for a boring reason
/// (a renamed type, a bad path) rather than the intended one, this one fails with it:
///
/// ```
/// # use richos_core::feedback::*;
/// let payload = FeedbackPayload::assemble(
///     Rating::Bad,
///     FailureClass::UnpreparedTaskHandedToUser,
///     Occurrences::ThreeTimes,
///     vec![DiagnosisTerm::NoMethodGiven],
///     vec![],
/// ).unwrap();
/// assert_eq!(payload.rating(), Rating::Bad);
/// ```
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct FeedbackPayload {
    taxonomy_version: TaxonomyVersion,
    rating: Rating,
    failure_class: FailureClass,
    occurrences_this_session: Occurrences,
    generic_diagnosis: Vec<DiagnosisTerm>,
    contributing_condition: Vec<ContributingCondition>,
}

impl FeedbackPayload {
    /// Assemble a report from terms. The only constructor there is.
    ///
    /// Selections are sorted into vocabulary order and de-duplicated, so the same set of
    /// terms always produces the same payload and the same rendered text — which is what
    /// makes "you are seeing exactly what would be reported" a property rather than a
    /// promise.
    pub fn assemble(
        rating: Rating,
        failure_class: FailureClass,
        occurrences_this_session: Occurrences,
        generic_diagnosis: Vec<DiagnosisTerm>,
        contributing_condition: Vec<ContributingCondition>,
    ) -> Result<Self, TaxonomyError> {
        if !rating.invites_report() {
            return Err(TaxonomyError::RatingDoesNotInviteReport(rating.key()));
        }
        if generic_diagnosis.is_empty() {
            return Err(TaxonomyError::NoDiagnosisSelected);
        }
        let mut generic_diagnosis = generic_diagnosis;
        generic_diagnosis.sort();
        generic_diagnosis.dedup();
        let mut contributing_condition = contributing_condition;
        contributing_condition.sort();
        contributing_condition.dedup();
        Ok(FeedbackPayload {
            taxonomy_version: TAXONOMY_VERSION,
            rating,
            failure_class,
            occurrences_this_session,
            generic_diagnosis,
            contributing_condition,
        })
    }

    /// Read a payload back. **This is the only door into the type from text**, and it is
    /// shut against anything that is not vocabulary: a prose string where a term list
    /// belongs is a type error, a term that does not exist is an unknown variant, and an
    /// extra field is refused outright.
    pub fn from_json(text: &str) -> Result<Self, TaxonomyError> {
        serde_json::from_str::<FeedbackPayload>(text).map_err(|e| {
            TaxonomyError::OutsideVocabulary {
                version: TAXONOMY_VERSION.wire(),
                detail: e.to_string(),
            }
        })
    }

    pub fn taxonomy_version(&self) -> TaxonomyVersion {
        self.taxonomy_version
    }
    pub fn rating(&self) -> Rating {
        self.rating
    }
    pub fn failure_class(&self) -> FailureClass {
        self.failure_class
    }
    pub fn occurrences_this_session(&self) -> Occurrences {
        self.occurrences_this_session
    }
    pub fn generic_diagnosis(&self) -> &[DiagnosisTerm] {
        &self.generic_diagnosis
    }
    pub fn contributing_condition(&self) -> &[ContributingCondition] {
        &self.contributing_condition
    }
}

/// A fingerprint over the entire vocabulary — every term's wire name and every term's
/// sentence, in declaration order, plus the version.
///
/// The point is not integrity against tampering; it is that **a change to what the
/// vocabulary can say cannot be made quietly.** Re-word one sentence and the pinned test
/// fails, naming the version bump the change requires. FNV-1a, chosen because it needs
/// no dependency and this is a change-detector, not a security primitive.
pub fn vocabulary_fingerprint() -> u64 {
    let mut h: u64 = 0xcbf2_9ce4_8422_2325;
    let mut eat = |s: &str| {
        for b in s.as_bytes() {
            h ^= *b as u64;
            h = h.wrapping_mul(0x1000_0000_01b3);
        }
        h ^= 0xff;
        h = h.wrapping_mul(0x1000_0000_01b3);
    };
    eat(TAXONOMY_VERSION.wire());
    for t in FailureClass::ALL {
        eat(t.wire());
        eat(t.label());
    }
    for t in Occurrences::ALL {
        eat(t.wire());
        eat(t.label());
    }
    for t in DiagnosisTerm::ALL {
        eat(t.wire());
        eat(t.sentence());
    }
    for t in ContributingCondition::ALL {
        eat(t.wire());
        eat(t.sentence());
    }
    h
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

    // -----------------------------------------------------------------------
    // THE TAXONOMY
    //
    // The controls below are INVENTED. The reference case's own §6 controls name a real
    // third party and a real business, and this repository gets published — so the
    // fixtures here reproduce the STRUCTURE of each control (one with proper nouns, one
    // with none that still discloses what the user does) in material that is nobody's.
    // -----------------------------------------------------------------------

    /// Structural analogue of the reference case's first negative control: names a third
    /// party, a company, a product and a business decision.
    const CONTROL_WITH_PROPER_NOUNS: &str = "Rich asked the operator four times to check \
        twenty pages of the Halverson Freight tariff schedule for the Meridian rollout, \
        without giving page numbers, so that the vendor choice could be settled.";

    /// Structural analogue of the second, harder control: **no proper nouns at all**, and
    /// still disqualifying — it discloses that the user hosts recorded sessions for a
    /// club, which narrows the population to a handful of people and which the user
    /// himself would find unremarkable enough to approve.
    const CONTROL_WITHOUT_PROPER_NOUNS: &str = "The assistant repeatedly failed to prepare \
        review tasks against the user's own recordings of the amateur-astronomy sessions \
        he hosts for his club.";

    /// The selection that reproduces the reference case's target payload.
    fn reference_case_payload() -> FeedbackPayload {
        FeedbackPayload::assemble(
            Rating::Bad,
            FailureClass::UnpreparedTaskHandedToUser,
            Occurrences::ThreeTimes,
            vec![
                DiagnosisTerm::RequestRepeatedWithoutPreparation,
                DiagnosisTerm::NoInputArtifactNamed,
                DiagnosisTerm::NoLocationWithinInputSpecified,
                DiagnosisTerm::NoMethodGiven,
                DiagnosisTerm::NoAcceptanceCriterionStated,
                DiagnosisTerm::AutomatedExecutorsReceivedSelfContainedBriefs,
                DiagnosisTerm::HumanExecutorReceivedTheLeastPreparedInstruction,
            ],
            vec![
                ContributingCondition::RecordSectionForItemsAwaitingTheUser,
                ContributingCondition::NoUserFacingItemCarriedAnAcceptanceCriterion,
            ],
        )
        .unwrap()
    }

    #[test]
    fn positive_control_the_reference_cases_target_payload_is_expressible() {
        // Without this, every rejection test below could be passing because the type
        // rejects EVERYTHING, which would be a feature that reports nothing.
        let p = reference_case_payload();
        assert_eq!(p.taxonomy_version(), TaxonomyVersion::V1);
        assert_eq!(p.rating(), Rating::Bad);
        assert_eq!(p.rating().key(), '1');
        assert_eq!(p.failure_class().wire(), "unprepared-task-handed-to-user");
        assert_eq!(p.occurrences_this_session().wire(), "3");
        assert_eq!(p.generic_diagnosis().len(), 7);
        // Two of the three conditions — a payload that simply selects the whole
        // vocabulary would prove nothing about the vocabulary being a choice.
        assert_eq!(p.contributing_condition().len(), 2);
        assert!(!p
            .contributing_condition()
            .contains(&ContributingCondition::RuleEnforcedByAttentionRatherThanMachinery));
    }

    #[test]
    fn negative_control_with_proper_nouns_is_disqualified() {
        // Presented the way an author would naturally write it: prose in the diagnosis
        // field. The field exists; it cannot hold a sentence.
        let as_prose = serde_json::json!({
            "taxonomy_version": "v1",
            "rating": "bad",
            "failure_class": "unprepared-task-handed-to-user",
            "occurrences_this_session": "4",
            "generic_diagnosis": CONTROL_WITH_PROPER_NOUNS,
            "contributing_condition": [],
        })
        .to_string();
        let err = FeedbackPayload::from_json(&as_prose).unwrap_err();
        assert!(
            format!("{err}").contains("invalid type: string"),
            "expected a type refusal, got: {err}"
        );

        // And presented as a term, which is the smarter attempt.
        let as_term = serde_json::json!({
            "taxonomy_version": "v1",
            "rating": "bad",
            "failure_class": "unprepared-task-handed-to-user",
            "occurrences_this_session": "4",
            "generic_diagnosis": [CONTROL_WITH_PROPER_NOUNS],
            "contributing_condition": [],
        })
        .to_string();
        let err = FeedbackPayload::from_json(&as_term).unwrap_err();
        assert!(format!("{err}").contains("unknown variant"), "expected a vocabulary refusal, got: {err}");
    }

    #[test]
    fn negative_control_without_a_single_proper_noun_is_disqualified_just_as_hard() {
        // THE HARD ONE. Nothing in this sentence is a name, and no filter over prose
        // catches it. It is refused for the only reason that scales: it is not a term,
        // and the type has no room for anything that is not a term.
        for shape in [
            serde_json::json!({
                "taxonomy_version": "v1",
                "rating": "ok-but-could-be-better",
                "failure_class": "unprepared-task-handed-to-user",
                "occurrences_this_session": "more-than-5",
                "generic_diagnosis": CONTROL_WITHOUT_PROPER_NOUNS,
                "contributing_condition": [],
            }),
            serde_json::json!({
                "taxonomy_version": "v1",
                "rating": "ok-but-could-be-better",
                "failure_class": "unprepared-task-handed-to-user",
                "occurrences_this_session": "more-than-5",
                "generic_diagnosis": [CONTROL_WITHOUT_PROPER_NOUNS],
                "contributing_condition": [],
            }),
            // Smuggled through the condition list instead.
            serde_json::json!({
                "taxonomy_version": "v1",
                "rating": "ok-but-could-be-better",
                "failure_class": "unprepared-task-handed-to-user",
                "occurrences_this_session": "more-than-5",
                "generic_diagnosis": ["no-method-given"],
                "contributing_condition": [CONTROL_WITHOUT_PROPER_NOUNS],
            }),
            // Smuggled through the failure class.
            serde_json::json!({
                "taxonomy_version": "v1",
                "rating": "ok-but-could-be-better",
                "failure_class": CONTROL_WITHOUT_PROPER_NOUNS,
                "occurrences_this_session": "more-than-5",
                "generic_diagnosis": ["no-method-given"],
                "contributing_condition": [],
            }),
        ] {
            let err = FeedbackPayload::from_json(&shape.to_string()).unwrap_err();
            let msg = format!("{err}");
            assert!(
                msg.contains("invalid type: string") || msg.contains("unknown variant"),
                "the control got through as {shape}, error was: {msg}"
            );
        }
    }

    #[test]
    fn a_field_the_vocabulary_does_not_define_is_refused_rather_than_ignored() {
        // The other way prose arrives: beside the payload rather than inside it. Serde's
        // default is to ignore unknown fields, which would have made this a silent
        // channel — deny_unknown_fields is what closes it.
        let smuggled = serde_json::json!({
            "taxonomy_version": "v1",
            "rating": "bad",
            "failure_class": "unprepared-task-handed-to-user",
            "occurrences_this_session": "3",
            "generic_diagnosis": ["no-method-given"],
            "contributing_condition": [],
            "notes": CONTROL_WITHOUT_PROPER_NOUNS,
        })
        .to_string();
        let err = FeedbackPayload::from_json(&smuggled).unwrap_err();
        assert!(format!("{err}").contains("unknown field"), "extra field survived: {err}");
    }

    #[test]
    fn a_payload_claiming_another_vocabulary_version_does_not_parse() {
        let v2 = serde_json::json!({
            "taxonomy_version": "v2",
            "rating": "bad",
            "failure_class": "unprepared-task-handed-to-user",
            "occurrences_this_session": "3",
            "generic_diagnosis": ["no-method-given"],
            "contributing_condition": [],
        })
        .to_string();
        assert!(
            FeedbackPayload::from_json(&v2).is_err(),
            "a v2 payload must not be read hopefully as v1 — the terms may mean something else"
        );
    }

    #[test]
    fn the_reference_payload_round_trips_through_its_own_door() {
        let p = reference_case_payload();
        let json = serde_json::to_string(&p).unwrap();
        assert_eq!(FeedbackPayload::from_json(&json).unwrap(), p);
    }

    #[test]
    fn a_good_rating_cannot_carry_a_report() {
        let err = FeedbackPayload::assemble(
            Rating::Good,
            FailureClass::UnpreparedTaskHandedToUser,
            Occurrences::Once,
            vec![DiagnosisTerm::NoMethodGiven],
            vec![],
        )
        .unwrap_err();
        assert_eq!(err, TaxonomyError::RatingDoesNotInviteReport('3'));
    }

    #[test]
    fn a_report_with_no_diagnosis_is_refused() {
        let err = FeedbackPayload::assemble(
            Rating::Bad,
            FailureClass::CheckingHandedToUser,
            Occurrences::Once,
            vec![],
            vec![ContributingCondition::RuleEnforcedByAttentionRatherThanMachinery],
        )
        .unwrap_err();
        assert_eq!(err, TaxonomyError::NoDiagnosisSelected);
    }

    #[test]
    fn the_same_terms_in_any_order_produce_the_same_payload() {
        // "You are seeing exactly what would be reported" needs the selection -> payload
        // step to be deterministic, or two users who picked the same things would be
        // shown two different texts.
        let a = FeedbackPayload::assemble(
            Rating::Bad,
            FailureClass::DecisionHandedToUser,
            Occurrences::Twice,
            vec![DiagnosisTerm::NoMethodGiven, DiagnosisTerm::NoInputArtifactNamed],
            vec![ContributingCondition::RuleEnforcedByAttentionRatherThanMachinery],
        )
        .unwrap();
        let b = FeedbackPayload::assemble(
            Rating::Bad,
            FailureClass::DecisionHandedToUser,
            Occurrences::Twice,
            vec![
                DiagnosisTerm::NoInputArtifactNamed,
                DiagnosisTerm::NoMethodGiven,
                DiagnosisTerm::NoMethodGiven, // and a duplicate
            ],
            vec![
                ContributingCondition::RuleEnforcedByAttentionRatherThanMachinery,
                ContributingCondition::RuleEnforcedByAttentionRatherThanMachinery,
            ],
        )
        .unwrap();
        assert_eq!(a, b);
        assert_eq!(a.generic_diagnosis().len(), 2);
    }

    #[test]
    fn every_terms_wire_name_is_the_one_serde_actually_writes() {
        // Two spellings of the same fact — the hand-written wire() and the serde
        // attribute — would eventually disagree. This is the check that they cannot.
        macro_rules! check {
            ($all:expr) => {
                for t in $all {
                    assert_eq!(
                        serde_json::to_string(t).unwrap(),
                        format!("\"{}\"", t.wire()),
                        "wire() and serde disagree about {t:?}"
                    );
                }
            };
        }
        check!(FailureClass::ALL);
        check!(Occurrences::ALL);
        check!(DiagnosisTerm::ALL);
        check!(ContributingCondition::ALL);
        assert_eq!(serde_json::to_string(&TAXONOMY_VERSION).unwrap(), "\"v1\"");
    }

    #[test]
    fn no_term_in_the_vocabulary_names_anybody() {
        // AN AUTHORING LINT, NOT A SCRUBBER — and the distinction matters. This runs over
        // the FINITE, compiled-in list of sentences that ships in the binary. It never
        // sees a user's data, because no user data ever reaches this type. Its job is to
        // make a careless addition to the vocabulary fail the build instead of shipping.
        let mut sentences: Vec<&str> = Vec::new();
        sentences.extend(FailureClass::ALL.iter().map(|t| t.label()));
        sentences.extend(Occurrences::ALL.iter().map(|t| t.label()));
        sentences.extend(DiagnosisTerm::ALL.iter().map(|t| t.sentence()));
        sentences.extend(ContributingCondition::ALL.iter().map(|t| t.sentence()));
        for s in sentences {
            for (i, word) in s.split_whitespace().enumerate() {
                if i == 0 {
                    continue;
                }
                let first = word.chars().next().unwrap();
                assert!(
                    !first.is_ascii_uppercase(),
                    "vocabulary term reads as a name: {word:?} in {s:?}"
                );
            }
        }
    }

    #[test]
    fn the_vocabulary_is_pinned_so_a_change_to_it_cannot_be_made_quietly() {
        // If this fails you changed what a report is CAPABLE OF SAYING. That is a
        // contract change: bump TAXONOMY_VERSION, add the new variant to the version
        // enum so old payloads still parse as what they were, then update this number.
        assert_eq!(
            vocabulary_fingerprint(),
            16_433_139_902_729_042_306,
            "the vocabulary changed"
        );
        assert_eq!(FailureClass::ALL.len(), 5);
        assert_eq!(Occurrences::ALL.len(), 6);
        assert_eq!(DiagnosisTerm::ALL.len(), 7);
        assert_eq!(ContributingCondition::ALL.len(), 3);
    }
}
