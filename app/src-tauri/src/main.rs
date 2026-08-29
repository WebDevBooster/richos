// RichOS desktop shell (Tauri). A THIN surface over the richos-core spine.
//
// Doctrine: clean output (only Rich's assistant text renders), one conversation with
// Rich, optional multi-thread topic organization. All runtime intelligence — the ACP
// client, the crash-safe ledger, threads, re-prime continuity — lives in richos-core;
// this file is just the window + the Tauri command bridge to the web UI in ../ui.
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

use richos_core::acp::{resolve_acp_bin, AcpCognition};
use richos_core::cognition::{Cognition, CognitionError, LeaseFactory};
use richos_core::config::{Assertiveness, ConfigStore};
use richos_core::entity::{EntityId, EntityRegistry};
use richos_core::journal::{MachineryJournal, RAW_MAX_TOTAL_BYTES, RAW_RETENTION_DAYS};
use richos_core::ledger::{AttentionTier, Ledger, Message, Source};
use richos_core::machinery::{MachineryObserver, MachineryRecord, EVENT_MACHINERY};
use richos_core::spine::Spine;
use richos_core::stream::{StreamEvent, TurnObserver};
use richos_core::thread::ThreadSummary;
use richos_core::worker_status::{self, WorkerStatusView};
use std::path::PathBuf;
use std::sync::Mutex;
use tauri::{AppHandle, Emitter, Manager, State};

/// The live UI sink: forwards each spine turn event to the webview as a Tauri event.
/// This is the ONLY place spine events become UI events — clean output is guaranteed by
/// the spine (assistant text only), so this layer just relays name + payload verbatim.
struct TauriEmitter {
    app: AppHandle,
}

impl TurnObserver for TauriEmitter {
    fn on_event(&self, event: &StreamEvent) {
        // Best-effort: a dropped/absent webview never affects the turn (ledger is truth).
        let _ = self.app.emit(event.event_name(), event.payload());
    }
}

/// The MACHINERY sink: forwards each machinery record to the webview on ONE event name,
/// `rich://machinery` (techy-mode design §1.3 — one name plus a `kind` field, because the
/// ACP update set is the vendor's and open, so a new kind must not need a new event).
///
/// A SEPARATE observer from `TauriEmitter` on purpose. The clean-output invariant is
/// structural, not a convention: machinery is not a `StreamEvent`, so a webview that
/// subscribes only to the four calm events cannot receive it. The default conversation
/// view does not subscribe to this event and must not (§3.3) — see `app/STREAMING.md`.
struct TauriMachineryEmitter {
    app: AppHandle,
}

impl MachineryObserver for TauriMachineryEmitter {
    fn on_machinery(&self, record: &MachineryRecord) {
        // Best-effort, and weaker than the ledger by design (§2.2): a webview that is not
        // listening never stalls or fails a turn, and machinery is not truth.
        let _ = self.app.emit(EVENT_MACHINERY, record.event_payload());
    }
}

/// The rotation/recovery seam (richos_core::LeaseFactory): spawns a fresh, un-primed ACP
/// lease exactly like the boot path (`AcpCognition::start`), so the spine can rotate at a
/// context watermark or recover from a mid-turn crash without knowing anything about
/// ACP/Node/the adapter binary — richos-core stays IO-agnostic (continuity §3.3 step 4).
struct EngineLeaseFactory {
    acp_bin: PathBuf,
    engine_dir: PathBuf,
}

impl LeaseFactory for EngineLeaseFactory {
    fn spawn(&self) -> Result<Box<dyn Cognition>, CognitionError> {
        let cog = AcpCognition::start(&self.acp_bin, &self.engine_dir)?;
        Ok(Box::new(cog))
    }
}

