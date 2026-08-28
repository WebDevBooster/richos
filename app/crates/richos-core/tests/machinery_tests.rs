//! Machinery routing + retention, end to end through the spine.
//!
//! Built to `docs/plans/richos-techy-mode-2026-08-26.md` Phase 1 (§5) and verified against
//! the emission set MEASURED on 2026-08-28
//! (`docs/verification/acp-emission-probe-2026-08-28.md`). Every ACP payload below is a
//! verbatim shape from that artifact — `Terminal` placeholder titles, empty `rawInput`,
//! status-less middle updates and all — so these tests fail if the normalization stops
//! matching the wire, not merely if it stops matching my opinion of the wire.
//!
//! No live Claude and no network: the lease is a mock that replays recorded wire shapes.
//! The real-adapter proof is `examples/machinery_roundtrip.rs`.

use richos_core::cognition::{Cognition, CognitionError, TurnItem};
use richos_core::journal::MachineryJournal;
use richos_core::ledger::{Ledger, Source};
use richos_core::machinery::{MachineryKind, MachineryObserver, MachineryRecord, ToolStatus, EVENT_MACHINERY};
use richos_core::spine::Spine;
use richos_core::stream::{StreamEvent, TurnObserver, EVENT_CHUNK, EVENT_PROACTIVE_MESSAGE, EVENT_TURN_COMPLETED, EVENT_TURN_ERROR, EVENT_TURN_STARTED};
use serde_json::{json, Value};
use std::sync::{Arc, Mutex};

// ---------------------------------------------------------------------------
// fixtures
// ---------------------------------------------------------------------------

fn tmp_dir(tag: &str) -> std::path::PathBuf {
    let d = std::env::temp_dir().join(format!("richos-mach-{tag}-{}", std::process::id()))
        .join(format!("{:?}", std::time::SystemTime::now()).replace([' ', ':', '{', '}'], "_"));
    std::fs::create_dir_all(&d).unwrap();
    d
}

/// One turn of REAL recorded traffic: "text, a whole tool-call lifecycle, more text",
/// which is precisely the interleaving §1.4 G1 exists to make reconstructible.
fn recorded_turn() -> Vec<Item> {
    vec![
        Item::Text("Let me check.".into()),
        // run1 n=11 — the OPEN event: placeholder title, empty rawInput.
        Item::Update(json!({"_meta":{"claudeCode":{"toolName":"Bash"}},"toolCallId":"toolu_A",
                            "sessionUpdate":"tool_call","rawInput":{},"status":"pending",
                            "title":"Terminal","kind":"execute","content":[]})),
        // run1 n=12 — arguments and the real title arrive.
        Item::Update(json!({"toolCallId":"toolu_A","sessionUpdate":"tool_call_update",
                            "rawInput":{"command":"cat engine/VERSION"},
                            "title":"cat engine/VERSION","kind":"execute"})),
        // run1 n=15 — NO status, and a _meta toolName that must not overwrite the title.
        Item::Update(json!({"_meta":{"claudeCode":{"toolResponse":{"stdout":"1.0.0"},"toolName":"Bash"}},
                            "toolCallId":"toolu_A","sessionUpdate":"tool_call_update"})),
        // run1 n=20 — the permission request, auto-approved.
        Item::Permission(json!({"sessionId":"sess-1",
            "toolCall":{"toolCallId":"toolu_A","title":"cat engine/VERSION","kind":"execute"},
            "options":[{"kind":"reject_once","optionId":"reject"},{"kind":"allow_once","optionId":"allow"}]})),
        // run1 n=16 — terminal.
        Item::Update(json!({"toolCallId":"toolu_A","sessionUpdate":"tool_call_update",
                            "status":"completed","rawOutput":"1.0.0"})),
        // run1 n=8 — Phase-2 kind: retained as Unknown, never dropped.
        Item::Update(json!({"sessionUpdate":"usage_update","used":30477,"size":1000000})),
        // §1.2's ONE deliberate drop.
        Item::Update(json!({"sessionUpdate":"user_message_chunk","content":{"type":"text","text":"echoed prompt"}})),
        Item::Text(" It says 1.0.0.".into()),
    ]
}

enum Item {
    Text(String),
    Update(Value),
    Permission(Value),
}

/// A lease that replays recorded wire traffic, assigning `seq` the way the real
/// `AcpClient::prompt` drain loop does — ONE counter over text and machinery, and no
/// position consumed by the dropped `user_message_chunk`.
struct ReplayCognition {
    session_id: String,
    script: Vec<Item>,
    reprime_machinery: bool,
}

