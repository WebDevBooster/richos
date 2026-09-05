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
    CorrectionDesk, CorrectionError, LoroWriteBackend, ProposalState, ProposedWrite, WriteOutput,
    KNOWN_DESK_TAGS,
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

/// A genuine seven-record desk log, written by the product's own desk:
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
fn write_real_desk(path: &PathBuf) -> Recorder {
    let _ = std::fs::remove_file(path);
    let w = Recorder::default();
    let mut desk = CorrectionDesk::open(path, Box::new(w.clone())).unwrap();
    desk.propose("ent_ceo", "thr_1", an_append(), "the price was wrong").unwrap();
    desk.confirm("ent_ceo", "prop-1").unwrap();
    desk.propose("ent_ceo", "thr_1", a_supersede(), "that is not what I decided").unwrap();
    desk.decline("prop-2", true).unwrap();
    desk.propose("ent_ceo", "thr_1", a_correct(), "the title is wrong").unwrap();
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
    let path = scratch(name);
    write_real_desk(&path);
    let edited = edit(lines_of(&path));
    let mut f = std::fs::File::create(&path).unwrap();
    for l in &edited {
        writeln!(f, "{l}").unwrap();
    }
    drop(f);
    let desk = CorrectionDesk::open(&path, Box::new(Recorder::default())).unwrap();
    (desk, path)
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
    assert_eq!(h.records_read, 7, "3 proposed, 1 confirmed, 1 written, 1 declined, 1 suppressed");
    assert_eq!(h.records_applied, 7, "every record must be APPLIED, not skipped");
    assert_eq!(h.skipped, 0);
    assert_eq!(h.headline, "", "a clean desk says nothing at all");
    assert_eq!(h.detail, "");

    // And the projection still means exactly what it always meant.
    assert_eq!(desk.get("prop-1").unwrap().state, ProposalState::Written, "he confirmed prop-1");
    assert_eq!(desk.get("prop-2").unwrap().state, ProposalState::Declined, "he declined prop-2");
    assert_eq!(desk.get("prop-3").unwrap().state, ProposalState::AwaitingCeo);
    assert_eq!(desk.suppressed(), ["rec:ceo/records/deal"]);
    let pending: Vec<&str> = desk.pending_for("ent_ceo").iter().map(|p| p.id.as_str()).collect();
    assert_eq!(pending, ["prop-3"], "exactly the one he has not answered");
    let _ = std::fs::remove_file(path);
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
    let _ = std::fs::remove_file(path);
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
    let _ = std::fs::remove_file(path);
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
    assert_eq!(lines.len(), 7);
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
    assert_eq!(h.records_read, 7, "all seven lines were still visited");
    assert_eq!(h.records_applied, 6, "six of seven folded");
    assert_eq!(desk.skipped_records()[0].kind, SkipKind::Damaged);
    assert_eq!(desk.skipped_records()[0].line, 2);

    // Everything BELOW the bad byte still loaded. This is the whole point.
    assert_eq!(desk.get("prop-1").unwrap().state, ProposalState::Written, "line 3 survived");
    assert_eq!(desk.get("prop-2").unwrap().state, ProposalState::Declined, "line 5 survived");
    assert!(desk.get("prop-3").is_some(), "line 7 survived");
    assert_eq!(desk.suppressed(), ["rec:ceo/records/deal"], "line 6 survived");
    let _ = std::fs::remove_file(path);
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
    assert!(h.headline.contains("newer version of RichOS"), "{}", h.headline);
    assert!(!h.headline.contains("could not be read"), "a benign record is not damage: {}", h.headline);
    assert!(h.detail.contains("Updating will bring it back"), "{}", h.detail);
    let _ = std::fs::remove_file(path);
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
    assert!(h.headline.contains("could not be read"), "{}", h.headline);
    let _ = std::fs::remove_file(path);
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
    let _ = std::fs::remove_file(path);
}

/// Damage that LOOKS like a new record type is still damage. A tag that is not a plain
/// identifier did not come out of a newer RichOS.
#[test]
fn a_mangled_tag_is_damage_not_a_new_record_type() {
    let (desk, path) = open_edited("mangled-tag", |mut l| {
        l.push(r#"{"rec":"wr itt en","id":"prop-3","at":7}"#.to_string());
        l
    });
    let h = desk.desk_health();
    assert_eq!(h.damaged, 1);
    assert_eq!(h.from_future, 0, "corruption must never be waved through as the future");
    assert_eq!(desk.skipped_records()[0].tag, None, "a mangled tag is not kept");
    let _ = std::fs::remove_file(path);
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
    assert_eq!(h.records_read, 10, "7 real + 3 planted");
    assert_eq!(h.records_applied, 7);
    assert_eq!(h.skipped, 3);
    assert_eq!(h.from_future + h.damaged + h.ambiguous, h.skipped, "every skip has exactly one kind");
    assert_eq!((h.from_future, h.damaged, h.ambiguous), (1, 1, 1));
    assert!(h.detail.contains("7 of 10 records"), "{}", h.detail);
    let _ = std::fs::remove_file(path);
}

/// An empty file and an absent file are both clean, and neither says anything.
#[test]
fn an_absent_or_empty_desk_says_nothing() {
    let path = scratch("absent");
    let _ = std::fs::remove_file(&path);
    let desk = CorrectionDesk::open(&path, Box::new(Recorder::default())).unwrap();
    let h = desk.desk_health();
    assert!(h.is_clean());
    assert_eq!((h.records_read, h.records_applied), (0, 0));
    assert_eq!(h.headline, "");

    std::fs::write(&path, "\n\n").unwrap();
    let desk = CorrectionDesk::open(&path, Box::new(Recorder::default())).unwrap();
    assert!(desk.desk_health().is_clean(), "blank lines are not records");
    assert_eq!(desk.desk_health().records_read, 0);
    let _ = std::fs::remove_file(path);
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
    let _ = std::fs::remove_file(path_one);
    let _ = std::fs::remove_file(path_two);
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
    let _ = std::fs::remove_file(path);
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
    assert_eq!(fresh.id, "prop-4", "a damaged line must not move the counter to 901");
    let _ = std::fs::remove_file(path);
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
        let _ = std::fs::remove_file(path);
    }
}

/// The anti-vacuous half of the secrecy test: the same planted string in a record that
/// PARSES is not reported at all, so the test above is not passing because nothing is ever
/// reported.
#[test]
fn a_desk_carrying_the_same_words_in_a_readable_record_reports_nothing_at_all() {
    const SECRET: &str = "ACQUISITION-PRICE-IS-FORTY-MILLION";
    let path = scratch("secret-clean");
    let _ = std::fs::remove_file(&path);
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
    let _ = std::fs::remove_file(path);
}