/// The durable Rich, guarded for cross-invocation access. `Spine` is `Send` (its
/// compute lease is `Box<dyn Cognition + Send>`), so `Mutex<Spine>` is valid Tauri state.
struct AppState {
    spine: Mutex<Spine>,
    /// Set false when no ACP lease could be attached at boot (e.g. Claude not logged in),
    /// so the UI can surface a calm, Rich-voiced "not connected" state instead of a crash.
    lease_ready: bool,
    /// Durable CEO-facing preferences (company name, the assertiveness dial) — stored
    /// alongside the ledger in the app data dir, same durability posture.
    config: Mutex<ConfigStore>,
    /// The entity area this launch is bound to, resolved DETERMINISTICALLY from the
    /// repository root (ECS §3.3: *"Repository-root mapping can select an entity
    /// deterministically during FemcBoost dogfood"*). `None` when the root is unknown or
    /// ambiguous — which fails closed: threads cannot be created and sends are refused,
    /// rather than defaulting to an entity nobody chose.
    ///
    /// This is deliberately the minimum wiring needed to keep the shell honest in slice 1.
    /// The CEO-facing entity PICKER is slice 4 (`ui: build entity and thread navigation`).
    entity: Option<EntityId>,
}

#[tauri::command]
fn list_threads(state: State<AppState>) -> Vec<ThreadSummary> {
    state.spine.lock().unwrap().threads()
}

#[tauri::command]
fn active_thread(state: State<AppState>) -> Option<String> {
    state.spine.lock().unwrap().active_thread().map(|s| s.to_string())
}

#[tauri::command]
fn create_thread(state: State<AppState>, title: String) -> Result<String, String> {
    let title = if title.trim().is_empty() { "New thread".to_string() } else { title };
    // A thread cannot exist without an immutable entity home (ECS §3.2). Until the entity
    // picker lands (slice 4) the entity comes from deterministic root resolution, and an
    // unresolved root refuses rather than guessing.
    let entity = state.entity.clone().ok_or_else(|| ENTITY_UNRESOLVED_MESSAGE.to_string())?;
    state.spine.lock().unwrap().create_thread(&title, &entity).map_err(|e| e.to_string())
}

#[tauri::command]
fn switch_thread(state: State<AppState>, thread_id: String) -> Result<(), String> {
    state.spine.lock().unwrap().switch_thread(&thread_id).map_err(|e| e.to_string())
}

/// Scoped read. Now fallible: a thread written before entity scoping existed has no
/// entity home, and `LedgerError::UnboundThread` is returned rather than an empty list —
/// "I will not serve this" and "there is nothing here" are different statements.
#[tauri::command]
fn get_messages(state: State<AppState>, thread_id: String) -> Result<Vec<Message>, String> {
    state.spine.lock().unwrap().messages(&thread_id).map_err(|e| e.to_string())
}

/// The "talk to Rich" loop. Persists the prompt (crash-safe) + runs the turn. While the
/// turn runs, the spine streams live events to the webview — `rich://turn-started`, a
/// sequence of `rich://chunk` deltas, then `rich://turn-completed` (or `rich://turn-error`)
/// — so the UI renders Rich's reply token-by-token and shows the "Rich is working" state.
/// The returned message view is the final, reconciled snapshot (a UI can rely on either
/// the stream or this return; both agree because the ledger backs both).
#[tauri::command]
fn send_message(state: State<AppState>, text: String) -> Result<Vec<Message>, String> {
    if !state.lease_ready {
        return Err(
            "I'm not connected to my thinking right now — check that the Claude CLI is signed in, \
             then restart me."
                .into(),
        );
    }
    let mut spine = state.spine.lock().unwrap();
    spine.submit_prompt(&text, Source::Text).map_err(|e| e.to_string())?;
    let thread = spine.active_thread().ok_or("no active thread")?.to_string();
    spine.messages(&thread).map_err(|e| e.to_string())
}

/// What the CEO is told when the repository root does not deterministically select one
/// entity. UX §21 "Entity binding failure": state that Rich cannot safely determine which
/// entity the work belongs to, and require an explicit choice. Never default.
const ENTITY_UNRESOLVED_MESSAGE: &str =
    "I can't safely tell which entity area this belongs to, so I won't guess. \
     Set RICHOS_ENTITY to one of femcboost, deeply, prospects or richos, or launch me from \
     that entity's repository root.";

