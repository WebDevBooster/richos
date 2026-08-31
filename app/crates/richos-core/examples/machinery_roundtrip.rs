//! Headless proof that machinery is ROUTED AND RETAINED end to end, against the REAL
//! `claude` binary — no GUI, no window, no mock, no npm.
//!
//! `native_roundtrip` proves the clean-output loop. This proves the second family: a real
//! tool-using turn produces real records in the real journal on disk, in one shared `seq`
//! with the assistant text, merged by the tool-use id, with the CEO's conversation
//! untouched.
//! A passing unit test is not this proof; this is.
//!
//! It prints, in order:
//!   1. the CALM view — exactly what the CEO sees, which must contain no machinery;
//!   2. the interleaved (`seq`-ordered) stream of text and machinery — the reconstruction
//!      §1.4 G1 exists for;
//!   3. the projected machinery rows (`toolCallId` merged, `internal` excluded);
//!   4. the journal files actually on disk, Tier A and Tier B, with byte counts.
//!
//! Run (needs the `claude` CLI installed and logged in — no npm, no adapter):
//!   cd app \
//!     cargo run -p richos-core --example machinery_roundtrip -- <engine_dir> "your message"
//!
//! The journal is left on disk and its path is printed, so the run can be inspected after
//! the process exits.

use richos_core::native::{resolve_claude_bin, NativeCognition};
use richos_core::journal::MachineryJournal;
use richos_core::ledger::{Ledger, Source};
use richos_core::machinery::{MachineryObserver, MachineryRecord};
use richos_core::entity::EntityId;
use richos_core::spine::Spine;
use richos_core::stream::{StreamEvent, TurnObserver};
use richos_core::Cognition;
use std::path::PathBuf;
use std::sync::{Arc, Mutex};

/// What the interleaved stream looked like live.
///
/// `turn` is carried alongside `seq` because `seq` is per-TURN: the re-prime turn and the
/// CEO's turn each start at 0, so a flat list sorted on `seq` alone would show two items
/// at position 0 and look like a violation of the very guarantee this example exists to
/// demonstrate. Sort key is `(turn, seq)` — exactly what §1.4 G3 says consumers must do.
struct Item {
    turn: Option<String>,
    seq: u64,
    family: &'static str,
    what: String,
}

#[derive(Clone, Default)]
struct Live {
    items: Arc<Mutex<Vec<Item>>>,
}
impl TurnObserver for Live {
    fn on_event(&self, event: &StreamEvent) {
        if let StreamEvent::Chunk { seq, turn_id, text_delta, .. } = event {
            self.items.lock().unwrap().push(Item {
                turn: Some(turn_id.clone()),
                seq: *seq,
                family: "text",
                what: text_delta.replace('\n', " "),
            });
        }
    }
}
impl MachineryObserver for Live {
    fn on_machinery(&self, r: &MachineryRecord) {
        self.items.lock().unwrap().push(Item {
            turn: r.turn_id.clone(),
            seq: r.seq,
            family: if r.internal { "MACHINERY*" } else { "machinery" },
            what: format!(
                "{:<20} {:<10} {}",
                r.kind.as_str(),
                r.status.as_ref().map(|s| s.as_str()).unwrap_or("-"),
                r.title
            ),
        });
    }
}

