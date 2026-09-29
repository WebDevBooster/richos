//! THE CORRECTION DESK SURVIVES A RECORD IT CANNOT READ, AND SAYS SO.
//!
//! `correction.rs`'s desk log is the file that holds what the CEO was ASKED and what he
//! ANSWERED: a loro proposal put in front of him, and his confirm, his decline, or his
//! "never ask me about this again". Until 2026-09-05 its replay was
//! `lines().map_while(Result::ok)` with `let Ok(rec) = … else { continue }` — no count, no
//! log line, and an iterator that ENDED at the first non-UTF-8 byte, so one damaged byte
//! discarded every answer he had given below it.
//!
//! **Every test here is worthless without `nothing_at_all_is_skipped_on_an_untouched_desk`.**
//! A reader that skips everything passes every "the damage was reported" test in this file
//! and fails the only one that matters, so that test comes first and is the anti-vacuous
//! floor for the rest.
//!
//! Every fixture is built by the REAL desk (`propose` / `confirm` / `decline`) and then
//! edited, so no test here can pass against a shape the product does not actually write.

use richos_core::correction::{
    asked_again_sentence, CorrectionDesk, CorrectionError, LoroWriteBackend, ProposalState,
    ProposedWrite, WriteOutput, KNOWN_DESK_TAGS,
};
use richos_core::skip::SkipKind;
use std::io::Write;
use std::path::PathBuf;
use std::sync::{Arc, Mutex};

// -------------------------------------------------------------------------------------
// A writer that records what it was asked to do and never touches a real corpus.
// -------------------------------------------------------------------------------------

#[derive(Clone, Default)]
struct Recorder {
    calls: Arc<Mutex<Vec<String>>>,
}

impl Recorder {
    fn commits(&self) -> usize {
        self.calls.lock().unwrap().iter().filter(|c| c.starts_with("commit:")).count()
    }
}

