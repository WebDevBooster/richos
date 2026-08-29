//! End-to-end tests for the ADDITIVE §13 event family (`live.rs`), driven through the
//! real `Spine` with a mock lease — no live Claude, no network.
//!
//! Four things are proven here, in this order of importance:
//!
//!   1. **The four existing events are untouched.** The exact `StreamEvent` sequence and
//!      the exact JSON payloads `app/STREAMING.md` documents are asserted BYTE-FOR-BYTE,
//!      and asserted to be IDENTICAL with and without a live observer attached. Slice 3
//!      adds a contract for a renderer that does not exist yet; breaking the shipping UI
//!      to do it would be a strict regression.
//!   2. **The wire and a reload agree.** The `rich://activity-upserted` payload is
//!      compared field-by-field with the item `Timeline::project` produces from the same
//!      durable records after a cold reopen.
//!   3. **Nothing crosses an entity boundary, including on a DEFERRED emit** — the
//!      cross-entity negative control, which fails when the guard is removed.
//!   4. **The gate holds**: model reasoning and internal machinery never reach the
//!      webview on this family.

use richos_core::cognition::{Cognition, CognitionError, MockCognition, TurnItem};
use richos_core::entity::EntityId;
use richos_core::ledger::{AttentionTier, Ledger, Source};
use richos_core::live::{LiveEvent, LiveObserver};
use richos_core::machinery::{MachineryObserver, MachineryRecord};
use richos_core::spine::Spine;
use richos_core::stream::{StreamEvent, TurnObserver};
use richos_core::timeline::{Timeline, ViewMode, Visibility};
use serde_json::{json, Value};
use std::sync::{Arc, Mutex};

fn femcboost() -> EntityId {
    EntityId::parse("femcboost").unwrap()
}

fn deeply() -> EntityId {
    EntityId::parse("deeply").unwrap()
}

fn tmp_ledger(tag: &str) -> (std::path::PathBuf, Ledger) {
    let path = std::env::temp_dir().join(format!(
        "richos-live-{tag}-{}-{}.jsonl",
        std::process::id(),
        richos_core::util::now_millis()
    ));
    let _ = std::fs::remove_file(&path);
    let ledger = Ledger::open(&path).unwrap();
    (path, ledger)
}

// ---------------------------------------------------------------------------
// Recorders
// ---------------------------------------------------------------------------

#[derive(Clone, Default)]
struct RecordingLive {
    events: Arc<Mutex<Vec<(String, Value)>>>,
}

impl RecordingLive {
    fn payloads(&self) -> Vec<(String, Value)> {
        self.events.lock().unwrap().clone()
    }

    fn of(&self, name: &str) -> Vec<Value> {
        self.payloads().into_iter().filter(|(n, _)| n == name).map(|(_, p)| p).collect()
    }

    fn names(&self) -> Vec<String> {
        self.payloads().into_iter().map(|(n, _)| n).collect()
    }
}

impl LiveObserver for RecordingLive {
    fn on_live_event(&self, event: &LiveEvent) {
        // Recorded as NAME + PAYLOAD, i.e. exactly what the Tauri shell forwards to the
        // webview — never the Rust value, so a test cannot pass on a field a renderer
        // would never see.
        self.events.lock().unwrap().push((event.event_name().to_string(), event.payload()));
    }
}

#[derive(Clone, Default)]
struct RecordingStream {
    events: Arc<Mutex<Vec<(String, Value)>>>,
}

impl RecordingStream {
    fn payloads(&self) -> Vec<(String, Value)> {
        self.events.lock().unwrap().clone()
    }
}

impl TurnObserver for RecordingStream {
    fn on_event(&self, event: &StreamEvent) {
        self.events.lock().unwrap().push((event.event_name().to_string(), event.payload()));
    }
}

#[derive(Clone, Default)]
struct RecordingMachinery {
    records: Arc<Mutex<Vec<MachineryRecord>>>,
}

impl MachineryObserver for RecordingMachinery {
    fn on_machinery(&self, record: &MachineryRecord) {
        self.records.lock().unwrap().push(record.clone());
    }
}

// ---------------------------------------------------------------------------
// A lease that interleaves text and machinery on ONE shared counter
// ---------------------------------------------------------------------------

