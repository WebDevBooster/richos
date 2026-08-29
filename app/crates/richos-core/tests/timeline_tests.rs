//! THE TYPED TIMELINE — scope containment, the shared sequence, the visibility gate, and
//! restart.
//!
//! Slice 2 of the Codex-inspired conversation UX brief §24: *"core: add typed timeline and
//! worker lifecycle events"*. These tests pin the four properties the brief makes
//! load-bearing and one it forbids:
//!
//!   - **no machinery from one entity may ever render in another entity's thread** (§22
//!     "must not be faked: cross-entity context", §25 Integrity) — a negative control with
//!     a positive probe, in the same shape as
//!     `entity_binding_tests::no_event_from_one_entity_renders_in_another_entitys_thread`;
//!   - **one shared per-turn sequence** across assistant text, machinery AND the new
//!     timeline records (techy-mode §1.4 G1) — dense, unique, no second counter, live and
//!     after a restart;
//!   - **visibility is a gate**: no internal item and no raw command can reach a CEO view;
//!   - **restart neither loses nor invents** (§23 Phase 1 exit gate);
//!   - **no worker is ever invented** (§22) — including from the one tool call a worker
//!     could plausibly be inferred from.

use richos_core::cognition::{Cognition, CognitionError, TurnItem};
use richos_core::entity::EntityId;
use richos_core::journal::MachineryJournal;
use richos_core::ledger::{Ledger, Source};
use richos_core::machinery::{MachineryObserver, MachineryRecord};
use richos_core::spine::Spine;
use richos_core::stream::{StreamEvent, TurnObserver};
use richos_core::timeline::{
    ActivityState, ActivityType, RejectionReason, RichMessagePhase, Timeline, TimelineItem, TimelineSlot, ViewMode,
    Visibility,
};
use serde_json::{json, Value};
use std::sync::{Arc, Mutex};

fn femcboost() -> EntityId {
    EntityId::parse("femcboost").unwrap()
}

fn tmp(tag: &str, ext: &str) -> std::path::PathBuf {
    let p = std::env::temp_dir().join(format!(
        "richos-timeline-{tag}-{}-{}{ext}",
        std::process::id(),
        richos_core::util::now_millis()
    ));
    let _ = std::fs::remove_file(&p);
    let _ = std::fs::remove_dir_all(&p);
    p
}

// ---------------------------------------------------------------------------
// A LEASE THAT INTERLEAVES TEXT AND MACHINERY
// ---------------------------------------------------------------------------

/// One step of a scripted turn.
enum Step {
    Text(&'static str),
    /// A raw ACP `session/update` payload, verbatim in the shape measured on 2026-08-28.
    Update(Value),
}

/// A `Cognition` that emits text AND machinery in one interleaved stream, assigning `seq`
/// exactly where the real client assigns it — once, at the drain point, shared by both
/// families (`acp.rs:309-317`, §1.4 G1). `MockCognition` only emits text, so it cannot
/// exercise the interleaving these tests exist to prove.
struct ScriptedLease {
    session_id: String,
    script: Vec<Step>,
}

impl Cognition for ScriptedLease {
    fn session_id(&self) -> &str {
        &self.session_id
    }

    fn reprime(&mut self, _priming: &str, _on_item: &mut dyn FnMut(TurnItem)) -> Result<(), CognitionError> {
        Ok(())
    }

