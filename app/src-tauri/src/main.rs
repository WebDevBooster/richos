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
use richos_core::config::{Assertiveness, ConfigStore, RetentionChoice, TechyMode};
use richos_core::correction::{
    CliLoroWriter, CorrectionDesk, Proposal, ProposalObserver, ProposedWrite, SharedCorrectionDesk,
    WriteOutput, EVENT_LORO_PROPOSED,
};
use richos_core::entity::{EntityId, EntityRegistry};
use richos_core::feedback::{
    ContributingCondition, DiagnosisTerm, Disclosure, FailureClass, FeedbackEntry, FeedbackPayload,
    FeedbackStore, Occurrences, PromptOutcome, Rating, ReportDecision, DISCLOSURE_HEADING,
    PROMPT_OPTIONS, PROMPT_QUESTION, REPORT_OFFER, TAXONOMY_VERSION,
};
use richos_core::journal::{MachineryJournal, RawRetention};
use richos_core::ledger::{AttentionTier, Ledger, Message, Source};
use richos_core::loro::{CliContextCompiler, SharedSliceProvenance, SliceProvenance};
use richos_core::machinery::{MachineryObserver, MachineryRecord, EVENT_MACHINERY};
use richos_core::spine::{Spine, WorkerEventsSource};
use richos_core::heard::{DictationJournal, HeardSource};
use richos_core::staging::{
    Candidate, CandidateDesk, CliVocabulary, CorrectionObserver, LearnOutcome, SharedCandidateDesk,
    Staged, EVENT_CORRECTION_STAGED,
};
use richos_core::steering::{IntakeRecord, StopOutcome, TurnControl};
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

/// The `get_machinery` command body — techy mode's read path. Its own file for the same
/// reason `timeline_view` is: an example includes the SAME source and prints the exact
/// JSON the webview receives.
mod machinery_view;
use machinery_view::machinery_payload;

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

/// The SPOKEN-CORRECTION sink (`staging.rs`): forwards §7's ask to the webview on
/// `rich://correction-staged`.
///
/// A FOURTH observer, separate from the other three for the reason the machinery sink is
/// separate: a surface's subscription list is the proof of what it carries, and the calm
/// conversation view must be able to ignore this entirely. Best-effort, like the others —
/// the question is already durable on disk before this runs, so a webview that is not
/// listening loses a prompt and never a record.
struct TauriCorrectionEmitter {
    app: AppHandle,
}

impl CorrectionObserver for TauriCorrectionEmitter {
    fn on_correction_staged(&self, staged: &Staged) {
        let _ = self.app.emit(EVENT_CORRECTION_STAGED, staged);
    }
}

/// The LORO-PROPOSAL sink (`belief.rs` -> `correction.rs`): forwards a filed proposal to
/// the webview on `rich://loro-proposed`.
///
/// A FIFTH observer, and a separate event from `rich://correction-staged` because the two
/// carry different payloads and a subscription list is the proof of what a surface renders.
/// Best-effort like the others: the proposal is durable on the desk's own log before this
/// runs, so a webview that is not listening loses a badge update and never a record.
struct TauriProposalEmitter {
    app: AppHandle,
}

impl ProposalObserver for TauriProposalEmitter {
    fn on_correction_proposed(&self, proposal: &Proposal) {
        let _ = self.app.emit(EVENT_LORO_PROPOSED, proposal);
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
    /// `<app-data>/machinery` — the Tier-B store the retention setting governs.
    ///
    /// Held here as a PATH rather than reached through `spine.machinery_journal()`
    /// deliberately: `send_message` holds the spine's mutex for the whole of a turn, so a
    /// settings command that locked it would sit there until Rich finished talking. A
    /// `MachineryJournal` is a path and nothing else, so building one per call costs
    /// nothing and the gear popover answers while a turn is running.
    machinery_root: PathBuf,
    /// Durable navigation view state (UX §3.1/§25: pin, rename, archive, rail width).
    /// Separate from `config` because it is view state, not a CEO preference about how
    /// Rich behaves — and separate from the ledger because it is not evidence (nav.rs).
    nav: Mutex<nav::NavStore>,
    /// THE CEO'S TWO MID-TURN CONTROLS (UX §9.2/§9.3), and the one thing here that is
    /// DELIBERATELY NOT behind `spine`'s mutex.
    ///
    /// `send_message` holds that mutex for the entire turn — `Spine::submit_prompt` takes
    /// `&mut self` and does not return until the lease is finished — so a stop command
    /// that locked the spine would fire only after the work it meant to interrupt had
    /// already ended. This is the same `Arc` the spine holds, reached without the lock.
    control: TurnControl,
    /// THE LORO CORRECTION DESK (open-items 3.5). `None` when no corpus is configured,
    /// which is an ordinary install and not an error — the commands then say so in words
    /// instead of failing obscurely.
    ///
    /// Behind its OWN mutex, not the spine's, for the same reason `control` is: reading
    /// what loro believes and confirming a correction are things the CEO does while Rich
    /// may be mid-turn, and `send_message` holds the spine lock for the whole of a turn.
    /// A correction UI that froze until Rich finished would be a UI nobody uses.
    correction: Option<SharedCorrectionDesk>,
    /// THE SPOKEN-CORRECTION DESK — the flywheel's automatic trigger (`spoken.rs` +
    /// `staging.rs`). The SAME `Arc` the spine holds, reached WITHOUT the spine lock, for
    /// exactly the reason `control` is: `send_message` holds the spine mutex for the whole
    /// of a turn, and answering "Add \"Kestrel\" to your vocabulary?" is something the CEO
    /// does WHILE Rich is working. A HUD that froze until the turn finished would be a HUD
    /// nobody answers, and an unanswered ask is a lost correction.
    ///
    /// `None` when the desk's own log could not be opened — the commands then say so
    /// rather than failing obscurely.
    spoken: Option<SharedCandidateDesk>,
    /// THE FEEDBACK CHANNEL'S LOCAL STORE (`feedback.rs`). One file beside the ledger, and
    /// that is the whole storage layer this feature has.
    ///
    /// Behind its OWN mutex and NOT the spine's, for the third time and the same reason:
    /// `send_message` holds the spine lock for the whole of a turn, and "how is RichOS
    /// doing this session?" is a question about a session that may still be running.
    ///
    /// `None` when the file could not be opened. The commands then REFUSE rather than
    /// pretend — asking the CEO what he thinks and dropping the answer on the floor is
    /// worse than saying the capability is not available.
    feedback: Option<Mutex<FeedbackStore>>,
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
/// **`(async)` is load-bearing, not decoration.** A plain `#[tauri::command]` on a
/// non-async fn is dispatched by the macro as `ExecutionContext::Blocking`, which runs it
/// inline on the IPC/main thread (`tauri-macros`'s own `kind` string for that arm is
/// `"sync"`; the `async` attribute on a sync fn makes it `"sync_threadpool"`). A turn can
/// last hours, so blocking there would freeze the webview AND queue `stop_turn` behind the
/// very turn it is meant to interrupt — the stop would be structurally impossible no
/// matter how the rest of the plumbing is written.
#[tauri::command(async)]
fn send_message(state: State<AppState>, text: String) -> Result<Vec<Message>, String> {
    if !state.lease_ready {
        return Err(LEASE_UNAVAILABLE_MESSAGE.into());
    }
    let mut spine = state.spine.lock().unwrap();
    spine.submit_prompt(&text, Source::Text).map_err(|e| e.to_string())?;
    // "no active thread" used to be the whole sentence here, and it went straight onto the
    // CEO's screen through `send()`'s `String(e)`. Machinery, and it named neither an action
    // nor an actor. The prompt IS already submitted by this line, so the sentence must not
    // claim the message was lost, and must not promise it will reappear — nothing here knows
    // that.
    let thread = spine
        .active_thread()
        .ok_or(
            "I've taken that down, but I haven't got a thread open to show it in. Quit RichOS \
             and open it again; if it still isn't here, whoever set RichOS up needs to look.",
        )?
        .to_string();
    spine.messages(&thread).map_err(|e| e.to_string())
}

/// What the CEO is told when there is no lease to think with.
///
/// WHAT IT USED TO SAY, AND WHY IT IS THE EXACT DEFECT THIS PASS EXISTS TO REMOVE:
///
///     "I'm not connected to my thinking right now — check that the Claude CLI is signed
///      in, then restart me."
///
/// "The Claude CLI" is a thing the CEO has never seen. "Restart me" names no control, and
/// there is no restart control in this app to name. So the app reported a condition that
/// required a human action while rendering neither the action nor the actor — a request
/// wearing a status's clothes, which is precisely how a landed-but-inert guard got reported
/// as a date instead of a five-second fix.
///
/// It now offers the one thing he can genuinely do (quit and reopen — no key combination is
/// quoted, because Windows packaging is still an open gap in the architecture doc §4.4 and
/// a hard-coded ⌘Q would become a lie the day it ships), and names who owns the rest.
///
/// THREE COPIES EXIST and that is one problem this commit only halves: the two Rust sites
/// now share this const, and `app/ui/mock.js` carries a fourth-wall copy for the browser
/// preview's `_notConnected` switch. The affordance suite asserts the two are identical, so
/// they cannot drift silently.
const LEASE_UNAVAILABLE_MESSAGE: &str =
    "I'm not connected to my thinking right now, so I can't take that on. Quit RichOS and \
     open it again — that clears it most of the time. If it keeps happening, whoever set \
     RichOS up has to sign me back in; that part isn't yours to fix.";

/// What the CEO is told when the repository root does not deterministically select one
/// entity. UX §21 "Entity binding failure": state that Rich cannot safely determine which
/// entity the work belongs to, and require an explicit choice. Never default.
///
/// THAT DAY IS TODAY. This sentence used to end "Set RICHOS_ENTITY to one of femcboost,
/// deeply, prospects or richos, or launch me from that entity's repository root", and it
/// carried its own note saying it was safe only because nothing in `app/ui/main.js`
/// invoked a command that raises it — *"the day a slice wires one of those commands to a
/// button, this sentence becomes a terminal instruction addressed to a man who does not
/// open terminals"*. The correction desk wires three of them
/// (`loro_pending_corrections`, `loro_propose_correction`, `loro_confirm_correction`), so
/// the sentence is now rewritten to the register `LEASE_UNAVAILABLE_MESSAGE` already uses:
/// it says what it will not do and why, it names who owns the fix, and it invents no
/// control — because there genuinely is none in the app. An environment variable is not an
/// action the CEO can take, and telling him to take it would be the same request-wearing-a-
/// status's-clothes defect one more time.
///
/// The operator has NOT lost the instruction. `RICHOS_ENTITY` is still exactly right for
/// whoever set RichOS up, and it is still printed at boot — beside this sentence, at the
/// one site whose audience is a terminal (see the `eprintln!` in `setup`). Two audiences,
/// two sentences, one condition.
const ENTITY_UNRESOLVED_MESSAGE: &str =
    "I can't tell which company this work belongs to, so I won't guess — filing it under \
     the wrong one would mix two companies' records together, and that's not a mistake \
     worth risking to save you a question. It isn't something you can set from in here: \
     whoever set RichOS up has to tell me which company this copy of me works for.";

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
                // THE OPERATOR'S HALF of the same condition. The const above is written for
                // the CEO and deliberately names no environment variable; this line is read
                // by whoever it names, in a terminal, where `RICHOS_ENTITY` is the correct
                // and actionable instruction.
                None => eprintln!(
                    "[richos] {ENTITY_UNRESOLVED_MESSAGE}\n\
                     [richos] operator: set RICHOS_ENTITY to one of femcboost, deeply, \
                     prospects or richos, or launch from that entity's repository root."
                ),
            }