/// What the lease should emit next, in arrival order. `seq` is assigned by the lease at
/// its drain point exactly as `acp.rs` does — one counter shared by both arms (§1.4 G1).
enum Beat {
    Text(&'static str),
    /// A raw ACP `session/update` payload, turned into a `MachineryRecord` the same way
    /// `acp.rs` turns one.
    Update(Value),
}

struct ScriptedLease {
    session_id: String,
    script: Vec<Beat>,
    /// When set, `prompt` returns this error AFTER replaying the script — a mid-turn
    /// crash with a POSITIVE termination signal, never a silence.
    die_with: Option<String>,
}

impl ScriptedLease {
    fn new(session_id: &str, script: Vec<Beat>) -> Self {
        ScriptedLease { session_id: session_id.into(), script, die_with: None }
    }
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
        for beat in &self.script {
            match beat {
                Beat::Text(t) => {
                    on_item(TurnItem::Text { seq, text: t });
                    seq += 1;
                }
                Beat::Update(u) => {
                    if let Some(rec) = MachineryRecord::from_acp_update(u, &self.session_id, seq) {
                        on_item(TurnItem::Machinery(rec));
                        seq += 1;
                    }
                }
            }
        }
        match &self.die_with {
            Some(reason) => Err(CognitionError::Io(reason.clone())),
            None => Ok("end_turn".to_string()),
        }
    }
}

/// The opening + closing shape of a real tool call, as measured on 2026-08-28
/// (`docs/verification/acp-emission-probe-2026-08-28.md` §7 / `machinery.rs`'s `open_bash`).
fn tool_open(id: &str, tool: &str, kind: &str) -> Value {
    json!({
        "_meta": {"claudeCode": {"toolName": tool}},
        "toolCallId": id,
        "sessionUpdate": "tool_call",
        "rawInput": {},
        "status": "pending",
        "title": "Terminal",
        "kind": kind
    })
}

fn tool_close(id: &str, title: &str, output: &str) -> Value {
    json!({
        "toolCallId": id,
        "sessionUpdate": "tool_call_update",
        "status": "completed",
        "title": title,
        "rawOutput": output
    })
}

// ===========================================================================
// 1. THE FOUR EXISTING EVENTS ARE UNTOUCHED
// ===========================================================================

/// Run the identical turn twice — once with NO live observer, once with one — and compare
/// the four documented events byte-for-byte.
fn run_turn_capturing_stream(live: Option<RecordingLive>) -> Vec<(String, Value)> {
    let (path, ledger) = tmp_ledger("compat");
    let mut spine = Spine::new(ledger);
    spine.create_thread("General", &femcboost()).unwrap();
    spine.attach_lease(Box::new(MockCognition::new("sess-1", vec!["Hello CEO, I'm Rich."])));
    let stream = RecordingStream::default();
    spine.set_observer(Box::new(stream.clone()));
    if let Some(l) = live {
        spine.set_live_observer(Box::new(l));
    }
    spine.submit_prompt("hi", Source::Text).unwrap();
    let out = stream.payloads();
    drop(spine);
    let _ = std::fs::remove_file(&path);
    out
}

#[test]
fn the_four_documented_events_are_byte_identical_with_and_without_the_additive_family() {
    let without = run_turn_capturing_stream(None);
    let with = run_turn_capturing_stream(Some(RecordingLive::default()));

    // Names and order first — STREAMING.md: "exactly one turn-started, then zero or more
    // chunks, then exactly one terminal event, never both".
    let names: Vec<&str> = without.iter().map(|(n, _)| n.as_str()).collect();
    assert_eq!(
        names,
        vec!["rich://turn-started", "rich://chunk", "rich://chunk", "rich://turn-completed"],
        "the documented sequence for a two-delta reply"
    );
    let with_names: Vec<&str> = with.iter().map(|(n, _)| n.as_str()).collect();
    assert_eq!(names, with_names, "attaching a live observer must not change the old family's shape");

    // Then the payloads, field by field. Three values legitimately differ between two
    // independent runs and are normalized rather than ignored: the wall-clock `at` (which
    // STREAMING.md explicitly calls a label, never the ordering key) and the freshly
    // generated thread/turn ids. Every other key AND value must be identical.
    for (i, ((n_a, p_a), (n_b, p_b))) in without.iter().zip(with.iter()).enumerate() {
        assert_eq!(n_a, n_b, "event {i} name");
        let normalize = |v: &Value| {
            let mut o = v.as_object().unwrap().clone();
            o.insert("at".into(), json!("<label>"));
            o.insert("threadId".into(), json!("<thread>"));
            o.insert("turnId".into(), json!("<turn>"));
            Value::Object(o)
        };
        assert_eq!(normalize(p_a), normalize(p_b), "event {i} payload changed when the live family was attached");
    }

    // And the exact documented shapes, so this test fails if a KEY is renamed rather than
    // only if the two runs diverge together.
    let started = &without[0].1;
    assert!(started.get("threadId").is_some() && started.get("turnId").is_some() && started.get("at").is_some());
    assert_eq!(started.as_object().unwrap().len(), 3, "turn-started is {{threadId, turnId, at}}");

    let chunk = &without[1].1;
    assert_eq!(chunk["seq"], json!(0), "seq is a per-turn counter starting at 0");
    assert!(chunk.get("textDelta").is_some());
    assert_eq!(chunk.as_object().unwrap().len(), 5, "chunk is {{threadId, turnId, seq, textDelta, at}}");

    let completed = &without[3].1;
    assert_eq!(completed["stopReason"], json!("end_turn"));
    assert_eq!(completed.as_object().unwrap().len(), 4, "turn-completed is {{threadId, turnId, stopReason, at}}");

    // Concatenating textDelta in seq order still reproduces the reply the ledger holds.
    let text: String = without
        .iter()
        .filter(|(n, _)| n == "rich://chunk")
        .map(|(_, p)| p["textDelta"].as_str().unwrap().to_string())
        .collect();
    assert_eq!(text, "Hello CEO, I'm Rich.");
}

