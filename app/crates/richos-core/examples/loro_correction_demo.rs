//! THE CONVERSATIONAL LOOP, END TO END, AGAINST THE REAL WRITER.
//!
//! Unit tests prove the state machine against a fake backend. This drives the real
//! `loro-write.mjs` over a real corpus and shows the whole property the CEO asked for:
//! read what the system believes → propose a correction → **see exactly what would change**
//! → say yes → read it back changed.
//!
//! ```bash
//! export RICHOS_LORO_DIR=/path/to/loro
//! cargo run -p richos-core --example loro_correction_demo
//! ```
//!
//! It provisions its OWN throwaway corpus under the system temp dir and deletes it at the
//! end. It never touches `LORO_CORPUS`/`LORO_ROOT`: a demonstration that writes into the
//! CEO's real second brain is not a demonstration, it is an accident waiting for an
//! audience.

use richos_core::correction::{CliLoroWriter, CorrectionDesk, ProposedWrite};
use richos_core::loro::{LoroRoot, LoroTools};

fn main() {
    let tools = match std::env::var("RICHOS_LORO_DIR").ok().map(LoroTools::locate) {
        Some(Ok(t)) => t,
        Some(Err(e)) => {
            eprintln!("[demo] RICHOS_LORO_DIR is set but is not a loro checkout: {e}");
            std::process::exit(2);
        }
        None => {
            eprintln!("[demo] set RICHOS_LORO_DIR to the loro checkout holding bin/loro-write.mjs");
            std::process::exit(2);
        }
    };

    // A throwaway corpus, provisioned the way loro expects: person/ + companies/.
    let corpus = std::env::temp_dir().join(format!("richos-correction-demo-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&corpus);
    std::fs::create_dir_all(corpus.join("person").join("records")).unwrap();
    std::fs::create_dir_all(corpus.join("companies")).unwrap();
    println!("corpus: {}\n", corpus.display());

    let writer = CliLoroWriter::new(tools, LoroRoot::Corpus(corpus.clone()));
    let log = corpus.join("desk.jsonl");
    let mut desk = CorrectionDesk::open(&log, Box::new(writer)).unwrap();

    // ---- 1. a belief gets recorded (proposed, then confirmed) -------------
    let p1 = desk
        .propose(
            "femcboost",
            "thr-demo",
            ProposedWrite::Append {
                id: "launch-date".into(),
                kind: "decision".into(),
                scope: Some("org-shared".into()),
                title: Some("Launch is Thursday".into()),
                body: "We are launching on Thursday. Marketing is briefed for Thursday.".into(),
                partition: Some("person".into()),
            },
            "recording what was decided on the call",
        )
        .unwrap();
    println!("== 1. PROPOSED (nothing written yet) — {} ==\n{}", p1.id, p1.preview);
    println!("records on disk before confirming: {:?}", ls(&corpus));
    let p1 = desk.confirm("femcboost", &p1.id).unwrap();
    println!("confirmed -> {:?} at {}\n", p1.state, p1.outcome.as_ref().unwrap().r#ref);

    // ---- 2. "that's wrong" ------------------------------------------------
    let believed = desk.show("rec:person/records/launch-date").unwrap();
    println!("== 2. WHAT DOES LORO BELIEVE? ==\n{}\n", believed.text);

    let p2 = desk
        .propose(
            "femcboost",
            "thr-demo",
            ProposedWrite::Supersede {
                record_ref: "rec:person/records/launch-date".into(),
                new_id: "launch-date-friday".into(),
                kind: "decision".into(),
                scope: Some("org-shared".into()),
                body: "We are launching on Friday. Thursday was never agreed.".into(),
            },
            "that's wrong — we never decided Thursday",
        )
        .unwrap();
    println!("== 3. PROPOSED CORRECTION (still nothing written) — {} ==", p2.id);
    println!("why: {}\n{}", p2.why, p2.preview);
    println!("the old record is still exactly as it was:");
    println!("{}\n", desk.show("rec:person/records/launch-date").unwrap().text);

    // ---- 3. he says yes ---------------------------------------------------
    let p2 = desk.confirm("femcboost", &p2.id).unwrap();
    let out = p2.outcome.as_ref().unwrap();
    println!("== 4. CONFIRMED ==\n{:?}  {} superseded by {}\n", p2.state, out.superseded_ref.clone().unwrap_or_default(), out.r#ref);
    println!("the old record, NOT deleted, now pointing at its replacement:");
    println!("{}", desk.show("rec:person/records/launch-date").unwrap().text);
    println!("the replacement:");
    println!("{}", desk.show("rec:person/records/launch-date-friday").unwrap().text);

    // ---- 4. and a decline writes nothing ---------------------------------
    let p3 = desk
        .propose(
            "femcboost",
            "thr-demo",
            ProposedWrite::Correct {
                record_ref: "rec:person/records/launch-date-friday".into(),
                title: Some("Launch is Saturday".into()),
                kind: None,
                confidence: None,
                tags: None,
                narrow_scope_to: None,
                body: None,
            },
            "a correction the CEO is about to decline",
        )
        .unwrap();
    desk.decline(&p3.id, false).unwrap();
    println!("== 5. DECLINED — {:?}, and the record is untouched ==", desk.get(&p3.id).unwrap().state);
    println!("{}", desk.show("rec:person/records/launch-date-friday").unwrap().text);

    println!("pending for femcboost: {}", desk.pending_for("femcboost").len());
    let _ = std::fs::remove_dir_all(&corpus);
}

fn ls(corpus: &std::path::Path) -> Vec<String> {
    std::fs::read_dir(corpus.join("person").join("records"))
        .map(|d| d.filter_map(|e| e.ok().map(|e| e.file_name().to_string_lossy().to_string())).collect())
        .unwrap_or_default()
}