            // Attach the live UI sink: streamed reply deltas + turn-state events flow to
            // the webview via Tauri events (see app/STREAMING.md for the contract).
            spine.set_observer(Box::new(TauriEmitter { app: app.handle().clone() }));

            // Durable CEO preferences (company name, assertiveness dial, the raw-retention
            // window) — same app data dir as the ledger, same durability posture, survives
            // restart.
            //
            // OPENED HERE, ahead of the machinery block below, rather than where it used to
            // sit fifty lines further down: boot eviction now reads its window out of this
            // store (§7.2), and a store opened after the eviction it governs would leave the
            // CEO's setting unread for exactly the one moment it matters.
            let config_path = data_dir.join("config.json");
            // ConfigStore::open never fails on a corrupt/missing file (it degrades to
            // defaults internally — see config.rs) — expect() here only guards the
            // genuinely-unexpected io error creating the parent dir.
            let config = ConfigStore::open(&config_path).expect("open config store");

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
            // Tier-B eviction at boot (§2.4), against THE CEO'S OWN WINDOW (§7.2) rather
            // than against two constants. `raw_retention()` on an install that has never
            // set it is `RAW_RETENTION_DAYS` / `RAW_MAX_TOTAL_BYTES` — the same 14 days and
            // 2 GB this line passed before — so nothing about an existing machine changes.
            // Tier A — the normalized record — is never touched at ANY setting, so an
            // evicted day still renders its structure, titles, statuses and paths. Boot is
            // the right moment: it is off the streaming hot path entirely.
            let evicted = journal.evict_raw_within(richos_core::util::now_millis(), config.raw_retention());
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

            // THE WORKER-LIFECYCLE STREAM (UX §7), 2026-08-29.
            //
            // Without this line `Spine::timeline` supplies an EMPTY worker stream and a
            // delegated `Task` call reaches the CEO as one nameless activity row reading
            // "Worked" — which is what shipped, and why `TimelineItem::WorkerActivity`
            // existed, was fully tested, and had never once occurred on the wire.
            //
            // `CurrentTeamDir` re-resolves on every read rather than binding a path at boot:
            // the engine's hooks are snapshotted at SESSION start, so the directory this
            // machine's current session writes to changes without RichOS relaunching. The
            // home fallback is deliberately never read — it accumulates across sessions and
            // cannot be session-scoped (`worker_events.rs`).
            spine.set_worker_events(WorkerEventsSource::CurrentTeamDir);

            // TIER C — COMPANY MEMORY (continuity §2.1 #8 / §4, open-items 3.5).
            //
            // Without this line the seam that has existed since the continuity foundation
            // stays unset and every re-prime asserts a fresh Rich into existence with no
            // company memory at all, while the compiler sits complete and versioned one
            // directory away. That is what shipped, and it is why `LoroContextCompiler`
            // was fully specified, fully documented and had never once been called.
            //
            // Nothing is inferred. `LORO_CORPUS`/`LORO_ROOT` names the corpus and
            // `RICHOS_LORO_DIR` names the tools; with either unset the app boots with
            // `LoroTier::NotWired`, which the priming prompt states as a fact about THIS
            // INSTALL rather than as a claim about what is recorded.
            //
            // PROVENANCE. The compiler retains the ITEMS of every accepted slice here, and
            // the spine reads them when the CEO says a record is wrong — see `belief.rs`.
            // Without this the loro desk has no proposer, because `propose` takes a record
            // reference and nothing in the app could supply one honestly.
            let loro_provenance: SharedSliceProvenance =
                std::sync::Arc::new(Mutex::new(SliceProvenance::new()));
            match CliContextCompiler::from_env() {
                Ok(Some(mut compiler)) => {
                    eprintln!("[richos] loro Tier C: compiling from {}", compiler.root().path().display());
                    compiler.set_provenance_sink(std::sync::Arc::clone(&loro_provenance));
                    spine.set_loro_context_compiler(Box::new(compiler));
                    spine.set_loro_provenance(std::sync::Arc::clone(&loro_provenance));
                }
                Ok(None) => eprintln!("[richos] loro Tier C: no corpus configured — re-primes carry no company memory"),
                Err(e) => eprintln!("[richos] loro Tier C: configured but unusable, continuing without it: {e}"),
            }

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

            // Left-navigation view state — same app data dir, same durability posture as
            // the ledger and config, and never fatal: a corrupt file degrades to defaults
            // rather than refusing the launch (nav.rs).
            let nav_store = nav::NavStore::open(data_dir.join("navigation.json"));

            // THE STOP/STEER CONTROL (UX §9.2/§9.3). Its intake log sits beside the
            // ledger, same app data dir, same durability posture — and deliberately NOT
            // inside the ledger, because a request that has not been acted on yet is not
            // evidence of anything that happened.
            //
            // A control that cannot be opened degrades to `detached()`, which REFUSES to
            // stop rather than acting on a request it cannot record. An unrecorded stop is
            // indistinguishable from a crash on the next boot, and §6.1's "You stopped
            // after {duration}" would be back to attributing a crash to the CEO.
            let control = match TurnControl::open(data_dir.join("intake.jsonl")) {
                Ok(c) => c,
                Err(e) => {
                    eprintln!("[richos] steering intake unavailable, stop will refuse rather than pretend: {e}");
                    TurnControl::detached()
                }
            };
            spine.set_turn_control(control.clone());

            // Apply any stop request that outlived the process. The window is one line
            // wide — request fsync'd, process dies, terminal event never written — and
            // without this the turn is `in_flight` forever and crash-replay would re-run
            // work the CEO explicitly stopped.
            if let Err(e) = spine.reconcile_intake() {
                eprintln!("[richos] intake reconciliation at boot: {e}");
            }

            // THE CORRECTION DESK (open-items 3.5). Its log sits beside the ledger and the
            // intake log, same durability posture, and deliberately NOT in the ledger: a
            // proposal the CEO has not answered yet is not evidence of anything that
            // happened — the same rule `TurnControl`'s intake log follows.
            let correction = match CliLoroWriter::from_env() {
                Ok(Some(writer)) => match CorrectionDesk::open(data_dir.join("loro-corrections.jsonl"), Box::new(writer)) {
                    Ok(desk) => Some(desk.shared()),
                    Err(e) => {
                        // Refuse rather than pretend. A desk that cannot record a proposal
                        // durably would lose the CEO's answer across a relaunch, which is
                        // worse than saying the capability is unavailable.
                        eprintln!("[richos] loro correction desk unavailable, corrections will refuse rather than pretend: {e}");
                        None
                    }
                },
                Ok(None) => None,
                Err(e) => {
                    eprintln!("[richos] loro correction desk: configured but unusable: {e}");
                    None
                }
            };