#[test]
fn the_shared_seq_still_gaps_where_machinery_happened_on_the_old_family() {
    // STREAMING.md: "seq is NOT contiguous ... never treat a gap as a lost chunk". The
    // additive family must not have quietly renumbered anything.
    let (path, ledger) = tmp_ledger("seqgap");
    let mut spine = Spine::new(ledger);
    spine.create_thread("General", &femcboost()).unwrap();
    spine.attach_lease(Box::new(ScriptedLease::new(
        "sess-1",
        vec![
            Beat::Text("Looking at the release"),
            Beat::Update(tool_open("toolu_A", "Bash", "execute")),
            Beat::Update(tool_close("toolu_A", "cat VERSION", "1.0.0")),
            Beat::Text("It shipped."),
        ],
    )));
    let stream = RecordingStream::default();
    spine.set_observer(Box::new(stream.clone()));
    spine.set_live_observer(Box::new(RecordingLive::default()));
    spine.submit_prompt("did it ship", Source::Text).unwrap();

    let seqs: Vec<u64> = stream
        .payloads()
        .iter()
        .filter(|(n, _)| n == "rich://chunk")
        .map(|(_, p)| p["seq"].as_u64().unwrap())
        .collect();
    assert_eq!(seqs, vec![0, 3], "two tool events took positions 1 and 2 — the gap is the point");
    let _ = std::fs::remove_file(&path);
}

// ===========================================================================
// 2. THE WIRE AND THE RELOAD AGREE
// ===========================================================================