impl ReplayCognition {
    fn new(session_id: &str, script: Vec<Item>) -> Self {
        ReplayCognition { session_id: session_id.into(), script, reprime_machinery: false }
    }
    fn replay(&self, items: &[Item], on_item: &mut dyn FnMut(TurnItem)) {
        let mut seq = 0u64;
        for it in items {
            match it {
                Item::Text(t) => {
                    on_item(TurnItem::Text { seq, text: t });
                    seq += 1;
                }
                Item::Update(u) => {
                    if let Some(r) = MachineryRecord::from_acp_update(u, &self.session_id, seq) {
                        on_item(TurnItem::Machinery(r));
                        seq += 1;
                    }
                }
                Item::Permission(p) => {
                    on_item(TurnItem::Machinery(MachineryRecord::from_permission_request(
                        p,
                        "allow",
                        &self.session_id,
                        seq,
                    )));
                    seq += 1;
                }
            }
        }
    }
}

impl Cognition for ReplayCognition {
    fn session_id(&self) -> &str {
        &self.session_id
    }
    fn reprime(&mut self, _priming: &str, on_item: &mut dyn FnMut(TurnItem)) -> Result<(), CognitionError> {
        if self.reprime_machinery {
            // §1.5: the priming turn is a REAL turn and produces real machinery.
            let script = vec![Item::Update(json!({"toolCallId":"toolu_PRIME",
                "sessionUpdate":"tool_call","status":"pending","title":"Read reprime payload","kind":"read"}))];
            self.replay(&script, on_item);
        }
        Ok(())
    }
    fn prompt(&mut self, _text: &str, on_item: &mut dyn FnMut(TurnItem)) -> Result<String, CognitionError> {
        let script = std::mem::take(&mut self.script);
        self.replay(&script, on_item);
        self.script = script;
        Ok("end_turn".into())
    }
}

#[derive(Clone, Default)]
struct RecordingObserver {
    events: Arc<Mutex<Vec<StreamEvent>>>,
}
impl TurnObserver for RecordingObserver {
    fn on_event(&self, event: &StreamEvent) {
        self.events.lock().unwrap().push(event.clone());
    }
}

#[derive(Clone, Default)]
struct RecordingMachineryObserver {
    records: Arc<Mutex<Vec<MachineryRecord>>>,
}
impl MachineryObserver for RecordingMachineryObserver {
    fn on_machinery(&self, record: &MachineryRecord) {
        self.records.lock().unwrap().push(record.clone());
    }
}

fn spine_with_journal(dir: &std::path::Path) -> (Spine, MachineryJournal) {
    let ledger = Ledger::open(dir.join("conversation-ledger.jsonl")).unwrap();
    let mut spine = Spine::new(ledger);
    spine.set_machinery_journal(MachineryJournal::new(dir.join("machinery")));
    spine.attach_lease(Box::new(ReplayCognition::new("sess-1", recorded_turn())));
    (spine, MachineryJournal::new(dir.join("machinery")))
}

// ---------------------------------------------------------------------------
// the tests
// ---------------------------------------------------------------------------

#[test]
fn a_turns_machinery_is_retained_keyed_to_its_thread_and_turn() {
    let dir = tmp_dir("retain");
    let (mut spine, journal) = spine_with_journal(&dir);
    let thread = spine.ensure_active_thread().unwrap();
    let turn = spine.submit_prompt("what version is the engine?", Source::Text).unwrap();

    let rows = journal.project_thread(&thread);
    assert!(!rows.is_empty(), "machinery must be RETAINED, not merely emitted");
    for r in &rows {
        assert_eq!(r.thread_id, thread);
        assert_eq!(r.turn_id.as_deref(), Some(turn.as_str()));
        assert_eq!(r.session_id, "sess-1", "which lease produced it stays reconstructible");
    }
}

#[test]
fn one_tool_call_is_one_row_with_the_real_title_and_a_terminal_status() {
    // Four wire events for toolu_A (open, args, a status-less middle, completed) collapse
    // to ONE row — §1.4 G2, against the exact shapes measured in run1.
    let dir = tmp_dir("merge");
    let (mut spine, journal) = spine_with_journal(&dir);
    let thread = spine.ensure_active_thread().unwrap();
    spine.submit_prompt("go", Source::Text).unwrap();

    let rows = journal.project_thread(&thread);
    let tool: Vec<_> = rows.iter().filter(|r| r.kind == MachineryKind::ToolCall).collect();
    assert_eq!(tool.len(), 1, "one toolCallId is one row, never two");
    assert_eq!(tool[0].title, "cat engine/VERSION", "not the 'Terminal' placeholder");
    assert_eq!(tool[0].status, Some(ToolStatus::Completed));
    assert_eq!(tool[0].summary.as_deref(), Some("1.0.0"));
}