            // THE FLYWHEEL'S AUTOMATIC TRIGGER (`spoken.rs` + `staging.rs`). Its log sits
            // beside the ledger, the intake log and the loro desk, same durability posture
            // and deliberately NOT in the ledger: a question the CEO has not answered is
            // not evidence of anything that happened.
            //
            // The desk is attached to the SPINE (so every utterance is examined as it is
            // submitted, with no command typed) and kept in `AppState` as the same `Arc`
            // (so answering it never waits on the turn lock).
            let spoken = match CandidateDesk::open(data_dir.join("spoken-corrections.jsonl")) {
                Ok(mut desk) => {
                    // The vocabulary writer. Absent on an ordinary install with no local
                    // service configured — detection and staging still work, and only the
                    // CONFIRM step reports that it has nowhere to write. It never claims a
                    // term was learned when nothing wrote it.
                    match CliVocabulary::from_env() {
                        Some(v) => desk.set_vocabulary(Box::new(v)),
                        None => eprintln!(
                            "[richos] no RICHOS_SERVICE_BIN — spoken corrections will be recorded \
                             and asked, and confirming one will report that there is no vocabulary \
                             to write to"
                        ),
                    }
                    let shared = desk.shared();
                    Some(shared)
                }
                Err(e) => {
                    // Refuse rather than pretend, exactly as the loro desk does above: a
                    // desk that cannot record durably would lose the CEO's correction
                    // across a relaunch, which is worse than saying so.
                    eprintln!(
                        "[richos] spoken-correction desk unavailable, corrections will not be \
                         recorded: {e}"
                    );
                    None
                }
            };
            // THE BELIEF TRIGGER, wired at the SAME seam as the spoken one: the desk the
            // Tauri commands answer through is the desk the turn path files into, one
            // `Arc`, so a proposal raised inside a two-hour turn is answerable during it.
            //
            // Attached only when BOTH halves exist. With a desk and no provenance nothing
            // can be resolved and the trigger would be silent anyway; saying so at boot is
            // better than a capability that looks wired and never fires.
            if let Some(desk) = &correction {
                spine.set_correction_desk(std::sync::Arc::clone(desk));
                spine.set_proposal_observer(Box::new(TauriProposalEmitter { app: app.handle().clone() }));
                if !spine.has_loro_context_compiler() {
                    eprintln!(
                        "[richos] loro correction desk is open but no context compiler is \
                         configured — nothing was ever put in front of Rich, so no correction \
                         can name a record and the trigger will stay silent"
                    );
                }
            }

            if let Some(desk) = &spoken {
                spine.set_candidate_desk(desk.clone());
                spine.set_correction_observer(Box::new(TauriCorrectionEmitter {
                    app: app.handle().clone(),
                }));

                // THE THIRD TRIGGER — heard vs sent (`heard.rs`), the one that watches
                // rather than listens, into the SAME desk. Opt-in, and this is the only
                // place that decides it.
                //
                // WHY IT IS NOT ON BY DEFAULT, when the other two are. It measured
                // precision 0.972 rather than 1.000 (156 invented pairs,
                // `docs/measurements/heard-vs-sent-trigger-2026-08-30/`), and its one false
                // positive is a pair that would rewrite an ordinary English word in every
                // future dictation. It also fires on an edit the CEO never volunteered —
                // he fixed his own text and moved on — so a wrong question here costs more
                // than after a sentence he just spoke. Until the defect is repaired in
                // `capture.js`'s shared expansion rule where it actually lives, the CEO
                // turns this on deliberately or not at all. **No default is a judgement
                // this file gets to make on his behalf.**
                match std::env::var("RICHOS_HEARD_TRIGGER").as_deref() {
                    Ok("on") | Ok("1") | Ok("true") => match DictationJournal::from_env() {
                        Some(j) if j.present() => {
                            eprintln!(
                                "[richos] heard-vs-sent trigger ON — reading the dictation \
                                 journal at {}",
                                j.describe()
                            );
                            spine.set_heard_source(Box::new(j));
                        }
                        Some(j) => eprintln!(
                            "[richos] heard-vs-sent trigger was switched on, but there is no \
                             dictation journal at {} — the trigger has no \"heard\" side and \
                             stays silent. Install the flywheel patch \
                             (tools/richos-hud/dictation-flywheel.patch) or point \
                             RICHOS_DICTATION_JOURNAL at the journal.",
                            j.describe()
                        ),
                        None => eprintln!(
                            "[richos] heard-vs-sent trigger was switched on, but no journal \
                             location could be resolved (no $HOME and no \
                             RICHOS_DICTATION_JOURNAL) — the trigger stays silent"
                        ),
                    },
                    _ => {}
                }
            }

            // THE FEEDBACK CHANNEL'S ONE FILE (`feedback.rs`), beside the ledger, the intake
            // log and the two correction desks — same durability posture, and deliberately
            // NOT in the ledger: what the CEO thinks of a session is not evidence of
            // anything that happened in it.
            //
            // ONE FILE, NOT A DIRECTORY, and that is the module's own testable property: a
            // directory invites a second file beside the first — a spool, an "unsent"
            // shard, a marker — and `feedback_no_outbound_tests.rs` asserts that recording
            // produces exactly one file and nothing else.
            let feedback = match FeedbackStore::open(data_dir.join("feedback.jsonl")) {
                Ok(store) => Some(Mutex::new(store)),
                Err(e) => {
                    eprintln!(
                        "[richos] feedback store unavailable, the feedback surface will refuse \
                         rather than take an answer it cannot keep: {e}"
                    );
                    None
                }
            };