#[test]
fn the_wire_and_the_reload_agree_on_every_field() {
    let (path, ledger) = tmp_ledger("agree");
    let mut spine = Spine::new(ledger);
    let thread = spine.create_thread("General", &femcboost()).unwrap();
    spine.attach_lease(Box::new(ScriptedLease::new(
        "sess-1",
        vec![
            Beat::Text("Checking the version"),
            Beat::Update(tool_open("toolu_A", "Bash", "execute")),
            Beat::Update(tool_close("toolu_A", "cat engine/VERSION", "1.0.0")),
            Beat::Text("It's 1.0.0."),
        ],
    )));
    let live = RecordingLive::default();
    spine.set_live_observer(Box::new(live.clone()));
    let machinery = RecordingMachinery::default();
    spine.set_machinery_observer(Box::new(machinery.clone()));
    let turn_id = spine.submit_prompt("what version", Source::Text).unwrap();

    // --- the LAST upsert for the tool call is what a reload will show ---
    let upserts = live.of("rich://activity-upserted");
    assert_eq!(upserts.len(), 2, "one event per raw record: the open, then the merged close");
    let wire = upserts.last().unwrap().clone();

    // --- rebuild the SAME thread from the durable records, the way a cold reopen does ---
    let records = machinery.records.lock().unwrap().clone();
    let binding = spine.ledger().thread_binding(&thread).unwrap();
    let reloaded = Timeline::project(spine.ledger(), &binding, &records).unwrap();
    let view = reloaded.view(ViewMode::Ceo);
    let projected = view
        .items()
        .iter()
        .find(|i| matches!(i, richos_core::timeline::TimelineItem::Activity { .. }))
        .expect("the reload projects one activity row");
    let mut reload = serde_json::to_value(projected).unwrap();

    // TWO fields legitimately differ, and the second one is a finding rather than a nit.
    //
    //   `at`             — §13's timestamp label, which a timeline item does not carry.
    //
    //   `bindingRevision` — the LIVE fence carries the revision of the ACTIVATION that
    //     produced the event (`rebind_at_new_revision`, ECS §11.3), while a re-projection
    //     carries whatever revision the binding handed to `Timeline::project` holds — for
    //     `Ledger::thread_binding` that is the thread's DURABLE home revision, which is
    //     lower. Both are correct and neither is the item's own property: the revision is
    //     a fencing token about the read, not about the record. The consequence for §13's
    //     "the renderer rejects events that do not match the immutable binding" is
    //     concrete: the IMMUTABLE part is entityId + threadId, and bindingRevision must be
    //     used as a staleness fence (reject anything OLDER than the current activation),
    //     never as an equality key — an equality check would reject every live event after
    //     any thread switch. `app/STREAMING.md` states this for the renderer.
    let at = wire["at"].clone();
    let live_revision = wire["bindingRevision"].as_u64().unwrap();
    let durable_revision = reload["bindingRevision"].as_u64().unwrap();
    assert!(
        live_revision >= durable_revision,
        "an activation fence never moves backwards: live {live_revision} vs durable {durable_revision}"
    );
    let mut wire_stripped = wire.as_object().unwrap().clone();
    wire_stripped.remove("at");
    wire_stripped.insert("bindingRevision".into(), json!(durable_revision));
    reload.as_object_mut().unwrap().remove("at");
    assert_eq!(
        Value::Object(wire_stripped),
        reload,
        "an event that reached the webview must be the SAME record a restart re-projects — \
         otherwise a cold reopen either duplicates what the CEO saw or contradicts it"
    );
    assert!(at.is_u64(), "§13's `at` is present on the wire");

    // The three properties that matter, named rather than implied by the equality above.
    assert_eq!(wire["kind"], json!("activity"));
    assert_eq!(wire["entityId"], json!("femcboost"));
    assert_eq!(wire["threadId"], json!(thread));
    assert_eq!(wire["turnId"], json!(turn_id));
    assert!(wire["bindingRevision"].is_u64(), "the fencing token is present on the wire");
    assert_eq!(wire["visibility"], json!("ceo"));
    assert_eq!(wire["state"], json!("completed"), "the wire status merged in from the closing update");
    assert_eq!(wire["summary"], json!("Ran a command"), "§5.3: semantic, never raw syntax");
    assert_eq!(wire["sequence"], json!(1), "the OPENING record's shared-counter position, not a new number");
    assert!(wire.get("detail").is_none(), "the exact command was removed, not flagged");
    let flat = serde_json::to_string(&wire).unwrap();
    assert!(!flat.contains("cat engine/VERSION"), "no command text on the calm family: {flat}");
    assert!(!flat.contains("1.0.0"), "no tool output on the calm family: {flat}");

    let _ = std::fs::remove_file(&path);
}

#[test]
fn a_live_message_id_is_the_id_a_reload_projects() {
    let (path, ledger) = tmp_ledger("msgid");
    let mut spine = Spine::new(ledger);
    let thread = spine.create_thread("General", &femcboost()).unwrap();
    spine.attach_lease(Box::new(ScriptedLease::new(
        "sess-1",
        vec![
            Beat::Text("Looking at the release"),
            Beat::Update(tool_open("toolu_A", "Bash", "execute")),
            Beat::Update(tool_close("toolu_A", "git log -1", "abc123")),
            Beat::Text("It shipped."),
        ],
    )));
    let live = RecordingLive::default();
    spine.set_live_observer(Box::new(live.clone()));
    let turn_id = spine.submit_prompt("did it ship", Source::Text).unwrap();

    let started = live.of("rich://message-started");
    let completed = live.of("rich://message-completed");
    assert_eq!(started.len(), 2, "one run of prose either side of the tool call");
    assert_eq!(completed.len(), 2, "each run is closed exactly once");

    let live_ids: Vec<&str> = started.iter().map(|p| p["messageId"].as_str().unwrap()).collect();
    assert_eq!(live_ids, vec![format!("{turn_id}:text:0"), format!("{turn_id}:text:1")]);

    // Reload from disk and re-project: the same ids come back.
    let binding = spine.ledger().thread_binding(&thread).unwrap();
    let reloaded = Timeline::project(spine.ledger(), &binding, &[]).unwrap();
    let projected: Vec<String> = reloaded
        .view(ViewMode::Ceo)
        .items()
        .iter()
        .filter(|i| matches!(i, richos_core::timeline::TimelineItem::RichMessage { .. }))
        .map(|i| i.id().to_string())
        .collect();
    assert_eq!(projected, live_ids, "§13: repeated event IDs are idempotent — across a restart too");

    // The runs split where the LEDGER says the prose was interrupted, and each carries its
    // full text so a consumer that missed every delta is still correct.
    assert_eq!(completed[0]["text"], json!("Looking at the release"));
    assert_eq!(completed[1]["text"], json!("It shipped."));
    assert_eq!(started[0]["seq"], json!(0));
    assert_eq!(started[1]["seq"], json!(3), "the real position, gap and all");

    // And the first run is CLOSED BEFORE the tool call's activity row — §5.2's
    // "commentary, then activity" is live-accurate, not reconstructed at turn end.
    let order = live.names();
    let first_completed = order.iter().position(|n| n == "rich://message-completed").unwrap();
    let first_activity = order.iter().position(|n| n == "rich://activity-upserted").unwrap();
    assert!(first_completed < first_activity, "the run of prose closes when the tool call starts");

    let _ = std::fs::remove_file(&path);
}

