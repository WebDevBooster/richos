//! **THE SEAM INTO THE REST OF THE APP** — [`routes::Bridge`] implemented over the Tauri handles,
//! and the one honest limit it runs into.
//!
//! # The wall this file works around, measured
//!
//! `Spine::submit_prompt` takes `&mut self` and does not return until the turn is over, and the
//! shell holds the one `Spine` behind a `Mutex` (`main.rs`, `state.spine.lock().unwrap()`). So for
//! the whole length of a turn — the spec's own example is *"Worked for 2h 17m 50s"* — **every path
//! into the spine is blocked.**
//!
//! Two consequences, and they are handled differently because they are different problems:
//!
//! **Writing** is already solved and not by this file: the CEO's words go to the durable intake
//! log, which is reachable without the spine lock, and `Spine::poll_intake` drains it. So
//! [`PhoneBridge::submit_text`] returns in the time one `fsync` takes, and the turn itself runs on
//! a thread that is allowed to wait for the lock for as long as it needs.
//!
//! **Reading** is the one that needed a decision. A phone opening its stream while Rich is
//! mid-turn cannot be made to wait for the lock: that is an HTTP request held open for
//! potentially hours, which presents as a phone that will not start. So this file keeps **the last
//! gated payload it was able to read** and serves that when the lock is busy.
//!
//! **What that costs, stated rather than buried:** a phone whose very first connection happens
//! during a long turn, on an install that has never had one, gets a readable *"Rich is working"*
//! instead of the conversation. Every other case is covered, because the cache is primed when the
//! channel starts (he has just opened the pairing screen, so nothing is running) and refreshed
//! after every turn the channel itself starts. It is a cache of something already gated — never a
//! second source of truth, and never something the phone can disagree with the Mac about for
//! longer than one turn.

use super::routes::{Accepted, Bridge};
use crate::timeline_view::timeline_payload;
use crate::AppState;
use serde_json::Value;
use std::collections::HashMap;
use std::sync::Mutex;
use tauri::{AppHandle, Manager};

/// What the phone is allowed to reach, and how.
pub struct PhoneBridge {
    app: AppHandle,
    /// The last gated payload per thread, and the thread list. Refreshed whenever the spine lock
    /// happens to be free.
    cache: Mutex<Cache>,
    voice: super::voice::VoiceDesk,
}

#[derive(Default)]
struct Cache {
    payloads: HashMap<String, Value>,
    threads: Vec<(String, String)>,
    active: Option<String>,
}

impl PhoneBridge {
    pub fn new(app: AppHandle) -> Self {
        let directory = app.state::<AppState>().data_dir.join("phone/speech");
        let bridge = PhoneBridge { app, cache: Mutex::new(Cache::default()), voice: super::voice::VoiceDesk::new(directory) };
        // Primed at construction, which is when the CEO opens the pairing screen — so nothing is
        // running and the lock is free. This is what makes the degraded path above rare rather
        // than ordinary.
        bridge.refresh();
        bridge
    }

    /// Read everything the phone might ask for, if the spine is free. Called at construction and
    /// after every turn the channel starts.
    pub fn refresh(&self) {
        let state = self.app.state::<AppState>();
        let Ok(spine) = state.spine.try_lock() else { return };
        let threads: Vec<(String, String)> =
            spine.threads().into_iter().map(|t| (t.id.clone(), t.title.clone())).collect();
        let active = spine.active_thread().map(|s| s.to_string()).or_else(|| threads.first().map(|t| t.0.clone()));
        let mut payloads = HashMap::new();
        if let Some(id) = active.as_deref() {
            if let Ok(payload) = timeline_payload(&*spine, id) {
                payloads.insert(id.to_string(), payload);
            }
        }
        let mut cache = self.cache.lock().unwrap();
        cache.threads = threads;
        cache.active = active;
        for (k, v) in payloads {
            cache.payloads.insert(k, v);
        }
    }
}

impl Bridge for PhoneBridge {
    fn native_notifications_available(&self)->bool {true}
    fn register_native_notifications(&self,device:&str,registration:Option<super::notifications::Registration>)->Result<Value,String> {
        self.app.state::<std::sync::Arc<super::PhoneRuntime>>().register_native_notifications(device,registration)
    }
    fn voice_available(&self) -> bool { self.voice.available() }
    /// `intake_<n>` -> the turn drained from intake record `n`, read with `try_lock` so a phone
    /// request never waits on a running turn: busy means "not yet", and the next request asks again.
    fn turn_for_intake(&self, message_id: &str) -> Option<String> {
        let n = message_id.strip_prefix("intake_")?.parse::<u64>().ok()?;
        let state = self.app.state::<AppState>();
        let spine = state.spine.try_lock().ok()?;
        spine.ledger().turn_for_intake(n).map(|turn| turn.id.clone())
    }
    fn transcribe(&self, bytes: &[u8]) -> Result<String, String> { self.voice.transcribe(bytes) }
    fn reply_audio(&self, thread: Option<&str>, id: &str) -> Result<Vec<u8>, String> {
        let payload = self.snapshot(thread)?;
        let rows = super::rows::rows_from_payload(&payload);
        let row = rows.iter().find(|row| row["id"] == id && row["role"] == "rich" && row["complete"] != false)
            .ok_or("This reply is not available for playback.")?;
        self.voice.synthesize(row["text"].as_str().unwrap_or(""))
    }