            app.manage(AppState {
                spine: Mutex::new(spine),
                lease_ready,
                config: Mutex::new(config),
                machinery_root,
                entity: boot_entity,
                nav: Mutex::new(nav_store),
                control,
                correction,
                spoken,
                feedback,
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
            // --- loro (2026-08-29) — appended, never reordered ---
            loro_available,
            loro_show_record,
            loro_pending_corrections,
            loro_propose_correction,
            loro_confirm_correction,
            loro_decline_correction,
            loro_suppressed_records,
            loro_unsuppress_record,
            // --- voice mode (2026-08-24) — appended, never reordered ---
            start_voice_capture,
            stop_voice_capture,
            voice_speak_delta,
            voice_speak_end,
            voice_turn_started,
            voice_turn_ended,
            voice_barge_in,
            voice_diagnostics,
            // --- spoken corrections (2026-08-30) — appended, never reordered ---
            spoken_corrections_available,
            spoken_pending_corrections,
            spoken_confirm_correction,
            spoken_decline_correction,
            spoken_suppressed_terms,
            spoken_unsuppress_term,
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
            get_timeline,
            // --- Codex-UX slice 7 (2026-08-29): the read-only worker inspector ---
            set_inspector_width,
            // --- Codex-UX slice 6 (2026-08-29): steering and stop (§9.2/§9.3) ---
            stop_turn,
            steer_message,
            running_turn,
            // --- the feedback channel, local half (2026-08-30) — appended, never reordered ---
            feedback_available,
            feedback_wording,
            feedback_taxonomy,
            feedback_preview,
            feedback_record,
            feedback_history,
            // --- techy mode Phase 2 (2026-08-30) — appended, never reordered ---
            get_machinery,
            get_machinery_raw,
            techy_mode,
            set_techy_mode,
            set_techy_default,
            // --- the raw-retention window as a setting (2026-08-30) — appended, never reordered ---
            raw_retention,
            set_raw_retention,
            // --- the opening screen and its off switch (2026-08-30) — appended, never reordered ---
            splash_enabled,
            set_splash_enabled,
            splash_note_shown,
            // --- appearance and the person at the foot of the rail (§15) — appended, never reordered ---
            get_appearance,
            set_theme,
            set_font_scale,
            get_user_identity,
            set_user_name
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

/// UX §3.2 / architecture P3.2: the optional AI-worker drill-down.
///
/// **Attributed, not guessed.** The team-session directory is derived from the session id
/// of the lease this app is actually serving; when there is no lease, or that session has
/// no team directory, the answer is an honest zero carrying the reason
/// (`WorkerStatusView::unattributed`). It is never the most-recently-touched directory
/// under `~/.claude/teams`, which is what shipped and which counted whoever's session had
/// been busiest — see richos-core's worker_status.rs, "WHOSE workers these are".
///
/// The session id is read from `TurnControl`, NOT from the spine, and that is deliberate:
/// `send_message` holds the spine mutex for the entire turn, and `app/ui/main.js` polls
/// this command on TURN START. Taking the spine lock here would make the worker chip block
/// until Rich finished — the same reason the stop control lives on this handle (§9.3).
#[tauri::command]
fn get_worker_status(state: State<AppState>) -> WorkerStatusView {
    worker_status::current_status(state.control.lease_session().as_deref())
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
// Voice is a MODE of the one persistent conversation, never a room: a recognized
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

    // The submit callback: a recognized utterance takes the SAME path typed text takes.
    let submit_app = app.clone();
    let submit: Arc<dyn Fn(String) + Send + Sync> = Arc::new(move |text: String| {
        let state = submit_app.state::<AppState>();
        if !state.lease_ready {
            let _ = submit_app.emit(
                richos_voice::event::EVENT_VOICE_ERROR,
                serde_json::json!({
                    "message": LEASE_UNAVAILABLE_MESSAGE,
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
/// are synthesized and queued immediately — this is the gapless pipelining.
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
        // Distinct from `interrupted` all the way to the rail: §6.1's "You stopped after
        // {duration}" is an attribution to the CEO, and the sidebar must not describe work
        // he ended as work that broke.
        TurnState::Stopped => "stopped",
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

/// Returns the width the store ACCEPTED (clamped to nav.rs's 280-520px, whose maximum is
/// derived from §20's 620px conversation floor). UX §7.2 / §25.
#[tauri::command]
fn set_inspector_width(state: State<AppState>, width: f64) -> Result<f64, String> {
    state.nav.lock().unwrap().set_inspector_width(width).map_err(|e| e.to_string())
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

    /// §25 Accessibility and performance: *"A 10,000-entity seeded index remains searchable
    /// and bounded."*
    ///
    /// THE SECOND HALF OF THE ROW THE TIMELINE'S SCALE WORK OPENED, AND IT LIVES HERE, NOT
    /// IN THE RENDERER. The claim sits in a UX document beside "a 10,000-item thread history
    /// remains smooth", and the two are different components: the thread history is
    /// `app/ui/timeline.js` (pinned by `app/ui/tests/scale.js`), the entity index is
    /// `run_search` above. Neither had a test at either number until 2026-08-30.
    ///
    /// SEEDED, NOT ASSUMED. The shipping registry is `EntityRegistry::dogfood()` — FOUR
    /// entities, hard-coded, because it IS the current registry rather than a default. So
    /// 10,000 is a scale the product cannot reach today, and this test SEEDS it through
    /// `Spine::set_entity_registry`, which exists for exactly this. That is stated plainly
    /// rather than left for a reader to infer from a passing test.
    ///
    /// BOUNDED means the RESULT, and that is what is asserted: `hits.truncate(limit)` and
    /// `limit.clamp(1, 200)` cap what crosses the IPC boundary however many entities match.
    /// The intermediate work is NOT bounded — steps 1 and 2 push a hit per matching entity
    /// and per matching thread before the truncate — and this test measures that cost rather
    /// than claiming it away.
    #[test]
    fn a_ten_thousand_entity_index_stays_searchable_and_the_result_stays_bounded() {
        use richos_core::entity::Entity;

        let (mut spine, path) = spine_from_real_ledger("scale");
        let mut entities = Vec::with_capacity(10_000);
        for i in 0..10_000u32 {
            let root = format!("/Users/alex/ab/seeded/client-{i:05}");
            // Every one of them matches the query below, which is the worst case: the
            // truncate is the ONLY thing standing between 10,000 matches and the renderer.
            entities.push(
                Entity::new(
                    &format!("client-{i:05}"),
                    &format!("Client {i:05}"),
                    &[root.as_str()],
                )
                .unwrap(),
            );
        }
        let seeded = EntityRegistry::new(entities).expect("10,000 distinct ids");
        assert_eq!(seeded.entities().len(), 10_000);
        spine.set_entity_registry(seeded);

        let empty = nav::NavState::default();

        let started = std::time::Instant::now();
        let hits = run_search(&spine, &empty, "client", 40);
        let elapsed = started.elapsed();

        // SEARCHABLE: 10,000 matching entities and it still answers.
        assert!(!hits.is_empty(), "a 10,000-entity index must still be searchable");
        assert!(hits.iter().all(|h| h.kind == "entity"));

        // BOUNDED: the cap holds however many matched.
        assert_eq!(hits.len(), 40, "the default limit is the ceiling, not a suggestion");
        assert_eq!(run_search(&spine, &empty, "client", 1).len(), 1);
        assert_eq!(
            run_search(&spine, &empty, "client", 100_000).len(),
            200,
            "`limit.clamp(1, 200)` caps a caller that asks for everything"
        );

        // A one-entity query is still exact at this scale — the cap is not a filter.
        let one = run_search(&spine, &empty, "client-07231", 40);
        assert_eq!(one.len(), 1);
        assert_eq!(one[0].entity_label, "Client 07231");

        // The measured number, on demand: `cargo test -- --nocapture`. Captured by default,
        // so a green run stays silent and the figure is still one flag away.
        eprintln!(
            "10,000-entity index: run_search(\"client\", 40) -> {} hits in {:?} (debug build)",
            hits.len(),
            elapsed
        );

        // The number, not an adjective. This runs in debug (`cargo test` builds unoptimized),
        // so the budget is generous on purpose; it exists to catch an order-of-magnitude
        // regression such as a per-hit registry rescan, not to police milliseconds.
        assert!(
            elapsed.as_millis() < 2_000,
            "10,000-entity search took {elapsed:?} — that is not `searchable`"
        );

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

// ---------------------------------------------------------------------------------------
// STEERING AND STOP (UX §9.2, §9.3) — Codex-UX slice 6, 2026-08-29.
//
// Neither of these touches `state.spine`. That is the entire point: while a turn runs, the
// spine mutex is held for its whole length, so anything that needs it is not a mid-turn
// control. Both go through `state.control`, the `Arc` the spine shares.
// ---------------------------------------------------------------------------------------

/// What the webview is told when it asks to stop.
///
/// `reachedLease` is reported rather than smoothed over. `false` means the request is
/// durable and the turn WILL be recorded as stopped, but nothing was there to interrupt —
/// so the work may still run to its natural end. The UI says so instead of implying an
/// interrupt that did not happen (§22: status must never claim more than is known).
#[derive(serde::Serialize)]
#[serde(rename_all = "camelCase")]
struct StopReport {
    /// `false` when nothing was running. Not an error — the honest answer.
    stopped: bool,
    turn_id: Option<String>,
    /// When the stop request became durable. The UI freezes its timer from this, so the
    /// number the CEO ends up reading is anchored to the moment he pressed the button.
    requested_at: Option<u64>,
    reached_lease: bool,
}

/// §9.3: persist a stop request, then interrupt the active turn. In that order, enforced
/// in `steering.rs` rather than here.
#[tauri::command(async)]
fn stop_turn(state: State<AppState>) -> Result<StopReport, String> {
    match state.control.request_stop().map_err(|e| e.to_string())? {
        StopOutcome::NothingRunning => {
            Ok(StopReport { stopped: false, turn_id: None, requested_at: None, reached_lease: false })
        }
        StopOutcome::Requested { turn_id, requested_at, reached_lease } => Ok(StopReport {
            stopped: true,
            turn_id: Some(turn_id),
            requested_at: Some(requested_at),
            reached_lease,
        }),
    }
}

/// What the webview gets back when it steers.
#[derive(serde::Serialize)]
#[serde(rename_all = "camelCase")]
struct SteerReport {
    /// The intake-log id. Not a turn id — there is no turn yet, and inventing one here
    /// would be a claim that the message had been accepted as work.
    intake_id: u64,
    thread_id: String,
    /// The turn that was running when he typed it — the evidence behind the
    /// "Added while Rich was working" cue, rather than a guess made in the renderer.
    steering_turn_id: String,
    at: u64,
}

/// §9.2: the CEO added words while Rich was working.
///
/// Durable on return, delivered at the next turn boundary. It does NOT join the running
/// ACP turn — one `session/prompt` at a time, and the continuity design's turn-boundary
/// controller is queue-not-interrupt by construction (§3.1) — and the UI says which of
/// those two things happened rather than letting the CEO assume the other.
#[tauri::command(async)]
fn steer_message(state: State<AppState>, text: String) -> Result<SteerReport, String> {
    let trimmed = text.trim();
    if trimmed.is_empty() {
        return Err("nothing to add".into());
    }
    match state.control.steer(trimmed).map_err(|e| e.to_string())? {
        IntakeRecord::Steer { id, thread_id, steering_turn_id, at, .. } => {
            Ok(SteerReport { intake_id: id, thread_id, steering_turn_id, at })
        }
        other => Err(format!("unexpected intake record: {other:?}")),
    }
}

/// The turn that is running right now, as the CONTROL sees it.
///
/// A mirror of the spine's `turn_in_progress`, written at the same durable points, and
/// readable without the spine lock — so the composer can arm its stop control after a
/// reload without waiting for a turn to finish first. It is not inferred from event
/// silence or from a timer (continuity §5.2).
#[derive(serde::Serialize)]
#[serde(rename_all = "camelCase")]
struct RunningTurn {
    turn_id: String,
    thread_id: String,
    entity_id: Option<String>,
    started_at: Option<u64>,
}

#[tauri::command]
fn running_turn(state: State<AppState>) -> Option<RunningTurn> {
    state.control.active_turn().map(|a| RunningTurn {
        turn_id: a.turn_id,
        thread_id: a.thread_id,
        entity_id: a.entity_id.map(|e| e.as_str().to_string()),
        started_at: a.started_at,
    })
}

// ---------------------------------------------------------------------------------------
// LORO — reading what the system believes, and correcting it (open-items 3.5)
//
// This is the surface that makes the writer reachable from the APP rather than only from a
// terminal. loro-writer.md named the gap: "Rich does not call the writer yet... the
// writer's reachable surface is the CLI."
//
// EVERY command here goes through `CorrectionDesk`, which cannot write without a prior
// proposal the CEO has confirmed (ceo-decisions.md §7, ask never infer). There is no
// command that writes loro directly, and adding one would be the bug.
//
// They take their own mutex, never the spine's: `send_message` holds the spine lock for a
// whole turn, and a correction panel that froze until Rich finished would not be used.
// ---------------------------------------------------------------------------------------

/// Whether this install can read and correct company memory at all — so the UI can show a
/// real state instead of a dead button. Never a guess: it reflects the configured corpus.
#[tauri::command]
fn loro_available(state: State<AppState>) -> bool {
    state.correction.is_some()
}

fn desk<'a>(state: &'a State<AppState>) -> Result<std::sync::MutexGuard<'a, CorrectionDesk>, String> {
    state
        .correction
        .as_ref()
        .ok_or_else(|| {
            "No loro corpus is configured for this install, so there is nothing to read or correct. \
             That is a statement about this install, not about what is recorded."
                .to_string()
        })
        .map(|d| d.lock().unwrap())
}

/// "What does loro actually believe?" — the answer is a file. Read-only; no proposal, no
/// confirmation, because reading is not correcting.
#[tauri::command]
fn loro_show_record(state: State<AppState>, record_ref: String) -> Result<WriteOutput, String> {
    desk(&state)?.show(&record_ref).map_err(|e| e.to_string())
}

/// Corrections waiting on the CEO, for the entity this launch is bound to. Scoped, not
/// global: a proposal about one entity's memory has no business in another's queue.
#[tauri::command]
fn loro_pending_corrections(state: State<AppState>) -> Result<Vec<Proposal>, String> {
    let entity = state.entity.as_ref().ok_or_else(|| ENTITY_UNRESOLVED_MESSAGE.to_string())?;
    Ok(desk(&state)?.pending_for(entity.as_str()).into_iter().cloned().collect())
}

/// Stage a change and get back exactly what it WOULD write. **Nothing is written here.**
/// `why` is the CEO's own words for what is wrong, and an empty one is refused before a
/// process is started — a correction with no stated reason is the shape an inferred one
/// takes.
#[tauri::command]
fn loro_propose_correction(
    state: State<AppState>,
    thread_id: Option<String>,
    write: ProposedWrite,
    why: String,
) -> Result<Proposal, String> {
    let entity = state.entity.as_ref().ok_or_else(|| ENTITY_UNRESOLVED_MESSAGE.to_string())?;
    // The thread id is PROVENANCE and comes from the caller. It is deliberately not read
    // off the spine: `send_message` holds that lock for the whole of a turn, so asking the
    // spine which thread is active would freeze a correction panel until Rich finished —
    // the same reason the stop control lives outside the lock (UX §9.3).
    let thread_id = thread_id.unwrap_or_default();
    desk(&state)?.propose(entity.as_str(), &thread_id, write, &why).map_err(|e| e.to_string())
}

/// The CEO says yes. The ONLY path in this application to a loro write.
///
/// The write is also recorded in the conversation ledger as a CEO-FACING action, because
/// "Rich changed what the company believes" is exactly the class of fact the action-ledger
/// digest exists to stop a successor denying from absent memory (`reprime.rs`, §2.1 #6).
/// The ledger write is best-effort and never fails the correction: the desk's own log is
/// already durable, and losing a ledger line must not un-write a record that landed.
#[tauri::command]
fn loro_confirm_correction(state: State<AppState>, id: String) -> Result<Proposal, String> {
    let entity = state.entity.as_ref().ok_or_else(|| ENTITY_UNRESOLVED_MESSAGE.to_string())?;
    let done = desk(&state)?.confirm(entity.as_str(), &id).map_err(|e| e.to_string())?;
    if let Some(outcome) = &done.outcome {
        let detail = match &outcome.superseded_ref {
            Some(old) => format!("superseded {old} with {}", outcome.r#ref),
            None => format!("wrote {}", outcome.r#ref),
        };
        let _ = state
            .spine
            .lock()
            .unwrap()
            .record_ceo_action("loro_correction", &format!("{detail} — \"{}\"", done.why));
    }
    Ok(done)
}

/// He says no. `permanent` is his explicit "don't ask about this record again" — a plain
/// decline is NOT permanent, because a decline is ambiguous while a repeat is evidence
/// (ceo-decisions.md §7).
#[tauri::command]
fn loro_decline_correction(state: State<AppState>, id: String, permanent: bool) -> Result<(), String> {
    desk(&state)?.decline(&id, permanent).map_err(|e| e.to_string())
}

/// The suppression list, inspectable — §7 requires it, "or a term silently refuses to
/// learn with no way to see why".
#[tauri::command]
fn loro_suppressed_records(state: State<AppState>) -> Result<Vec<String>, String> {
    Ok(desk(&state)?.suppressed().to_vec())
}

/// ...and liftable. A list you can see and cannot clear is only half of inspectable.
#[tauri::command]
fn loro_unsuppress_record(state: State<AppState>, record_ref: String) -> Result<(), String> {
    desk(&state)?.unsuppress(&record_ref).map_err(|e| e.to_string())
}

// ---------------------------------------------------------------------------------------
// SPOKEN CORRECTIONS (2026-08-30) — the flywheel's automatic trigger, answered
// ---------------------------------------------------------------------------------------
//
// Nothing here DETECTS anything and nothing here decides anything. The trigger runs inside
// `Spine::submit_prompt` on every utterance the CEO speaks or types, and it only ever
// STAGES — ceo-decisions.md §7: "Nothing is ever learned silently." These commands are the
// other half: the surface through which he gives the answer §7 requires, and the only route
// by which a term reaches the vocabulary.
//
// Every one of them goes through `state.spoken`, which is the same `Arc` the spine holds
// and is NOT behind the spine mutex — so a question raised during a two-hour turn can be
// answered during that turn rather than after it.

/// The desk, or the sentence to show the CEO when there isn't one.
fn spoken_desk<'a>(
    state: &'a State<'a, AppState>,
) -> Result<std::sync::MutexGuard<'a, CandidateDesk>, String> {
    let desk = state.spoken.as_ref().ok_or(
        "I can't record corrections right now — my correction log could not be opened. \
         Nothing you say is being lost from the conversation itself.",
    )?;
    desk.lock().map_err(|_| "the correction desk is busy — try that again".to_string())
}

/// Is the trigger live at all? A UI that cannot tell "nothing to ask" from "the desk is
/// broken" would render a permanently empty HUD and call it calm.
#[tauri::command]
fn spoken_corrections_available(state: State<AppState>) -> bool {
    state.spoken.is_some()
}

/// Everything awaiting §7's one-keystroke answer. Each carries the CEO's own sentence, the
/// pair, the prompt to show, and — when the wrong form was found on the record — the line
/// it appeared on, so the ask can quote him rather than assert at him.
#[tauri::command]
fn spoken_pending_corrections(state: State<AppState>) -> Result<Vec<Candidate>, String> {
    Ok(spoken_desk(&state)?.pending().to_vec())
}

/// **He says yes.** The ONLY path from a staged correction to the vocabulary.
///
/// A confirm with no local service configured returns the writer's honest refusal rather
/// than a cheerful nothing — reporting "learned" when nothing wrote is the one outcome that
/// would make him stop correcting the term.
///
/// The ledger write is best-effort and never fails the answer, the same posture
/// `loro_confirm_correction` takes: what the CEO decided is already durable on the desk's
/// own log, and the action-ledger row is a record OF that decision, not the decision.
#[tauri::command]
fn spoken_confirm_correction(state: State<AppState>, key: String) -> Result<LearnOutcome, String> {
    let (outcome, canonical, mangled) = {
        let mut desk = spoken_desk(&state)?;
        let pair = desk
            .pending()
            .iter()
            .find(|c| c.key == key)
            .map(|c| (c.ask.to.clone(), c.ask.from.clone()))
            .ok_or_else(|| format!("no correction {key} is awaiting an answer"))?;
        let outcome = desk.confirm(&key).map_err(|e| e.to_string())?;
        (outcome, pair.0, pair.1)
    };
    let _ = state.spine.lock().unwrap().record_ceo_action(
        "vocabulary_learn",
        &format!("learned \"{canonical}\" (heard as \"{mangled}\")"),
    );
    Ok(outcome)
}

/// He says no. `permanent` is his explicit "don't ask for this term again". A plain decline
/// is NOT permanent and the pair is asked again on its very next repeat — §7: repetition is
/// the evidence, and waiting dilutes it.
#[tauri::command]
fn spoken_decline_correction(
    state: State<AppState>,
    key: String,
    permanent: bool,
) -> Result<(), String> {
    spoken_desk(&state)?.decline(&key, permanent).map_err(|e| e.to_string())
}

/// The suppression list, inspectable — §7 requires it, "or a term silently refuses to learn
/// with no way to see why".
#[tauri::command]
fn spoken_suppressed_terms(state: State<AppState>) -> Result<Vec<String>, String> {
    Ok(spoken_desk(&state)?.suppressed().to_vec())
}

/// ...and liftable. A list you can see and cannot clear is only half of inspectable.
#[tauri::command]
fn spoken_unsuppress_term(state: State<AppState>, key: String) -> Result<(), String> {
    spoken_desk(&state)?.unsuppress(&key).map_err(|e| e.to_string())
}

// ---------------------------------------------------------------------------------------
// THE FEEDBACK CHANNEL — the local half, made reachable (RICH-TODOs row 5)
// ---------------------------------------------------------------------------------------
//
// `feedback.rs` landed complete on 2026-08-30: the CEO's wording in constants, the four
// keys, the versioned taxonomy, the local store, the disclosure, and four tests in
// `tests/feedback_no_outbound_tests.rs` asserting there is no way off this machine. And
// `grep -n feedback src-tauri/src/main.rs` returned nothing, which is row 5b's defect in a
// second costume: a capability the CEO can only reach by writing Rust is not a property of
// the product he uses.
//
// **NOTHING HERE SENDS ANYTHING, AND NOTHING HERE MAY.** These six commands are a window
// onto one local file. There is no transport, no endpoint, no address, no background job
// and no queue — and `feedback_no_outbound_tests.rs` now reads THESE FUNCTIONS' bodies as
// well as the module's, so a later "just wire it up" commit fails a test rather than a
// review.
//
// THIS LAYER AUTHORS NO WORDING. Every sentence the CEO reads on this surface is a
// constant or a term from `feedback.rs` — `PROMPT_QUESTION`, `PROMPT_OPTIONS`,
// `REPORT_OFFER`, `DISCLOSURE_HEADING`, and the `label()`/`sentence()` of every term. The
// module puts them in one place precisely so a UI cannot paraphrase them, so this file
// projects them and adds none of its own. The one exception is the sentence below, which
// is about THIS INSTALL and has nowhere else to live.
//
// They take their own mutex, never the spine's — a question about a session is asked while
// the session is still running.

/// What the CEO is told when the one file cannot be opened.
///
/// The register the other two desks use: it says what it will not do, it names who owns the
/// fix, and it invents no control, because there genuinely is none in the app. Asking him
/// what he thinks and then dropping the answer would be worse than not asking.
const FEEDBACK_STORE_UNAVAILABLE: &str =
    "I can't keep an answer right now — the file I record them in wouldn't open, and I'm \
     not going to ask you what you think and then lose it. That one is for whoever set \
     RichOS up to look at; it isn't yours to fix.";

/// What he is told if a key that is not one of the four ever reaches the store.
///
/// `PromptOutcome::from_key` returns `None` for anything else, and this is that `None` said
/// out loud: an unrecognized key is not a dismissal, it is not an answer at all, and
/// recording it as one would put invented data in the store.
const FEEDBACK_KEY_NOT_ONE_OF_FOUR: &str =
    "That isn't one of the four answers, so I haven't written anything down.";

/// What he is told if the text he approved is not the text this build would report.
///
/// The CEO's own rule — *he sees exactly what his RichOS would say, before any of it could
/// ever travel* — is a STRUCTURAL property in `feedback.rs` (`ApprovedReport` has no public
/// constructor; the only way to one is `Disclosure::approve`, and a `Disclosure` cannot
/// exist without having rendered its text). That property is enforced inside one process.
/// This command sits on the other side of an IPC boundary, so it re-renders and compares:
/// an approval whose text does not match what this build would say is refused rather than
/// recorded, and the mismatch is the one case where consent could be recorded for something
/// he was never shown.
const FEEDBACK_PREVIEW_MISMATCH: &str =
    "I won't record that. What you were shown isn't what I would say now, so approving it \
     would be approving something you haven't read. Ask me to show it again.";

/// The store, or the sentence to show the CEO when there isn't one.
fn feedback_store<'a>(
    state: &'a State<AppState>,
) -> Result<std::sync::MutexGuard<'a, FeedbackStore>, String> {
    let store = state.feedback.as_ref().ok_or(FEEDBACK_STORE_UNAVAILABLE)?;
    store.lock().map_err(|_| FEEDBACK_STORE_UNAVAILABLE.to_string())
}

/// Can an answer be kept at all? A surface that cannot tell "nothing recorded yet" from
/// "the file would not open" would render an empty history over a broken store and call it
/// calm — the same distinction both correction desks draw.
#[tauri::command]
fn feedback_available(state: State<AppState>) -> bool {
    state.feedback.is_some()
}

/// THE PROMPT, THE KEYS AND THE OFFER, verbatim from `feedback.rs`.
///
/// Projected rather than re-typed: the module holds the CEO's wording in constants
/// specifically so the UI cannot paraphrase it, and `invitesReport` comes from
/// `Rating::invites_report` so the "only 1 and 2" rule is not re-derived on the other side
/// of the bridge.
#[tauri::command]
fn feedback_wording() -> serde_json::Value {
    // Every rating there is. Not a list this file keeps: `Rating` has exactly three
    // variants and `0` is deliberately not one of them, so a fourth would be a compile
    // error here rather than a silently missing button.
    let ratings: Vec<serde_json::Value> = [Rating::Bad, Rating::OkButCouldBeBetter, Rating::Good]
        .iter()
        .map(|r| {
            serde_json::json!({
                "key": r.key().to_string(),
                "label": r.label(),
                // The value serde ACTUALLY writes for this rating, so a surface reading an
                // entry back off disk can match it without transforming the label into a
                // wire name and hoping the two agree.
                "wire": serde_json::to_value(r).unwrap_or(serde_json::Value::Null),
                "invitesReport": r.invites_report(),
            })
        })
        .collect();
    serde_json::json!({
        "question": PROMPT_QUESTION,
        "options": PROMPT_OPTIONS,
        "reportOffer": REPORT_OFFER,
        "disclosureHeading": DISCLOSURE_HEADING,
        "taxonomyVersion": TAXONOMY_VERSION.wire(),
        "ratings": ratings,
        // `0` is deliberately not a `Rating` — dismissing is the absence of a rating, not a
        // fourth value of one — so it is carried separately and its label is read out of
        // the options line the module wrote, never typed here.
        "dismiss": { "key": "0", "label": "Dismiss" },
    })
}

/// THE WHOLE VOCABULARY a report can be assembled from, iterated from each term's own
/// `ALL`. Nothing here is a list this file maintains: adding a term in `feedback.rs` puts
/// it on screen, and removing one takes it off.
#[tauri::command]
fn feedback_taxonomy() -> serde_json::Value {
    let failure_class: Vec<serde_json::Value> = FailureClass::ALL
        .iter()
        .map(|t| serde_json::json!({ "wire": t.wire(), "label": t.label() }))
        .collect();
    let occurrences: Vec<serde_json::Value> = Occurrences::ALL
        .iter()
        .map(|t| serde_json::json!({ "wire": t.wire(), "label": t.label() }))
        .collect();
    let diagnosis: Vec<serde_json::Value> = DiagnosisTerm::ALL
        .iter()
        .map(|t| serde_json::json!({ "wire": t.wire(), "sentence": t.sentence() }))
        .collect();
    let conditions: Vec<serde_json::Value> = ContributingCondition::ALL
        .iter()
        .map(|t| serde_json::json!({ "wire": t.wire(), "sentence": t.sentence() }))
        .collect();
    serde_json::json!({
        "version": TAXONOMY_VERSION.wire(),
        "failureClass": failure_class,
        "occurrences": occurrences,
        "diagnosis": diagnosis,
        "conditions": conditions,
    })
}

/// What the CEO chose, in the payload's OWN field names.
///
/// `deny_unknown_fields` for the reason `FeedbackPayload` carries it: prose arrives beside a
/// payload as often as inside it, and serde's default is to ignore what it does not know.
/// A `notes` field posted from the webview would otherwise be silently dropped here and
/// then, one careless commit later, silently kept.
#[derive(serde::Deserialize)]
#[serde(deny_unknown_fields)]
struct Selection {
    failure_class: FailureClass,
    occurrences_this_session: Occurrences,
    generic_diagnosis: Vec<DiagnosisTerm>,
    #[serde(default)]
    contributing_condition: Vec<ContributingCondition>,
}

/// What he answered when offered the chance to report.
///
/// There is no `Pending` and no `Later`, mirroring `ReportDecision`: an answer is an answer,
/// and a half-state here is the seam a future outbox would grow from.
#[derive(serde::Deserialize)]
#[serde(tag = "decision", rename_all = "snake_case", deny_unknown_fields)]
enum ReportChoice {
    /// `3`, or a dismissal — the offer was never made.
    NotOffered,
    /// The offer was made and he said no. The payload is dropped and nothing about it is
    /// recorded, because a declined report is not a report.
    Declined,
    /// He read the rendered report and said yes. `shown` is the exact block he read, and it
    /// is checked against what this build renders before any consent is recorded.
    Approved { selection: Selection, shown: String },
}

/// Assemble a disclosure from a rating and a selection. The ONLY route to a payload in this
/// file, so the preview command and the record command cannot render two different things.
fn disclosure_for(rating: Rating, sel: &Selection) -> Result<Disclosure, String> {
    let payload = FeedbackPayload::assemble(
        rating,
        sel.failure_class,
        sel.occurrences_this_session,
        sel.generic_diagnosis.clone(),
        sel.contributing_condition.clone(),
    )
    .map_err(|e| e.to_string())?;
    Ok(Disclosure::of(payload))
}

fn rating_from_key(key: &str) -> Result<Rating, String> {
    let outcome = outcome_from_key(key)?;
    outcome.rating().ok_or_else(|| FEEDBACK_KEY_NOT_ONE_OF_FOUR.to_string())
}

fn outcome_from_key(key: &str) -> Result<PromptOutcome, String> {
    let mut chars = key.chars();
    let (first, rest) = (chars.next(), chars.next());
    match (first, rest) {
        (Some(c), None) => {
            PromptOutcome::from_key(c).ok_or_else(|| FEEDBACK_KEY_NOT_ONE_OF_FOUR.to_string())
        }
        _ => Err(FEEDBACK_KEY_NOT_ONE_OF_FOUR.to_string()),
    }
}

/// **THE PREVIEW.** Exactly what would be said, rendered from the same structure that gets
/// recorded — never a description of it.
///
/// Nothing is stored by this command and nothing is consented to by calling it. It exists
/// so the CEO reads the report BEFORE he is asked to approve it, which is the half of his
/// design that the type system cannot carry across an IPC boundary on its own.
#[tauri::command]
fn feedback_preview(key: String, selection: Selection) -> Result<serde_json::Value, String> {
    let rating = rating_from_key(&key)?;
    let disclosure = disclosure_for(rating, &selection)?;
    Ok(serde_json::json!({
        // The heading and the report separately, so a surface can lay them out, AND the two
        // together in one block — which is the string an approval is checked against, so
        // there is no arrangement of the parts the UI could get wrong.
        "heading": DISCLOSURE_HEADING,
        "text": disclosure.text(),
        "full": disclosure.full_text(),
    }))
}

/// **THE ANSWER, KEPT LOCALLY.** One line appended to one file, and that is the entire
/// effect of this command.
///
/// The report half re-renders from the selection and compares against the block the CEO was
/// shown. `Disclosure::approve` is then the only route to the `ApprovedReport` that goes in,
/// and `FeedbackEntry::with_report` refuses a report attached to a rating that never invited
/// one, or one that disagrees with the rating he gave. Every one of those rules lives in
/// `feedback.rs`; none of them is re-implemented here.
#[tauri::command]
fn feedback_record(
    state: State<AppState>,
    key: String,
    report: ReportChoice,
) -> Result<FeedbackEntry, String> {
    let outcome = outcome_from_key(&key)?;
    let decision = match &report {
        ReportChoice::NotOffered => ReportDecision::NotOffered,
        ReportChoice::Declined => ReportDecision::Declined,
        ReportChoice::Approved { selection, shown } => {
            let rating = outcome.rating().ok_or_else(|| FEEDBACK_KEY_NOT_ONE_OF_FOUR.to_string())?;
            let disclosure = disclosure_for(rating, selection)?;
            if disclosure.full_text() != *shown {
                return Err(FEEDBACK_PREVIEW_MISMATCH.to_string());
            }
            disclosure.approve()
        }
    };
    let entry = FeedbackEntry::new(outcome).with_report(decision).map_err(|e| e.to_string())?;
    let store = feedback_store(&state)?;
    store.record(&entry).map_err(|e| e.to_string())?;
    Ok(entry)
}

/// What is on this machine, oldest first.
///
/// Each approved entry carries `shown` — the text he read when he approved it, re-rendered
/// from the stored payload. `render_disclosure` is deterministic and total, so no second
/// free-text copy of what he saw has to be kept in the record; keeping one would have put an
/// unvalidated `String` into the durable file, which is the exact channel this design closes.
#[tauri::command]
fn feedback_history(state: State<AppState>) -> Result<Vec<serde_json::Value>, String> {
    let entries = feedback_store(&state)?.entries().map_err(|e| e.to_string())?;
    Ok(entries
        .into_iter()
        .map(|e| {
            let shown = match &e.report {
                ReportDecision::Approved(a) => Some(a.as_shown()),
                _ => None,
            };
            serde_json::json!({ "entry": e, "shown": shown })
        })
        .collect())
}

// ---------------------------------------------------------------------------------------
// TECHY MODE, Phase 2 (techy-mode design §3.1/§3.4) — the renderer's five commands.
//
// Appended at the END for the reason the block above says: a parallel branch appending its
// own glue merges without touching a line this one also touched.
//
// PHASE 1 ROUTED AND RETAINED AND HAD NO CALLER. `Spine::machinery_journal()` and
// `rich://machinery` shipped 2026-08-28 complete and tested, and `grep -rn machinery
// app/ui/` returned three comments. These five commands are the door.
//
// WHAT IS DELIBERATELY NOT HERE: any control. No interrupt, no approve/deny, no re-run.
// Techy mode is a window, not a cockpit (§5, §9) — R2 business-action governance is
// deferred to V2 by CEO decision for v1 and all 1.x, and a button here is how that gets
// un-deferred by accident.
// ---------------------------------------------------------------------------------------

/// One thread's machinery, for the technical view (§3.4).
///
/// See `machinery_view.rs` for why this is a second command rather than a `mode` argument
/// on `get_timeline` — the calm command stays byte-for-byte what it was, and its gate stays
/// structural rather than becoming a branch.
///
/// **The toggle is NOT read here.** §3.2's rule is that routing and retention run always
/// and the toggle controls RENDERING only; making the read conditional on the flag would
/// put policy in two places, and the second one would eventually disagree. The renderer
/// decides whether to ask.
#[tauri::command]
fn get_machinery(state: State<AppState>, thread_id: String) -> Result<serde_json::Value, String> {
    let mut spine = state.spine.lock().unwrap();
    // PUMP, THEN READ (techy-mode §1.5). Between-turn traffic is parked by the ACP reader
    // thread and lands in the journal only when the spine drains it. The turn boundaries do
    // that, but opening the technical view is the other moment somebody actually wants to
    // SEE it — and without this line the newest between-turn records would appear one turn
    // late, which reads as the feature being broken rather than as a drain schedule.
    //
    // It takes the same lock the read takes, so nothing new can interleave, and it is a
    // no-op costing one mutex and one `Vec::is_empty` when the lane is quiet.
    spine.pump_between_turn();
    machinery_payload(&spine, &thread_id)
}

/// §2.4's raw pane, one record at a time.
///
/// Three answers, and the middle one is the point: `retained` with the payload,
/// `not_retained` when the Tier-B window has passed over it (**the record still renders —
/// structure, title, status, paths, summary — and the pane says so; an honest degrade,
/// never a silent blank**), and `unreadable` when the store refused.
///
/// `truncated: true` means §2.4's 32 KB per-record cap fired and the payload is a
/// char-boundary-safe prefix as a JSON *string* rather than the object — a visibly
/// different shape, so nothing can mistake it for the whole thing.
///
/// **§7.2 is not answered here.** How long raw payloads survive is the CEO's open question;
/// nothing in this path consults the window. Whatever he chooses — 14 days, 2 GB, or
/// forever — this returns what is on disk and the two states stay the same two states.
#[tauri::command]
fn get_machinery_raw(
    state: State<AppState>,
    thread_id: String,
    machinery_id: String,
) -> Result<serde_json::Value, String> {
    let spine = state.spine.lock().unwrap();
    let Some(journal) = spine.machinery_journal() else {
        return Ok(not_retained());
    };
    match journal.raw_payload(&thread_id, &machinery_id) {
        Ok(Some((payload, truncated))) => Ok(serde_json::json!({
            "state": "retained",
            "payload": payload,
            "truncated": truncated,
            "note": truncated.then_some(RAW_TRUNCATED),
        })),
        Ok(None) => Ok(not_retained()),
        Err(why) => Ok(serde_json::json!({
            "state": "unreadable", "payload": null, "truncated": false,
            "note": RAW_UNREADABLE, "reason": why,
        })),
    }
}

/// The sentence for §2.4's evicted-raw state. **The record still renders** — structure,
/// title, status, paths, summary — and this says why the bytes are gone rather than showing
/// a blank. An honest degrade.
///
/// It states the fact and NOT a duration, because the duration is §7.2 and §7.2 is the
/// CEO's open question. A sentence naming "14 days" would answer it in copy.
const RAW_NOT_RETAINED: &str =
    "The full output isn't kept this long — what's above is the whole record that was.";

/// §2.4's 32 KB per-record cap fired. Named so nobody reads a prefix as the whole thing.
const RAW_TRUNCATED: &str = "This output was longer than RichOS keeps; you're seeing the start of it.";

const RAW_UNREADABLE: &str =
    "I can't read the stored output for this one. It's on this machine and I haven't lost it \
     — whoever set RichOS up needs to look.";

fn not_retained() -> serde_json::Value {
    serde_json::json!({
        "state": "not_retained", "payload": null, "truncated": false, "note": RAW_NOT_RETAINED,
    })
}

/// This thread's resolved techy-mode state, with its provenance (§3.1).
///
/// `source` is `"thread"` when the CEO pinned this conversation and `"default"` when it
/// follows the global switch — so the surface can say *"follows your default"* instead of
/// implying a choice he did not make, and so clearing a pin is a visible, reversible act.
#[tauri::command]
fn techy_mode(state: State<AppState>, thread_id: String) -> TechyMode {
    state.config.lock().unwrap().techy_mode(&thread_id)
}

/// Pin or unpin ONE thread (§3.1). `enabled: null` clears the override and hands the
/// thread back to the global default.
///
/// **The `null` arm is what keeps §7.1 open** (global default vs per-thread only — the
/// CEO's, unanswered). Without it a pin is one-way, "all of their conversations" stops
/// reaching any thread he ever touched, and the product has answered his question for him.
#[tauri::command]
fn set_techy_mode(
    state: State<AppState>,
    thread_id: String,
    enabled: Option<bool>,
) -> Result<TechyMode, String> {
    let mut config = state.config.lock().unwrap();
    match enabled {
        Some(on) => config.set_techy_thread(&thread_id, on).map_err(|e| e.to_string())?,
        None => config.clear_techy_thread(&thread_id).map_err(|e| e.to_string())?,
    }
    Ok(config.techy_mode(&thread_id))
}

/// The one switch for "all of their conversations" (§3.1, the CEO's own words).
///
/// Threads he pinned individually are untouched — that is what makes a pin mean something,
/// and it is the half of §7.1 a global-only build would lose.
#[tauri::command]
fn set_techy_default(state: State<AppState>, enabled: bool) -> Result<bool, String> {
    let mut config = state.config.lock().unwrap();
    config.set_techy_default(enabled).map_err(|e| e.to_string())?;
    Ok(config.techy_default())
}

// ---------------------------------------------------------------------------------------
// THE RAW-RETENTION WINDOW AS A SETTING (design §7.2 — open-items 1.4).
//
// §7.2 IS THE CEO'S QUESTION AND IS NOT ANSWERED HERE. These two commands answer a
// different one: what does each of HIS possible answers cost? Until they existed, "14 days"
// was two `const`s and "forever" was a developer, and a question whose status quo is the
// only free answer is not really open. Now all three cost a click.
//
// EVICTION IS AN `unlink` AND NOTHING ANNOUNCES IT, which is the whole reason `set_` below
// applies the new window IMMEDIATELY and returns what it removed. Boot-only eviction would
// make a tightened window look like it did nothing, and then delete at some later launch he
// would never connect to the click. Immediate + counted turns a silent delayed delete into a
// visible present one. Tier A is untouched at every setting, so what is being counted is
// stored OUTPUT, never a record.
// ---------------------------------------------------------------------------------------

/// The window, as the surface needs to show it: the menu entry it is (or `custom`), both
/// axes verbatim, and what the store currently costs on disk.
///
/// `retained_bytes` is not decoration. "Keep everything" is only a real choice if the person
/// making it can see what it costs, and `raw_bytes()` answers that off directory metadata
/// without parsing a byte of anyone's terminal output.
#[derive(serde::Serialize)]
#[serde(rename_all = "camelCase")]
struct RetentionView {
    /// `two-weeks` | `three-months` | `forever` | `custom`.
    choice: &'static str,
    /// Days, or the string `"forever"`.
    age_days: richos_core::journal::RetentionLimit,
    /// Bytes, or the string `"forever"`.
    total_bytes: richos_core::journal::RetentionLimit,
    /// Raw payload bytes currently on disk, install-wide.
    retained_bytes: u64,
    /// Raw day-shards removed by the call that produced this view. Always 0 for a read.
    evicted: usize,
}

impl RetentionView {
    fn of(retention: RawRetention, choice: RetentionChoice, retained_bytes: u64, evicted: usize) -> Self {
        RetentionView {
            choice: choice.as_str(),
            age_days: retention.age_days,
            total_bytes: retention.total_bytes,
            retained_bytes,
            evicted,
        }
    }
}

/// What the window is set to right now, and what it currently costs.
#[tauri::command]
fn raw_retention(state: State<AppState>) -> RetentionView {
    let config = state.config.lock().unwrap();
    let bytes = MachineryJournal::new(&state.machinery_root).raw_bytes();
    RetentionView::of(config.raw_retention(), config.retention_choice(), bytes, 0)
}

/// Set the window from one of the three named choices, and apply it now.
///
/// An unrecognized choice — including `custom`, which is a description of the file and never
/// an instruction — is REFUSED rather than rounded to something plausible. Nothing is
/// written and nothing is evicted: the failure mode of a bad argument to a command that
/// deletes has to be "did nothing".
#[tauri::command]
fn set_raw_retention(state: State<AppState>, choice: String) -> Result<RetentionView, String> {
    let Some(choice) = RetentionChoice::parse(&choice) else {
        return Err(format!("unknown retention choice: {choice}"));
    };
    let mut config = state.config.lock().unwrap();
    config.set_retention_choice(choice).map_err(|e| e.to_string())?;
    let retention = config.raw_retention();
    // Applied at the moment of the click, not at the next boot — see the block comment.
    let journal = MachineryJournal::new(&state.machinery_root);
    let evicted = journal.evict_raw_within(richos_core::util::now_millis(), retention);
    Ok(RetentionView::of(retention, config.retention_choice(), journal.raw_bytes(), evicted))
}

// ---------------------------------------------------------------------------------------
// The opening screen's off switch (2026-08-30).
//
// `docs/design/richos-splash-micro-game-2026-08-30.md` §2 (richos-hq) verified that neither
// the splash NOR a way to turn it off existed at richos `1807319`. This branch adds both, in
// the same commit, deliberately: the surface's failure mode is silent — nobody writes in to
// say a splash screen was beneath them, they switch it off — so the switch is the only
// honest instrument we will ever have for knowing whether it is wanted (§7). A splash
// without one cannot be measured.
//
// THE SURFACE ITSELF IS ENTIRELY IN THE WEBVIEW (`app/ui/splash.js`, `splash-library.js`,
// `splash.css`), and nothing here is on the launch path. `setup()` is untouched by this
// slice: the store these three commands read was already opened there for the company name
// and the assertiveness dial, so the shell does not do one byte of extra work at boot on
// account of the splash. The commands below are called AFTER the app is up.
// ---------------------------------------------------------------------------------------

/// Whether the opening screen shows at launch. Default on (`config.rs`).
#[tauri::command]
fn splash_enabled(state: State<AppState>) -> bool {
    state.config.lock().unwrap().splash_enabled()
}

/// The switch. `config.rs` stamps `splash_disabled_at` on the way off and clears it on the
/// way back on, and ignores a write of the value already stored — so the UI syncing this
/// preference on every launch can never walk the timestamp forward.
#[tauri::command]
fn set_splash_enabled(state: State<AppState>, enabled: bool) -> Result<(), String> {
    state
        .config
        .lock()
        .unwrap()
        .set_splash_enabled(enabled, richos_core::util::now_millis())
        .map_err(|e| e.to_string())
}

/// The surface reporting that it has been shown. Idempotent and cheap: only the FIRST call
/// in this store's life touches the disk, so the UI calls it unconditionally rather than
/// having to know whether it is the first launch.
///
/// It is the zero point of §7's time-to-disable, and it is MEASUREMENT, never display —
/// §5 bans every counter and score from the CEO's screen and nothing reads this back to him.
#[tauri::command]
fn splash_note_shown(state: State<AppState>) -> Result<(), String> {
    state
        .config
        .lock()
        .unwrap()
        .note_splash_shown(richos_core::util::now_millis())
        .map(|_wrote| ())
        .map_err(|e| e.to_string())
}

// ---------------------------------------------------------------------------------------
// APPEARANCE, AND THE PERSON AT THE FOOT OF THE RAIL (CEO ruling §15, 2026-08-30)
// ---------------------------------------------------------------------------------------
//
// Five commands, and NONE of them is on the launch path. The webview applies the CEO's
// theme and type size from a synchronous mirror in `theme-boot.js` before its first paint —
// an async round trip through this shell cannot decide frame one, and booting on the default
// then correcting is a full-screen flash of the wrong palette on every launch. These
// commands are what makes the preference DURABLE and what reconciles the mirror against the
// truth once the app is up. The store they read was already opened in `setup()` for the
// company name and the assertiveness dial, so this costs the boot nothing.
//
// WHO WINS A DISAGREEMENT: this side. `RichTheme.sync` in the webview takes what
// `get_appearance` returns and corrects the mirror, never the other way round. The mirror is
// a cache of a decision, not a second place the decision is made.
//
// ON ⌘/CTRL +/−/0 BEING THE APP'S: `zoomHotkeysEnabled` is now set to `false` EXPLICITLY in
// tauri.conf.json rather than left to its default. That flag is precisely the seam — with it
// on, Tauri injects a polyfill on macOS/Linux that zooms the webview 20% a step, and sets
// WebView2's `IsZoomControlEnabled` on Windows. Webview zoom would scale the whole document
// including fixed chrome, would not persist, and would be invisible to the Text size row:
// two controls, two states, one of them a lie. The app's own handler (`settings-button.js`)
// takes the keystroke with `preventDefault` and moves the single persisted number below.

/// The two appearance preferences, in one call — the UI wants both at init and neither is
/// useful without the other.
#[derive(serde::Serialize)]
struct Appearance {
    /// "dark" | "light" | "system". The CHOICE, not the resolved palette: resolving
    /// "system" needs the OS preference, which is observable in the webview and not here.
    theme: String,
    /// A percentage of the 16px root, always one of `FONT_SCALE_STEPS`.
    font_scale: u16,
}

#[tauri::command]
fn get_appearance(state: State<AppState>) -> Appearance {
    let config = state.config.lock().unwrap();
    Appearance { theme: config.theme().as_str().to_string(), font_scale: config.font_scale() }
}

/// Persist the CEO's lighting. An unparseable string is REFUSED rather than coerced to the
/// default: silently writing "dark" because the UI sent something unexpected would look
/// exactly like the CEO changing his mind, on his own machine, for no reason he can see.
#[tauri::command]
fn set_theme(state: State<AppState>, theme: String) -> Result<(), String> {
    let parsed = richos_core::config::Theme::parse(&theme)
        .ok_or_else(|| format!("unknown theme {theme:?} — expected \"dark\", \"light\" or \"system\""))?;
    state.config.lock().unwrap().set_theme(parsed).map_err(|e| e.to_string())
}

/// Persist the type size. Off-ladder values are snapped by `config.rs` rather than refused,
/// for the reason stated there: rejecting would put a hand-edited file silently back to 100%.
#[tauri::command]
fn set_font_scale(state: State<AppState>, scale: u16) -> Result<(), String> {
    state.config.lock().unwrap().set_font_scale(scale).map_err(|e| e.to_string())
}

/// The person, and his initials, or honest nulls.
///
/// BOTH FIELDS ARE NULLABLE AND THAT IS THE POINT. The CEO's correction to round 10.1 is
/// that the foot of HIS rail carries HIS identity, not Rich's — and there was no user-name
/// preference in this product until today, so "unset" is the overwhelmingly common state and
/// has to be a real answer rather than an edge case. It is NOT `get_company_name`'s shape:
/// that one has a fallback because a company with no name can honestly be called
/// "My Company", and a person with no name cannot be called anything without inventing them.
#[derive(serde::Serialize)]
struct UserIdentity {
    name: Option<String>,
    initials: Option<String>,
}

#[tauri::command]
fn get_user_identity(state: State<AppState>) -> UserIdentity {
    let config = state.config.lock().unwrap();
    UserIdentity {
        name: config.user_name().map(|s| s.to_string()),
        initials: config.user_initials(),
    }
}

/// Set (or, with a blank string, clear) the CEO's name. Clearing returns the rail footer to
/// its honest unset state rather than storing an empty string that would render as a circle
/// with nothing in it.
#[tauri::command]
fn set_user_name(state: State<AppState>, name: String) -> Result<(), String> {
    state.config.lock().unwrap().set_user_name(&name).map_err(|e| e.to_string())
}
