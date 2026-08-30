//! **NOTHING GOES OUTBOUND.** The CEO's constraint on the feedback channel's v1 half,
//! asserted mechanically instead of promised in a comment.
//!
//! # Why this suite is not in `feedback.rs`
//!
//! Most of what follows reads the feedback module's own source and fails on tokens that
//! would indicate a way off this machine. If the check lived inside the file it reads,
//! its own list of banned tokens would be in the text being scanned, and the test would
//! either fail against itself or have to be written in an obfuscated way that nobody can
//! review. It lives one directory over, where the list can be plain.
//!
//! # What "no outbound path" is taken to mean, stated so it can be argued with
//!
//! Three separate claims, each with its own test, because they fail independently:
//!
//! 1. **The feature contains no transport.** No socket, no client, no address, no
//!    subprocess — checked against the module's code with its comments removed, so the
//!    words in the prose above cannot make the check pass or fail.
//! 2. **The crate could not reach the network if it wanted to.** `richos-core` depends on
//!    four crates, none of which can open a connection. A dependency added later fails
//!    this test by name, which is the point: the person adding it has to say what it is.
//! 3. **Nothing else in the crate consumes the feature.** The module is reachable only
//!    from the crate root. It is not wired into the ACP client, the spine, or anything
//!    else that already talks to a subprocess, so there is no existing pipe for a report
//!    to be handed to.
//!
//! And one behavioural claim: recording an approval touches exactly one file and leaves
//! no second artefact — no spool, no marker, no "unsent" shard that a later version could
//! find and flush.

use richos_core::feedback::*;
use std::collections::BTreeSet;

/// The feedback module's source, embedded at compile time so this test cannot be fooled
/// by a working directory.
const FEEDBACK_SOURCE: &str = include_str!("../src/feedback.rs");

/// The crate manifest, same reasoning.
const MANIFEST: &str = include_str!("../Cargo.toml");

/// Everything a report could be handed to, or handed through.
///
/// Matched against lower-cased code with comments removed. The list is deliberately
/// broader than "things that open a socket": a subprocess is a transport, an outbox is a
/// transport with a delay on it, and both are the shapes a "just wire it up" commit
/// reaches for first.
///
/// **String literals are in scope on purpose** — an address is a literal, so exempting
/// them would exempt the thing most worth finding. The price is real and was paid on the
/// first run: this list rejected the module's own user-facing heading, which said RichOS
/// had no way to "transmit" the report. The copy was reworded, not the check. Product
/// copy in this module may not use transport vocabulary verbatim, and that is the cheaper
/// side of the trade.
const BANNED_IN_CODE: &[&str] = &[
    // A connection, by any name.
    "tcpstream",
    "tcplistener",
    "udpsocket",
    "socket",
    "std::net",
    "toserveraddrs",
    "reqwest",
    "hyper",
    "ureq",
    "isahc",
    "attohttpc",
    "curl",
    "http",
    "url",
    "websocket",
    "grpc",
    "dns",
    // A subprocess is a transport too — `acp.rs` in this same crate talks to another
    // program this way.
    "command",
    "process::",
    "spawn",
    // A queue is a transport with a delay on it. This is the class the CEO named: "no
    // queue that something else could later flush."
    "outbox",
    "spool",
    "enqueue",
    "dequeue",
    "unsent",
    "transmit",
    "upload",
    "telemetry",
    "analytics",
    "beacon",
    "endpoint",
    "webhook",
    "bearer",
    "api_key",
];

/// Strip comments and the in-file test module, leaving only shipping code.
///
/// Comments must go or the module's own doc prose — which discusses transports at
/// length, deliberately — would trip every needle. The test module must go because its
/// fixtures build JSON by hand and use `std::process::id()` for temp paths; neither is a
/// path off this machine, and neither ships.
fn shipping_code(src: &str) -> String {
    let cut = src.find("#[cfg(test)]").unwrap_or(src.len());
    src[..cut]
        .lines()
        .map(|line| match line.find("//") {
            Some(i) => &line[..i],
            None => line,
        })
        .collect::<Vec<_>>()
        .join("\n")
        .to_lowercase()
}

#[test]
fn the_feedback_module_contains_no_transport_of_any_kind() {
    let code = shipping_code(FEEDBACK_SOURCE);
    // Guard the guard: if the strip ever eats the whole file, every needle passes
    // vacuously and this suite reports green over nothing.
    assert!(
        code.contains("pub fn render_disclosure"),
        "comment/test stripping removed the code it was supposed to check"
    );
    for needle in BANNED_IN_CODE {
        assert!(
            !code.contains(needle),
            "the feedback module's shipping code contains {needle:?} — \
             v1 has no outbound path and must not acquire one by accident"
        );
    }
}