/// Resolve this launch's entity area (ECS §3.3/§10.2), deterministically and fail-closed.
///
/// `RICHOS_ENTITY` is an explicit operator statement and wins. Otherwise the current
/// working directory is resolved against the registry by path CONTAINMENT — an unknown or
/// ambiguous root yields `None`, which blocks thread creation and sends rather than
/// picking an entity nobody chose.
fn boot_entity() -> Option<EntityId> {
    let registry = EntityRegistry::dogfood();
    if let Ok(explicit) = std::env::var("RICHOS_ENTITY") {
        return match EntityId::parse(explicit.trim()) {
            Ok(id) if registry.contains(&id) => Some(id),
            _ => {
                eprintln!("[richos] RICHOS_ENTITY={explicit:?} is not a registered entity — refusing it");
                None
            }
        };
    }
    let cwd = std::env::current_dir().ok()?;
    match registry.resolve_root(&cwd) {
        Ok(entity) => Some(entity.id.clone()),
        Err(e) => {
            eprintln!("[richos] entity not resolved from {}: {e}", cwd.display());
            None
        }
    }
}

fn engine_dir() -> PathBuf {
    if let Ok(dir) = std::env::var("RICHOS_ENGINE_DIR") {
        return PathBuf::from(dir);
    }
    // Default: the engine repo sibling of app/ (dogfood layout).
    std::env::current_dir()
        .map(|d| d.join("../engine"))
        .unwrap_or_else(|_| PathBuf::from("../engine"))
}

fn main() {
    tauri::Builder::default()
        .setup(|app| {
            // Durable ledger lives in the app data dir (survives restart + rotation).
            let data_dir = app.path().app_data_dir().unwrap_or_else(|_| std::env::temp_dir());
            std::fs::create_dir_all(&data_dir).ok();
            let ledger_path = data_dir.join("conversation-ledger.jsonl");
            let ledger = Ledger::open(&ledger_path).expect("open ledger");

            let mut spine = Spine::new(ledger);
            // A thread now requires an entity home, so boot no longer conjures one out of
            // nowhere. If the root resolves, the default thread is created/activated in
            // that entity; if it does not, the app still launches with NO active context
            // and every send is refused with an explanation. Failing closed at boot beats
            // binding a conversation to a guess.
            let boot_entity = boot_entity();
            match &boot_entity {
                Some(entity) => {
                    spine.ensure_active_thread_in(entity).expect("ensure thread");
                }
                None => eprintln!("[richos] {ENTITY_UNRESOLVED_MESSAGE}"),
            }

            // Attach the live UI sink: streamed reply deltas + turn-state events flow to
            // the webview via Tauri events (see app/STREAMING.md for the contract).
            spine.set_observer(Box::new(TauriEmitter { app: app.handle().clone() }));

            // The MACHINERY journal + its live sink (techy-mode design §2.1). Its own
            // directory beside the ledger and config, per §2.1: NOT loro (it would poison
            // the context compiler) and NOT the conversation ledger (which replays whole
            // at every boot, and whose `messages()` is one missing filter away from the
            // CEO's conversation).
            //
            // Retention is attached UNCONDITIONALLY and has no flag gating it (§3.2:
            // "Routing and retention run ALWAYS"). That is what makes "flip a thread I
            // already had" possible at all, and it is why this line is here rather than
            // behind a setting. The accepted cost is ~1-2 MB/day of machinery an owner may
            // never look at — named as a cost, not hidden.
            let machinery_root = data_dir.join("machinery");
            let journal = MachineryJournal::new(&machinery_root);
            // Tier-B eviction at boot (§2.4): raw payloads older than 14 days, then
            // oldest-first until under 2 GB. Tier A — the normalized record — is never
            // touched, so an evicted day still renders its structure, titles, statuses and
            // paths. Boot is the right moment: it is off the streaming hot path entirely.
            let evicted = journal.evict_raw(richos_core::util::now_millis(), RAW_RETENTION_DAYS, RAW_MAX_TOTAL_BYTES);
            if evicted > 0 {
                eprintln!("[richos] machinery: evicted {evicted} raw shard(s) past the retention window");
            }
            spine.set_machinery_journal(journal);
            spine.set_machinery_observer(Box::new(TauriMachineryEmitter { app: app.handle().clone() }));

            // Attach the compute lease best-effort. A boot with no Claude auth degrades
            // to a calm "not connected" state rather than failing to launch.
            let engine = engine_dir();
            let acp_bin = resolve_acp_bin(Some(&std::env::current_dir().unwrap_or_default()));
            let lease_ready = match AcpCognition::start(&acp_bin, &engine) {
                Ok(cog) => {
                    spine.attach_lease(Box::new(cog));
                    true
                }
                Err(e) => {
                    eprintln!("[richos] ACP lease not attached at boot: {e}");
                    false
                }
            };

            // Attach the rotation/recovery seam REGARDLESS of initial boot success — even
            // if Claude wasn't signed in at launch, wiring the factory means a later sign-in
            // + retry (or a crash recovery attempt) has a real respawn path rather than none.
            spine.set_lease_factory(Box::new(EngineLeaseFactory { acp_bin, engine_dir: engine }));

            // Durable CEO preferences (company name, assertiveness dial) — same app data
            // dir as the ledger, same durability posture, survives restart.
            let config_path = data_dir.join("config.json");
            // ConfigStore::open never fails on a corrupt/missing file (it degrades to
            // defaults internally — see config.rs) — expect() here only guards the
            // genuinely-unexpected io error creating the parent dir.
            let config = ConfigStore::open(&config_path).expect("open config store");

            app.manage(AppState {
                spine: Mutex::new(spine),
                lease_ready,
                config: Mutex::new(config),
                entity: boot_entity,
            });
            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
            list_threads,
            active_thread,
            create_thread,
            switch_thread,
            get_messages,
            send_message,
            get_company_name,
            set_company_name,
            get_assertiveness,
            set_assertiveness,
            get_worker_status,
            raise_proactive_message,
            // --- voice mode (2026-08-24) — appended, never reordered ---
            start_voice_capture,
            stop_voice_capture,
            voice_speak_delta,
            voice_speak_end,
            voice_turn_started,
            voice_turn_ended,
            voice_barge_in,
            voice_diagnostics
        ])
        .run(tauri::generate_context!())
        .expect("error while running RichOS");
}