#[test]
fn text_and_machinery_share_one_sequence_so_the_true_order_is_reconstructible() {
    // §1.4 G1, the guarantee everything else rests on: "he said X, then ran Y, then said
    // Z". Two independent counters cannot express this.
    let dir = tmp_dir("seq");
    let (mut spine, journal) = spine_with_journal(&dir);
    let thread = spine.ensure_active_thread().unwrap();
    let stream = RecordingObserver::default();
    spine.set_observer(Box::new(stream.clone()));
    spine.submit_prompt("go", Source::Text).unwrap();

    let chunk_seqs: Vec<u64> = stream
        .events
        .lock()
        .unwrap()
        .iter()
        .filter_map(|e| match e {
            StreamEvent::Chunk { seq, .. } => Some(*seq),
            _ => None,
        })
        .collect();
    let mach_seqs: Vec<u64> = journal.read_thread(&thread).iter().map(|r| r.seq).collect();

    assert_eq!(chunk_seqs, vec![0, 7], "text takes positions 0 and 7 — the gap IS the tool call");
    assert_eq!(mach_seqs, vec![1, 2, 3, 4, 5, 6]);
    let mut all: Vec<u64> = chunk_seqs.iter().chain(mach_seqs.iter()).copied().collect();
    all.sort_unstable();
    let unique_count = {
        let mut c = all.clone();
        c.dedup();
        c.len()
    };
    assert_eq!(unique_count, all.len(), "no two items ever share a position");
    assert_eq!(all, (0..=7).collect::<Vec<u64>>(), "one dense sequence across both families");
}

#[test]
fn the_dropped_user_message_chunk_consumes_no_position_and_leaves_no_record() {
    // §1.2's ONE deliberate drop: the ledger already holds the CEO's words verbatim and
    // fsync'd, and a second copy would create two sources of truth.
    let dir = tmp_dir("drop");
    let (mut spine, journal) = spine_with_journal(&dir);
    let thread = spine.ensure_active_thread().unwrap();
    spine.submit_prompt("go", Source::Text).unwrap();
    let all = journal.read_thread(&thread);
    assert!(
        !all.iter().any(|r| r.title == "user_message_chunk"),
        "the echo of our own prompt is never retained"
    );
    // 9 scripted items, 1 dropped, so positions run 0..=7 with nothing skipped.
    assert_eq!(all.len() + 2, 8, "6 machinery + 2 text = 8 delivered items");
}

#[test]
fn a_phase_two_kind_is_retained_as_unknown_rather_than_dropped() {
    // usage_update has no typed route until Phase 2. It must still be KEPT — §1.4 G5, and
    // the CEO's whole argument that a dropped byte is a permanent hole.
    let dir = tmp_dir("unknown");
    let (mut spine, journal) = spine_with_journal(&dir);
    let thread = spine.ensure_active_thread().unwrap();
    spine.submit_prompt("go", Source::Text).unwrap();
    let unknown: Vec<_> = journal
        .read_thread(&thread)
        .into_iter()
        .filter(|r| r.kind == MachineryKind::Unknown)
        .collect();
    assert_eq!(unknown.len(), 1);
    assert_eq!(unknown[0].title, "usage_update", "the vendor kind survives");
    assert_eq!(unknown[0].payload.as_ref().unwrap()["used"], json!(30477), "verbatim payload");
}

#[test]
fn the_calm_conversation_is_byte_identical_whether_or_not_machinery_flows() {
    // §3.3's provable-not-promised test (b): the Ledger gains no variant and `messages()`
    // is unchanged. Same script, same prompts; the only difference is whether a journal
    // and a machinery observer are attached at all.
    let with_dir = tmp_dir("calm-with");
    let (mut a, _) = spine_with_journal(&with_dir);
    a.set_machinery_observer(Box::new(RecordingMachineryObserver::default()));
    let ta = a.ensure_active_thread().unwrap();
    a.submit_prompt("what version is the engine?", Source::Text).unwrap();

    let without_dir = tmp_dir("calm-without");
    let ledger = Ledger::open(without_dir.join("conversation-ledger.jsonl")).unwrap();
    let mut b = Spine::new(ledger);
    b.attach_lease(Box::new(ReplayCognition::new("sess-1", recorded_turn())));
    let tb = b.ensure_active_thread().unwrap();
    b.submit_prompt("what version is the engine?", Source::Text).unwrap();

    let ma: Vec<(String, String)> = a.messages(&ta).into_iter().map(|m| (m.role, m.text)).collect();
    let mb: Vec<(String, String)> = b.messages(&tb).into_iter().map(|m| (m.role, m.text)).collect();
    assert_eq!(ma, mb, "the CEO's conversation is identical with the journal on and off");
    assert_eq!(ma.last().unwrap().1, "Let me check. It says 1.0.0.");
}

