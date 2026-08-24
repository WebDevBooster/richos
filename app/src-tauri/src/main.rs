// RichOS desktop shell (Tauri). A THIN surface over the richos-core spine.
//
// Doctrine: clean output (only Rich's assistant text renders), one conversation with
// Rich, optional multi-thread topic organization. All runtime intelligence — the ACP
// client, the crash-safe ledger, threads, re-prime continuity — lives in richos-core;
// this file is just the window + the Tauri command bridge to the web UI in ../ui.
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

use richos_core::acp::{resolve_acp_bin, AcpCognition};
use richos_core::ledger::{Ledger, Message, Source};
use richos_core::spine::Spine;
use richos_core::stream::{StreamEvent, TurnObserver};
use richos_core::thread::ThreadSummary;
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

/// The durable Rich, guarded for cross-invocation access. `Spine` is `Send` (its
/// compute lease is `Box<dyn Cognition + Send>`), so `Mutex<Spine>` is valid Tauri state.
struct AppState {
    spine: Mutex<Spine>,
    /// Set false when no ACP lease could be attached at boot (e.g. Claude not logged in),
    /// so the UI can surface a calm, Rich-voiced "not connected" state instead of a crash.
    lease_ready: bool,
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
    state.spine.lock().unwrap().create_thread(&title).map_err(|e| e.to_string())
}

#[tauri::command]
fn switch_thread(state: State<AppState>, thread_id: String) -> Result<(), String> {
    state.spine.lock().unwrap().switch_thread(&thread_id).map_err(|e| e.to_string())
}

#[tauri::command]
fn get_messages(state: State<AppState>, thread_id: String) -> Vec<Message> {
    state.spine.lock().unwrap().messages(&thread_id)
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
    Ok(spine.messages(&thread))
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
            spine.ensure_active_thread().expect("ensure thread");

            // Attach the live UI sink: streamed reply deltas + turn-state events flow to
            // the webview via Tauri events (see app/STREAMING.md for the contract).
            spine.set_observer(Box::new(TauriEmitter { app: app.handle().clone() }));

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

            app.manage(AppState { spine: Mutex::new(spine), lease_ready });
            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
            list_threads,
            active_thread,
            create_thread,
            switch_thread,
            get_messages,
            send_message
        ])
        .run(tauri::generate_context!())
        .expect("error while running RichOS");
}