// ===========================================================================
// 3. THE MESSAGE PHASE
// ===========================================================================

#[test]
fn every_streamed_message_is_phase_unknown_and_never_final() {
    let (path, ledger) = tmp_ledger("phase");
    let mut spine = Spine::new(ledger);
    spine.create_thread("General", &femcboost()).unwrap();
    // The exact shape that makes "the last run is the final answer" false: Rich writes his
    // conclusion, THEN verifies it, THEN says two words. A heuristic would label "Confirmed."
    // as the deliverable and hide the actual answer as commentary.
    spine.attach_lease(Box::new(ScriptedLease::new(
        "sess-1",
        vec![
            Beat::Text("The release shipped at 14:02 and the migration is complete."),
            Beat::Update(tool_open("toolu_A", "Bash", "execute")),
            Beat::Update(tool_close("toolu_A", "git log -1", "abc123")),
            Beat::Text("Confirmed."),
        ],
    )));
    let live = RecordingLive::default();
    spine.set_live_observer(Box::new(live.clone()));
    spine.submit_prompt("did it ship", Source::Text).unwrap();

    for p in live.of("rich://message-started").iter().chain(live.of("rich://message-completed").iter()) {
        assert_eq!(
            p["phase"],
            json!("unknown"),
            "the ACP stream carries no commentary-vs-final signal; message-started fires \
             before the turn is even over"
        );
        assert!(p.get("phase").is_some(), "serialized explicitly — an absent field invites `?? 'final'`");
    }
    // Neither run is labelled, INCLUDING the last one. That is the whole point: the
    // deliverable here is run 0, and run 1 is a two-word verification.
    let completed = live.of("rich://message-completed");
    assert_eq!(completed.last().unwrap()["text"], json!("Confirmed."));
    assert_eq!(completed.last().unwrap()["phase"], json!("unknown"));

    // No turn-status ever claims §11's `streaming_final` either — same missing signal.
    for p in live.of("rich://turn-status") {
        assert_ne!(p["status"], json!("streaming_final"));
    }
    let _ = std::fs::remove_file(&path);
}

#[test]
fn a_proactive_message_carries_the_one_phase_that_is_real() {
    let (path, ledger) = tmp_ledger("proactive");
    let mut spine = Spine::new(ledger);
    spine.create_thread("General", &femcboost()).unwrap();
    let live = RecordingLive::default();
    spine.set_live_observer(Box::new(live.clone()));

    let turn_id = spine.raise_proactive(None, AttentionTier::Digest, "The staging deploy has been red for 40 minutes.").unwrap();

    let started = live.of("rich://message-started");
    assert_eq!(started.len(), 1);
    assert_eq!(started[0]["phase"], json!("proactive"), "the ledger records Source::Proactive — this one IS sourced");
    assert_eq!(started[0]["messageId"], json!(format!("{turn_id}:text:0")));
    assert_eq!(started[0]["seq"], json!(null), "written atomically, outside the stream counter");

    let completed = live.of("rich://message-completed");
    assert_eq!(completed[0]["text"], json!("The staging deploy has been red for 40 minutes."));

    // A proactive turn had no delivery span, so it claims none.
    let status = live.of("rich://turn-status");
    assert_eq!(status.len(), 1);
    assert_eq!(status[0]["status"], json!("completed"));
    assert_eq!(status[0]["startedAt"], json!(null), "there was no hand-off to a lease to time");
    assert_eq!(status[0]["activeDurationMs"], json!(null));

    let _ = std::fs::remove_file(&path);
}

