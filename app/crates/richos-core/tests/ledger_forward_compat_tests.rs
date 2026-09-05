//! **NOTHING ALREADY READABLE MAY BECOME LESS READABLE.**
//!
//! This suite exists to hold one line, and it holds it with a recording rather than an
//! argument: `tests/fixtures/ledgers/*.golden` is a content-free digest of the projection
//! that `Ledger::open` built from those exact bytes at `ccaaf00` — the reader that shipped
//! in v1.0.0, v1.0.1 and v1.0.2. Every one of those three builds is still published and
//! still downloadable. If a change to how a ledger is read alters one character of a
//! golden, it has changed what a customer's history says, and this suite fails.
//!
//! The fixtures are synthetic (see `fixtures/ledgers/README.md`) but their SHAPES are not
//! invented: each record shape was read off the five real `conversation-ledger.jsonl`
//! files on the author's machine and reproduced field-for-field with the content replaced.
//! A public repository is no place for a real ledger, even a hashed one.

#[path = "support/ledger_digest.rs"]
mod ledger_digest;

use std::path::{Path, PathBuf};

fn fixtures() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/ledgers")
}

fn scratch(name: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!(
        "richos-fwdcompat-{}-{}-{name}",
        std::process::id(),
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos()
    ));
    std::fs::create_dir_all(&dir).expect("scratch dir");
    dir
}

/// Digest one fixture and compare it, line by line, against the golden beside it.
fn assert_matches_golden(stem: &str) {
    let src = fixtures().join(format!("{stem}.jsonl"));
    let golden_path = fixtures().join(format!("{stem}.golden"));
    let dir = scratch(stem);

    let mut actual = vec![format!("=== ledger {} ===", ledger_digest::label(&src))];
    actual.extend(
        ledger_digest::digest_ledger(&src, &dir.join("copy.jsonl"))
            .unwrap_or_else(|e| panic!("{stem} did not replay at all: {e}")),
    );

    let golden = std::fs::read_to_string(&golden_path)
        .unwrap_or_else(|e| panic!("golden {}: {e}", golden_path.display()));
    let expected: Vec<&str> = golden.lines().collect();

    for (i, (a, e)) in actual.iter().zip(expected.iter()).enumerate() {
        assert_eq!(
            a,
            e,
            "\n{stem}: line {} of the projection changed.\n  the shipped reader produced: {e}\n  \
             this build produced:         {a}\nA customer on v1.0.0-v1.0.2 reads these bytes \
             with the recorded behavior. Changing it changes their history.",
            i + 1
        );
    }
    assert_eq!(
        actual.len(),
        expected.len(),
        "{stem}: the projection has {} lines and the shipped reader produced {}",
        actual.len(),
        expected.len()
    );

    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn every_record_shape_the_shipped_builds_wrote_still_replays_identically() {
    assert_matches_golden("v1-current");
}

#[test]
fn every_legacy_record_shape_still_replays_identically() {
    assert_matches_golden("v1-legacy");
}

/// The digest is only evidence if it is deterministic. Two runs over the same bytes must
/// agree, or a passing golden comparison proves nothing about the run after it.
#[test]
fn the_digest_is_deterministic_across_runs() {
    let src = fixtures().join("v1-legacy.jsonl");
    let a = ledger_digest::digest_ledger(&src, &scratch("det-a").join("copy.jsonl")).unwrap();
    let b = ledger_digest::digest_ledger(&src, &scratch("det-b").join("copy.jsonl")).unwrap();
    assert_eq!(a, b, "the same bytes digested twice must give the same answer");
}

/// The tool is run against real ledgers on a real machine. It must never open the
/// original for writing, and it must leave the original byte-for-byte and
/// modification-time untouched.
#[test]
fn digesting_a_ledger_does_not_touch_the_original() {
    let dir = scratch("readonly");
    let original = dir.join("customer.jsonl");
    let bytes = std::fs::read(fixtures().join("v1-current.jsonl")).unwrap();
    std::fs::write(&original, &bytes).unwrap();
    let before_len = std::fs::metadata(&original).unwrap().len();
    let before_mtime = std::fs::metadata(&original).unwrap().modified().unwrap();

    ledger_digest::digest_ledger(&original, &dir.join("copy.jsonl")).unwrap();

    let after = std::fs::read(&original).unwrap();
    assert_eq!(after, bytes, "the original ledger's bytes changed");
    assert_eq!(std::fs::metadata(&original).unwrap().len(), before_len);
    assert_eq!(
        std::fs::metadata(&original).unwrap().modified().unwrap(),
        before_mtime,
        "the original ledger was written to"
    );
    let _ = std::fs::remove_dir_all(&dir);
}