impl LoroWriteBackend for Recorder {
    fn preview(&self, write: &ProposedWrite, _why: &str) -> Result<WriteOutput, CorrectionError> {
        self.calls.lock().unwrap().push(format!("preview:{}", write.verb()));
        Ok(WriteOutput {
            op: write.verb().into(),
            dry_run: true,
            r#ref: "rec:ceo/records/x".into(),
            text: "---\nkind: decision\n---\n\nWhat would be written.\n".into(),
            ..Default::default()
        })
    }
    fn commit(&self, write: &ProposedWrite, _why: &str) -> Result<WriteOutput, CorrectionError> {
        self.calls.lock().unwrap().push(format!("commit:{}", write.verb()));
        Ok(WriteOutput {
            op: write.verb().into(),
            r#ref: "rec:ceo/records/x".into(),
            text: "written\n".into(),
            ..Default::default()
        })
    }
    fn show(&self, record_ref: &str) -> Result<WriteOutput, CorrectionError> {
        self.calls.lock().unwrap().push(format!("show:{record_ref}"));
        Ok(WriteOutput { op: "show".into(), r#ref: record_ref.into(), ..Default::default() })
    }
}

fn scratch(name: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!("richos-desk-fc-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    dir.join(format!("{name}.jsonl"))
}

/// A genuine eight-record desk log, written by the product's own desk:
///
/// | line | record | what it means |
/// |---|---|---|
/// | 1 | `proposed` | prop-1, an append |
/// | 2 | `confirmed` | he said yes to prop-1 |
/// | 3 | `written` | and the write landed |
/// | 4 | `proposed` | prop-2, a supersede of `rec:ceo/records/deal` |
/// | 5 | `declined` | he said no to prop-2, permanently |
/// | 6 | `suppressed` | so `rec:ceo/records/deal` is never proposed again |
/// | 7 | `proposed` | prop-3, a correction he has NOT answered |
/// | 8 | `proposed` | prop-4, a second correction he has NOT answered |
///
/// **TWO unanswered proposals, and they are deliberately at different depths.** A single
/// one cannot tell "held back because its answer might be missing" apart from "held back
/// because everything is", and the second failure is the one that would stop him being
/// asked at all.
fn write_real_desk(path: &PathBuf) -> Recorder {
    discard(path);
    let w = Recorder::default();
    let mut desk = CorrectionDesk::open(path, Box::new(w.clone())).unwrap();
    desk.propose("ent_ceo", "thr_1", an_append(), "the price was wrong").unwrap();
    desk.confirm("ent_ceo", "prop-1").unwrap();
    desk.propose("ent_ceo", "thr_1", a_supersede(), "that is not what I decided").unwrap();
    desk.decline("prop-2", true).unwrap();
    desk.propose("ent_ceo", "thr_1", a_correct(), "the title is wrong").unwrap();
    desk.propose("ent_ceo", "thr_1", a_second_correct(), "the lawyer changed").unwrap();
    w
}

fn an_append() -> ProposedWrite {
    ProposedWrite::Append {
        id: "new-1".into(),
        kind: "decision".into(),
        scope: None,
        title: Some("A decision".into()),
        body: "The body.".into(),
        partition: None,
    }
}

fn a_supersede() -> ProposedWrite {
    ProposedWrite::Supersede {
        record_ref: "rec:ceo/records/deal".into(),
        new_id: "deal-2".into(),
        kind: "decision".into(),
        scope: None,
        body: "The corrected body.".into(),
    }
}

fn a_correct() -> ProposedWrite {
    ProposedWrite::Correct {
        record_ref: "rec:ceo/records/vendor".into(),
        title: Some("Deepgram".into()),
        kind: None,
        confidence: None,
        tags: None,
        narrow_scope_to: None,
        body: None,
    }
}

fn a_second_correct() -> ProposedWrite {
    ProposedWrite::Correct {
        record_ref: "rec:ceo/records/lawyer".into(),
        title: Some("Nelson & Co".into()),
        kind: None,
        confidence: None,
        tags: None,
        narrow_scope_to: None,
        body: None,
    }
}

fn lines_of(path: &PathBuf) -> Vec<String> {
    std::fs::read_to_string(path)
        .unwrap()
        .lines()
        .filter(|l| !l.trim().is_empty())
        .map(|s| s.to_string())
        .collect()
}

/// Build the real log, hand its lines to `edit`, write the result back, and reopen.
fn open_edited(name: &str, edit: impl FnOnce(Vec<String>) -> Vec<String>) -> (CorrectionDesk, PathBuf) {
    let (desk, _w, path) = open_edited_with(name, edit);
    (desk, path)
}

/// The same, keeping the writer handle — so "and it wrote nothing" is checked against what
/// the loro writer was actually asked to do, not against a flag.
fn open_edited_with(
    name: &str,
    edit: impl FnOnce(Vec<String>) -> Vec<String>,
) -> (CorrectionDesk, Recorder, PathBuf) {
    let path = scratch(name);
    write_real_desk(&path);
    let edited = edit(lines_of(&path));
    let mut f = std::fs::File::create(&path).unwrap();
    for l in &edited {
        writeln!(f, "{l}").unwrap();
    }
    drop(f);
    let w = Recorder::default();
    let desk = CorrectionDesk::open(&path, Box::new(w.clone())).unwrap();
    (desk, w, path)
}

/// Replace one 1-based line of the real log with `replacement`, keeping every other byte.
fn open_with_line_replaced(name: &str, line_no: usize, replacement: &str) -> (CorrectionDesk, Recorder, PathBuf) {
    let r = replacement.to_string();
    open_edited_with(name, move |lines| {
        lines
            .into_iter()
            .enumerate()
            .map(|(i, l)| if i + 1 == line_no { r.clone() } else { l })
            .collect()
    })
}

// -------------------------------------------------------------------------------------
// THE ANTI-VACUOUS TEST. Everything below it is worthless without this one.
// -------------------------------------------------------------------------------------

/// A desk log nobody has damaged skips NOTHING and says NOTHING. A change that made every
/// record skip would satisfy every other test in this file, and would be the exact failure
/// this work exists to prevent.
#[test]
fn nothing_at_all_is_skipped_on_an_untouched_desk() {
    let (desk, path) = open_edited("clean", |l| l);
    let h = desk.desk_health();
    assert!(h.is_clean(), "an untouched desk skipped something: {:?}", desk.skipped_records());
    assert_eq!(h.records_read, 8, "4 proposed, 1 confirmed, 1 written, 1 declined, 1 suppressed");
    assert_eq!(h.records_applied, 8, "every record must be APPLIED, not skipped");
    assert_eq!(h.skipped, 0);
    assert_eq!(h.headline, "", "a clean desk says nothing at all");
    assert_eq!(h.detail, "");

    // And the projection still means exactly what it always meant.
    assert_eq!(desk.get("prop-1").unwrap().state, ProposalState::Written, "he confirmed prop-1");
    assert_eq!(desk.get("prop-2").unwrap().state, ProposalState::Declined, "he declined prop-2");
    assert_eq!(desk.get("prop-3").unwrap().state, ProposalState::AwaitingCeo);
    assert_eq!(desk.suppressed(), ["rec:ceo/records/deal"]);
    assert_eq!(desk.get("prop-4").unwrap().state, ProposalState::AwaitingCeo);
    let pending: Vec<&str> = desk.pending_for("ent_ceo").iter().map(|p| p.id.as_str()).collect();
    assert_eq!(pending, ["prop-3", "prop-4"], "exactly the ones he has not answered");
    discard(path);
}

/// The same claim from the other end: reopening a log the product wrote, unedited, leaves
/// the file byte-for-byte as it was. The reader never rewrites what it read, and there is
/// no compaction here to delete what it could not.
#[test]
fn replaying_a_desk_leaves_the_file_exactly_as_it_was() {
    let path = scratch("untouched-bytes");
    write_real_desk(&path);
    let before = std::fs::read(&path).unwrap();
    let before_mtime = std::fs::metadata(&path).unwrap().modified().unwrap();
    let desk = CorrectionDesk::open(&path, Box::new(Recorder::default())).unwrap();
    assert!(desk.desk_health().is_clean());
    assert_eq!(std::fs::read(&path).unwrap(), before, "the replay rewrote the file");
    assert_eq!(std::fs::metadata(&path).unwrap().modified().unwrap(), before_mtime);
    discard(path);
}

/// And a damaged record is still on disk afterwards, untouched — the property that makes
/// "updating will bring it back" a true sentence rather than a comforting one.
#[test]
fn a_record_this_build_cannot_read_is_still_on_disk_after_the_replay() {
    let future = r#"{"rec":"acknowledged","id":"prop-3","at":7,"by":"ceo"}"#;
    let path = scratch("untouched-skip");
    write_real_desk(&path);
    let mut lines = lines_of(&path);
    lines.push(future.to_string());
    let mut f = std::fs::File::create(&path).unwrap();
    for l in &lines {
        writeln!(f, "{l}").unwrap();
    }
    drop(f);
    let desk = CorrectionDesk::open(&path, Box::new(Recorder::default())).unwrap();
    assert_eq!(desk.desk_health().skipped, 1);
    assert!(
        lines_of(&path).contains(&future.to_string()),
        "the record this build could not read was removed from the file"
    );
    discard(path);
}

// -------------------------------------------------------------------------------------
// THE KNOWN-TAG TABLE
// -------------------------------------------------------------------------------------

/// `DeskRecord` is private, so its exhaustive match lives in `correction.rs`'s own test
/// module. What is checkable from out here is that the table has no DUPLICATES and no
/// entry that is not a plain tag — a duplicate would hide a missing entry from the
/// exhaustive test's count.
#[test]
fn the_known_tag_table_is_a_set_of_plain_tags() {
    let mut sorted: Vec<&str> = KNOWN_DESK_TAGS.to_vec();
    sorted.sort_unstable();
    let mut deduped = sorted.clone();
    deduped.dedup();
    assert_eq!(sorted, deduped, "KNOWN_DESK_TAGS has a duplicate");
    for t in KNOWN_DESK_TAGS {
        assert!(richos_core::skip::is_plain_identifier(t), "{t} is not a plain tag");
    }
}

// -------------------------------------------------------------------------------------
// ONE BAD BYTE NO LONGER TAKES EVERY ANSWER BELOW IT
// -------------------------------------------------------------------------------------

/// **The defect this file exists for, at its worst.** A single non-UTF-8 byte on line 2
/// used to end the ITERATOR, so lines 3 through 7 — the write that landed, the decline, the
/// suppression and the open proposal — were all discarded with no trace. What the CEO would
/// have seen: a correction he confirmed offered to him again, and a record he had
/// permanently declined proposed again.
#[test]
fn one_bad_byte_no_longer_discards_every_record_below_it() {
    let path = scratch("bad-byte");
    write_real_desk(&path);
    let mut lines = lines_of(&path);
    assert_eq!(lines.len(), 8);
    // Line 2 (`confirmed`) becomes bytes that are not text at all.
    let mut f = std::fs::File::create(&path).unwrap();
    for (i, l) in lines.drain(..).enumerate() {
        if i == 1 {
            f.write_all(&[0xff, 0xfe, 0xff, b'\n']).unwrap();
        } else {
            writeln!(f, "{l}").unwrap();
        }
    }
    drop(f);

    let desk = CorrectionDesk::open(&path, Box::new(Recorder::default())).unwrap();
    let h = desk.desk_health();
    assert_eq!(h.skipped, 1, "exactly the bad line, and nothing else");
    assert_eq!(h.damaged, 1);
    assert_eq!(h.records_read, 8, "all eight lines were still visited");
    assert_eq!(h.records_applied, 7, "seven of eight folded");
    assert_eq!(desk.skipped_records()[0].kind, SkipKind::Damaged);
    assert_eq!(desk.skipped_records()[0].line, 2);

    // Everything BELOW the bad byte still loaded. This is the whole point.
    assert_eq!(desk.get("prop-1").unwrap().state, ProposalState::Written, "line 3 survived");
    assert_eq!(desk.get("prop-2").unwrap().state, ProposalState::Declined, "line 5 survived");
    assert!(desk.get("prop-3").is_some(), "line 7 survived");
    assert_eq!(desk.suppressed(), ["rec:ceo/records/deal"], "line 6 survived");
    discard(path);
}

// -------------------------------------------------------------------------------------
// THE THREE KINDS ARE TOLD APART
// -------------------------------------------------------------------------------------

#[test]
fn a_record_from_a_newer_build_is_benign_and_labeled_as_such() {
    let (desk, path) = open_edited("future", |mut l| {
        l.push(r#"{"rec":"acknowledged","id":"prop-3","at":7,"by":"ceo"}"#.to_string());
        l
    });
    let h = desk.desk_health();
    assert_eq!(h.from_future, 1);
    assert_eq!(h.damaged, 0);
    assert_eq!(h.ambiguous, 0);
    let r = &desk.skipped_records()[0];
    assert_eq!(r.kind, SkipKind::FromFuture);
    assert_eq!(r.tag.as_deref(), Some("acknowledged"));
    assert!(
        h.detail.contains("written by a newer version of RichOS"),
        "the cause is stated: {}",
        h.detail
    );
    assert!(!h.detail.contains("damaged and could not be read"), "a benign record is not damage: {}", h.detail);
    assert!(h.detail.contains("Updating will bring it back"), "{}", h.detail);
    discard(path);
}

#[test]
fn a_torn_write_is_damage_and_is_never_waved_through_as_the_future() {
    let (desk, path) = open_edited("torn", |mut l| {
        l.push(r#"{"rec":"written","id":"prop-3","at":7,"outcome":{"op":"cor"#.to_string());
        l
    });
    let h = desk.desk_health();
    assert_eq!(h.damaged, 1, "a torn line is DAMAGED, never `from a newer version`");
    assert_eq!(h.from_future, 0);
    assert_eq!(desk.skipped_records()[0].kind, SkipKind::Damaged);
    assert!(h.detail.contains("1 record is damaged and could not be read"), "{}", h.detail);
    discard(path);
}

#[test]
fn a_known_tag_that_does_not_fit_says_it_cannot_tell_rather_than_guessing() {
    // `written` is a tag this build knows; `outcome` is required and is the wrong type.
    let (desk, path) = open_edited("ambiguous", |mut l| {
        l.push(r#"{"rec":"written","id":"prop-3","at":7,"outcome":42}"#.to_string());
        l
    });
    let h = desk.desk_health();
    assert_eq!(h.ambiguous, 1);
    assert_eq!(h.damaged, 0);
    assert_eq!(h.from_future, 0);
    let r = &desk.skipped_records()[0];
    assert_eq!(r.kind, SkipKind::Ambiguous);
    assert_eq!(r.tag.as_deref(), Some("written"));
    assert!(r.detail.contains("cannot tell"), "{}", r.detail);
    assert!(h.detail.contains("cannot tell which"), "{}", h.detail);
    discard(path);
}

/// Damage that LOOKS like a new record type is still damage. A tag that is not a plain
/// identifier did not come out of a newer RichOS.
#[test]
fn a_mangled_tag_is_damage_not_a_new_record_type() {
    let (desk, path) = open_edited("mangled-tag", |mut l| {
        l.push(r#"{"rec":"wr itt en","id":"prop-3","at":7}"#.to_string());
        l
    });
    let h = desk.desk_health();
    assert_eq!(h.damaged, 1);
    assert_eq!(h.from_future, 0, "corruption must never be waved through as the future");
    assert_eq!(desk.skipped_records()[0].tag, None, "a mangled tag is not kept");
    discard(path);
}

// -------------------------------------------------------------------------------------
// THE COUNTS ARE A MEASUREMENT
// -------------------------------------------------------------------------------------

#[test]
fn the_summary_counts_every_line_it_visited_and_every_one_it_folded() {
    let (desk, path) = open_edited("counts", |mut l| {
        l.push(r#"{"rec":"acknowledged","id":"prop-9","at":7}"#.to_string()); // future
        l.push(r#"{"rec":"written","id":"prop-3","at":7,"outcome":42}"#.to_string()); // ambiguous
        l.push(r#"{"rec":"declined","id":"prop-3"#.to_string()); // damaged
        l
    });
    let h = desk.desk_health();
    assert_eq!(h.records_read, 11, "8 real + 3 planted");
    assert_eq!(h.records_applied, 8);
    assert_eq!(h.skipped, 3);
    assert_eq!(h.from_future + h.damaged + h.ambiguous, h.skipped, "every skip has exactly one kind");
    assert_eq!((h.from_future, h.damaged, h.ambiguous), (1, 1, 1));
    assert!(h.detail.contains("8 of 11 records"), "{}", h.detail);
    discard(path);
}

/// An empty file and an absent file are both clean, and neither says anything.
#[test]
fn an_absent_or_empty_desk_says_nothing() {
    let path = scratch("absent");
    discard(&path);
    let desk = CorrectionDesk::open(&path, Box::new(Recorder::default())).unwrap();
    let h = desk.desk_health();
    assert!(h.is_clean());
    assert_eq!((h.records_read, h.records_applied), (0, 0));
    assert_eq!(h.headline, "");

    std::fs::write(&path, "\n\n").unwrap();
    let desk = CorrectionDesk::open(&path, Box::new(Recorder::default())).unwrap();
    assert!(desk.desk_health().is_clean(), "blank lines are not records");
    assert_eq!(desk.desk_health().records_read, 0);
    discard(path);
}

/// Plurals are composed, not glued. "1 records" in a notice reads as a machine talking.
#[test]
fn the_sentences_agree_with_their_own_numbers() {
    let (one, path_one) = open_edited("plural-one", |mut l| {
        l.push(r#"{"rec":"declined","id":"prop-3"#.to_string());
        l
    });
    let h = one.desk_health();
    assert!(h.detail.contains("1 record is damaged"), "{}", h.detail);
    assert!(!h.detail.contains("1 records"), "{}", h.detail);

    let (two, path_two) = open_edited("plural-two", |mut l| {
        l.push(r#"{"rec":"declined","id":"prop-3"#.to_string());
        l.push(r#"{"rec":"written","id":"prop-1"#.to_string());
        l
    });
    let h = two.desk_health();
    assert!(h.detail.contains("2 records are damaged"), "{}", h.detail);
    assert!(!h.detail.contains("2 record is"), "{}", h.detail);
    discard(path_one);
    discard(path_two);
}

// -------------------------------------------------------------------------------------
// A SKIPPED RECORD CAN NO LONGER COLLIDE WITH A FRESH ONE
// -------------------------------------------------------------------------------------

/// `next` used to be `max(loaded proposal number) + 1`. A `proposed` record this build
/// could not fold is not in `proposals`, so the highest one being unreadable made the desk
/// mint an id that was ALREADY IN THE FILE — and the day that record becomes readable (an
/// update, for a `FromFuture` line) two different proposals answer to one id and
/// `find_mut` folds the wrong CEO answer onto the wrong proposal.
#[test]
fn a_fresh_proposal_never_reuses_an_id_hidden_in_an_unreadable_record() {
    let path = scratch("id-collision");
    write_real_desk(&path);
    let mut lines = lines_of(&path);
    // A newer build's record about prop-9 — a proposal this build cannot see.
    lines.push(r#"{"rec":"deferred","id":"prop-9","at":7,"until":"tomorrow"}"#.to_string());
    let mut f = std::fs::File::create(&path).unwrap();
    for l in &lines {
        writeln!(f, "{l}").unwrap();
    }
    drop(f);

    let w = Recorder::default();
    let mut desk = CorrectionDesk::open(&path, Box::new(w.clone())).unwrap();
    assert_eq!(desk.desk_health().from_future, 1);
    let fresh = desk.propose("ent_ceo", "thr_1", an_append(), "another one").unwrap();
    assert_eq!(fresh.id, "prop-10", "the counter must clear every id the FILE has used");
    assert_eq!(w.commits(), 0, "propose writes nothing");
    discard(path);
}

/// The other half of that rule: a DAMAGED line's numbers are not facts, so nothing is
/// salvaged from one. `steering.rs` draws the identical line, and the reason it is safe is
/// that damaged bytes never become readable — the collision this guards cannot materialize.
#[test]
fn a_damaged_lines_number_is_not_treated_as_a_fact() {
    let path = scratch("damaged-number");
    write_real_desk(&path);
    let mut lines = lines_of(&path);
    lines.push(r#"{"rec":"proposed","id":"prop-900","at":7"#.to_string()); // torn: damaged
    let mut f = std::fs::File::create(&path).unwrap();
    for l in &lines {
        writeln!(f, "{l}").unwrap();
    }
    drop(f);

    let mut desk = CorrectionDesk::open(&path, Box::new(Recorder::default())).unwrap();
    assert_eq!(desk.desk_health().damaged, 1);
    let fresh = desk.propose("ent_ceo", "thr_1", an_append(), "another one").unwrap();
    assert_eq!(fresh.id, "prop-5", "a damaged line must not move the counter to 901");
    discard(path);
}

// -------------------------------------------------------------------------------------
// NOTHING THE CEO WROTE, AND NOTHING LORO HOLDS, EVER REACHES A LOG OR A REPORT
// -------------------------------------------------------------------------------------

/// serde's own messages quote the offending value — `invalid type: string "…"`. On this
/// file that value is the CEO's stated reason for a correction, the body that would be
/// written into his memory, or the preview of what loro believes. The classifier composes
/// its sentences from the line's STRUCTURE and never consults the parser error, and this is
/// what holds it.
///
/// The assertion covers every string that leaves the module: the structured record, the two
/// health sentences, and the exact operator line `report_skipped` prints — reconstructed
/// here from the same four components it formats, because those components are the only
/// thing it has to print.
#[test]
fn a_skipped_records_report_never_contains_one_word_of_his_memory() {
    const SECRET: &str = "ACQUISITION-PRICE-IS-FORTY-MILLION";
    let cases = [
        // from a newer version, his words in a field
        format!(r#"{{"rec":"deferred","id":"prop-9","at":7,"note":"{SECRET}"}}"#),
        // known tag, wrong shape, his words where a record belongs
        format!(r#"{{"rec":"written","id":"prop-3","at":7,"outcome":"{SECRET}"}}"#),
        // damaged, his words inside
        format!(r#"{{"rec":"proposed","id":"prop-9","why":"{SECRET}""#),
        // damaged, his words AS the tag
        format!(r#"{{"rec":"{SECRET} and more","at":7}}"#),
        // valid JSON, not an object, his words inside
        format!(r#"["{SECRET}"]"#),
    ];
    for case in cases {
        let (desk, path) = open_edited("secret", |mut l| {
            l.push(case.clone());
            l
        });
        let r = desk.skipped_records().last().expect("the record was skipped");
        let h = desk.desk_health();
        // Exactly what report_skipped formats, from exactly the fields it formats.
        let operator_line = format!(
            "[richos] CORRECTION DESK RECORD SKIPPED ({}): line {} ({} bytes) — {}",
            r.kind.label(),
            r.line,
            r.bytes,
            r.detail
        );
        for printed in [operator_line, format!("{r:?}"), h.headline.clone(), h.detail.clone()] {
            assert!(!printed.contains(SECRET), "leaked his memory: {printed}");
            assert!(!printed.contains("FORTY"), "leaked his memory: {printed}");
            assert!(!printed.contains("MILLION"), "leaked his memory: {printed}");
        }
        discard(path);
    }
}

/// The anti-vacuous half of the secrecy test: the same planted string in a record that
/// PARSES is not reported at all, so the test above is not passing because nothing is ever
/// reported.
#[test]
fn a_desk_carrying_the_same_words_in_a_readable_record_reports_nothing_at_all() {
    const SECRET: &str = "ACQUISITION-PRICE-IS-FORTY-MILLION";
    let path = scratch("secret-clean");
    discard(&path);
    let mut desk = CorrectionDesk::open(&path, Box::new(Recorder::default())).unwrap();
    desk.propose(
        "ent_ceo",
        "thr_1",
        ProposedWrite::Append {
            id: "new-1".into(),
            kind: "decision".into(),
            scope: None,
            title: None,
            body: SECRET.into(),
            partition: None,
        },
        SECRET,
    )
    .unwrap();
    drop(desk);

    let reopened = CorrectionDesk::open(&path, Box::new(Recorder::default())).unwrap();
    let h = reopened.desk_health();
    assert!(h.is_clean(), "a readable record must not be reported");
    assert_eq!(h.headline, "");
    assert_eq!(h.detail, "");
    assert!(reopened.skipped_records().is_empty());
    // And his words ARE still there, in the one place they belong.
    assert_eq!(reopened.get("prop-1").unwrap().why, SECRET);
    discard(path);
}

// -------------------------------------------------------------------------------------
// A CONFIRMED DECISION NEVER BECOMES PENDING AGAIN
//
// This is the defect the file was opened for. The desk is an EVENT LOG: a `proposed`
// record carries the proposal in state `AwaitingCeo`, and his ANSWER is a separate, later
// record. Lose the answer and the proposal replays as `AwaitingCeo` — a decision he
// confirmed, silently pending again, offered to him a second time.
// -------------------------------------------------------------------------------------

/// **The headline case.** prop-1 was proposed (line 1), confirmed (line 2) and written
/// (line 3). Damage line 3 and the old reader put prop-1 straight back into
/// `pending_for` — the CEO asked a second time about a correction he had already approved,
/// and `confirm` would have accepted it and run the loro write again.
#[test]
fn a_confirmed_decision_never_becomes_pending_again_when_its_answer_is_unreadable() {
    let (mut desk, w, path) =
        open_with_line_replaced("lost-answer", 3, r#"{"rec":"written","id":"prop-1","at":3,"outcome":"#);

    let h = desk.desk_health();
    assert_eq!(h.damaged, 1);
    assert_eq!(h.unresolved, 1, "prop-1's answer is unreadable, so prop-1 is held back");

    // NOT offered again. This is the whole property.
    let pending: Vec<&str> = desk.pending_for("ent_ceo").iter().map(|p| p.id.as_str()).collect();
    assert_eq!(pending, ["prop-3", "prop-4"], "prop-1 must not be back in front of him");
    assert_eq!(desk.get("prop-1").unwrap().state, ProposalState::Unresolved);

    // And it cannot be answered a second time from any direction, so the loro write that
    // may already have landed cannot run twice.
    match desk.confirm("ent_ceo", "prop-1") {
        Err(CorrectionError::AnswerUnreadable { id }) => assert_eq!(id, "prop-1"),
        other => panic!("confirm must refuse a proposal whose answer is unreadable: {other:?}"),
    }
    match desk.decline("prop-1", false) {
        Err(CorrectionError::AnswerUnreadable { id }) => assert_eq!(id, "prop-1"),
        other => panic!("decline must refuse it too: {other:?}"),
    }
    assert_eq!(w.commits(), 0, "a held-back proposal never reaches the writer");

    // Held back is not lost: it is inspectable, by id and as a list.
    let held: Vec<&str> = desk.unresolved().iter().map(|p| p.id.as_str()).collect();
    assert_eq!(held, ["prop-1"]);
    discard(path);
}

/// **The reverse direction, and it is NOT the same failure.** Losing the EARLIER
/// `proposed` record loses the question: the answer records that follow find no proposal
/// and fold onto nothing. That is a loss, and nothing WRONG is put in front of him — which
/// is why the fix is aimed at the other end.
#[test]
fn losing_the_proposal_instead_of_the_answer_shows_him_nothing_wrong() {
    let (desk, _w, path) =
        open_with_line_replaced("lost-question", 7, r#"{"rec":"proposed","id":"prop-3","at":7,"why":"#);
    let h = desk.desk_health();
    assert_eq!(h.damaged, 1);
    assert_eq!(h.unresolved, 0, "no LOADED proposal is in doubt — the missing one never loaded");
    assert!(desk.get("prop-3").is_none(), "the question is gone");
    let pending: Vec<&str> = desk.pending_for("ent_ceo").iter().map(|p| p.id.as_str()).collect();
    assert_eq!(pending, ["prop-4"], "and nothing wrong is offered in its place");
    assert_eq!(desk.get("prop-1").unwrap().state, ProposalState::Written, "his answer still stands");
    assert_eq!(desk.get("prop-2").unwrap().state, ProposalState::Declined);
    discard(path);
}

/// **The quarantine is as narrow as the file allows.** A record from a newer build is
/// well-formed and carries a trustworthy `id`, so it holds back exactly the proposal it
/// names and nothing else. Holding everything back would be safe and useless.
#[test]
fn an_unreadable_record_that_names_its_proposal_holds_back_only_that_one() {
    let (desk, path) = open_edited("narrow", |mut l| {
        l.push(r#"{"rec":"acknowledged","id":"prop-3","at":9,"by":"ceo"}"#.to_string());
        l
    });
    let h = desk.desk_health();
    assert_eq!(h.from_future, 1);
    assert_eq!(h.unresolved, 1);
    assert_eq!(desk.get("prop-3").unwrap().state, ProposalState::Unresolved, "named, so held");
    assert_eq!(
        desk.get("prop-4").unwrap().state,
        ProposalState::AwaitingCeo,
        "not named, and a well-formed record from a newer build is trustworthy about which"
    );
    let pending: Vec<&str> = desk.pending_for("ent_ceo").iter().map(|p| p.id.as_str()).collect();
    assert_eq!(pending, ["prop-4"], "the other open proposal is still offered");
    discard(path);
}

/// A proposal that already HAS its answer on disk is not in doubt and is never held back,
/// even when the unreadable record names it. `confirm`/`decline` already refuse a second
/// answer, so there is nothing here to protect him from.
#[test]
fn a_proposal_whose_answer_did_load_is_never_held_back() {
    let (desk, path) = open_edited("answered", |mut l| {
        l.push(r#"{"rec":"acknowledged","id":"prop-1","at":9,"by":"ceo"}"#.to_string());
        l
    });
    assert_eq!(desk.desk_health().from_future, 1);
    assert_eq!(desk.desk_health().unresolved, 0, "prop-1's answer is right there on line 3");
    assert_eq!(desk.get("prop-1").unwrap().state, ProposalState::Written);
    discard(path);
}

/// A DAMAGED line names nothing this build will trust, so every proposal ABOVE it is in
/// doubt — and every proposal below it is not, because an answer is always appended after
/// the proposal it answers.
///
/// Until 2026-09-28 "in doubt" here meant held back forever. The CEO's answer (§96) makes it
/// "asked again, and saying so": the doubt is exactly as narrow as before, and what changes
/// is what the doubted proposal does.
#[test]
fn a_damaged_record_asks_again_about_what_is_above_it_and_nothing_below_it() {
    // A damaged line INSERTED between prop-3 (line 7) and prop-4 (which becomes line 9).
    // An answer is always appended after the proposal it answers, so this line could have
    // answered prop-3 and could not possibly have answered prop-4.
    let (desk, path) = open_edited("above-only", |lines| {
        let mut out: Vec<String> = Vec::new();
        for (i, l) in lines.into_iter().enumerate() {
            out.push(l);
            if i + 1 == 7 {
                out.push(r#"{"rec":"declined","id":"#.to_string());
            }
        }
        out
    });
    let h = desk.desk_health();
    assert_eq!(h.damaged, 1);
    assert_eq!(h.unresolved, 0, "damaged bytes never become readable, so nothing waits on them");
    assert_eq!(h.asked_again, 1, "only prop-3 is above the damage and unanswered");
    let asked: Vec<&str> = desk.asked_again().iter().map(|p| p.id.as_str()).collect();
    assert_eq!(asked, ["prop-3"]);
    assert_eq!(desk.get("prop-3").unwrap().state, ProposalState::AwaitingCeo);
    assert_eq!(desk.get("prop-3").unwrap().asked_again.as_deref(), Some(asked_again_sentence(1).as_str()));
    assert_eq!(
        desk.get("prop-4").unwrap().asked_again,
        None,
        "prop-4 was proposed BELOW the damage, so nothing above it can have answered it — an \
         ordinary question with no 'asked again' on it"
    );
    assert_eq!(desk.get("prop-1").unwrap().state, ProposalState::Written, "answered above the damage");
    assert_eq!(desk.get("prop-2").unwrap().state, ProposalState::Declined);
    let pending: Vec<&str> = desk.pending_for("ent_ceo").iter().map(|p| p.id.as_str()).collect();
    assert_eq!(pending, ["prop-3", "prop-4"]);
    discard(path);
}

// -------------------------------------------------------------------------------------
// "NEVER ASK ME ABOUT THIS AGAIN" SURVIVES TOO
// -------------------------------------------------------------------------------------

/// `decline(permanent)` writes TWO records, fsync'd separately — the `declined` and the
/// `suppressed`. The second can be the one that is unreadable, and on its own that used to
/// put a record he had permanently declined straight back in front of him. The suppression
/// is now derived from the decline itself, so the `suppressed` record is confirmatory.
#[test]
fn a_permanent_decline_survives_its_suppression_record_being_unreadable() {
    let (mut desk, _w, path) =
        open_with_line_replaced("lost-suppression", 6, r#"{"rec":"suppressed","record_ref":"#);
    assert_eq!(desk.desk_health().damaged, 1);
    assert_eq!(
        desk.suppressed(),
        ["rec:ceo/records/deal"],
        "the permanent decline is enough on its own"
    );
    match desk.propose("ent_ceo", "thr_1", a_supersede(), "again?") {
        Err(CorrectionError::Suppressed(r)) => assert_eq!(r, "rec:ceo/records/deal"),
        other => panic!("a record he permanently declined must not be proposed again: {other:?}"),
    }
    discard(path);
}

/// A `declined` record from a NEWER RichOS: a known tag, fields this build cannot fit, and a
/// writer stamp above this build's. Intact on disk, and an update reads it.
const NEWER_BUILDS_DECLINE: &str = r#"{"rec":"declined","id":"prop-2","at":5,"permanent":"forever","written_by":2}"#;

/// And when the DECLINE itself is unreadable because a NEWER build wrote it, this build
/// genuinely does not know whether he said "never again" — and an update will tell it. So it
/// holds the record rather than asking. The refusal says which of the two it is: claiming he
/// permanently declined something would be a wrong statement, not a short one.
#[test]
fn a_newer_builds_decline_puts_the_record_on_hold_rather_than_asking_about_it_again() {
    // BOTH records of the permanent decline are unreadable. Either one alone is enough to
    // reconstruct the suppression — that is the test above — so the hold path is only
    // reached when there is genuinely nothing left to read.
    let (mut desk, _w, path) = open_edited_with("lost-decline", |lines| {
        lines
            .into_iter()
            .enumerate()
            .map(|(i, l)| match i + 1 {
                5 => NEWER_BUILDS_DECLINE.to_string(),
                6 => r#"{"rec":"suppressed","record_ref":"#.to_string(),
                _ => l,
            })
            .collect()
    });
    let h = desk.desk_health();
    assert_eq!((h.from_future, h.damaged), (1, 1), "{:?}", desk.skipped_records());
    assert_eq!(h.unresolved, 1, "prop-2's answer is a newer build's, so it waits for the update");
    assert_eq!(h.asked_again, 0, "and it is NOT asked again meanwhile");
    assert!(desk.pending_for("ent_ceo").iter().all(|p| p.id != "prop-2"));
    assert_eq!(h.held_records, 1);
    assert_eq!(desk.held_records(), ["rec:ceo/records/deal"]);
    assert!(desk.suppressed().is_empty(), "this build has NOT read a permanent decline");

    match desk.propose("ent_ceo", "thr_1", a_supersede(), "again?") {
        Err(CorrectionError::HeldRecord { record_ref }) => {
            assert_eq!(record_ref, "rec:ceo/records/deal")
        }
        other => panic!("a record with an unreadable decision must be held: {other:?}"),
    }
    // A DIFFERENT record is unaffected — the hold is per record, not a shutdown.
    assert!(desk.propose("ent_ceo", "thr_1", a_second_correct(), "the lawyer changed again").is_ok());
    discard(path);
}

/// **The same loss with DAMAGED bytes, and his answer (§96) decides it the other way.** Both
/// records of the permanent decline are unreadable for good, so a hold would never lift on
/// its own. prop-2 is asked again, saying why, and the record is NOT put on hold — he is being
/// asked about it right now, and if he says "never" again that is recorded as it always was.
#[test]
fn a_damaged_decline_is_asked_again_rather_than_held_forever() {
    let (mut desk, w, path) = open_edited_with("damaged-decline", |lines| {
        lines
            .into_iter()
            .enumerate()
            .map(|(i, l)| match i + 1 {
                5 => r#"{"rec":"declined","id":"prop-2","at":5,"permanent":"#.to_string(),
                6 => r#"{"rec":"suppressed","record_ref":"#.to_string(),
                _ => l,
            })
            .collect()
    });
    let h = desk.desk_health();
    assert_eq!(h.damaged, 2);
    assert_eq!(h.unresolved, 0);
    assert_eq!(h.asked_again, 1);
    assert_eq!(h.held_records, 0, "nothing is on hold: the question is in front of him");
    let pending: Vec<&str> = desk.pending_for("ent_ceo").iter().map(|p| p.id.as_str()).collect();
    assert_eq!(pending, ["prop-2", "prop-3", "prop-4"]);
    assert!(desk.get("prop-2").unwrap().asked_again.is_some());

    // He says never, again — and that is exactly as durable as the first time.
    desk.decline("prop-2", true).unwrap();
    assert_eq!(desk.suppressed(), ["rec:ceo/records/deal"]);
    assert_eq!(w.commits(), 0, "a decline writes nothing to loro");
    drop(desk);
    let reopened = CorrectionDesk::open(&path, Box::new(Recorder::default())).unwrap();
    assert_eq!(reopened.get("prop-2").unwrap().state, ProposalState::Declined);
    assert_eq!(reopened.suppressed(), ["rec:ceo/records/deal"]);
    assert_eq!(reopened.desk_health().asked_again, 0, "answered below the damage: settled for good");
    discard(path);
}

/// A hold he lifts stays lifted. `unsuppress` writes a durable record, so the next replay
/// does not silently re-apply the same hold and make the lift look like it never happened.
#[test]
fn a_hold_the_ceo_lifts_stays_lifted_across_a_restart() {
    let (mut desk, _w, path) = open_edited_with("lift-hold", |lines| {
        lines
            .into_iter()
            .enumerate()
            .map(|(i, l)| match i + 1 {
                5 => NEWER_BUILDS_DECLINE.to_string(),
                6 => r#"{"rec":"suppressed","record_ref":"#.to_string(),
                _ => l,
            })
            .collect()
    });
    assert_eq!(desk.held_records(), ["rec:ceo/records/deal"]);
    desk.unsuppress("rec:ceo/records/deal").unwrap();
    assert!(desk.held_records().is_empty());
    assert!(desk.propose("ent_ceo", "thr_1", a_supersede(), "go ahead").is_ok());
    drop(desk);

    let reopened = CorrectionDesk::open(&path, Box::new(Recorder::default())).unwrap();
    assert!(
        reopened.held_records().is_empty(),
        "the lift is durable — a replay must not re-apply a hold he cleared"
    );
    assert_eq!(reopened.desk_health().held_records, 0);
    discard(path);
}

// -------------------------------------------------------------------------------------
// THE QUARANTINE IS A PROJECTION, NOT A WRITE
// -------------------------------------------------------------------------------------

/// **The anti-vacuous test for the quarantine.** An untouched desk holds NOTHING back, and
/// the one genuinely open proposal is offered and can be confirmed all the way through to
/// the writer. A change that held everything back would pass every test above and fail
/// this one, and it is the failure that would matter: he would stop being asked at all.
#[test]
fn nothing_is_held_back_on_an_untouched_desk_and_a_real_proposal_still_reaches_the_writer() {
    let path = scratch("hold-nothing");
    write_real_desk(&path);
    let w = Recorder::default();
    let mut desk = CorrectionDesk::open(&path, Box::new(w.clone())).unwrap();
    let h = desk.desk_health();
    assert_eq!(h.unresolved, 0, "nothing is in doubt on a file with nothing wrong in it");
    assert_eq!(h.held_records, 0);
    assert!(desk.unresolved().is_empty());
    assert!(desk.held_records().is_empty());

    let confirmed = desk.confirm("ent_ceo", "prop-3").unwrap();
    assert_eq!(confirmed.state, ProposalState::Written);
    assert_eq!(w.commits(), 1, "the open proposal went all the way to the writer");
    discard(path);
}

/// `Unresolved` is never written to disk. It is recomputed from the file on every open, so
/// a build that CAN read the record resolves it — which is what makes "updating will bring
/// it back" true of the proposal and not only of the record.
#[test]
fn the_quarantine_is_recomputed_from_the_file_and_never_written_into_it() {
    let path = scratch("no-write-back");
    write_real_desk(&path);
    let mut lines = lines_of(&path);
    let future = r#"{"rec":"acknowledged","id":"prop-3","at":9,"by":"ceo"}"#.to_string();
    lines.push(future.clone());
    let mut f = std::fs::File::create(&path).unwrap();
    for l in &lines {
        writeln!(f, "{l}").unwrap();
    }
    drop(f);

    let before = std::fs::read(&path).unwrap();
    let desk = CorrectionDesk::open(&path, Box::new(Recorder::default())).unwrap();
    assert_eq!(desk.desk_health().unresolved, 1);
    assert_eq!(std::fs::read(&path).unwrap(), before, "the quarantine rewrote the file");
    let text = std::fs::read_to_string(&path).unwrap();
    assert!(!text.contains("unresolved"), "the held-back state must never reach the disk");

    // Remove the record this build could not read — the stand-in for an update that can —
    // and the proposal comes back exactly as it was.
    let mut f = std::fs::File::create(&path).unwrap();
    for l in lines.iter().filter(|l| **l != future) {
        writeln!(f, "{l}").unwrap();
    }
    drop(f);
    let updated = CorrectionDesk::open(&path, Box::new(Recorder::default())).unwrap();
    assert_eq!(updated.desk_health().unresolved, 0);
    assert_eq!(updated.get("prop-3").unwrap().state, ProposalState::AwaitingCeo);
    discard(path);
}

// -------------------------------------------------------------------------------------
// HIS ANSWER, 2026-09-28 (ceo-decisions.md §96, escalation esc-20260905T124300Z-3ce871e9)
//
// Asked: "If the file holding your past answers gets corrupted, RichOS can't tell whether
// you already answered. Should it ask you again, or stay silent about that one?"
// He answered: "Ask me again".
// -------------------------------------------------------------------------------------

/// **The acceptance test for his answer.** A DAMAGED line sits where prop-3's answer could
/// have been. Until this change prop-3 was held back forever — damaged bytes never become
/// readable — so it could never reach him again. Now it is an ordinary question: offered,
/// and confirmable all the way to the writer, exactly once, and settled for good afterwards.
#[test]
fn a_correction_whose_answer_is_damaged_is_asked_again_and_can_be_confirmed() {
    let (mut desk, w, path) = open_edited_with("ask-again", |lines| {
        let mut out: Vec<String> = Vec::new();
        for (i, l) in lines.into_iter().enumerate() {
            out.push(l);
            if i + 1 == 7 {
                // Damaged bytes directly under prop-3: the one place its answer could be.
                out.push(r#"{"rec":"declined","id":"#.to_string());
            }
        }
        out
    });
    assert_eq!(desk.desk_health().damaged, 1);

    // Offered again, as an ordinary question, beside the one that was never in doubt.
    let pending: Vec<&str> = desk.pending_for("ent_ceo").iter().map(|p| p.id.as_str()).collect();
    assert_eq!(pending, ["prop-3", "prop-4"], "prop-3 must be back in front of him");
    assert_eq!(desk.get("prop-3").unwrap().state, ProposalState::AwaitingCeo);
    assert!(desk.unresolved().is_empty(), "nothing is held back any more");
    // ...and the question says plainly why he is seeing it.
    assert_eq!(
        desk.get("prop-3").unwrap().asked_again.as_deref(),
        Some("RichOS could not read your earlier answer to this correction, so it is asking you again. You may already have answered it."),
    );

    // And he can answer it: the write reaches the writer exactly once.
    let done = desk.confirm("ent_ceo", "prop-3").expect("a re-asked correction can be confirmed");
    assert_eq!(done.state, ProposalState::Written);
    assert_eq!(w.commits(), 1);
    assert!(desk.pending_for("ent_ceo").iter().all(|p| p.id != "prop-3"), "answered, so gone");
    drop(desk);

    // His new answer is durable and sits BELOW the damage, so the next open reads it and
    // never asks a third time.
    let reopened = CorrectionDesk::open(&path, Box::new(Recorder::default())).unwrap();
    assert_eq!(reopened.get("prop-3").unwrap().state, ProposalState::Written);
    let pending: Vec<&str> = reopened.pending_for("ent_ceo").iter().map(|p| p.id.as_str()).collect();
    assert_eq!(pending, ["prop-4"]);
    assert_eq!(reopened.desk_health().unresolved, 0);
    discard(path);
}

/// The real eight-line desk with damaged bytes directly under prop-3 (line 7).
fn damaged_under_prop_3(lines: Vec<String>) -> Vec<String> {
    let mut out: Vec<String> = Vec::new();
    for (i, l) in lines.into_iter().enumerate() {
        out.push(l);
        if i + 1 == 7 {
            out.push(r#"{"rec":"declined","id":"#.to_string());
        }
    }
    out
}

/// **One sentence, every surface.** The card's line and the health notice's line come from
/// one composer, so the desktop card, any other client rendering a `Proposal`, and the boot
/// notice cannot drift into three wordings of the same fact.
#[test]
fn the_card_and_the_health_notice_say_the_same_thing() {
    let (one, _w, path_one) = open_edited_with("asked-again-one", damaged_under_prop_3);
    let h = one.desk_health();
    assert_eq!(h.headline, "A correction you may have already answered is being asked again.");
    let card = one.get("prop-3").unwrap().asked_again.clone().unwrap();
    assert!(h.detail.contains(&card), "the notice must carry the card's own sentence: {}", h.detail);
    assert!(h.detail.contains("1 record is damaged"), "and still name the cause: {}", h.detail);
    assert!(!h.is_clean());

    // Two asked again reads as two, from the same composer.
    let (two, _w2, path_two) = open_edited_with("asked-again-two", |mut l| {
        l.push(r#"{"rec":"declined","id":"#.to_string());
        l
    });
    let h = two.desk_health();
    assert_eq!(h.asked_again, 2);
    assert_eq!(h.headline, "Some corrections you may have already answered are being asked again.");
    assert!(h.detail.contains(&asked_again_sentence(2)), "{}", h.detail);
    assert!(h.detail.contains("earlier answers to 2 corrections"), "{}", h.detail);
    for id in ["prop-3", "prop-4"] {
        assert_eq!(two.get(id).unwrap().asked_again.as_deref(), Some(asked_again_sentence(1).as_str()));
    }
    discard(path_one);
    discard(path_two);
}

/// **Demonstrably answered is never re-asked**, from both directions a loaded record can
/// prove it: an answer that loaded (prop-1 written, prop-2 declined, both ABOVE the damage),
/// and a `confirmed` record that loaded while the writer's receipt is the damaged line.
#[test]
fn a_correction_he_demonstrably_answered_is_never_asked_again() {
    // Damage at the very end: every proposal is above it.
    let (desk, _w, path) = open_edited_with("answered-stays-answered", |mut l| {
        l.push(r#"{"rec":"declined","id":"#.to_string());
        l
    });
    assert_eq!(desk.get("prop-1").unwrap().state, ProposalState::Written);
    assert_eq!(desk.get("prop-2").unwrap().state, ProposalState::Declined);
    assert!(desk.get("prop-1").unwrap().asked_again.is_none());
    assert!(desk.get("prop-2").unwrap().asked_again.is_none());
    let asked: Vec<&str> = desk.asked_again().iter().map(|p| p.id.as_str()).collect();
    assert_eq!(asked, ["prop-3", "prop-4"], "only the two he never answered");
    discard(path);

    // He said yes (line 2 loaded); the receipt (line 3) is the damage. The write may have
    // landed, so asking again could run it twice: held, exactly as before §96.
    let (mut desk, w, path) =
        open_with_line_replaced("confirmed-stays-held", 3, r#"{"rec":"written","id":"prop-1","at":3,"outcome":"#);
    assert_eq!(desk.get("prop-1").unwrap().state, ProposalState::Unresolved);
    assert!(desk.get("prop-1").unwrap().asked_again.is_none());
    assert_eq!(desk.desk_health().asked_again, 0);
    assert!(desk.pending_for("ent_ceo").iter().all(|p| p.id != "prop-1"));
    assert!(desk.confirm("ent_ceo", "prop-1").is_err());
    assert_eq!(w.commits(), 0);
    discard(path);
}

/// An unstamped misfit (`Ambiguous`) that names its proposal is not a newer build's record —
/// every build that writes one stamps it — so no update will ever read it. It asks again
/// about exactly the proposal it names, and no other.
#[test]
fn an_unstamped_misfit_asks_again_about_only_the_proposal_it_names() {
    let (desk, path) = open_edited("ambiguous-names-one", |mut l| {
        l.push(r#"{"rec":"written","id":"prop-3","at":7,"outcome":42}"#.to_string());
        l
    });
    let h = desk.desk_health();
    assert_eq!(h.ambiguous, 1);
    assert_eq!((h.unresolved, h.asked_again), (0, 1));
    assert!(desk.get("prop-3").unwrap().asked_again.is_some());
    assert!(desk.get("prop-4").unwrap().asked_again.is_none(), "not named, so not in doubt");
    discard(path);
}

/// A line that is not text at all could have been any answer to anything above it. It used
/// to be counted and then left out of the reckoning, so the proposal above it came back as a
/// plain question with nothing saying why. Now it says why.
#[test]
fn an_answer_turned_into_non_text_is_asked_again_and_says_so() {
    let path = scratch("non-text-answer");
    write_real_desk(&path);
    let lines = lines_of(&path);
    let mut f = std::fs::File::create(&path).unwrap();
    for (i, l) in lines.iter().enumerate() {
        writeln!(f, "{l}").unwrap();
        if i + 1 == 7 {
            f.write_all(&[0xff, 0xfe, 0xff, b'\n']).unwrap();
        }
    }
    drop(f);
    let desk = CorrectionDesk::open(&path, Box::new(Recorder::default())).unwrap();
    assert_eq!(desk.desk_health().damaged, 1);
    let asked: Vec<&str> = desk.asked_again().iter().map(|p| p.id.as_str()).collect();
    assert_eq!(asked, ["prop-3"], "prop-3 is above the bytes, prop-4 below them");
    discard(path);
}

/// **A record he said never to ask about stays unasked** — the one answer this build CAN read
/// wins over the one it cannot. And lifting that suppression turns the held proposal into a
/// question at once, and on every open after, because the lift is durable.
#[test]
fn a_suppressed_record_is_not_asked_about_until_he_lifts_it() {
    let path = scratch("suppressed-then-lifted");
    discard(&path);
    let mut desk = CorrectionDesk::open(&path, Box::new(Recorder::default())).unwrap();
    desk.propose("ent_ceo", "thr_1", a_supersede(), "that is not what I decided").unwrap(); // prop-1
    desk.propose("ent_ceo", "thr_1", a_supersede(), "still not what I decided").unwrap(); // prop-2
    desk.decline("prop-2", true).unwrap(); // never ask about the deal record again
    drop(desk);
    // Damaged bytes directly under prop-1: its answer could have been there.
    let lines = lines_of(&path);
    let mut f = std::fs::File::create(&path).unwrap();
    for (i, l) in lines.iter().enumerate() {
        writeln!(f, "{l}").unwrap();
        if i == 0 {
            writeln!(f, r#"{{"rec":"declined","id":"#).unwrap();
        }
    }
    drop(f);

    let mut desk = CorrectionDesk::open(&path, Box::new(Recorder::default())).unwrap();
    assert_eq!(desk.suppressed(), ["rec:ceo/records/deal"]);
    assert_eq!(desk.get("prop-1").unwrap().state, ProposalState::Unresolved);
    assert!(desk.pending_for("ent_ceo").is_empty(), "he said never ask about this record");
    assert_eq!(desk.desk_health().asked_again, 0);

    desk.unsuppress("rec:ceo/records/deal").unwrap();
    let pending: Vec<&str> = desk.pending_for("ent_ceo").iter().map(|p| p.id.as_str()).collect();
    assert_eq!(pending, ["prop-1"], "lifted, so asked — now, not after a restart");
    assert_eq!(desk.get("prop-1").unwrap().asked_again.as_deref(), Some(asked_again_sentence(1).as_str()));
    drop(desk);

    let reopened = CorrectionDesk::open(&path, Box::new(Recorder::default())).unwrap();
    let pending: Vec<&str> = reopened.pending_for("ent_ceo").iter().map(|p| p.id.as_str()).collect();
    assert_eq!(pending, ["prop-1"], "and the lift is durable");
    assert!(reopened.get("prop-1").unwrap().asked_again.is_some());
    discard(path);
}

/// The asked-again state is a PROJECTION: not one byte of it reaches the desk log, so an
/// older build reads exactly what it read before.
#[test]
fn asking_again_writes_nothing_into_the_desk_log() {
    let path = scratch("asked-again-no-write");
    write_real_desk(&path);
    let edited = damaged_under_prop_3(lines_of(&path));
    let mut f = std::fs::File::create(&path).unwrap();
    for l in &edited {
        writeln!(f, "{l}").unwrap();
    }
    drop(f);
    let before = std::fs::read(&path).unwrap();
    let desk = CorrectionDesk::open(&path, Box::new(Recorder::default())).unwrap();
    assert_eq!(desk.desk_health().asked_again, 1);
    assert_eq!(std::fs::read(&path).unwrap(), before, "opening rewrote the file");
    assert!(!String::from_utf8_lossy(&before).contains("asked_again"));
    discard(path);
}

/// **The UI fixture is the proposal the desk really asks again**, byte for byte — the same
/// posture as `belief_trigger_tests`' fixture: `ui/tests/corrections.js` renders THIS file,
/// so the sentence on the desktop card is read off the Rust desk, never retyped in JS.
/// Regenerate with `RICHOS_WRITE_FIXTURES=1`.
#[test]
fn the_ui_fixture_is_the_proposal_the_desk_really_asks_again() {
    let (desk, _w, path) = open_edited_with("asked-again-fixture", damaged_under_prop_3);
    let p = desk.get("prop-3").unwrap().clone();
    assert!(p.asked_again.is_some());
    let mut json = serde_json::to_value(&p).unwrap();
    json["at"] = serde_json::json!(0);
    let rendered = serde_json::to_string_pretty(&json).unwrap() + "\n";
    let fixture = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../ui/tests/fixtures/loro-proposal-asked-again.json");
    if std::env::var("RICHOS_WRITE_FIXTURES").is_ok() {
        std::fs::write(&fixture, &rendered).unwrap();
    }
    let on_disk = std::fs::read_to_string(&fixture).unwrap_or_else(|e| {
        panic!("the UI fixture is missing at {} ({e}) — regenerate with RICHOS_WRITE_FIXTURES=1", fixture.display())
    });
    assert_eq!(on_disk, rendered, "the UI fixture no longer matches what the desk asks again");
    discard(path);
}

/// The consequence he can feel leads the notice, ahead of its cause: whether the record was
/// damaged or written by a newer build matters less to him than a decision of his not being
/// acted on. Both are said, in that order.
#[test]
fn the_notice_leads_with_the_held_back_correction_and_still_names_the_cause() {
    let (desk, _w, path) =
        open_with_line_replaced("notice", 3, r#"{"rec":"written","id":"prop-1","at":3,"outcome":"#);
    let h = desk.desk_health();
    assert_eq!(h.headline, "A correction you may have already answered is being held back.");
    assert!(h.detail.contains("1 record is damaged"), "the cause is still stated: {}", h.detail);
    assert!(
        h.detail.contains("asking you a second time about something you have already decided"),
        "{}",
        h.detail
    );
    assert!(h.detail.contains("7 of 8 records"), "{}", h.detail);
    assert!(!h.detail.contains("1 corrections"), "{}", h.detail);

    // Two held back reads as two.
    let (two, _w2, path2) = open_edited_with("notice-two", |mut l| {
        l.push(r#"{"rec":"acknowledged","id":"prop-3","at":9}"#.to_string());
        l.push(r#"{"rec":"acknowledged","id":"prop-4","at":10}"#.to_string());
        l
    });
    let h = two.desk_health();
    assert_eq!(h.unresolved, 2);
    assert_eq!(h.headline, "Some corrections you may have already answered are being held back.");
    assert!(h.detail.contains("2 corrections are being held back"), "{}", h.detail);
    discard(path);
    discard(path2);
}

/// Test cleanup: a file already gone is fine; any other failure is a real fault.
fn discard(path: impl AsRef<std::path::Path>) {
    match std::fs::remove_file(path.as_ref()) {
        Ok(()) => {}
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
        Err(e) => panic!("cleanup of {} failed: {e}", path.as_ref().display()),
    }
}