#[test]
fn a_silent_proactive_message_reaches_the_wire_on_no_family_at_all() {
    let (path, ledger) = tmp_ledger("silent");
    let mut spine = Spine::new(ledger);
    spine.create_thread("General", &femcboost()).unwrap();
    let live = RecordingLive::default();
    let stream = RecordingStream::default();
    spine.set_live_observer(Box::new(live.clone()));
    spine.set_observer(Box::new(stream.clone()));

    let turn_id = spine.raise_proactive(None, AttentionTier::Silent, "noted for later").unwrap();

    assert!(live.payloads().is_empty(), "§5.1: Tier 3 never appears in the conversation");
    assert!(stream.payloads().is_empty(), "and the old family already agreed");
    // ...but it IS durable. Silence on the wire is not silence in the ledger.
    assert!(spine.ledger().turn(&turn_id).is_some(), "the message is recorded, only never shown");
    let _ = std::fs::remove_file(&path);
}

// ===========================================================================
// 4. TURN STATUS
// ===========================================================================

#[test]
fn turn_status_walks_the_states_it_can_actually_observe() {
    let (path, ledger) = tmp_ledger("status");
    let mut spine = Spine::new(ledger);
    spine.create_thread("General", &femcboost()).unwrap();
    spine.attach_lease(Box::new(MockCognition::new("sess-1", vec!["done"])));
    let live = RecordingLive::default();
    spine.set_live_observer(Box::new(live.clone()));
    spine.submit_prompt("go", Source::Text).unwrap();

    let statuses: Vec<String> =
        live.of("rich://turn-status").iter().map(|p| p["status"].as_str().unwrap().to_string()).collect();
    assert_eq!(statuses, vec!["queued", "working", "completed"], "§11, restricted to what is observable");

    let s = live.of("rich://turn-status");
    assert_eq!(s[0]["activeDurationMs"], json!(null), "queued: nothing has been timed");
    assert_eq!(s[1]["activeDurationMs"], json!(null), "working: the span is not over, so it is not a span");
    assert!(s[1]["startedAt"].is_u64(), "but startedAt is real, so a live view can tick from it");
    assert!(
        s[2]["activeDurationMs"].is_u64(),
        "completed: ended_at - started_at, MEASURED — never now() - started_at (§6.3)"
    );

    // The thread's sidebar row tracked it, using the same numbers `thread::summaries` uses.
    let summaries: Vec<String> = live
        .of("rich://thread-summary-updated")
        .iter()
        .map(|p| p["status"].as_str().unwrap().to_string())
        .collect();
    assert_eq!(summaries, vec!["queued", "working", "idle"]);
    let last = live.of("rich://thread-summary-updated").last().unwrap().clone();
    assert_eq!(last["title"], json!("General"));
    assert_eq!(last["messageCount"], json!(2), "the CEO's prompt and Rich's reply");

    let _ = std::fs::remove_file(&path);
}

#[test]
fn a_crash_with_no_recovery_path_says_failed_and_says_it_once() {
    let (path, ledger) = tmp_ledger("failed");
    let mut spine = Spine::new(ledger);
    spine.create_thread("General", &femcboost()).unwrap();
    let mut lease = ScriptedLease::new("sess-1", vec![Beat::Text("I started to say")]);
    lease.die_with = Some("broken pipe".into());
    spine.attach_lease(Box::new(lease));
    let live = RecordingLive::default();
    let stream = RecordingStream::default();
    spine.set_live_observer(Box::new(live.clone()));
    spine.set_observer(Box::new(stream.clone()));

    // No lease factory attached -> no recovery is possible, so `failed` is the truth.
    assert!(spine.submit_prompt("go", Source::Text).is_err());

    let statuses: Vec<String> =
        live.of("rich://turn-status").iter().map(|p| p["status"].as_str().unwrap().to_string()).collect();
    assert_eq!(statuses, vec!["queued", "working", "failed"]);
    assert!(!statuses.contains(&"recovering".to_string()), "nothing is recovering when nothing can recover");

    // The partial reply was still finalized — it is already durable.
    let completed = live.of("rich://message-completed");
    assert_eq!(completed.len(), 1);
    assert_eq!(completed[0]["text"], json!("I started to say"));

    // The old family behaved exactly as STREAMING.md documents: partial chunks, then
    // turn-error, and never a turn-completed alongside it.
    let names: Vec<String> = stream.payloads().into_iter().map(|(n, _)| n).collect();
    assert_eq!(names, vec!["rich://turn-started", "rich://chunk", "rich://turn-error"]);

    // And no raw reason reached the calm family — the FACT of the failure did, the
    // stack-trace-ish text did not.
    let flat = serde_json::to_string(&live.payloads()).unwrap();
    assert!(!flat.contains("broken pipe"), "the calm family carries state, not a stack trace: {flat}");

    let _ = std::fs::remove_file(&path);
}