#[test]
fn no_tool_output_ever_reaches_the_conversation_ledger() {
    // The correctness hazard §2.1 names: putting machinery in the same log would leave it
    // one missing filter away from the CEO's conversation. It is a different file.
    let dir = tmp_dir("ledger-clean");
    let (mut spine, _journal) = spine_with_journal(&dir);
    spine.ensure_active_thread().unwrap();
    spine.submit_prompt("go", Source::Text).unwrap();
    drop(spine);

    let ledger_bytes = std::fs::read_to_string(dir.join("conversation-ledger.jsonl")).unwrap();
    for needle in ["toolCallId", "tool_call", "rawOutput", "usage_update", "cat engine/VERSION"] {
        assert!(!ledger_bytes.contains(needle), "the ledger must not contain {needle}");
    }
    assert!(ledger_bytes.contains("It says 1.0.0."), "but it does hold the reply");
}

#[test]
fn machinery_never_reaches_the_stream_event_family() {
    // §3.3's test (a), expressed structurally: a `StreamEvent` cannot name the machinery
    // event, so a UI subscribed only to the four calm events cannot receive machinery.
    let names = [EVENT_TURN_STARTED, EVENT_CHUNK, EVENT_TURN_COMPLETED, EVENT_TURN_ERROR, EVENT_PROACTIVE_MESSAGE];
    assert!(!names.contains(&EVENT_MACHINERY), "two families, two name spaces");
    assert_eq!(EVENT_MACHINERY, "rich://machinery");

    let dir = tmp_dir("families");
    let (mut spine, _j) = spine_with_journal(&dir);
    let stream = RecordingObserver::default();
    let mach = RecordingMachineryObserver::default();
    spine.set_observer(Box::new(stream.clone()));
    spine.set_machinery_observer(Box::new(mach.clone()));
    spine.ensure_active_thread().unwrap();
    spine.submit_prompt("go", Source::Text).unwrap();

    for e in stream.events.lock().unwrap().iter() {
        assert_ne!(e.event_name(), EVENT_MACHINERY);
        if let StreamEvent::Chunk { text_delta, .. } = e {
            assert!(!text_delta.contains("cat engine"), "no tool text in a chunk, ever");
        }
    }
    assert_eq!(mach.records.lock().unwrap().len(), 6, "and the machinery sink got all six");
}

#[test]
fn reprime_machinery_is_retained_internal_and_never_projected() {
    // §1.5: re-prime machinery is recorded, `internal: true`, `turnId: None`, and NEVER in
    // a thread render — the standing order that Rich never reveals session rotation.
    let dir = tmp_dir("reprime");
    let ledger = Ledger::open(dir.join("conversation-ledger.jsonl")).unwrap();
    let mut spine = Spine::new(ledger);
    spine.set_machinery_journal(MachineryJournal::new(dir.join("machinery")));
    let mut lease = ReplayCognition::new("sess-1", recorded_turn());
    lease.reprime_machinery = true;
    spine.attach_lease(Box::new(lease));
    let thread = spine.ensure_active_thread().unwrap();
    spine.submit_prompt("go", Source::Text).unwrap();

    let journal = MachineryJournal::new(dir.join("machinery"));
    let internal: Vec<_> = journal.read_thread(&thread).into_iter().filter(|r| r.internal).collect();
    assert_eq!(internal.len(), 1, "retained for debugging");
    assert_eq!(internal[0].title, "Read reprime payload");
    assert_eq!(internal[0].turn_id, None, "attached to the thread, not to a turn (G4)");

    let rendered = journal.project_thread(&thread);
    assert!(!rendered.iter().any(|r| r.internal), "and never rendered");
    assert!(!rendered.iter().any(|r| r.title == "Read reprime payload"));
}

