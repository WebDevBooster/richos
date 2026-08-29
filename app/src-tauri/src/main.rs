// RichOS desktop shell (Tauri). A THIN surface over the richos-core spine.
//
// Doctrine: clean output (only Rich's assistant text renders), one conversation with
// Rich, optional multi-thread topic organization. All runtime intelligence — the ACP
// client, the crash-safe ledger, threads, re-prime continuity — lives in richos-core;
// this file is just the window + the Tauri command bridge to the web UI in ../ui.
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

mod events;

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

/// Durable left-navigation view state (pin, rename, archive, rail width). See nav.rs
/// for why these are shell state and not ledger events.
mod nav;

/// The `get_timeline` command body, in its own file so `examples/timeline_payload.rs`
/// can include the SAME source and print the exact JSON the webview receives.
mod timeline_view;
use timeline_view::timeline_payload;

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
    /// Durable navigation view state (UX §3.1/§25: pin, rename, archive, rail width).
    /// Separate from `config` because it is view state, not a CEO preference about how
    /// Rich behaves — and separate from the ledger because it is not evidence (nav.rs).
    nav: Mutex<nav::NavStore>,
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

/// One thread's TYPED TIMELINE (UX §12), gated to the CEO view (§5.3).
///
/// The RELOAD half of the §13 live family. `rich://*` events carry a turn while it runs;
/// this is how a cold reopen — or a thread switch back to a thread that finished while
/// the CEO was elsewhere — gets the same items with the same ids. §13's *"reconnect uses a
/// full snapshot followed by events after a cursor"*, and §14's *"load the selected thread
/// snapshot"*.
///
/// **THE GATE IS NOT RE-IMPLEMENTED HERE, AND MUST NOT BE.** `Timeline` deliberately does
/// not implement `Serialize`, so there is no ungated path from this function to the
/// webview; `view(ViewMode::Ceo)` is the only way to obtain a payload, and it REMOVES
/// technical items and technical detail rather than masking them (timeline.rs). This
/// command therefore cannot leak a raw command, a file path or an internal item even if it
/// wanted to — it never holds those bytes.
///
/// Fails closed on an unbound thread, exactly like `get_messages`.
#[tauri::command]
fn get_timeline(state: State<AppState>, thread_id: String) -> Result<serde_json::Value, String> {
    timeline_payload(&state.spine.lock().unwrap(), &thread_id)
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

            // The ADDITIVE §13 family (UX brief slice 3) — see `events.rs`. A THIRD sink
            // beside the two above, so the four events the shipping UI listens to are
            // untouched; `crates/richos-core/tests/live_event_tests.rs` asserts their
            // payloads are byte-identical with and without this line.
            spine.set_live_observer(Box::new(events::TauriLiveEmitter { app: app.handle().clone() }));

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

            // Left-navigation view state — same app data dir, same durability posture as
            // the ledger and config, and never fatal: a corrupt file degrades to defaults
            // rather than refusing the launch (nav.rs).
            let nav_store = nav::NavStore::open(data_dir.join("navigation.json"));

            app.manage(AppState {
                spine: Mutex::new(spine),
                lease_ready,
                config: Mutex::new(config),
                entity: boot_entity,
                nav: Mutex::new(nav_store),
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
            voice_diagnostics,
            // --- entity + thread navigation (Codex-UX slice 4, 2026-08-29) ---
            // Appended at the END so a parallel timeline branch appending its own glue
            // merges without touching a line this branch also touched.
            navigation_tree,
            active_context,
            thread_scope,
            create_thread_in,
            search_nav,
            nav_state,
            set_sidebar_width,
            set_sidebar_collapsed,
            set_entity_collapsed,
            set_thread_pinned,
            set_thread_archived,
            rename_thread,
            // --- Codex-UX slice 5 (2026-08-29): the timeline reload path ---
            get_timeline
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

// =====================================================================================
// ENTITY + THREAD NAVIGATION — appended block (Codex-UX slice 4, 2026-08-29)
//
// `docs/design/richos-codex-inspired-conversation-ux-2026-08-28.md` §3 (left navigation),
// §25 (Navigation acceptance criteria).
//
// THE POINT OF THIS BLOCK, in one sentence: grouping is done HERE, by the authority that
// owns the binding, and never by the renderer filtering a flat list.
//
// §1 says an entity is *"also a hard scope and privacy boundary"*, and the brief for this
// slice is explicit that selecting an entity must actually scope what follows rather than
// filter a list on screen. A renderer that receives every thread and sorts them into
// buckets by an `entity_id` string is one `if` away from putting a thread in the wrong
// bucket, and nothing would catch it. So `navigation_tree` resolves each thread through
// the ledger's immutable binding and emits threads already inside their entity's group. A
// thread whose binding cannot be produced is not placed anywhere: it goes to `unbound`,
// which is a separate list and not an entity.
//
// Everything below is APPEND-ONLY — nothing above is reordered or edited except four
// mechanical seams (the `mod nav;` line, the `nav` field on `AppState`, its construction
// in `setup`, and the command names at the END of `generate_handler!`).
// =====================================================================================

use richos_core::entity::EntityStatus;
use richos_core::ledger::TurnState;

/// One registered entity area, as the rail renders it (§3.1 "Each entity row").
#[derive(serde::Serialize)]
struct EntityView {
    id: String,
    display_name: String,
    /// "active" | "archived"
    status: String,
    /// The bound source root(s) — §3.1's entity overflow shows *"bound source root or
    /// primary workspace when one exists"*. Empty when the entity has none registered.
    roots: Vec<String>,
}

/// One thread row. `title` is the LEDGER's title (evidence); `display_title` is what the
/// rail shows, which is the CEO's rename override when one exists. Both are sent so the
/// rename UI can offer the original back without a second round trip.
#[derive(serde::Serialize)]
struct ThreadRow {
    id: String,
    title: String,
    display_title: String,
    entity_id: Option<String>,
    binding_revision: u64,
    created_at: u64,
    last_activity: u64,
    message_count: usize,
    pinned: bool,
    archived: bool,
    /// The state of this thread's most recent CEO-visible turn in the DURABLE ledger:
    /// "completed" | "interrupted" | "received" | "in_flight", or `None` when the thread
    /// has never taken a turn. `None` for an unbound thread too — its turns are not read.
    last_turn_state: Option<String>,
    /// A turn is still non-terminal on disk. Combined with "this session has seen no live
    /// turn for this thread", that is an outcome nobody knows — which the rail renders as
    /// UNKNOWN rather than as idle. §22: *"If the source signal does not exist, build the
    /// signal first or show unknown."*
    has_pending_turn: bool,
}

/// One entity group: the entity, and the threads whose IMMUTABLE home is that entity.
#[derive(serde::Serialize)]
struct NavGroup {
    entity: EntityView,
    threads: Vec<ThreadRow>,
}

/// The authoritative active scope. The main-pane header renders from THIS, never from the
/// renderer's own idea of what is selected — so a UI bug can show the wrong thread but can
/// never mislabel which entity the CEO is talking to.
#[derive(serde::Serialize, Clone)]
struct ActiveContext {
    thread_id: String,
    entity_id: String,
    binding_revision: u64,
}

#[derive(serde::Serialize)]
struct NavigationTree {
    groups: Vec<NavGroup>,
    /// Pre-entity records (`ThreadEntity::Unbound`). Their own top-level list — never
    /// folded into an entity, because choosing one would be exactly the guess slice 1
    /// refused to make.
    unbound: Vec<ThreadRow>,
    active: Option<ActiveContext>,
    /// The verbatim core explanation for an unbound thread, so the UI renders the SAME
    /// sentence the ledger raises rather than a paraphrase that can drift from it.
    unbound_explanation: String,
}

fn entity_view(e: &richos_core::entity::Entity) -> EntityView {
    EntityView {
        id: e.id.to_string(),
        display_name: e.display_name.clone(),
        status: match e.status {
            EntityStatus::Active => "active".to_string(),
            EntityStatus::Archived => "archived".to_string(),
        },
        roots: e.roots.iter().map(|p| p.display().to_string()).collect(),
    }
}

fn turn_state_str(s: TurnState) -> &'static str {
    match s {
        TurnState::Received => "received",
        TurnState::InFlight => "in_flight",
        TurnState::Completed => "completed",
        TurnState::Interrupted => "interrupted",
    }
}

/// The durable, per-thread turn facts the rail is allowed to show.
///
/// Read through `Ledger::thread_turns`, the SCOPED accessor — not the unscoped
/// `Ledger::turns()`. That matters: `thread_turns` refuses an unbound thread and drops
/// quarantined cross-entity turns, so this function structurally cannot report a turn that
/// does not belong to the thread it is describing. An unbound thread therefore reports
/// `(None, false)` — no state, no pending flag — which is the truth: its turns are not
/// readable, so their outcome is not knowable from here.
fn thread_turn_facts(ledger: &Ledger, thread_id: &str) -> (Option<String>, bool) {
    let Ok(turns) = ledger.thread_turns(thread_id) else { return (None, false) };
    // Internal turns (re-prime, handoff-summary) are machinery, never the CEO's work — a
    // completed re-prime must not make a thread look like it finished something.
    let visible: Vec<_> = turns.into_iter().filter(|t| t.source != Source::Internal).collect();
    let pending = visible.iter().any(|t| matches!(t.state, TurnState::Received | TurnState::InFlight));
    let last = visible.iter().max_by_key(|t| t.created_at).map(|t| turn_state_str(t.state).to_string());
    (last, pending)
}

/// The sentence an unbound thread is explained with. It is the CORE error's own wording
/// (`LedgerError::UnboundThread`, ledger.rs), lifted deliberately rather than re-written:
/// §21 "Entity binding failure" wants one honest statement, and two independently-authored
/// versions of it would drift the moment either side is edited.
const UNBOUND_THREAD_EXPLANATION: &str =
    "This thread has no entity home: it predates entity scoping, and Rich will not guess \
     which entity this work belongs to. An operator must bind it explicitly.";

fn active_binding_view(spine: &Spine) -> Option<ActiveContext> {
    spine.active_binding().map(|b| ActiveContext {
        thread_id: b.thread_id().to_string(),
        entity_id: b.entity_id().to_string(),
        binding_revision: b.binding_revision(),
    })
}

/// THE navigation query. One call returns the whole rail: every registered entity as its
/// own group, each group's threads resolved through the immutable binding, the unbound
/// quarantine list, and the authoritative active scope.
#[tauri::command]
fn navigation_tree(state: State<AppState>) -> NavigationTree {
    let spine = state.spine.lock().unwrap();
    let nav = state.nav.lock().unwrap();
    build_navigation_tree(&spine, nav.state())
}

/// The command's whole body, taking plain references instead of Tauri state — so the rail's
/// grouping can be tested against a REAL ledger file rather than only exercised by hand.
fn build_navigation_tree(spine: &Spine, nav_state: &nav::NavState) -> NavigationTree {
    let ledger = spine.ledger();
    let registry = spine.entity_registry();

    let summaries = spine.threads();
    let row = |s: &ThreadSummary| -> ThreadRow {
        let (last_turn_state, has_pending_turn) = thread_turn_facts(ledger, &s.id);
        let display_title =
            nav_state.renamed_threads.get(&s.id).cloned().unwrap_or_else(|| s.title.clone());
        ThreadRow {
            id: s.id.clone(),
            title: s.title.clone(),
            display_title,
            entity_id: s.entity_id.clone(),
            binding_revision: s.binding_revision,
            created_at: s.created_at,
            last_activity: s.last_activity,
            message_count: s.message_count,
            pinned: nav_state.pinned_threads.iter().any(|t| t == &s.id),
            archived: nav_state.archived_threads.iter().any(|t| t == &s.id),
            last_turn_state,
            has_pending_turn,
        }
    };

    let mut groups: Vec<NavGroup> = Vec::new();
    for entity in registry.entities() {
        let id = entity.id.to_string();
        let mut threads: Vec<ThreadRow> = summaries
            .iter()
            // The binding, not a label: `ThreadSummary::entity_id` is filled in by
            // `thread::summaries` from `Ledger::thread_binding`, which reads the immutable
            // record and fails closed for an unbound thread.
            .filter(|s| s.entity_id.as_deref() == Some(id.as_str()))
            .map(&row)
            .collect();
        // Most recent first; the renderer never re-sorts, so ordering is one decision in
        // one place.
        threads.sort_by(|a, b| b.last_activity.cmp(&a.last_activity));
        groups.push(NavGroup { entity: entity_view(entity), threads });
    }

    let mut unbound: Vec<ThreadRow> =
        summaries.iter().filter(|s| s.entity_id.is_none()).map(&row).collect();
    unbound.sort_by(|a, b| b.last_activity.cmp(&a.last_activity));

    NavigationTree {
        groups,
        unbound,
        active: active_binding_view(&spine),
        unbound_explanation: UNBOUND_THREAD_EXPLANATION.to_string(),
    }
}

/// The authoritative answer to "which entity and thread is the CEO actually talking to?".
#[tauri::command]
fn active_context(state: State<AppState>) -> Option<ActiveContext> {
    active_binding_view(&state.spine.lock().unwrap())
}

/// One thread's durable scope. Fallible on purpose: an unbound thread returns the core's
/// own `UnboundThread` message, which is what the UI renders in the binding-failure state.
#[tauri::command]
fn thread_scope(state: State<AppState>, thread_id: String) -> Result<ActiveContext, String> {
    let spine = state.spine.lock().unwrap();
    spine
        .ledger()
        .thread_binding(&thread_id)
        .map(|b| ActiveContext {
            thread_id: b.thread_id().to_string(),
            entity_id: b.entity_id().to_string(),
            binding_revision: b.binding_revision(),
        })
        .map_err(|e| e.to_string())
}

/// Create a thread inside an EXPLICITLY CHOSEN entity and make it the active context.
///
/// This is the command that makes entity selection real rather than cosmetic. The older
/// `create_thread` takes its entity from launch-time root resolution and cannot express
/// "the CEO picked Deeply in the picker"; this one takes the choice as an argument and
/// hands it to `Spine::create_thread`, which refuses an unregistered entity
/// (`SpineError::UnknownEntity`) rather than inventing one.
///
/// §3.3: *"no pre-created thread record until the CEO sends the first message"* — so the
/// UI holds a draft with no record and calls this on first send, not on picker open.
#[tauri::command]
fn create_thread_in(state: State<AppState>, entity_id: String, title: String) -> Result<String, String> {
    let entity = EntityId::parse(entity_id.trim()).map_err(|e| e.to_string())?;
    let title = if title.trim().is_empty() { "New thread".to_string() } else { title.trim().to_string() };
    let mut spine = state.spine.lock().unwrap();
    let id = spine.create_thread(&title, &entity).map_err(|e| e.to_string())?;
    // Activate it: `Spine::create_thread` only auto-activates when nothing is active, and
    // a thread the CEO just started must become the scope every subsequent send runs under.
    spine.switch_thread(&id).map_err(|e| e.to_string())?;
    Ok(id)
}

// ---- search (§3.4) --------------------------------------------------------------------

#[derive(serde::Serialize)]
struct SearchHit {
    /// "entity" | "thread" | "message"
    kind: String,
    entity_id: Option<String>,
    entity_label: String,
    thread_id: Option<String>,
    thread_title: Option<String>,
    excerpt: String,
    at: u64,
}

/// Default result cap. §3.4: *"Search must not load all thread bodies into the renderer."*
/// The match runs HERE, against the ledger, and only bounded excerpts cross the IPC
/// boundary — so a long history costs the renderer a few dozen short strings.
const SEARCH_DEFAULT_LIMIT: usize = 40;
/// Per-thread cap on message hits, so one long thread cannot fill the palette and hide
/// every other entity's results.
const SEARCH_HITS_PER_THREAD: usize = 3;
/// Characters of context either side of a match in an excerpt.
const SEARCH_EXCERPT_RADIUS: usize = 60;

/// Case-fold to a `Vec<char>` that is INDEX-ALIGNED with the original's chars.
///
/// `str::to_lowercase` is not usable for locating a match: it can change the character
/// count (`ß` -> `ss`), so an index found in the folded string can point at the wrong
/// character of the original and slice an excerpt in the wrong place. Taking only the
/// first char of each `char::to_lowercase()` keeps the 1:1 mapping the excerpt maths
/// depends on.
fn fold_chars(s: &str) -> Vec<char> {
    s.chars().map(|c| c.to_lowercase().next().unwrap_or(c)).collect()
}

fn find_folded(hay: &[char], needle: &[char]) -> Option<usize> {
    if needle.is_empty() || needle.len() > hay.len() {
        return None;
    }
    (0..=hay.len() - needle.len()).find(|&i| hay[i..i + needle.len()] == *needle)
}

fn excerpt_at(original: &[char], at: usize, needle_len: usize) -> String {
    let start = at.saturating_sub(SEARCH_EXCERPT_RADIUS);
    let end = (at + needle_len + SEARCH_EXCERPT_RADIUS).min(original.len());
    let mut out = String::new();
    if start > 0 {
        out.push('…');
    }
    out.extend(original[start..end].iter());
    if end < original.len() {
        out.push('…');
    }
    out.split_whitespace().collect::<Vec<_>>().join(" ")
}

/// Command-palette search over entity names, thread titles and message text (§3.4).
///
/// Scope-safe by construction: message bodies are read with `Ledger::messages`, which is
/// the scoped accessor and refuses an unbound thread — so search can surface an unbound
/// thread's TITLE (already listed in the rail, and a title is navigation metadata) but can
/// never surface its contents. Each hit carries its entity so the renderer groups by entity
/// without having to work out which entity a result came from.
#[tauri::command]
fn search_nav(state: State<AppState>, query: String, limit: Option<usize>) -> Vec<SearchHit> {
    let spine = state.spine.lock().unwrap();
    let nav = state.nav.lock().unwrap();
    run_search(&spine, nav.state(), &query, limit.unwrap_or(SEARCH_DEFAULT_LIMIT))
}

fn run_search(spine: &Spine, nav_state: &nav::NavState, query: &str, limit: usize) -> Vec<SearchHit> {
    let needle = fold_chars(query.trim());
    if needle.is_empty() {
        return Vec::new();
    }
    let limit = limit.clamp(1, 200);
    let ledger = spine.ledger();
    let registry = spine.entity_registry();

    let label_of = |id: Option<&str>| -> String {
        match id.and_then(|i| EntityId::parse(i).ok()).and_then(|i| registry.get(&i)) {
            Some(e) => e.display_name.clone(),
            None => "No entity".to_string(),
        }
    };

    let mut hits: Vec<SearchHit> = Vec::new();

    // 1. Entity names.
    for e in registry.entities() {
        let hay_name = fold_chars(&e.display_name);
        let hay_id = fold_chars(e.id.as_str());
        if find_folded(&hay_name, &needle).is_some() || find_folded(&hay_id, &needle).is_some() {
            hits.push(SearchHit {
                kind: "entity".into(),
                entity_id: Some(e.id.to_string()),
                entity_label: e.display_name.clone(),
                thread_id: None,
                thread_title: None,
                excerpt: e.display_name.clone(),
                at: 0,
            });
        }
    }

    let summaries = spine.threads();

    // 2. Thread titles (ledger title AND the CEO's rename override — searching for what
    //    you can see on screen has to work).
    for s in &summaries {
        let display = nav_state.renamed_threads.get(&s.id).cloned().unwrap_or_else(|| s.title.clone());
        let matched = find_folded(&fold_chars(&s.title), &needle).is_some()
            || find_folded(&fold_chars(&display), &needle).is_some();
        if matched {
            hits.push(SearchHit {
                kind: "thread".into(),
                entity_id: s.entity_id.clone(),
                entity_label: label_of(s.entity_id.as_deref()),
                thread_id: Some(s.id.clone()),
                thread_title: Some(display),
                excerpt: String::new(),
                at: s.last_activity,
            });
        }
    }

    // 3. Message bodies — scoped read only; an unbound thread is skipped by the `Err` arm.
    for s in &summaries {
        if hits.len() >= limit {
            break;
        }
        let Ok(messages) = ledger.messages(&s.id) else { continue };
        let display = nav_state.renamed_threads.get(&s.id).cloned().unwrap_or_else(|| s.title.clone());
        let mut per_thread = 0usize;
        for m in messages.iter().rev() {
            if per_thread >= SEARCH_HITS_PER_THREAD || hits.len() >= limit {
                break;
            }
            let chars: Vec<char> = m.text.chars().collect();
            let folded = fold_chars(&m.text);
            if let Some(at) = find_folded(&folded, &needle) {
                let excerpt = excerpt_at(&chars, at, needle.len());
                // A message whose whole text IS the thread title (the common case for the
                // first message, since §3.3 derives the provisional title from it) would
                // render as a second identical row under the title hit. One match, one row.
                if excerpt == display {
                    continue;
                }
                hits.push(SearchHit {
                    kind: "message".into(),
                    entity_id: s.entity_id.clone(),
                    entity_label: label_of(s.entity_id.as_deref()),
                    thread_id: Some(s.id.clone()),
                    thread_title: Some(display.clone()),
                    excerpt,
                    at: m.at,
                });
                per_thread += 1;
            }
        }
    }

    hits.truncate(limit);
    hits
}

// ---- durable navigation view state (nav.rs) -------------------------------------------

#[tauri::command]
fn nav_state(state: State<AppState>) -> nav::NavState {
    state.nav.lock().unwrap().state().clone()
}

/// Returns the width the store ACCEPTED (clamped to UX §2.1's 224–420px), not the width
/// requested — so the rail renders what was persisted and the two cannot disagree.
#[tauri::command]
fn set_sidebar_width(state: State<AppState>, width: f64) -> Result<f64, String> {
    state.nav.lock().unwrap().set_sidebar_width(width).map_err(|e| e.to_string())
}

#[tauri::command]
fn set_sidebar_collapsed(state: State<AppState>, collapsed: bool) -> Result<(), String> {
    state.nav.lock().unwrap().set_sidebar_collapsed(collapsed).map_err(|e| e.to_string())
}

#[tauri::command]
fn set_entity_collapsed(state: State<AppState>, entity_id: String, collapsed: bool) -> Result<(), String> {
    state.nav.lock().unwrap().set_entity_collapsed(&entity_id, collapsed).map_err(|e| e.to_string())
}

#[tauri::command]
fn set_thread_pinned(state: State<AppState>, thread_id: String, pinned: bool) -> Result<(), String> {
    state.nav.lock().unwrap().set_thread_pinned(&thread_id, pinned).map_err(|e| e.to_string())
}

/// Archive REMOVES FROM THE NORMAL LIST (§3.2) — it does not delete, and it does not touch
/// the thread's entity home. An archived thread is still bound to exactly the entity it was
/// always bound to and is still fully readable from the archive view.
#[tauri::command]
fn set_thread_archived(state: State<AppState>, thread_id: String, archived: bool) -> Result<(), String> {
    state.nav.lock().unwrap().set_thread_archived(&thread_id, archived).map_err(|e| e.to_string())
}

/// A DISPLAY override. The ledger's title is evidence and is left exactly as written — see
/// nav.rs's module doc for why a rename is not a ledger edit.
#[tauri::command]
fn rename_thread(state: State<AppState>, thread_id: String, title: String) -> Result<(), String> {
    state.nav.lock().unwrap().rename_thread(&thread_id, &title).map_err(|e| e.to_string())
}

#[cfg(test)]
mod navigation_tests {
    use super::*;

    /// The FIRST TWO LINES OF THE REAL SHIPPING LEDGER on this machine
    /// (`~/Library/Application Support/com.richos.app/conversation-ledger.jsonl`), copied
    /// byte-for-byte on 2026-08-29. They are the two cases the rail has to get right and
    /// the reason this test is written against real bytes instead of a synthetic fixture:
    ///
    ///   line 1 — a `ThreadCreated` with NO `entity_id` at all. Written before entity
    ///            scoping existed, so it replays as `ThreadEntity::Unbound`. This is the
    ///            record that used to break the shell when opened.
    ///   line 2 — a `ThreadCreated` carrying `entity_id: "richos"`, written after slice 1.
    ///
    /// Any future change to the on-disk event shape that would silently reclassify either
    /// of these fails here.
    const REAL_PRE_ENTITY_LEDGER: &str = concat!(
        r#"{"event":"ThreadCreated","thread_id":"thr_5941509111b84531a299acfce7f99948","title":"General","at":1787577795601}"#,
        "\n",
        r#"{"event":"ThreadCreated","thread_id":"thr_dbaacd4320ee482daf414414f590ccba","title":"Running","at":1787975160731,"entity_id":"richos","person_id":"ceo-default","binding_revision":1}"#,
        "\n",
    );

    const UNBOUND_ID: &str = "thr_5941509111b84531a299acfce7f99948";
    const BOUND_ID: &str = "thr_dbaacd4320ee482daf414414f590ccba";

    fn spine_from_real_ledger(tag: &str) -> (Spine, PathBuf) {
        let mut path = std::env::temp_dir();
        path.push(format!("richos-nav-real-{}-{}.jsonl", tag, std::process::id()));
        let _ = std::fs::remove_file(&path);
        std::fs::write(&path, REAL_PRE_ENTITY_LEDGER).unwrap();
        let ledger = Ledger::open(&path).expect("replay the real ledger");
        (Spine::new(ledger), path)
    }

    #[test]
    fn the_real_pre_entity_thread_lands_in_unbound_and_in_no_entity_group() {
        let (spine, path) = spine_from_real_ledger("group");
        let tree = build_navigation_tree(&spine, &nav::NavState::default());

        // Four registered entities, each its own top-level group (§25 Navigation #1).
        let ids: Vec<&str> = tree.groups.iter().map(|g| g.entity.id.as_str()).collect();
        assert_eq!(ids, vec!["femcboost", "deeply", "prospects", "richos"]);

        // The pre-entity thread is listed, but NOT inside any entity.
        assert_eq!(tree.unbound.len(), 1);
        assert_eq!(tree.unbound[0].id, UNBOUND_ID);
        assert_eq!(tree.unbound[0].display_title, "General");
        assert!(tree.unbound[0].entity_id.is_none());
        for group in &tree.groups {
            assert!(
                !group.threads.iter().any(|t| t.id == UNBOUND_ID),
                "an unbound thread must never be placed in {} — that placement WOULD BE the guess \
                 slice 1 refused to make",
                group.entity.id
            );
        }

        // The bound thread is in exactly one group, and it is its own home entity.
        let homes: Vec<&str> = tree
            .groups
            .iter()
            .filter(|g| g.threads.iter().any(|t| t.id == BOUND_ID))
            .map(|g| g.entity.id.as_str())
            .collect();
        assert_eq!(homes, vec!["richos"], "§25: exactly one immutable entity home per thread");

        let _ = std::fs::remove_file(&path);
    }

    #[test]
    fn an_unbound_thread_reports_no_turn_state_because_its_turns_are_not_readable() {
        let (spine, path) = spine_from_real_ledger("facts");
        let tree = build_navigation_tree(&spine, &nav::NavState::default());
        let row = &tree.unbound[0];
        // NOT "idle" and NOT "completed" — unknown, because the scoped accessor refuses.
        assert_eq!(row.last_turn_state, None);
        assert!(!row.has_pending_turn);
        assert_eq!(row.message_count, 0);
        // And the read the UI performs when the row is clicked genuinely refuses.
        let err = spine.messages(UNBOUND_ID).unwrap_err().to_string();
        assert!(err.contains("no entity binding"), "{err}");
        assert!(err.contains("An operator must bind it explicitly"), "{err}");
        // The sentence the UI shows is the one the core raises, not a paraphrase.
        assert!(tree.unbound_explanation.contains("predates entity scoping"));
        assert!(tree.unbound_explanation.contains("An operator must bind it explicitly"));
        let _ = std::fs::remove_file(&path);
    }

    #[test]
    fn pin_rename_and_archive_move_the_row_without_touching_the_entity_home() {
        let (spine, path) = spine_from_real_ledger("navstate");
        let mut nav_state = nav::NavState::default();
        nav_state.pinned_threads.push(BOUND_ID.to_string());
        nav_state.archived_threads.push(BOUND_ID.to_string());
        nav_state.renamed_threads.insert(BOUND_ID.to_string(), "Rich's desk".to_string());

        let tree = build_navigation_tree(&spine, &nav_state);
        let row = tree
            .groups
            .iter()
            .flat_map(|g| &g.threads)
            .find(|t| t.id == BOUND_ID)
            .expect("still in its entity group");

        assert!(row.pinned && row.archived);
        // §25: these "work without changing context authority".
        assert_eq!(row.entity_id.as_deref(), Some("richos"), "archive must not move a thread's home");
        // A rename is a DISPLAY override; the ledger's title is evidence and is untouched.
        assert_eq!(row.title, "Running");
        assert_eq!(row.display_title, "Rich's desk");
        let _ = std::fs::remove_file(&path);
    }

    #[test]
    fn search_finds_titles_and_entities_but_never_an_unbound_threads_contents() {
        let (mut spine, path) = spine_from_real_ledger("search");
        // Give the bound thread real content to find.
        let entity = EntityId::parse("richos").unwrap();
        spine.switch_thread(BOUND_ID).unwrap();
        let binding = spine.active_binding().unwrap().clone();
        assert_eq!(binding.entity_id(), &entity);

        let empty = nav::NavState::default();
        // Entity name.
        let hits = run_search(&spine, &empty, "richos", 40);
        assert!(hits.iter().any(|h| h.kind == "entity" && h.entity_id.as_deref() == Some("richos")));
        // The unbound thread's TITLE is findable (navigation metadata, already on screen).
        let hits = run_search(&spine, &empty, "general", 40);
        let unbound_hits: Vec<&SearchHit> = hits.iter().filter(|h| h.thread_id.as_deref() == Some(UNBOUND_ID)).collect();
        assert_eq!(unbound_hits.len(), 1);
        assert_eq!(unbound_hits[0].kind, "thread");
        assert!(unbound_hits[0].excerpt.is_empty(), "a title hit carries no body excerpt");
        assert_eq!(unbound_hits[0].entity_label, "No entity", "never labelled with a guessed entity");
        // No hit anywhere is ever a `message` from the unbound thread.
        for q in ["e", "a", "n"] {
            for h in run_search(&spine, &empty, q, 200) {
                assert!(
                    !(h.kind == "message" && h.thread_id.as_deref() == Some(UNBOUND_ID)),
                    "search must never read an unbound thread's body"
                );
            }
        }
        let _ = std::fs::remove_file(&path);
    }

    #[test]
    fn search_folding_is_index_aligned_so_excerpts_are_not_sliced_in_the_wrong_place() {
        // U+0130 LATIN CAPITAL LETTER I WITH DOT ABOVE lowercases to TWO chars
        // ("i" + U+0307 COMBINING DOT ABOVE). `str::to_lowercase` would therefore shift
        // every index after it by one and slice the excerpt in the wrong place;
        // `fold_chars` keeps a strict 1:1 char mapping, so the excerpt maths stays correct.
        const SUBJECT: &str = "\u{130}stanbul office MATCH tail";
        let original: Vec<char> = SUBJECT.chars().collect();
        let folded = fold_chars(SUBJECT);
        assert_eq!(folded.len(), original.len(), "folding must not change the character count");

        // Proof the hazard is real and not theoretical on this exact input.
        assert_eq!(SUBJECT.to_lowercase().chars().count(), original.len() + 1);

        let at = find_folded(&folded, &fold_chars("match")).expect("found");
        assert_eq!(original[at..at + 5].iter().collect::<String>(), "MATCH");
        assert!(excerpt_at(&original, at, 5).contains("MATCH"));

        // The naive index would have landed one char early — on "H" through "tail".
        let naive = SUBJECT.to_lowercase().chars().collect::<Vec<char>>();
        let naive_at = find_folded(&naive, &fold_chars("match")).expect("found");
        assert_eq!(naive_at, at + 1, "the two indices genuinely differ");
    }

    #[test]
    fn create_thread_in_refuses_an_unregistered_entity_rather_than_inventing_one() {
        let (mut spine, path) = spine_from_real_ledger("create");
        let err = spine.create_thread("x", &EntityId::parse("not-an-entity").unwrap()).unwrap_err();
        assert!(err.to_string().contains("not-an-entity"), "{err}");
        // And the valid case binds immutably to the chosen entity.
        let id = spine.create_thread("Q4 board pack", &EntityId::parse("deeply").unwrap()).unwrap();
        spine.switch_thread(&id).unwrap();
        assert_eq!(spine.active_entity().unwrap().as_str(), "deeply");
        let tree = build_navigation_tree(&spine, &nav::NavState::default());
        let deeply = tree.groups.iter().find(|g| g.entity.id == "deeply").unwrap();
        assert!(deeply.threads.iter().any(|t| t.id == id));
        assert_eq!(tree.active.as_ref().unwrap().entity_id, "deeply");
        let _ = std::fs::remove_file(&path);
    }
}