// ---------------------------------------------------------------------------------------
// Seam commands (the session-continuity design / the UX direction doc).
// Appended at the END of the file (and the END of generate_handler! above) so a parallel
// voice-crate branch appending its own Tauri commands here merges cleanly.
// ---------------------------------------------------------------------------------------

/// UX §2.1: "Rail header = the company/CEO identity, not RichOS." Configurable,
/// persisted, sensible fallback when unset — the fallback lives in richos-core's
/// config.rs so this thin shell layer never has to know the placeholder string.
#[tauri::command]
fn get_company_name(state: State<AppState>) -> String {
    state.config.lock().unwrap().company_name_or_default()
}

#[tauri::command]
fn set_company_name(state: State<AppState>, name: String) -> Result<(), String> {
    state.config.lock().unwrap().set_company_name(&name).map_err(|e| e.to_string())
}

/// UX §5.2: the CEO's one plain 3-way proactive-attention dial. Default = Quiet,
/// survives restart (config.rs).
#[tauri::command]
fn get_assertiveness(state: State<AppState>) -> String {
    state.config.lock().unwrap().assertiveness().as_str().to_string()
}

#[tauri::command]
fn set_assertiveness(state: State<AppState>, level: String) -> Result<(), String> {
    let parsed = Assertiveness::parse(&level).ok_or_else(|| format!("unknown assertiveness level: {level}"))?;
    state.config.lock().unwrap().set_assertiveness(parsed).map_err(|e| e.to_string())
}

/// UX §3.2 / architecture P3.2: the optional AI-worker drill-down. Stateless (reads the
/// engine's event logs directly), so no `AppState` lock needed. Honest-zero when nothing
/// has completed since boot — see richos-core's worker_status.rs for the documented scope
/// limit (no "active"/"decision required" signal exists in the engine's hook set yet).
#[tauri::command]
fn get_worker_status() -> WorkerStatusView {
    worker_status::current_status()
}