#[test]
fn a_thread_from_before_this_commit_shows_the_honest_empty_state() {
    // THE retroactivity limit, stated as a test rather than a promise. Retention begins at
    // the routing commit; a thread that ran before it has nothing, and asking for it
    // returns an empty list — not an error, not a panic. The renderer's job is to say
    // "nothing was recorded for this conversation."
    let dir = tmp_dir("empty");
    let journal = MachineryJournal::new(dir.join("machinery"));
    assert!(journal.read_thread("thr_from_yesterday").is_empty());
    assert!(journal.project_thread("thr_from_yesterday").is_empty());
}

#[test]
fn a_journal_write_failure_never_fails_the_turn() {
    // §2.2's corollary. `spine.rs` makes a LEDGER write failure terminal for the turn —
    // correctly, because the ledger is truth. Machinery is not truth. Here the journal
    // root is a FILE, so every create_dir_all under it fails.
    let dir = tmp_dir("wedged");
    let blocked = dir.join("machinery");
    std::fs::write(&blocked, b"not a directory").unwrap();

    let ledger = Ledger::open(dir.join("conversation-ledger.jsonl")).unwrap();
    let mut spine = Spine::new(ledger);
    spine.set_machinery_journal(MachineryJournal::new(&blocked));
    spine.attach_lease(Box::new(ReplayCognition::new("sess-1", recorded_turn())));
    let thread = spine.ensure_active_thread().unwrap();

    let turn = spine.submit_prompt("go", Source::Text).expect("the turn must still succeed");
    assert_eq!(spine.ledger().turn(&turn).unwrap().assistant_text, "Let me check. It says 1.0.0.");
    assert_eq!(spine.messages(&thread).len(), 2, "the CEO's conversation is unharmed");
}

#[test]
fn a_spine_with_no_journal_still_routes_and_completes_the_turn() {
    // An honest degrade for headless runs and tests — NOT a supported product state: §3.2
    // says retention runs ALWAYS, because the requirement is to flip a thread the CEO
    // already had. Nothing here silently makes retention optional at runtime.
    let dir = tmp_dir("nojournal");
    let ledger = Ledger::open(dir.join("conversation-ledger.jsonl")).unwrap();
    let mut spine = Spine::new(ledger);
    assert!(!spine.has_machinery_journal());
    let mach = RecordingMachineryObserver::default();
    spine.set_machinery_observer(Box::new(mach.clone()));
    spine.attach_lease(Box::new(ReplayCognition::new("sess-1", recorded_turn())));
    let thread = spine.ensure_active_thread().unwrap();
    spine.submit_prompt("go", Source::Text).unwrap();
    assert_eq!(spine.messages(&thread).len(), 2);
    assert_eq!(mach.records.lock().unwrap().len(), 6, "routed and emitted, just not retained");
}

#[test]
fn a_permission_request_is_recorded_as_an_observation_with_no_control_attached() {
    // §1.2 / §9: recording the auto-approval is a FACT. Gap #1 stays deferred; there is no
    // approve/deny anything. A window, not a cockpit.
    let dir = tmp_dir("perm");
    let (mut spine, journal) = spine_with_journal(&dir);
    let thread = spine.ensure_active_thread().unwrap();
    spine.submit_prompt("go", Source::Text).unwrap();
    let perms: Vec<_> = journal
        .read_thread(&thread)
        .into_iter()
        .filter(|r| r.kind == MachineryKind::PermissionRequested)
        .collect();
    assert_eq!(perms.len(), 1);
    assert_eq!(perms[0].payload.as_ref().unwrap()["auto"], json!(true));
    assert_eq!(perms[0].payload.as_ref().unwrap()["chosen"], json!("allow"));
    assert_eq!(perms[0].tool_call_id.as_deref(), Some("toolu_A"), "linked to its tool call");
}

#[test]
fn machinery_survives_a_restart_and_is_readable_from_a_fresh_process() {
    // Retroactivity is worth nothing if it does not outlive the process that wrote it.
    let dir = tmp_dir("restart");
    let thread = {
        let (mut spine, _j) = spine_with_journal(&dir);
        let t = spine.ensure_active_thread().unwrap();
        spine.submit_prompt("go", Source::Text).unwrap();
        t
    };
    let reopened = MachineryJournal::new(dir.join("machinery"));
    let rows = reopened.project_thread(&thread);
    assert!(rows.iter().any(|r| r.title == "cat engine/VERSION"));
    assert!(rows.iter().any(|r| r.kind == MachineryKind::Unknown));
}