    fn submit_text(&self, thread_id: Option<&str>, text: &str) -> Result<Accepted, String> {
        let state = self.app.state::<AppState>();
        // The thread the words belong to, resolved HERE and never at drain time: the desktop's
        // active thread can move while a record waits, and re-scoping the CEO's words to wherever
        // the Mac happens to be looking would launder them across an entity boundary (ECS §3.4).
        let thread = thread_id
            .map(|s| s.to_string())
            .or_else(|| self.cache.lock().unwrap().active.clone())
            .ok_or_else(|| "this Mac has no conversation to add to yet".to_string())?;
        let entity = state.entity.lock().unwrap().clone();

        // Durable before the phone is answered. This is the whole reason the phone writes here
        // rather than calling the spine.
        let record = state
            .control
            .submit_from_channel(&thread, entity, text, "phone")
            .map_err(|e| e.to_string())?;
        let intake_id = record.id();

        // THE DRAIN RUNS ON ITS OWN THREAD, because it runs the turn. A phone that waited for the
        // reply before its POST returned would be a phone that times out on every question worth
        // asking.
        let app = self.app.clone();
        let reply_thread=thread.clone();
        std::thread::Builder::new()
            .name("richos-phone-drain".to_string())
            .spawn(move || {
                let state = app.state::<AppState>();
                let (outcome, binding) = {
                    let mut spine = state.spine.lock().unwrap();
                    let outcome = spine.poll_intake();
                    // On an operator install, work written down on this turn goes to his team's
                    // desk, which refuses a phone assignment with its sentence (r3 (s) rule 1).
                    let binding = state.operator.is_some()
                        .then(|| spine.ledger().thread_binding(&reply_thread).ok()).flatten();
                    (outcome, binding)
                };
                if let Err(e) = outcome {
                    eprintln!("[richos] the phone's message could not be drained: {e}");
                }
                if let Some(binding) = binding {
                    state.work.adopt_registered(&binding);
                }
                // The lock is free again here, so this is the cheapest correct moment both to
                // make the cached view current and to push the reply that just finished. Neither
                // can be done from inside the turn: one needs the lock, and the other needs to
                // await, which §13 says the live observer must never do.
                let runtime = app.state::<std::sync::Arc<super::PhoneRuntime>>();
                runtime.bridge_refresh();
                runtime.push_last_reply(&reply_thread);
            })
            .map_err(|e| format!("could not start the drain: {e}"))?;

        Ok(Accepted {
            // The intake id, not a turn id: there is no turn yet, and inventing one here would be
            // a claim that the message had been accepted as work rather than as words.
            message_id: format!("intake_{intake_id}"),
            thread_id: thread,
            at: super::now_millis(),
        })
    }

    fn snapshot(&self, thread_id: Option<&str>) -> Result<Value, String> {
        let state = self.app.state::<AppState>();
        let thread = thread_id
            .map(|s| s.to_string())
            .or_else(|| self.cache.lock().unwrap().active.clone())
            .ok_or_else(|| "this Mac has no conversation yet".to_string())?;
        if let Ok(spine) = state.spine.try_lock() {
            // `timeline_payload` is the ONLY way this file can obtain a payload, and it is
            // `view(ViewMode::Ceo)` — `Timeline` does not implement `Serialize`, so there is no
            // ungated path from here to the phone even by mistake.
            let payload = timeline_payload(&*spine, &thread)?;
            self.cache.lock().unwrap().payloads.insert(thread.clone(), payload.clone());
            return Ok(payload);
        }
        self.cache
            .lock()
            .unwrap()
            .payloads
            .get(&thread)
            .cloned()
            .ok_or_else(|| "Rich is working. Your conversation will appear when he finishes.".to_string())
    }

    fn current_thread(&self) -> Option<(String, String)> {
        let cache = self.cache.lock().unwrap();
        let id = cache.active.clone()?;
        let title = cache
            .threads
            .iter()
            .find(|(known, _)| *known == id)
            .map(|(_, t)| t.clone())
            .unwrap_or_else(|| "Rich".to_string());
        Some((id, title))
    }

    fn threads(&self) -> Vec<(String, String)> {
        self.cache.lock().unwrap().threads.clone()
    }
}