#[test]
fn the_crate_depends_on_nothing_that_could_open_a_connection() {
    // Not "the feedback module does not call the network" — the stronger claim that
    // there is nothing here to call. serde/serde_json are data formats, uuid generates
    // identifiers, thiserror derives error types. None can reach a host.
    let mut found: BTreeSet<&str> = BTreeSet::new();
    let mut in_deps = false;
    for line in MANIFEST.lines() {
        let t = line.trim();
        if t.starts_with('[') {
            in_deps = t == "[dependencies]";
            continue;
        }
        if !in_deps || t.is_empty() || t.starts_with('#') {
            continue;
        }
        if let Some((name, _)) = t.split_once('=') {
            found.insert(name.trim());
        }
    }
    let expected: BTreeSet<&str> =
        ["serde", "serde_json", "uuid", "thiserror"].into_iter().collect();
    assert_eq!(
        found, expected,
        "richos-core's dependency set changed. That is not automatically wrong — but the \
         feedback channel's 'nothing goes outbound' guarantee rests on this crate having \
         no network-capable dependency, so state what the new one is and why it cannot \
         reach a host, then update this list."
    );
    assert!(
        !MANIFEST.contains("[dev-dependencies]"),
        "a dev-dependency arrived; check it the same way and update this assertion"
    );
}

#[test]
fn no_other_module_in_the_crate_consumes_the_feedback_feature() {
    // The module is reachable from the crate root and nowhere else. So a report cannot be
    // slipped into a pipe that already exists — notably acp.rs, which does talk to
    // another program.
    let src_dir = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("src");
    let mut consumers: Vec<String> = Vec::new();
    let mut checked = 0usize;
    for entry in std::fs::read_dir(&src_dir).expect("src/ is readable") {
        let path = entry.unwrap().path();
        let name = path.file_name().unwrap().to_string_lossy().into_owned();
        if path.extension().and_then(|e| e.to_str()) != Some("rs") {
            continue;
        }
        if name == "lib.rs" || name == "feedback.rs" {
            continue;
        }
        checked += 1;
        let text = std::fs::read_to_string(&path).unwrap();
        if text.contains("feedback::") || text.contains("crate::feedback") {
            consumers.push(name);
        }
    }
    assert!(checked > 10, "only {checked} modules scanned — the walk found the wrong directory");
    assert!(
        consumers.is_empty(),
        "the feedback module is consumed by {consumers:?}. That may be legitimate, but it \
         means a report can now reach code this suite has not checked for a transport."
    );
}

#[test]
fn an_approved_report_lands_in_one_local_file_and_leaves_nothing_else_behind() {
    // The behavioural half. Whatever the source says, this watches the filesystem: one
    // file, containing the payload, with no sibling for anything to pick up later.
    let dir = std::env::temp_dir().join(format!(
        "richos-feedback-outbound-{}-{}",
        std::process::id(),
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos()
    ));
    let path = dir.join("feedback.jsonl");
    let store = FeedbackStore::open(&path).unwrap();

    let payload = FeedbackPayload::assemble(
        Rating::Bad,
        FailureClass::UnpreparedTaskHandedToUser,
        Occurrences::ThreeTimes,
        vec![DiagnosisTerm::NoInputArtifactNamed, DiagnosisTerm::NoMethodGiven],
        vec![ContributingCondition::NoUserFacingItemCarriedAnAcceptanceCriterion],
    )
    .unwrap();
    let entry = FeedbackEntry::new(PromptOutcome::Rated(Rating::Bad))
        .with_report(Disclosure::of(payload).approve())
        .unwrap();
    store.record(&entry).unwrap();

    let siblings: BTreeSet<String> = std::fs::read_dir(&dir)
        .unwrap()
        .map(|e| e.unwrap().file_name().to_string_lossy().into_owned())
        .collect();
    assert_eq!(
        siblings,
        ["feedback.jsonl".to_string()].into_iter().collect::<BTreeSet<_>>(),
        "an approval produced something besides the one local file"
    );

    let written = std::fs::read_to_string(&path).unwrap();
    assert!(written.contains("unprepared-task-handed-to-user"));
    // Nothing in the stored line is addressed to anywhere, and nothing marks it as owed.
    for shape in ["http", "://", "@", "host", "pending", "queued", "sent", "attempt"] {
        assert!(
            !written.contains(shape),
            "the stored record contains {shape:?}: {written}"
        );
    }

    std::fs::remove_dir_all(&dir).ok();
}