    fn prompt(&mut self, _text: &str, on_item: &mut dyn FnMut(TurnItem)) -> Result<String, CognitionError> {
        let mut seq = 0u64;
        for step in &self.script {
            match step {
                Step::Text(t) => {
                    on_item(TurnItem::Text { seq, text: t });
                    seq += 1;
                }
                Step::Update(u) => {
                    if let Some(r) = MachineryRecord::from_acp_update(u, &self.session_id, seq) {
                        on_item(TurnItem::Machinery(r));
                        seq += 1;
                    }
                }
            }
        }
        Ok("end_turn".to_string())
    }
}

/// Records what the UI actually saw, live, in both event families.
#[derive(Clone, Default)]
struct Live {
    text: Arc<Mutex<Vec<u64>>>,
    machinery: Arc<Mutex<Vec<u64>>>,
}
impl TurnObserver for Live {
    fn on_event(&self, event: &StreamEvent) {
        if let StreamEvent::Chunk { seq, .. } = event {
            self.text.lock().unwrap().push(*seq);
        }
    }
}
impl MachineryObserver for Live {
    fn on_machinery(&self, r: &MachineryRecord) {
        if r.turn_id.is_some() && !r.internal {
            self.machinery.lock().unwrap().push(r.seq);
        }
    }
}

/// "he said X, then ran Y, then said Z" — the sentence §1.4 G1 exists to make
/// reconstructible, as an actual turn: text, tool call, text, tool result.
fn interleaved_script() -> Vec<Step> {
    vec![
        Step::Text("Reading the release notes"),
        // seq 1 — the OPEN event, verbatim from run1 n=11 (probe §5.1).
        Step::Update(json!({"_meta":{"claudeCode":{"toolName":"Bash"}},"toolCallId":"toolu_A",
                            "sessionUpdate":"tool_call","rawInput":{},"status":"pending",
                            "title":"Terminal","kind":"execute"})),
        Step::Text(" — the build is green"),
        // seq 3 — the CLOSE event: no title, no _meta, no kind. The measured shape.
        Step::Update(
            json!({"toolCallId":"toolu_A","sessionUpdate":"tool_call_update","status":"completed","rawOutput":"1.0.0"}),
        ),
    ]
}

/// A spine wired with a journal, an interleaving lease and a live recorder.
fn spine_with(script: Vec<Step>, ledger_path: &std::path::Path, journal_root: &std::path::Path) -> (Spine, Live) {
    let mut spine = Spine::new(Ledger::open(ledger_path).unwrap());
    spine.set_machinery_journal(MachineryJournal::new(journal_root));
    let live = Live::default();
    spine.set_observer(Box::new(live.clone()));
    spine.set_machinery_observer(Box::new(live.clone()));
    spine.attach_lease(Box::new(ScriptedLease { session_id: "sess-1".into(), script }));
    (spine, live)
}

// ---------------------------------------------------------------------------
// THE INTEGRITY PROPERTY
// ---------------------------------------------------------------------------

#[test]
fn no_machinery_from_one_entity_renders_in_another_entitys_thread() {
    // Slice 1 closed this leak for ledger TURNS. Machinery is the omission that would
    // re-open it: `MachineryRecord` carries a `thread_id` and NO `entity_id`, so a record
    // attached to a forged cross-entity turn has nothing on its own face to reject it by.
    //
    // The fixture is the slice-1 forgery — a turn filed under the femcboost thread while
    // claiming the deeply entity — with real machinery hanging off it, plus one record
    // that belongs to the deeply thread outright.
    let path = tmp("leak", ".jsonl");
    let secret = "deeply's Q4 term sheet numbers";
    std::fs::write(
        &path,
        concat!(
            r#"{"event":"ThreadCreated","thread_id":"thr_fem","title":"Avelor release","at":1,"entity_id":"femcboost","person_id":"ceo-default","binding_revision":1}"#,
            "\n",
            r#"{"event":"ThreadCreated","thread_id":"thr_dee","title":"Partner book","at":2,"entity_id":"deeply","person_id":"ceo-default","binding_revision":2}"#,
            "\n",
            r#"{"event":"PromptReceived","turn_id":"turn_ok","thread_id":"thr_fem","text":"how is the release","source":"text","at":3,"entity_id":"femcboost","binding_revision":1}"#,
            "\n",
            r#"{"event":"TurnStarted","turn_id":"turn_ok","session_id":"s1","at":4}"#,
            "\n",
            r#"{"event":"AssistantDelta","turn_id":"turn_ok","text":"on track","at":5,"seq":0}"#,
            "\n",
            r#"{"event":"TurnCompleted","turn_id":"turn_ok","stop_reason":"end_turn","at":6}"#,
            "\n",
            // THE FORGERY: thread_id says femcboost's thread, entity_id says deeply.
            r#"{"event":"PromptReceived","turn_id":"turn_leak","thread_id":"thr_fem","text":"deeply's Q4 term sheet numbers","source":"text","at":7,"entity_id":"deeply","binding_revision":2}"#,
            "\n",
            r#"{"event":"TurnCompleted","turn_id":"turn_leak","stop_reason":"end_turn","at":8}"#,
            "\n",
        ),
    )
    .unwrap();

    let journal_root = tmp("leak-journal", "");
    let journal = MachineryJournal::new(&journal_root);
    let mk = |update: Value, thread: &str, turn: &str, seq: u64| {
        MachineryRecord::from_acp_update(&update, "sess", seq).unwrap().stamp(thread, Some(turn), false)
    };
    // Legitimate femcboost machinery.
    journal
        .append(&mk(
            json!({"toolCallId":"t_ok","sessionUpdate":"tool_call","status":"completed","title":"git status"}),
            "thr_fem",
            "turn_ok",
            1,
        ))
        .unwrap();
    // The forged turn's machinery — filed under the femcboost THREAD, carrying deeply's
    // secret in its title and its touched path.
    journal
        .append(&mk(
            json!({"toolCallId":"t_leak","sessionUpdate":"tool_call","status":"completed",
                   "title":"cat deeply's Q4 term sheet numbers",
                   "locations":[{"path":"/Users/alex/ab/deeply/q4-term-sheet.md"}]}),
            "thr_fem",
            "turn_leak",
            0,
        ))
        .unwrap();
    // The forged turn again, this time sharing a toolCallId with the LEGITIMATE call
    // above. `machinery::project` merges by toolCallId across everything it is handed
    // (§1.4 G2, last-write-wins per present field), so if a quarantined turn's records
    // reach the merge, this one does not need a row of its own — it overwrites the title
    // of a row femcboost is entitled to see.
    journal
        .append(&mk(
            json!({"toolCallId":"t_ok","sessionUpdate":"tool_call_update","status":"completed",
                   "title":"deeply's Q4 term sheet numbers"}),
            "thr_fem",
            "turn_leak",
            1,
        ))
        .unwrap();
    // ...and the nastier one: a record stamped with the DEEPLY thread but carrying a
    // femcboost TURN id. A mis-stamp, a corrupt shard, a replayed stale active context —
    // and the only thing standing between it and femcboost's screen is the thread clause,
    // because its turn id is one this thread legitimately accepts.
    journal
        .append(&mk(
            json!({"toolCallId":"t_dee","sessionUpdate":"tool_call","status":"completed",
                   "title":"deeply's Q4 term sheet numbers"}),
            "thr_dee",
            "turn_ok",
            2,
        ))
        .unwrap();

    let ledger = Ledger::open(&path).unwrap();
    let binding = ledger.thread_binding("thr_fem").unwrap();

    // (1) POSITIVE PROBE — the input really does contain foreign content, filed under the
    //     femcboost thread. Without this the assertion below could pass because nothing
    //     foreign was ever there (the negative test that passes for the wrong reason).
    let mut records = journal.read_thread("thr_fem");
    records.extend(journal.read_thread("thr_dee"));
    let raw_text: String = records.iter().map(|r| format!("{} {}", r.title, r.locations.join(","))).collect();
    assert!(raw_text.contains(secret), "the fixture must actually cross the boundary, or this test proves nothing");
    assert!(
        records.iter().any(|r| r.turn_id.as_deref() == Some("turn_leak") && r.thread_id == "thr_fem"),
        "the forged turn's machinery really is filed under the femcboost thread"
    );
    assert!(
        records.iter().any(|r| r.thread_id == "thr_dee" && r.turn_id.as_deref() == Some("turn_ok")),
        "and one record names the other thread while claiming a turn THIS thread accepts"
    );

    // (2) THE GUARD, and what each clause is for.
    //
    //     Delete the `r.thread_id != thread_id` clause in `Timeline::project` and the
    //     third record above — deeply's thread, femcboost's turn id — is placed into
    //     turn_ok's bucket and RENDERS: this assertion fails with deeply's term-sheet line
    //     inside a femcboost thread.
    //
    //     Delete the `rank.contains_key(turn_id)` clause and the quarantined turn's own
    //     row still cannot be placed (`rank` is the placement key, so there is no bucket
    //     for it) — but the fourth record above never needed a row: it shares a toolCallId
    //     with a legitimate call, so the merge folds its title into a row femcboost IS
    //     entitled to see, and this assertion fails with the secret rendered under
    //     turn_ok. Keeping foreign records out of the MERGE INPUT is what that clause is
    //     for; the placement key alone is not enough.
    let timeline = Timeline::project(&ledger, &binding, &records).unwrap();
    let rendered = format!("{:?}", timeline.audit_including_internal());
    assert!(!rendered.contains(secret), "CROSS-ENTITY LEAK in the timeline:\n{rendered}");
    assert!(!rendered.contains("q4-term-sheet"), "...including the touched path");
    for item in timeline.audit_including_internal() {
        assert_eq!(item.entity_id(), &femcboost(), "every item carries — and matches — the thread's entity");
        assert_ne!(item.turn_id(), "turn_leak", "the quarantined turn contributes nothing");
    }

    // (3) ...and it is REPORTED, not silently swallowed. Both clauses fired, each once.
    let violations = timeline.scope_violations();
    assert_eq!(violations.len(), 3, "three rejections, reported not hidden: {violations:?}");
    assert_eq!(
        violations.iter().filter(|v| v.reason == RejectionReason::UnscopedTurn).count(),
        2,
        "both of the forged turn's records are refused, including the one that would have \
         merged into a legitimate row: {violations:?}"
    );
    assert!(
        violations.iter().any(|v| v.reason == RejectionReason::ForeignThread && v.thread_id == "thr_dee"),
        "the other thread's machinery is refused: {violations:?}"
    );

    // (4) The legitimate femcboost activity still renders — the guard excludes, it does
    //     not blank the lane.
    let ceo = timeline.view(ViewMode::Ceo);
    assert!(
        ceo.items().iter().any(|i| matches!(i, TimelineItem::Activity { .. })),
        "femcboost's own tool call is still there"
    );

    // (5) The deeply thread is untouched by any of this.
    let dee_binding = ledger.thread_binding("thr_dee").unwrap();
    let dee = Timeline::project(&ledger, &dee_binding, &journal.read_thread("thr_dee")).unwrap();
    assert!(dee.audit_including_internal().is_empty(), "no turns there, so no items — and no femcboost content");

    let _ = std::fs::remove_file(&path);
    let _ = std::fs::remove_dir_all(&journal_root);
}

// ---------------------------------------------------------------------------
// G1 — ONE SHARED PER-TURN SEQUENCE
// ---------------------------------------------------------------------------

#[test]
fn text_machinery_and_timeline_records_share_one_dense_per_turn_sequence() {
    let path = tmp("g1", ".jsonl");
    let journal_root = tmp("g1-journal", "");
    let (mut spine, live) = spine_with(interleaved_script(), &path, &journal_root);
    let thread = spine.create_thread("Avelor release", &femcboost()).unwrap();
    let turn_id = spine.submit_prompt("how is the release", Source::Text).unwrap();

    // (1) THE COUNTER ITSELF IS DENSE AND UNIQUE. Four items left the lease and the two
    //     families between them consumed positions 0,1,2,3 — every position used exactly
    //     once, no gaps, no collisions. Neither family is dense alone: text has a hole at
    //     1 and 3, machinery at 0 and 2. That is the point of a shared counter.
    let text_live = live.text.lock().unwrap().clone();
    let mach_live = live.machinery.lock().unwrap().clone();
    assert_eq!(text_live, vec![0, 2]);
    assert_eq!(mach_live, vec![1, 3]);
    let mut all: Vec<u64> = text_live.iter().chain(mach_live.iter()).copied().collect();
    all.sort_unstable();
    let mut unique = all.clone();
    unique.dedup();
    assert_eq!(all, vec![0, 1, 2, 3], "the shared counter is dense across the two families");
    assert_eq!(unique, all, "and no position is claimed twice");

    let timeline = spine.timeline(&thread).unwrap();
    let turn_items: Vec<&TimelineItem> =
        timeline.audit_including_internal().iter().filter(|i| i.turn_id() == turn_id).collect();

    // (2) THE TIMELINE READS THAT COUNTER; IT DOES NOT OPEN ONE.
    //
    //     Its stream items sit at 0, 1, 2 — three items for four wire positions, and the
    //     missing one is NOT a lost item. Position 3 is the `tool_call_update` that closed
    //     the call opened at position 1, and §1.4 G2's merge folds it into that row:
    //     "four wire events, ONE row", positioned where the call STARTED. So the timeline
    //     sequence set is a strictly increasing SUBSET of the shared counter, never a
    //     renumbering of it — the check below pins exactly that, and would fail just as
    //     loudly for a second counter (which would restart at 0) as for a dropped item.
    let seqs: Vec<u64> = turn_items
        .iter()
        .filter(|i| i.base().slot == TimelineSlot::Stream)
        .map(|i| i.sequence().expect("a stream item written by this build always has a position"))
        .collect();
    assert_eq!(seqs, vec![0, 1, 2], "positions read straight off the shared counter, in order");
    assert!(seqs.windows(2).all(|w| w[0] < w[1]), "strictly increasing, and never re-sorted by the clock");
    assert!(seqs.iter().all(|s| all.contains(s)), "every timeline position is a position the counter actually issued");

    // ...and position 3 is accounted for rather than dropped: the row at 1 carries the
    // later event's outcome, which is what the merge means.
    let merged = turn_items
        .iter()
        .find_map(|i| match i {
            TimelineItem::Activity { base, state, .. } if base.sequence == Some(1) => Some(*state),
            _ => None,
        })
        .expect("the tool call is on the timeline at the position it started");
    assert_eq!(merged, ActivityState::Completed, "the seq-3 update merged into the seq-1 row (§1.4 G2)");

    // NO SECOND COUNTER: the timeline's positions ARE the live ones, not a renumbering.
    let text_seqs: Vec<u64> = turn_items
        .iter()
        .filter(|i| matches!(i, TimelineItem::RichMessage { .. }))
        .map(|i| i.sequence().unwrap())
        .collect();
    let mach_seqs: Vec<u64> = turn_items
        .iter()
        .filter(|i| matches!(i, TimelineItem::Activity { .. }))
        .map(|i| i.sequence().unwrap())
        .collect();
    assert_eq!(text_seqs, text_live, "the message items sit exactly where the live chunks sat");
    assert_eq!(mach_seqs, vec![1], "the two tool events merged into ONE row, positioned where the call STARTED");

    // THE SENTENCE G1 EXISTS FOR: "he said X, then ran Y, then said Z" reads back in order.
    let narrative: Vec<String> = turn_items
        .iter()
        .filter(|i| i.base().slot == TimelineSlot::Stream)
        .map(|i| match i {
            TimelineItem::RichMessage { text, .. } => format!("said {text:?}"),
            TimelineItem::Activity { summary, .. } => format!("did {summary:?}"),
            other => format!("{other:?}"),
        })
        .collect();
    assert_eq!(
        narrative,
        vec![
            r#"said "Reading the release notes""#.to_string(),
            r#"did "Ran a command""#.to_string(),
            r#"said " — the build is green""#.to_string(),
        ]
    );

    // The ledger's own runs agree: prose split at the gap the tool call made.
    let turn = spine.ledger().turn(&turn_id).unwrap();
    assert_eq!(turn.text_runs.len(), 2);
    assert_eq!(turn.text_runs[0].start_seq, Some(0));
    assert_eq!(turn.text_runs[1].start_seq, Some(2));
    assert_eq!(turn.assistant_text, "Reading the release notes — the build is green");

    let _ = std::fs::remove_file(&path);
    let _ = std::fs::remove_dir_all(&journal_root);
}

// ---------------------------------------------------------------------------
// RESTART (§23 Phase 1 exit gate)
// ---------------------------------------------------------------------------

#[test]
fn a_timeline_survives_a_cold_reopen_neither_losing_nor_inventing_anything() {
    let path = tmp("restart", ".jsonl");
    let journal_root = tmp("restart-journal", "");
    let (before, thread);
    {
        let (mut spine, _live) = spine_with(interleaved_script(), &path, &journal_root);
        thread = spine.create_thread("Avelor release", &femcboost()).unwrap();
        spine.submit_prompt("how is the release", Source::Text).unwrap();
        before = spine.timeline(&thread).unwrap();
    }

    // KILL AND RESTART: a cold `Ledger::open` replays the log, a cold journal re-reads the
    // shards. No process state survives.
    let mut fresh = Spine::new(Ledger::open(&path).unwrap());
    fresh.set_machinery_journal(MachineryJournal::new(&journal_root));
    let after = fresh.timeline(&thread).unwrap();

    // NOT LOST and NOT INVENTED — identical, item for item, id for id.
    assert_eq!(
        after, before,
        "a re-projection of the same durable inputs must be the same timeline, not a similar one"
    );
    // Ids are DERIVED, so they are stable across the restart rather than regenerated.
    let ids_before: Vec<&str> = before.audit_including_internal().iter().map(|i| i.id()).collect();
    let ids_after: Vec<&str> = after.audit_including_internal().iter().map(|i| i.id()).collect();
    assert_eq!(ids_after, ids_before);

    // The interleaving specifically — the thing that was NOT durable before this slice.
    let seqs: Vec<Option<u64>> = after
        .audit_including_internal()
        .iter()
        .filter(|i| i.base().slot == TimelineSlot::Stream && i.visibility() != Visibility::Internal)
        .map(|i| i.sequence())
        .collect();
    assert_eq!(seqs, vec![Some(0), Some(1), Some(2)], "text/tool/text, positions intact after a cold reopen");

    // Nothing was conjured: no worker, no plan, no approval card, no question, no artifact.
    for item in after.audit_including_internal() {
        assert!(
            !matches!(
                item,
                TimelineItem::Worker { .. }
                    | TimelineItem::Plan { .. }
                    | TimelineItem::Approval { .. }
                    | TimelineItem::Question { .. }
                    | TimelineItem::Artifact { .. }
            ),
            "restart invented an unsourced item: {item:?}"
        );
    }

    let _ = std::fs::remove_file(&path);
    let _ = std::fs::remove_dir_all(&journal_root);
}

// ---------------------------------------------------------------------------
// THE VISIBILITY GATE
// ---------------------------------------------------------------------------

#[test]
fn a_ceo_view_carries_no_internal_item_and_no_raw_command() {
    let path = tmp("gate", ".jsonl");
    let journal_root = tmp("gate-journal", "");
    let script = vec![
        Step::Text("Checking"),
        Step::Update(json!({"_meta":{"claudeCode":{"toolName":"Bash"}},"toolCallId":"toolu_S",
                            "sessionUpdate":"tool_call","status":"pending","title":"Terminal","kind":"execute"})),
        Step::Update(json!({"toolCallId":"toolu_S","sessionUpdate":"tool_call_update","status":"completed",
                            "title":"cat /Users/alex/.ssh/config","rawOutput":"Host prod\n  User root"})),
        // Model reasoning — §5.3's "do not render: model reasoning text".
        Step::Update(json!({"sessionUpdate":"agent_thought_chunk","content":{"type":"text","text":"maybe I should check the key"}})),
    ];
    let (mut spine, _live) = spine_with(script, &path, &journal_root);
    let thread = spine.create_thread("Avelor release", &femcboost()).unwrap();
    spine.submit_prompt("check the deploy", Source::Text).unwrap();

    let timeline = spine.timeline(&thread).unwrap();
    let audit = format!("{:?}", timeline.audit_including_internal());
    // POSITIVE PROBE: the sensitive strings really are in the timeline's audit view, so
    // the assertions below are about a gate that has something to stop.
    assert!(audit.contains("cat /Users/alex/.ssh/config"), "the exact command IS retained (technical mode needs it)");
    assert!(audit.contains("maybe I should check the key"), "the reasoning text IS retained");
    assert!(audit.contains("[re-prime]"), "the re-prime turn IS retained");

    // THE CEO VIEW: nothing internal, and the technical detail is GONE — not flagged,
    // removed. A renderer cannot show a command it was never handed.
    let ceo = timeline.view(ViewMode::Ceo);
    let payload = ceo.payload().to_string();
    assert!(!payload.contains("cat /Users/alex/.ssh/config"), "raw command leaked into the CEO payload:\n{payload}");
    assert!(!payload.contains("Host prod"), "raw output leaked into the CEO payload");
    assert!(!payload.contains("maybe I should check the key"), "model reasoning leaked into the CEO payload");
    assert!(!payload.contains("[re-prime]"), "re-prime traffic leaked into the CEO payload");
    for item in ceo.items() {
        assert_eq!(item.visibility(), Visibility::Ceo, "a CEO view contains only CEO items: {item:?}");
        if let TimelineItem::Activity { detail, summary, .. } = item {
            assert!(detail.is_none(), "technical detail must be removed, not merely marked");
            assert_eq!(summary, "Ran a command", "§5.3: the CEO default is semantic");
        }
    }
    // ...and the CEO still sees the work happen. Silence is not privacy.
    assert!(ceo.items().iter().any(|i| matches!(i, TimelineItem::Activity { .. })));

    // TECHNICAL MODE: the same items, with the detail restored — and still no internal
    // item, because `Internal` renders in no mode at all.
    let tech = timeline.view(ViewMode::Technical);
    let tech_payload = tech.payload().to_string();
    assert!(tech_payload.contains("cat /Users/alex/.ssh/config"), "technical mode is where exact commands live");
    assert!(!tech_payload.contains("maybe I should check the key"), "reasoning text renders in NO mode");
    assert!(!tech_payload.contains("[re-prime]"), "re-prime traffic renders in NO mode");
    for item in tech.items() {
        assert_ne!(item.visibility(), Visibility::Internal);
    }

    let _ = std::fs::remove_file(&path);
    let _ = std::fs::remove_dir_all(&journal_root);
}

#[test]
fn between_turn_machinery_has_no_render_path_and_is_not_a_violation() {
    // Re-prime and rotation traffic is journaled with `turn_id: None` (§1.5 G4) — a
    // first-class state, not a bug. A timeline item requires a turn, so those records are
    // EXCLUDED; and the exclusion is classified honestly as "not turn-scoped" rather than
    // reported as a cross-entity violation.
    let path = tmp("unturned", ".jsonl");
    let journal_root = tmp("unturned-journal", "");
    let (mut spine, _live) = spine_with(interleaved_script(), &path, &journal_root);
    let thread = spine.create_thread("Avelor release", &femcboost()).unwrap();
    spine.submit_prompt("how is the release", Source::Text).unwrap();

    let journal = MachineryJournal::new(&journal_root);
    let unturned = MachineryRecord::from_acp_update(
        &json!({"toolCallId":"t_rp","sessionUpdate":"tool_call","status":"completed","title":"rotate the lease"}),
        "sess",
        0,
    )
    .unwrap()
    .stamp(&thread, None, true);
    journal.append(&unturned).unwrap();

    let timeline = spine.timeline(&thread).unwrap();
    assert!(timeline.scope_violations().is_empty(), "an unturned record is not a leak");
    let rejections = timeline.rejections();
    assert_eq!(rejections.len(), 1);
    assert_eq!(rejections[0].reason, RejectionReason::NotTurnScoped);
    assert!(!format!("{:?}", timeline.audit_including_internal()).contains("rotate the lease"));

    let _ = std::fs::remove_file(&path);
    let _ = std::fs::remove_dir_all(&journal_root);
}

// ---------------------------------------------------------------------------
// MUST NOT BE FAKED
// ---------------------------------------------------------------------------

#[test]
fn a_delegated_task_never_becomes_a_worker_and_a_status_less_call_never_becomes_completed() {
    // §22's "must not be faked" list, as a projection over a real turn: active worker
    // count, worker waiting state, completion state.
    let path = tmp("nofake", ".jsonl");
    let journal_root = tmp("nofake-journal", "");
    let script = vec![
        // The vendor's delegated-work tool — the ONE place a worker could be inferred.
        Step::Update(json!({"_meta":{"claudeCode":{"toolName":"Task"}},"toolCallId":"toolu_T",
                            "sessionUpdate":"tool_call","status":"pending","title":"Task","kind":"other"})),
        // ...and a tool call that never reports a status at all: 34 of the 58 events
        // measured on 2026-08-28 looked like this.
        Step::Update(json!({"toolCallId":"toolu_Q","sessionUpdate":"tool_call","title":"Read File","kind":"read"})),
    ];
    let (mut spine, _live) = spine_with(script, &path, &journal_root);
    let thread = spine.create_thread("Avelor release", &femcboost()).unwrap();
    spine.submit_prompt("delegate the audit", Source::Text).unwrap();

    let timeline = spine.timeline(&thread).unwrap();
    let activities: Vec<(&ActivityType, &ActivityState)> = timeline
        .audit_including_internal()
        .iter()
        .filter_map(|i| match i {
            TimelineItem::Activity { activity_type, state, .. } => Some((activity_type, state)),
            _ => None,
        })
        .collect();

    assert!(
        !timeline.audit_including_internal().iter().any(|i| matches!(i, TimelineItem::Worker { .. })),
        "a Task tool call is an activity that happened, not a worker lifecycle claim"
    );
    assert!(
        activities.contains(&(&ActivityType::Other, &ActivityState::Queued)),
        "Task projects as an unclassified activity: {activities:?}"
    );
    assert!(
        activities.contains(&(&ActivityType::Read, &ActivityState::Unknown)),
        "no status on the wire ⇒ unknown state, never completed: {activities:?}"
    );
    assert!(
        !activities.iter().any(|(_, s)| **s == ActivityState::Completed),
        "nothing here reported completion, so nothing may claim it: {activities:?}"
    );

    // And no CEO turn's prose is labelled `final`, because no signal says which run is.
    let phases: Vec<RichMessagePhase> = timeline
        .audit_including_internal()
        .iter()
        .filter_map(|i| match i {
            TimelineItem::RichMessage { phase, .. } => Some(*phase),
            _ => None,
        })
        .collect();
    assert!(!phases.contains(&RichMessagePhase::Final), "phase: {phases:?}");

    let _ = std::fs::remove_file(&path);
    let _ = std::fs::remove_dir_all(&journal_root);
}

#[test]
fn an_unbound_legacy_thread_refuses_to_produce_a_timeline_at_all() {
    // Fail closed, same as `Ledger::messages`: "I will not serve this" and "there is
    // nothing here" are different statements, and a renderer must not show the second
    // when the first is true.
    let path = tmp("unbound", ".jsonl");
    std::fs::write(
        &path,
        concat!(
            r#"{"event":"ThreadCreated","thread_id":"thr_old","title":"Running","at":1}"#,
            "\n",
            r#"{"event":"PromptReceived","turn_id":"turn_old","thread_id":"thr_old","text":"an old conversation","source":"text","at":2}"#,
            "\n",
        ),
    )
    .unwrap();
    let spine = Spine::new(Ledger::open(&path).unwrap());
    let err = spine.timeline("thr_old").unwrap_err();
    assert!(err.to_string().contains("will not guess"), "the refusal explains itself: {err}");
    let _ = std::fs::remove_file(&path);
}