// ===========================================================================
// 5. THE GATE
// ===========================================================================

#[test]
fn model_reasoning_and_internal_machinery_never_reach_the_calm_family() {
    let (path, ledger) = tmp_ledger("gate");
    let mut spine = Spine::new(ledger);
    spine.create_thread("General", &femcboost()).unwrap();
    spine.attach_lease(Box::new(ScriptedLease::new(
        "sess-1",
        vec![
            // §5.3 lists model reasoning under "do not render". The adapter emits this
            // route (acp-agent.js:6462-6473) even though it is structurally empty on
            // today's models — the route is built, so the gate must hold on it.
            Beat::Update(json!({
                "sessionUpdate": "agent_thought_chunk",
                "content": {"type": "text", "text": "The CEO probably means the staging deploy, not prod."}
            })),
            Beat::Text("The staging deploy is red."),
        ],
    )));
    let live = RecordingLive::default();
    let machinery = RecordingMachinery::default();
    spine.set_live_observer(Box::new(live.clone()));
    spine.set_machinery_observer(Box::new(machinery.clone()));
    spine.submit_prompt("what's broken", Source::Text).unwrap();

    // The thought WAS routed and retained — it just has no render path.
    let recorded = machinery.records.lock().unwrap().clone();
    assert_eq!(recorded.len(), 1, "the technical family still carries it");

    assert!(live.of("rich://activity-upserted").is_empty(), "a thought is Internal in every mode");
    let flat = serde_json::to_string(&live.payloads()).unwrap();
    assert!(
        !flat.contains("probably means"),
        "model reasoning must not appear anywhere on the calm family: {flat}"
    );

    // THE NEGATIVE CONTROL, stated as the guard rather than as the symptom: the event was
    // CONSTRUCTED, carries the reasoning, and is refused only because visibility != Ceo.
    // Remove the `may_reach_webview()` check in `Spine::forward_live` and this content is
    // exactly what leaks.
    let projected = Timeline::project(
        spine.ledger(),
        &spine.ledger().thread_binding(spine.active_thread().unwrap()).unwrap(),
        &recorded,
    )
    .unwrap();
    let internal_row = projected
        .audit_including_internal()
        .iter()
        .find(|i| matches!(i, richos_core::timeline::TimelineItem::Activity { .. }))
        .expect("the row exists — it is the GATE that stops it, not its absence");
    assert_eq!(internal_row.visibility(), Visibility::Internal);
    assert!(projected.view(ViewMode::Technical).items().iter().all(
        |i| !matches!(i, richos_core::timeline::TimelineItem::Activity { .. })
    ), "not even technical mode renders reasoning");

    let _ = std::fs::remove_file(&path);
}

// ===========================================================================
// 6. THE CROSS-ENTITY NEGATIVE CONTROL
// ===========================================================================

#[test]
fn no_event_ever_carries_one_entitys_content_under_another_entitys_fence() {
    // TWO entities, TWO threads, ONE spine — the shape slice 1 proved leaks in the
    // re-prime digest and slice 2a proved leaks through a merged machinery row.
    let (path, ledger) = tmp_ledger("crossentity");
    let mut spine = Spine::new(ledger);
    let femc_thread = spine.create_thread("Memory strategy", &femcboost()).unwrap();
    let deeply_thread = spine.create_thread("Pricing", &deeply()).unwrap();

    let live = RecordingLive::default();
    spine.set_live_observer(Box::new(live.clone()));
    spine.attach_lease(Box::new(MockCognition::new(
        "sess-1",
        vec!["FEMCBOOST-ONLY: the coach roster is 40.", "DEEPLY-ONLY: the price is 90."],
    )));

    spine.switch_thread(&femc_thread).unwrap();
    spine.submit_prompt("how many coaches", Source::Text).unwrap();
    spine.switch_thread(&deeply_thread).unwrap();
    spine.submit_prompt("what price", Source::Text).unwrap();

    // Every single event is scoped to the thread that produced it, and the entity of that
    // thread — never the entity that happens to be active.
    let mut femc_events = 0;
    let mut deeply_events = 0;
    for (name, p) in live.payloads() {
        let entity = p["entityId"].as_str().unwrap();
        let thread = p["threadId"].as_str().unwrap();
        let expected = if thread == femc_thread { "femcboost" } else { "deeply" };
        assert_eq!(entity, expected, "{name} carried thread {thread} under entity {entity}");
        assert!(p["bindingRevision"].is_u64(), "{name} must carry the fencing revision");
        assert!(p["turnId"].as_str().is_some_and(|t| !t.is_empty()), "{name} must carry a turn");

        let flat = serde_json::to_string(&p).unwrap();
        if entity == "femcboost" {
            femc_events += 1;
            assert!(!flat.contains("DEEPLY-ONLY"), "{name} leaked deeply's content into femcboost: {flat}");
        } else {
            deeply_events += 1;
            assert!(!flat.contains("FEMCBOOST-ONLY"), "{name} leaked femcboost's content into deeply: {flat}");
        }
    }
    assert!(femc_events > 0 && deeply_events > 0, "both entities actually produced events");

    let _ = std::fs::remove_file(&path);
}