/// The proactive-attention SEAM (architecture §2.3/§4.2, UX §5): persistence + the live
/// UI event. Judgment of WHEN to raise one is explicitly NOT here — no timer/log-watcher
/// trigger is wired yet (a later leg); this command is the seam a future trigger (or, for
/// now, a manual/test caller) calls once it has already decided to speak.
#[tauri::command]
fn raise_proactive_message(
    state: State<AppState>,
    thread_id: Option<String>,
    tier: String,
    text: String,
) -> Result<String, String> {
    let parsed_tier = AttentionTier::parse(&tier).ok_or_else(|| format!("unknown attention tier: {tier}"))?;
    let mut spine = state.spine.lock().unwrap();
    spine
        .raise_proactive(thread_id.as_deref(), parsed_tier, &text)
        .map_err(|e| e.to_string())
}
// =====================================================================================
// VOICE MODE — appended block (2026-08-24)
//
// Voice is a MODE of the one persistent conversation, never a room: a recognised
// utterance goes through `Spine::submit_prompt` exactly like typed text (only the
// `Source` differs — `Jam` instead of `Text`), so it lands in the SAME thread, the SAME
// durable ledger, and streams back through the SAME `rich://` events. There is no second
// conversation path anywhere in this file.
//
// Rich's reply is spoken by feeding the UI's own `rich://chunk` deltas back down through
// `voice_speak_delta`. That is deliberate: the webview already renders exactly the text
// the CEO is allowed to see, so TTS inherits the clean-output guarantee instead of
// re-deriving it, and the spine's single observer slot needs no change.
//
// Everything below is APPEND-ONLY — no existing item is reordered or edited — so it
// merges cleanly alongside parallel work in `spine.rs` / `reprime.rs`.
// =====================================================================================

use richos_voice::capture::AudioSource;
use richos_voice::controller::{VoiceController, VoiceOptions};
use richos_voice::event::{VoiceEvent, VoiceObserver};
use std::sync::Arc;

/// Live voice mode, or `None` when the `◉` toggle is off. Managed lazily (see
/// `ensure_voice_state`) so this whole feature stays one appended block.
#[derive(Default)]
struct VoiceHandle {
    controller: Mutex<Option<VoiceController>>,
}

/// Forwards voice events to the webview. Same shape as `TauriEmitter` above — the voice
/// crate is UI-agnostic and names its own events; this just relays them verbatim.
struct TauriVoiceEmitter {
    app: AppHandle,
}

impl VoiceObserver for TauriVoiceEmitter {
    fn on_voice_event(&self, event: &VoiceEvent) {
        let _ = self.app.emit(event.event_name(), event.payload());
    }
}

fn ensure_voice_state(app: &AppHandle) {
    // `manage` is a no-op if the type is already managed, so this is idempotent.
    app.manage(VoiceHandle::default());
}

/// Enter voice mode: open the mic and start listening. Returns the resolved audio
/// configuration for developer eyes; the CEO-facing UI only renders `rich://voice-state`.
#[tauri::command]
fn start_voice_capture(app: AppHandle, thread_id: Option<String>) -> Result<serde_json::Value, String> {
    let _ = thread_id; // voice rides the ACTIVE thread — there is no per-thread voice.
    ensure_voice_state(&app);
    let handle = app.state::<VoiceHandle>();
    let mut slot = handle.controller.lock().map_err(|_| "voice state poisoned")?;
    if slot.is_some() {
        return Ok(serde_json::json!({ "already": true }));
    }

    let observer: Arc<dyn VoiceObserver> = Arc::new(TauriVoiceEmitter { app: app.clone() });

    // The submit callback: a recognised utterance takes the SAME path typed text takes.
    let submit_app = app.clone();
    let submit: Arc<dyn Fn(String) + Send + Sync> = Arc::new(move |text: String| {
        let state = submit_app.state::<AppState>();
        if !state.lease_ready {
            let _ = submit_app.emit(
                richos_voice::event::EVENT_VOICE_ERROR,
                serde_json::json!({
                    "message": "I'm not connected to my thinking right now — check that the Claude CLI is signed in, then restart me.",
                    "at": richos_voice::controller::now_millis(),
                }),
            );
            return;
        }
        let mut spine = match state.spine.lock() {
            Ok(s) => s,
            Err(_) => return,
        };
        // Source::Jam — voice and text are ONE thread and ONE ledger.
        if let Err(e) = spine.submit_prompt(&text, Source::Jam) {
            eprintln!("[richos] voice turn failed: {e}");
        }
    });

    let scratch_dir = app
        .path()
        .app_data_dir()
        .unwrap_or_else(|_| std::env::temp_dir())
        .join("voice-scratch");

    let opts = VoiceOptions { source: AudioSource::from_env(), scratch_dir };
    match VoiceController::start(opts, observer, submit) {
        Ok(ctl) => {
            let d = ctl.diagnostics().clone();
            *slot = Some(ctl);
            Ok(serde_json::json!({
                "inputSource": d.input_source,
                "inputRate": d.input_rate,
                "outputDevice": d.output_device,
                "outputRate": d.output_rate,
                "sttModel": d.stt_model,
                "ttsVoice": d.tts_voice,
                "echoCancellation": d.echo_cancellation,
                "bargeInFrames": d.barge_in_frames,
                "bargeInSecs": d.barge_in_secs,
            }))
        }
        Err(e) => {
            eprintln!("[richos] voice mode failed to start: {e}");
            Err(e.ceo_message())
        }
    }
}