fn main() {
    let mut args = std::env::args().skip(1);
    let engine_dir = args.next().map(PathBuf::from).unwrap_or_else(|| PathBuf::from("../engine"));
    let message = args.next().unwrap_or_else(|| {
        // A prompt that genuinely exercises tools — the whole point of this example.
        "Using your tools, do these two things and then answer in one sentence: \
         (1) read the file VERSION in your current working directory, \
         (2) run the shell command: echo machinery-roundtrip-ok && uname -s"
            .to_string()
    });

    let root = std::env::temp_dir().join(format!("richos-machinery-{}", std::process::id()));
    std::fs::create_dir_all(&root).expect("scratch dir");
    let ledger = Ledger::open(root.join("conversation-ledger.jsonl")).expect("open ledger");
    let mut spine = Spine::new(ledger);
    spine.set_machinery_journal(MachineryJournal::new(root.join("machinery")));
    let live = Live::default();
    spine.set_observer(Box::new(live.clone()));
    spine.set_machinery_observer(Box::new(live.clone()));
    let thread_id = spine.create_thread("Machinery roundtrip proof", &EntityId::parse("richos").unwrap()).expect("thread");

    let claude_bin = resolve_claude_bin();
    eprintln!("[machinery] claude    = {}", claude_bin.display());
    eprintln!("[machinery] engine cwd = {}", engine_dir.display());
    let cognition = NativeCognition::start(&claude_bin, &engine_dir).expect("start the native claude session");
    eprintln!("[machinery] session   = {}", cognition.session_id());
    spine.attach_lease(Box::new(cognition));

    println!("\nCEO> {message}\n");
    let turn_id = spine.submit_prompt(&message, Source::Text).expect("submit");

    // ---- 1. the calm view: exactly what the CEO sees ------------------------
    println!("================ 1. THE CALM VIEW (what the CEO sees) ================");
    for m in spine.messages(&thread_id).expect("scoped read") {
        println!("{:>6}> {}", m.role, m.text);
    }

    // ---- 2. the interleaved stream, in ONE seq order per turn ---------------
    println!("\n================ 2. INTERLEAVED, ORDERED BY (turn, seq) — G1 ================");
    println!("  rows marked MACHINERY* are `internal: true` (re-prime, turnId None) and are");
    println!("  RETAINED but NEVER rendered in a thread view — §1.5.");
    println!("  The re-prime turn reports dense: NO on purpose — the positions missing from it");
    println!("  are its assistant TEXT, which is discarded unrendered. The gap is the proof");
    println!("  that text was there and deliberately not kept, which is exactly what a shared");
    println!("  counter buys you. The CEO's turn keeps both families and must be dense.\n");
    let mut items = live.items.lock().unwrap();
    let mut turns: Vec<Option<String>> = Vec::new();
    for i in items.iter() {
        if !turns.contains(&i.turn) {
            turns.push(i.turn.clone());
        }
    }
    items.sort_by_key(|i| (turns.iter().position(|t| t == &i.turn).unwrap_or(usize::MAX), i.seq));
    let mut current: Option<Option<String>> = None;
    let mut seen: Vec<u64> = Vec::new();
    for i in items.iter() {
        if current.as_ref() != Some(&i.turn) {
            if current.is_some() {
                report_dense(&seen);
                seen.clear();
            }
            println!("  --- turn {} ---", i.turn.clone().unwrap_or_else(|| "<none: re-prime>".into()));
            current = Some(i.turn.clone());
        }
        seen.push(i.seq);
        let shown: String = i.what.chars().take(92).collect();
        println!("  seq {:>3}  {:<11}  {}", i.seq, i.family, shown);
    }
    report_dense(&seen);

    // ---- 3. the projected rows ---------------------------------------------
    let journal = MachineryJournal::new(root.join("machinery"));
    let raw = journal.read_thread(&thread_id);
    let rows = journal.project_thread(&thread_id);
    println!("\n================ 3. PROJECTED ROWS (merged by toolCallId) ================");
    println!("  {} journal lines  ->  {} rows after the merge", raw.len(), rows.len());
    for r in &rows {
        println!(
            "  seq {:>3}  {:<20} {:<10} {}",
            r.seq,
            r.kind.as_str(),
            r.status.as_ref().map(|s| s.as_str()).unwrap_or("-"),
            r.title.chars().take(70).collect::<String>()
        );
        if let Some(s) = &r.summary {
            println!("           summary: {s}");
        }
        if !r.locations.is_empty() {
            println!("           paths  : {}", r.locations.join(", "));
        }
    }

    // ---- 4. what is actually on disk ----------------------------------------
    println!("\n================ 4. ON DISK ================");
    let dir = root.join("machinery").join(&thread_id);
    match std::fs::read_dir(&dir) {
        Ok(entries) => {
            for e in entries.filter_map(|e| e.ok()) {
                let n = e.metadata().map(|m| m.len()).unwrap_or(0);
                let lines = std::fs::read_to_string(e.path()).map(|s| s.lines().count()).unwrap_or(0);
                println!("  {:>9} bytes  {:>4} lines  {}", n, lines, e.path().display());
            }
        }
        Err(e) => println!("  (no machinery directory: {e})"),
    }
    println!("  raw payload bytes retained (Tier B, install-wide): {}", journal.raw_bytes());

    let turn = spine.ledger().turn(&turn_id).expect("turn");
    eprintln!("\n[machinery] turn state = {:?}, stop = {:?}", turn.state, turn.stop_reason);
    eprintln!("[machinery] journal kept at {}", root.display());
    eprintln!("[machinery] OK");
}


/// The G1 check, shown rather than asserted: within ONE turn, the positions taken by text
/// and by machinery must together form a dense run with no value used twice. A duplicate
/// would mean two counters; a gap would mean a lost item.
fn report_dense(seqs: &[u64]) {
    if seqs.is_empty() {
        return;
    }
    let mut s: Vec<u64> = seqs.to_vec();
    s.sort_unstable();
    let n = s.len();
    s.dedup();
    let unique = s.len() == n;
    let dense = s.first() == Some(&0) && s.last() == Some(&(n as u64 - 1));
    println!(
        "        -> {} items, positions {}..={}, unique: {}, dense: {}",
        n,
        s.first().copied().unwrap_or(0),
        s.last().copied().unwrap_or(0),
        if unique { "YES" } else { "NO" },
        if dense { "YES" } else { "NO" }
    );
}