#[test]
fn a_deferred_proactive_emit_keeps_the_entity_it_was_written_under() {
    // THE NEGATIVE CONTROL WITH TEETH. A proactive message raised on entity B's thread
    // while entity A's thread is the active context is DEFERRED to the next turn boundary
    // (it must not collide with a working row). At flush time the active context is A.
    //
    // Point `emit_proactive_live` at the ACTIVE binding instead of the carried one — a
    // one-line change, and exactly the kind a future refactor makes to "simplify" the
    // queue struct — and this test fails: deeply's sentence is emitted stamped femcboost.
    let (path, ledger) = tmp_ledger("deferred");
    let mut spine = Spine::new(ledger);
    let femc_thread = spine.create_thread("Memory strategy", &femcboost()).unwrap();
    let deeply_thread = spine.create_thread("Pricing", &deeply()).unwrap();
    spine.attach_lease(Box::new(MockCognition::new("sess-1", vec!["ack"])));
    let live = RecordingLive::default();
    spine.set_live_observer(Box::new(live.clone()));

    spine.switch_thread(&femc_thread).unwrap();
    // Pretend a turn is in flight, so the proactive emit is deferred rather than immediate.
    spine.debug_set_turn_in_progress(true);
    spine
        .raise_proactive(Some(&deeply_thread), AttentionTier::Digest, "DEEPLY-ONLY: the pricing page is down.")
        .unwrap();
    assert!(live.payloads().is_empty(), "deferred: nothing is emitted while a turn is in flight");

    // Now let a real turn run on femcboost's thread; its boundary flushes the deferred emit.
    spine.debug_set_turn_in_progress(false);
    spine.submit_prompt("status", Source::Text).unwrap();

    let proactive: Vec<Value> = live
        .of("rich://message-completed")
        .into_iter()
        .filter(|p| p["phase"] == json!("proactive"))
        .collect();
    assert_eq!(proactive.len(), 1, "the deferred message was flushed exactly once");
    assert_eq!(
        proactive[0]["entityId"],
        json!("deeply"),
        "flushed under the binding it was WRITTEN under, not the one that is active now"
    );
    assert_eq!(proactive[0]["threadId"], json!(deeply_thread));
    assert_eq!(proactive[0]["text"], json!("DEEPLY-ONLY: the pricing page is down."));

    // And nothing stamped femcboost carries deeply's sentence.
    for (name, p) in live.payloads() {
        if p["entityId"] == json!("femcboost") {
            let flat = serde_json::to_string(&p).unwrap();
            assert!(!flat.contains("DEEPLY-ONLY"), "{name}: {flat}");
        }
    }

    let _ = std::fs::remove_file(&path);
}

#[test]
fn an_unbound_legacy_thread_emits_nothing_at_all() {
    // Fail-closed, the same posture as `messages()` and `Timeline::project`: a thread with
    // no entity home cannot produce a fence, so it cannot produce an event.
    let path = std::env::temp_dir().join(format!(
        "richos-live-unbound-{}-{}.jsonl",
        std::process::id(),
        richos_core::util::now_millis()
    ));
    // A thread written before entity scoping existed: no binding, ever.
    std::fs::write(&path, r#"{"event":"ThreadCreated","thread_id":"thr_old","title":"Legacy","at":1}"#.to_string() + "\n")
        .unwrap();
    let mut spine = Spine::new(Ledger::open(&path).unwrap());
    let live = RecordingLive::default();
    spine.set_live_observer(Box::new(live.clone()));

    assert!(spine.switch_thread("thr_old").is_err(), "an unbound thread cannot be activated");
    assert!(spine.submit_prompt("hi", Source::Text).is_err(), "and no turn can be accepted for it");
    assert!(live.payloads().is_empty(), "no binding, no fence, no event");
    let _ = std::fs::remove_file(&path);
}