/// Leave voice mode. Dropping the controller closes the microphone — "off" means the mic
/// is genuinely closed, not merely ignored.
#[tauri::command]
fn stop_voice_capture(app: AppHandle, thread_id: Option<String>) -> Result<(), String> {
    let _ = thread_id;
    ensure_voice_state(&app);
    let handle = app.state::<VoiceHandle>();
    let mut slot = handle.controller.lock().map_err(|_| "voice state poisoned")?;
    slot.take(); // Drop closes the device and joins the threads.
    Ok(())
}

/// One `rich://chunk` delta, relayed by the UI while voice mode is on. Completed sentences
/// are synthesised and queued immediately — this is the gapless pipelining.
#[tauri::command]
fn voice_speak_delta(app: AppHandle, text: String) {
    if let Some(handle) = app.try_state::<VoiceHandle>() {
        if let Ok(slot) = handle.controller.lock() {
            if let Some(ctl) = slot.as_ref() {
                ctl.speak_delta(&text);
            }
        }
    }
}

/// The turn's terminal event: speak the unterminated tail so Rich never swallows his last
/// words.
#[tauri::command]
fn voice_speak_end(app: AppHandle) {
    if let Some(handle) = app.try_state::<VoiceHandle>() {
        if let Ok(slot) = handle.controller.lock() {
            if let Some(ctl) = slot.as_ref() {
                ctl.speak_end();
            }
        }
    }
}

/// `rich://turn-started`, relayed from the UI.
#[tauri::command]
fn voice_turn_started(app: AppHandle) {
    if let Some(handle) = app.try_state::<VoiceHandle>() {
        if let Ok(slot) = handle.controller.lock() {
            if let Some(ctl) = slot.as_ref() {
                ctl.turn_started();
            }
        }
    }
}

/// `rich://turn-completed` / `rich://turn-error`, relayed from the UI.
#[tauri::command]
fn voice_turn_ended(app: AppHandle) {
    if let Some(handle) = app.try_state::<VoiceHandle>() {
        if let Ok(slot) = handle.controller.lock() {
            if let Some(ctl) = slot.as_ref() {
                ctl.turn_ended();
            }
        }
    }
}

/// The UI's "tap to stop" — the CEO's instant interrupt while AEC is missing. Returns the
/// seconds of queued speech dropped and the measured stop latency, so an interruption is
/// reported in real units rather than as an adjective.
#[tauri::command]
fn voice_barge_in(app: AppHandle) -> serde_json::Value {
    if let Some(handle) = app.try_state::<VoiceHandle>() {
        if let Ok(slot) = handle.controller.lock() {
            if let Some(ctl) = slot.as_ref() {
                let rate = ctl.diagnostics().output_rate.max(1) as f32;
                let dropped = ctl.force_barge_in();
                return serde_json::json!({
                    "droppedSamples": dropped,
                    "droppedSecs": dropped as f32 / rate,
                    "stopLatencySecs": ctl.stop_latency_secs(),
                });
            }
        }
    }
    serde_json::json!({ "droppedSamples": 0, "droppedSecs": 0.0, "stopLatencySecs": 0.0 })
}

/// Developer-facing audio facts. Never rendered to the CEO.
#[tauri::command]
fn voice_diagnostics(app: AppHandle) -> Option<String> {
    let handle = app.try_state::<VoiceHandle>()?;
    let slot = handle.controller.lock().ok()?;
    let ctl = slot.as_ref()?;
    Some(ctl.diagnostics().summary())
}
