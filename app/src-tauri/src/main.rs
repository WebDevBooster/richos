// RichOS desktop shell (Tauri). A THIN surface over the richos-core spine.
//
// Doctrine: clean output (only Rich's assistant text renders), one conversation with
// Rich, optional multi-thread topic organization. All runtime intelligence — the native
// client, the crash-safe ledger, threads, re-prime continuity — lives in richos-core;
// this file is just the window + the Tauri command bridge to the web UI in ../ui.
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

mod events;

use richos_core::native::{resolve_claude_bin, NativeCognition};
use richos_core::cognition::{Cognition, CognitionError, LeaseFactory};
use richos_core::config::{Assertiveness, ConfigStore, RetentionChoice, TechyMode};
use richos_core::launch::{LaunchCounts, LaunchKind, LaunchStore, PriorRun};
use richos_core::correction::{
    CliLoroWriter, CorrectionDesk, Proposal, ProposalObserver, ProposedWrite,
    SharedCorrectionDesk, WriteOutput, EVENT_LORO_PROPOSED,
};
use richos_core::entity::{EntityId, EntityRegistry};
use richos_core::feedback::{
    ContributingCondition, DiagnosisTerm, Disclosure, FailureClass, FeedbackEntry, FeedbackPayload,
    FeedbackStore, Occurrences, PromptOutcome, Rating, ReportDecision, DISCLOSURE_HEADING,
    PROMPT_OPTIONS, PROMPT_QUESTION, REPORT_OFFER, TAXONOMY_VERSION,
};
use richos_core::journal::{MachineryJournal, RawRetention};
use richos_core::ledger::{AttentionTier, Ledger, Message, Source};
use richos_core::loro::{SharedSliceProvenance, SliceProvenance};
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
use std::path::{Path, PathBuf};
use std::sync::Mutex;
use tauri::{AppHandle, Emitter, Manager, State};

/// WHERE THE ENGINE DIRECTORY IS. Its own file because the answer is an ORDER of seven
/// candidates that has to be readable and testable — the one-expression default it replaced
/// was a `cargo run` assumption that resolved to a nonexistent path under a Finder launch,
/// and nothing tested it because there was nothing to test.
mod engine;

/// Durable left-navigation view state (pin, rename, archive, rail width). See nav.rs
/// for why these are shell state and not ledger events.
mod nav;

/// Check, download, VERIFY, install, relaunch — the update path. Its own file because it
/// is the one surface where a mistake ships code to the CEO's machine, and because the
/// signature-failure classification in it is unit-tested without a webview.
mod updates;

/// The `get_timeline` command body, in its own file so `examples/timeline_payload.rs`
/// can include the SAME source and print the exact JSON the webview receives.
mod timeline_view;
use timeline_view::timeline_payload;

/// The `get_machinery` command body — techy mode's read path. Its own file for the same
/// reason `timeline_view` is: an example includes the SAME source and prints the exact
/// JSON the webview receives.
mod machinery_view;
use machinery_view::machinery_payload;

/// COMPANY MEMORY: where it is, whether it is readable, and — new on 2026-09-01 — how a
/// machine that has none gets one. Its own file because `wire_company_memory` runs twice:
/// once at boot, and once more the moment the CEO answers the first-run question.
mod memory;
use memory::MemoryStatus;

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
/// agent's frame set is the vendor's and open, so a new kind must not need a new event).
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

/// The rotation/recovery seam (richos_core::LeaseFactory): spawns a fresh, un-primed
/// lease exactly like the boot path (`NativeCognition::start`), so the spine can rotate at
/// a context watermark or recover from a mid-turn crash without knowing anything about the
/// wire — richos-core stays IO-agnostic (continuity §3.3 step 4).
struct EngineLeaseFactory {
    claude_bin: PathBuf,
    engine_dir: PathBuf,
}

impl LeaseFactory for EngineLeaseFactory {
    fn spawn(&self) -> Result<Box<dyn Cognition>, CognitionError> {
        let cog = NativeCognition::start(&self.claude_bin, &self.engine_dir)?;
        Ok(Box::new(cog))
    }
}

/// The durable Rich, guarded for cross-invocation access. `Spine` is `Send` (its
/// compute lease is `Box<dyn Cognition + Send>`), so `Mutex<Spine>` is valid Tauri state.
struct AppState {
    spine: Mutex<Spine>,
    /// Set false when no lease could be attached at boot (e.g. Claude not logged in),
    /// so the UI can surface a calm, Rich-voiced "not connected" state instead of a crash.
    lease_ready: bool,
    /// Durable CEO-facing preferences (company name, the assertiveness dial) — stored
    /// alongside the ledger in the app data dir, same durability posture.
    config: Mutex<ConfigStore>,
    /// The entity area this launch is bound to (ECS §3.3). `None` fails closed: threads
    /// cannot be created and the loro desk is scoped to nothing, rather than defaulting to
    /// an entity nobody chose.
    ///
    /// **BEHIND A MUTEX SINCE SLICE 4, and that is the whole shape of the fix.** It used to
    /// be a plain `Option` fixed at boot, with a comment saying the CEO-facing picker was
    /// slice 4 — which meant a launch that could not resolve a root stayed unresolved for
    /// its whole life, and a double-clicked bundle (working directory `/`) can never
    /// resolve one. The picker writes here, at runtime, so answering the question does not
    /// cost a relaunch.
    ///
    /// It is NOT inside `config`'s mutex even though `choose_entity` writes both: this is
    /// read on the `create_thread` and loro paths, and `config` is held by the settings
    /// surface. Lock order everywhere is config, then entity, then spine.
    entity: Mutex<Option<EntityId>>,
    /// Whether `RICHOS_ENTITY` decided the answer. Fixed for the life of the process,
    /// because the variable is: nothing the CEO does in the window can change it, so the
    /// settings surface must render a statement rather than a control (§21's own rule —
    /// a state he cannot change has to say who can).
    entity_pinned_by_env: bool,
    /// Where the entity in force came from, so the settings surface can say so. Moves when
    /// `choose_entity` writes, which is why it is behind the same kind of lock as `entity`.
    entity_source: Mutex<Option<EntitySource>>,
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
    /// THE LORO CORRECTION DESK (open-items 3.5). Its writer comes from the SAME
    /// `LoroInstall` the read half was built from (`memory::wire_company_memory`), so the
    /// record the CEO is shown and the record his confirmation writes to cannot be two
    /// different corpora.
    ///
    /// **IT MOVES, and until 2026-09-01 it did not.** The field was a plain `Option` fixed
    /// at boot, so `provision_memory` re-wired the READ half into the running spine and
    /// could not re-wire this one: a genuinely fresh user answered "set my memory up", got a
    /// corpus, and then had a Rich that could read it and not correct it until he quit and
    /// reopened. That was printed rather than hidden, which was the right call for a limit
    /// nobody had time to fix — and it is not a limit, it is a `Mutex`. The CEO's own
    /// install never saw it (his corpus predates the app); every customer's first five
    /// minutes did.
    ///
    /// `None` when no corpus is configured, which is an ordinary install and not an error —
    /// the commands then say so in words instead of failing obscurely.
    ///
    /// TWO LOCKS, NEVER HELD TOGETHER AS A PAIR BY ANY READER. The outer `Mutex` guards
    /// WHETHER there is a desk; the inner one (inside `SharedCorrectionDesk`) guards the
    /// desk itself. [`desk`] takes the outer lock, clones the `Arc`, RELEASES it, and only
    /// then locks the desk — so a confirmation that takes ten seconds inside `loro-write`
    /// never blocks `loro_available`, and `provision_memory` can install a desk while one is
    /// being read.
    ///
    /// Behind its OWN mutex and not the spine's, for the same reason `control` is: reading
    /// what loro believes and confirming a correction are things the CEO does while Rich
    /// may be mid-turn, and `send_message` holds the spine lock for the whole of a turn.
    /// A correction UI that froze until Rich finished would be a UI nobody uses.
    correction: Mutex<Option<SharedCorrectionDesk>>,
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
    /// THE LAUNCH RECORD (`richos_core::launch`). What a start is, the log of starts, the
    /// recency ring, the install date and which rewards have fired.
    ///
    /// Behind its own mutex and NOT inside `config` for the reason `config.rs`'s own first
    /// paragraph gives: that file holds mutable point-in-time preference, and this is an
    /// append-only event log. They share a directory and a durability posture, nothing else.
    launch: Mutex<LaunchStore>,
    /// WHERE HIS MEMORY IS, AND WHETHER THIS INSTALL CAN READ IT (`memory.rs`).
    ///
    /// Behind its own mutex and NOT the spine's, for the fourth time and the same reason:
    /// `send_message` holds the spine lock for a whole turn, and "set my memory up" is
    /// something the CEO does before he has sent anything at all — but the surface that
    /// asks it also re-reads this after a turn may have started.
    ///
    /// It MOVES: `provision_memory` rewrites it after wiring a corpus that did not exist
    /// when the process started. That is the whole point — the answer must not cost a
    /// relaunch, exactly as `choose_entity`'s answer does not.
    memory: Mutex<MemoryStatus>,
    /// The same `Arc` the spine holds. Kept here so provisioning can re-run
    /// `wire_company_memory` with the provenance sink the correction desk reads from — a
    /// second `SliceProvenance` would mean the desk could not propose against a slice the
    /// compiler had just accepted.
    loro_provenance: SharedSliceProvenance,
    /// WHERE THE DURABLE STORES LIVE — `app_data_dir()`, resolved once in `setup` and
    /// carried rather than re-asked.
    ///
    /// `provision_memory` needs it to open the correction desk's log, and it must be the
    /// SAME directory this boot used: a command that re-resolved it would be a second
    /// answer to a question already answered, which is the shape of every defect this
    /// evening has been about. The desk's log is `<data_dir>/loro-corrections.jsonl` and
    /// there is exactly one expression for that path.
    data_dir: PathBuf,
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
    let entity = state.entity.lock().unwrap().clone().ok_or_else(|| ENTITY_UNRESOLVED_MESSAGE.to_string())?;
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

/// What the CEO is told when there is no corpus this install could write a correction to.
///
/// **A CONST, and it became one because it being prose inside a closure cost two test
/// suites.** `49e2cd4` rewrote this sentence in place — it had said *"No loro corpus is
/// configured for this install…"*, a word that is false when the corpus is sitting at a path
/// nobody looked at — and left `app/ui/mock.js` and `tests/lib/state-registry.js` holding the
/// old one. `affordances.js` and `corrections.js` have been failing ever since and NOBODY
/// SAW IT, because `app/ui/tests` had no `node_modules` and eighteen of the nineteen suites
/// could not start.
///
/// The affordance scrape (`tests/lib/state-strings.js::RUST_CEO_CONTEXT`) finds a CEO-facing
/// sentence by the shape of the code around it — `Err(`, `ok_or`, `.into()`, or a
/// `const … : &str =` on the line above. Three lines below an `ok_or_else(|| {`, inside a
/// `String::from(`, it matched none of them, so the string was invisible to the very
/// machinery that exists to notice it drifting. As a const it is found the same way
/// [`LEASE_UNAVAILABLE_MESSAGE`] is, and `mock.js` copies it the way `_notConnected` copies
/// that one.
///
/// The candidate list `desk()` appends is deliberately NOT part of it: the list is a fact
/// about one machine, this is the sentence.
const LORO_DESK_ABSENT_MESSAGE: &str =
    "This install has no company memory it can write to, so there is nothing to read or \
     correct here. That is a statement about this install, not about what is recorded.";

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
///
/// THE LAST CLAUSE CHANGED ON 2026-09-01, AND IT HAD TO. It read *"It isn't something you
/// can set from in here: whoever set RichOS up has to tell me which company this copy of me
/// works for"* — true when it was written, and false the moment the picker landed. It is
/// now something he sets from in here, in two places (the launch picker and the
/// preferences popover), so the sentence names the control instead of naming a party who
/// no longer owns it. A state's copy going stale in the direction of "you cannot do this"
/// is the worse direction: it teaches him not to look for a control that is right there.
const ENTITY_UNRESOLVED_MESSAGE: &str =
    "I can't tell which company this work belongs to, so I won't guess — filing it under \
     the wrong one would mix two companies' records together, and that's not a mistake \
     worth risking to save you a question. Pick the company and I'll keep everything under \
     it from then on.";

/// WHERE A RESOLVED ENTITY CAME FROM. Reported to the CEO's settings surface and printed
/// at boot, because "RichOS is filing this under RichOS" and "somebody set an environment
/// variable that RichOS cannot change from in here" are different facts about the same
/// entity id, and a surface that renders a control over the second one is lying.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum EntitySource {
    /// `RICHOS_ENTITY` — an explicit operator statement, made outside the app.
    Environment,
    /// The answer the CEO gave the picker, kept in `config.json`.
    SavedChoice,
    /// Deterministic repository-root containment (ECS §3.3/§10.2) — the dogfood path.
    WorkingDirectory,
}

impl EntitySource {
    /// The wire string. Kebab-case and stable: `app/ui/main.js` switches on it.
    fn as_str(&self) -> &'static str {
        match self {
            EntitySource::Environment => "environment",
            EntitySource::SavedChoice => "saved-choice",
            EntitySource::WorkingDirectory => "working-directory",
        }
    }

    /// How the boot log names it, for the operator reading a terminal.
    fn describe(&self) -> &'static str {
        match self {
            EntitySource::Environment => "RICHOS_ENTITY",
            EntitySource::SavedChoice => "the saved choice",
            EntitySource::WorkingDirectory => "the working directory",
        }
    }
}

/// The outcome of entity resolution: what was resolved, where it came from, and every
/// line the operator should see about it.
///
/// `notes` rather than `eprintln!` inside the resolver so the ORDER is a pure function of
/// its inputs and can be asserted by a test. The resolver that this replaces read
/// `std::env::var` and `std::env::current_dir()` directly, which is precisely why nothing
/// ever tested it under the one condition that matters — a Finder launch, where both are
/// answers no developer's shell ever produces.
#[derive(Debug, Clone, PartialEq, Eq)]
struct BootEntity {
    entity: Option<EntityId>,
    source: Option<EntitySource>,
    notes: Vec<String>,
}

/// Resolve this launch's entity area (ECS §3.3/§10.2), deterministically and fail-closed.
///
/// **THE ORDER, and why each step is where it is.** This is slice 4 — the picker the
/// comment at `create_thread` has named since slice 1 — so there is now a fourth step, and
/// the fourth step is the one that makes the other three safe to keep fail-closed.
///
///   1. **`RICHOS_ENTITY`** — an explicit operator statement, made deliberately, from
///      outside the app. It wins, it is still validated against the registry, and an
///      unregistered value STILL REFUSES rather than falling through: someone who names an
///      entity meant it, and quietly resolving a different one would be worse than
///      stopping.
///   2. **The saved choice** — the answer the CEO gave the picker, read from `config.json`.
///      It outranks the working directory because it is a person's stated answer and a
///      working directory is an accident of how the process was started. A value that no
///      longer parses or is no longer registered is STALE DATA rather than a statement, so
///      it is named in a note and falls through to (3), which is deterministic.
///   3. **Working-directory containment** — unchanged. Every dogfood launch behaves today
///      exactly as it did yesterday, because on those machines nothing has ever been saved
///      at (2): the `entity` key did not exist until this pass.
///   4. **Nothing** — `None`, which still blocks every send. The difference this pass makes
///      is not that an unresolved entity is now allowed through; it is that the CEO can
///      always REACH one, through the picker, which writes (2).
///
/// Pure on purpose: every input is an argument, so the GUI condition (`cwd = /`, no
/// environment, empty config) is a test rather than a build-and-double-click.
fn resolve_boot_entity(
    registry: &EntityRegistry,
    env_value: Option<&str>,
    saved: Option<&str>,
    cwd: Option<&Path>,
) -> BootEntity {
    let mut notes: Vec<String> = Vec::new();

    if let Some(explicit) = env_value {
        return match EntityId::parse(explicit.trim()) {
            Ok(id) if registry.contains(&id) => {
                BootEntity { entity: Some(id), source: Some(EntitySource::Environment), notes }
            }
            _ => {
                notes.push(format!(
                    "RICHOS_ENTITY={explicit:?} is not a registered entity — refusing it"
                ));
                BootEntity { entity: None, source: None, notes }
            }
        };
    }

    if let Some(raw) = saved {
        match EntityId::parse(raw.trim()) {
            Ok(id) if registry.contains(&id) => {
                return BootEntity {
                    entity: Some(id),
                    source: Some(EntitySource::SavedChoice),
                    notes,
                };
            }
            // NAMED, NOT DROPPED. A saved choice that no longer resolves is the one state
            // in which the CEO believes he has answered this question and has not.
            _ => notes.push(format!(
                "the saved company {raw:?} is not a registered entity any more — ignoring it                  and asking again rather than filing work under a guess"
            )),
        }
    }

    match cwd {
        Some(dir) => match registry.resolve_root(dir) {
            Ok(entity) => BootEntity {
                entity: Some(entity.id.clone()),
                source: Some(EntitySource::WorkingDirectory),
                notes,
            },
            Err(e) => {
                notes.push(format!("entity not resolved from {}: {e}", dir.display()));
                BootEntity { entity: None, source: None, notes }
            }
        },
        None => {
            notes.push("no working directory could be read".to_string());
            BootEntity { entity: None, source: None, notes }
        }
    }
}

/// The process-reading wrapper around [`resolve_boot_entity`]. Everything it knows it reads
/// here and hands over as an argument; it holds no logic of its own.
fn boot_entity(registry: &EntityRegistry, config: &ConfigStore) -> BootEntity {
    let env_value = std::env::var("RICHOS_ENTITY").ok();
    let cwd = std::env::current_dir().ok();
    let resolved = resolve_boot_entity(
        registry,
        env_value.as_deref(),
        config.entity_raw(),
        cwd.as_deref(),
    );
    for note in &resolved.notes {
        eprintln!("[richos] {note}");
    }
    resolved
}

/// Where this launch's engine directory is — the working directory `claude` is started in.
///
/// The seven-candidate order, and the reasoning behind it, is `engine.rs`. This wrapper holds
/// the one decision the resolver deliberately does not make: what to hand
/// `NativeCognition::start` when NOTHING was found.
///
/// **It hands over the last place it looked, and it never invents a plausible path.** A launch
/// with no engine has to fail, and it has to fail naming a real candidate an operator can act
/// on — `native.rs::preflight` turns that into `the engine directory <path> does not exist`,
/// which is a true sentence about a path that was genuinely checked. Synthesizing a default
/// instead is exactly how `cwd/../engine` became `/../engine` under a Finder launch and got
/// reported as a missing `claude` binary.
fn resolve_engine() -> engine::EngineResolution {
    let mut resolution = engine::resolve_engine_dir(&engine::LaunchPaths::from_process());
    if resolution.dir.is_none() {
        resolution.dir = resolution.tried.last().map(|(_, path)| path.clone());
    }
    resolution
}

/// OPEN THE LORO CORRECTION DESK AND WIRE IT IN — the only place that does, called from
/// both `setup` and [`provision_memory`].
///
/// **It exists because it was called from one place and needed to be called from two.**
/// `AppState::correction` used to be fixed at boot, so a customer who answered "set my
/// memory up" got a corpus, a working read half, and a correction desk that stayed shut
/// until he quit and reopened. The read half already re-wired without a relaunch, through
/// `memory::wire_company_memory`, for exactly the reason this function now exists: the
/// alternative is two copies of the same wiring, and the one that drifts is always the one
/// a new customer hits first.
///
/// Four things happen here and all four have to happen together, which is the other reason
/// this is a function and not a comment:
///
///   1. the desk's own fsync'd log is opened beside the ledger — failure REFUSES rather
///      than pretending, because a desk that cannot record a proposal durably would lose
///      the CEO's answer across a relaunch;
///   2. the spine gets the desk, so the belief trigger has somewhere to file;
///   3. the spine gets the proposal observer, so a proposal raised inside a two-hour turn
///      moves the badge during it rather than at the next open;
///   4. a desk with no context compiler says so — nothing was ever put in front of Rich, so
///      no correction can name a record and the trigger would sit silent looking wired.
fn install_correction_desk(
    spine: &mut Spine,
    app: &tauri::AppHandle,
    data_dir: &Path,
    writer: CliLoroWriter,
) -> Option<SharedCorrectionDesk> {
    let desk = match CorrectionDesk::open(data_dir.join("loro-corrections.jsonl"), Box::new(writer)) {
        Ok(d) => d.shared(),
        Err(e) => {
            eprintln!(
                "[richos] loro correction desk unavailable, corrections will refuse rather than \
                 pretend: {e}"
            );
            return None;
        }
    };
    spine.set_correction_desk(std::sync::Arc::clone(&desk));
    spine.set_proposal_observer(Box::new(TauriProposalEmitter { app: app.clone() }));
    if !spine.has_loro_context_compiler() {
        eprintln!(
            "[richos] loro correction desk is open but no context compiler is configured — \
             nothing was ever put in front of Rich, so no correction can name a record and the \
             trigger will stay silent"
        );
    }
    Some(desk)
}

fn main() {
    tauri::Builder::default()
        .setup(|app| {
            // Durable ledger lives in the app data dir (survives restart + rotation).
            let data_dir = app.path().app_data_dir().unwrap_or_else(|_| std::env::temp_dir());
            std::fs::create_dir_all(&data_dir).ok();

            // =====================================================================
            // THE LAUNCH RECORD, AND THE WINDOW — FIRST, AND FOR ONE REASON
            // =====================================================================
            //
            // `app/ui/splash.js` decides whether to draw the opening screen on its FIRST
            // synchronous line, before anything can be awaited. So the one fact it needs —
            // is this a fresh launch, a crash-restart, or a second window — has to already
            // be in the page. Tauri creates config-declared windows BEFORE this hook runs
            // (tauri-2.11.5 `src/app.rs:2524`), which is why `tauri.conf.json` now carries
            // `"create": false` and the window is built here instead: `from_config` keeps
            // every property the config declares and this adds exactly one line of script.
            //
            // IT IS FIRST IN THIS FUNCTION, NOT WHEREVER IT FITTED. Everything below —
            // ledger replay, machinery eviction, loro — used to happen with the window
            // already on screen. Moving window creation into `setup` puts all of it AHEAD
            // of first paint unless the window goes first, so the window goes first and
            // what precedes it is one small file read and one small file write. Measured on
            // this machine, `launches.json` at 100 starts is under 4 KB
            // (`launch.rs::a_hundred_launches_stay_in_order_and_cost_a_few_kilobytes`).
            //
            // `PriorRun::Unknown` is the honest answer and not a placeholder: this shell
            // does not check whether the process that left a marker behind is still alive,
            // so it says so rather than guessing, and `launch.rs` reads Unknown as a
            // crash-restart — not counted, no splash, back where he was.
            let mut launch_store = LaunchStore::open(data_dir.join("launches.json"), richos_core::util::now_millis())
                .expect("open launch record");
            if let Some(why) = launch_store.unreadable_reason() {
                eprintln!("[richos] launch record: {why}");
            }
            let launch_kind = launch_store
                .begin_run(richos_core::util::now_millis(), std::process::id().to_string(), PriorRun::Unknown)
                .unwrap_or(LaunchKind::Fresh);
            // WHICH START THIS IS, for the splash's selection rule. Read from the ledger
            // that was just written, one line above — never a second counter. `None` when
            // this is not a start or when the record would not parse, and the webview reads
            // a missing ordinal as the first start, which shows splash #1.
            let start_ordinal = launch_store.start_ordinal();
            let window_configs = app.config().app.windows.clone();
            for window_config in &window_configs {
                let kind = launch_store.next_window_kind();
                tauri::WebviewWindowBuilder::from_config(app.handle(), window_config)?
                    .initialization_script(launch_init_script(kind, start_ordinal))
                    .build()?;
            }
            eprintln!(
                "[richos] launch: {} (start {}, {} window(s))",
                launch_kind.as_str(),
                start_ordinal.map(|n| n.to_string()).unwrap_or_else(|| "-".to_string()),
                window_configs.len()
            );
            let ledger_path = data_dir.join("conversation-ledger.jsonl");
            let ledger = Ledger::open(&ledger_path).expect("open ledger");

            let mut spine = Spine::new(ledger);

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

            // =====================================================================
            // WHICH COMPANY THIS COPY OF RICH WORKS FOR — resolved HERE, and here for
            // one reason: step 2 of the order is the saved choice, and the saved
            // choice lives in the store opened on the line above.
            // =====================================================================
            //
            // It used to run fifty lines further up, before the config file was open,
            // which is exactly why there were only two steps and why a Finder launch
            // had no route to an entity at all. A resolver that runs before the store
            // holding the answer cannot read the answer.
            //
            // A thread requires an entity home, so boot still conjures none out of
            // nowhere. If an entity resolves, the default thread is created/activated
            // in it; if none does, the app launches with NO active context, every send
            // is still refused — and `entity_choice`/`choose_entity` are how the CEO
            // reaches one from inside the window, which is the part that was missing.
            let boot = boot_entity(&EntityRegistry::ceos_companies(), &config);
            match &boot.entity {
                Some(entity) => {
                    eprintln!("[richos] company: {entity} (via {})", boot.source.map(|s| s.describe()).unwrap_or("resolution"));
                    spine.ensure_active_thread_in(entity).expect("ensure thread");
                }
                // THE OPERATOR'S HALF of the same condition. `ENTITY_UNRESOLVED_MESSAGE`
                // is written for the CEO and deliberately names no environment variable;
                // this line is read by whoever it names, in a terminal, where
                // `RICHOS_ENTITY` is the correct and actionable instruction.
                //
                // IT NO LONGER ENDS THERE, and that is the substantive change: the CEO is
                // now asked in the window, so this says what he will see rather than
                // implying a terminal is the only way through.
                // THE LIST IS DERIVED, NOT TYPED. It was typed, it said "femcboost,
                // deeply, prospects or richos", and on 2026-09-01 the registry grew to the
                // CEO's real six — at which point a hand-written list becomes an operator
                // instruction that omits two of the valid answers and reads as if they are
                // invalid. Reading it off the registry is one expression and cannot drift.
                None => eprintln!(
                    "[richos] no company resolved — RichOS will ask in the window and \
                     remember the answer.\n\
                     [richos] operator: RICHOS_ENTITY (one of {}) still overrides, as does \
                     launching from that entity's repository root.",
                    EntityRegistry::ceos_companies()
                        .entities()
                        .iter()
                        .map(|e| e.id.to_string())
                        .collect::<Vec<_>>()
                        .join(", ")
                ),
            }

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
            // RESOLVED FOR A LAUNCH WITH NO TERMINAL, since 2026-09-01. `from_env` is
            // still the whole of the explicit path and is still exclusive; what changed is
            // that a Finder launch — launchd's environment, no LORO_* anything — now also
            // reaches the two per-user pointers an operator can put in place. Measured
            // before and after on the signed bundle:
            // `docs/verification/installed-app-2026-09-01/`.
            // MOVED, UNCHANGED, TO `memory.rs` ON 2026-09-01, and moved for one reason:
            // first-run provisioning has to run all of it a SECOND time. The CEO answers
            // "set my memory up", a corpus appears on disk, and the app has to start using
            // it without being relaunched — so the wiring cannot be a hundred lines that
            // only exist inside `setup`. Two copies would drift and the drifted one would
            // be the one he hits.
            //
            // BOTH HALVES COME BACK. Until 2026-09-01 this call produced only the READ half
            // and the correction desk below built its own writer out of the environment,
            // ninety lines later — which is how a GUI launch came to resolve the CEO's
            // corpus for reading and nothing at all for writing. `WiredMemory` carries the
            // writer that the SAME `LoroInstall` produced, so the two cannot disagree.
            let wired = memory::wire_company_memory(&mut spine, &loro_provenance);
            let memory_status = wired.status;

            // Attach the compute lease. A boot with no Claude auth, no `claude` binary, or a
            // binary that rejects our flags does NOT silently degrade: `lease_ready` goes
            // false and EVERY send is refused with `LEASE_UNAVAILABLE_MESSAGE` — a calm,
            // Rich-voiced "not connected" that the CEO cannot mistake for a working app
            // (`send_message`, and the voice submit callback, both check it).
            //
            // **The DIAGNOSIS is printed verbatim, and that is the loud half §16 demands.**
            // `NativeError` carries the child's own stderr, so a binary that stopped
            // accepting `--permission-prompt-tool stdio` announces itself here as
            // `error: unknown option '--permission-prompt-tool'` rather than as a mystery.
            // It is not shown to the CEO — a flag name is not CEO copy — but it is the first
            // thing whoever set RichOS up will read, and the sentence he DOES see points at
            // exactly that person.
            // NAMED AT BOOT, ALWAYS. Seven candidates resolve this now (engine.rs), so
            // "which one answered" is a fact an operator needs and cannot otherwise obtain —
            // the same reason the success line below names the binary instead of leaving a
            // working boot silent. When nothing answered, every place looked is printed:
            // "not found" without the list is what sends someone hunting.
            let resolution = resolve_engine();
            eprintln!("[richos] engine directory: {}", resolution.describe());
            if resolution.source.is_none() {
                for (source, path) in &resolution.tried {
                    eprintln!("[richos]   looked in {} ({})", path.display(), source.as_str());
                }
            }
            let engine = resolution.dir.clone().unwrap_or_else(|| std::path::PathBuf::from("/nonexistent/richos-engine"));
            let claude_bin = resolve_claude_bin();
            let lease_ready = match NativeCognition::start(&claude_bin, &engine) {
                Ok(cog) => {
                    // The POSITIVE half, and it is here because its absence is not evidence:
                    // before this line, a successful boot was silent and a reader had to
                    // infer success from the failure line NOT appearing. It names the binary
                    // because that is the operator-useful fact — which `claude` this install
                    // is actually driving, out of the several a self-updating installer
                    // leaves under `~/.local/share/claude/versions/`.
                    //
                    // It names the BINARY and nothing else. Not the account, not the
                    // subscription, not a token: RichOS may never collect, store or
                    // intermediate Claude credentials (§16's licence condition), and a log
                    // line is storage.
                    eprintln!("[richos] compute lease attached over {}", claude_bin.display());
                    spine.attach_lease(Box::new(cog));
                    true
                }
                Err(e) => {
                    eprintln!("[richos] NO COMPUTE LEASE — RichOS cannot talk to Rich.");
                    eprintln!("[richos]   binary: {}", claude_bin.display());
                    // THE SECOND PATH, printed because it was the missing one. Until
                    // 2026-09-01 this block named only the binary, so a failure caused by the
                    // WORKING DIRECTORY printed a binary path, a "binary was not found"
                    // message, and no mention of the directory at all. `native.rs::preflight`
                    // now separates the two causes; this line makes the other path visible
                    // whichever cause fired, so nobody has to infer it from the message text.
                    eprintln!("[richos]   engine: {}", engine.display());
                    eprintln!("[richos]   cause : {e}");
                    false
                }
            };

            // Attach the rotation/recovery seam REGARDLESS of initial boot success — even
            // if Claude wasn't signed in at launch, wiring the factory means a later sign-in
            // + retry (or a crash recovery attempt) has a real respawn path rather than none.
            spine.set_lease_factory(Box::new(EngineLeaseFactory { claude_bin, engine_dir: engine }));

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
            //
            // THE WRITER IS NOT RESOLVED HERE. It arrives from `wire_company_memory` above,
            // out of the one `LoroInstall` the read half was also built from. What used to
            // be on this line was `CliLoroWriter::from_env()`, and it is the third instance
            // in one day of the same premise failure — a component reading its configuration
            // from environment variables that a Finder launch does not have. `ps eww` on a
            // real double-click carries `HOME`, `USER` and
            // `PATH=/usr/bin:/bin:/usr/sbin:/sbin`, and nothing else, so on the CEO's
            // installed app this was `Ok(None)` on every boot and the desk was dead: he
            // could be shown a proposal, confirm it, and reach a writer with no corpus.
            //
            // OPENED AND WIRED BY `install_correction_desk`, which `provision_memory` also
            // calls. ONE function, because the boot path and the first-run path have to
            // produce the same desk wired to the same seams — and two copies of "open it,
            // hand it to the spine, attach the observer" would drift, with the copy that
            // drifted being the one a new customer hits in his first five minutes.
            let correction = match wired.writer {
                Some(writer) => install_correction_desk(&mut spine, app.handle(), &data_dir, writer),
                // NOT A SILENT NO-OP. `wire_company_memory` has already printed the reason
                // and, for the no-corpus case, every candidate it looked at — the same
                // sentences the read path prints, because it is the same resolution. This
                // line says what it MEANS for the desk, so nobody has to join the two facts
                // up themselves.
                None => {
                    eprintln!(
                        "[richos] loro correction desk: CLOSED — {}. Confirming a correction \
                         will refuse and say so rather than appearing to write.",
                        match memory_status.state.as_str() {
                            "none" => "no corpus resolved (candidates listed above)",
                            "no-compiler" => "a corpus resolved but loro-write.mjs is not installed",
                            other => other,
                        }
                    );
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
            // THE SPOKEN TRIGGER, wired at the same seam the belief one is
            // (`install_correction_desk`): the desk the Tauri commands answer through is
            // the desk the turn path files into, one `Arc`, so a question raised inside a
            // two-hour turn is answerable during it.
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
                entity: Mutex::new(boot.entity),
                // PRESENCE, not success. A `RICHOS_ENTITY` that names nothing resolves to
                // `None` and short-circuits BEFORE the saved choice — so a CEO who answered
                // the picker under one would have his answer written to disk and never read
                // again, and be asked at every launch for ever. Keying this on the variable
                // being SET means the surface tells him it was decided outside the window and
                // names who owns it, instead of silently swallowing his answer.
                entity_pinned_by_env: std::env::var_os("RICHOS_ENTITY").is_some(),
                entity_source: Mutex::new(boot.source),
                nav: Mutex::new(nav_store),
                control,
                correction: Mutex::new(correction),
                spoken,
                feedback,
                launch: Mutex::new(launch_store),
                memory: Mutex::new(memory_status),
                loro_provenance,
                // KEPT, not re-derived. `provision_memory` opens the correction desk's log
                // beside the ledger, and it must be the SAME directory this boot used —
                // re-asking `app_data_dir()` in the command would be a second resolution of
                // a question already answered, which is the shape of defect this whole
                // evening has been about.
                data_dir,
            });

            // ================================================================
            // THE UPDATE PATH — last in setup, and last for a reason
            // ================================================================
            //
            // `updates::init` is pure (one `app.manage`, no I/O, no network), so its
            // position costs first paint nothing — but the LAUNCH CHECK it arms must come
            // after everything above, because a TLS handshake started before the ledger
            // has replayed competes with the one thing the CEO is actually waiting for.
            // The check itself then waits a further three seconds on its own task.
            //
            // The selftest branch is `app/scripts/updater-e2e.sh`'s entry point. It runs
            // the app EXACTLY as it boots — same ledger, same window, same everything —
            // and then drives the same `check`/`install` functions the two commands drive.
            // A harness that skipped the boot would be proving a different program.
            updates::init(app.handle());
            match updates::selftest_mode() {
                Some(mode) => {
                    eprintln!("[richos] update selftest: {mode}");
                    updates::spawn_selftest(app.handle().clone(), mode);
                }
                None => updates::spawn_launch_check(app.handle().clone()),
            }

            // ================================================================
            // THE END OF RESOLUTION, SAID OUT LOUD
            // ================================================================
            //
            // Everything above this line is this launch answering "where is my
            // configuration?" — the engine directory, the compute lease, the corpus, both
            // halves of loro, the company, the four durable stores. Everything below it and
            // after it is conduct rather than resolution: `spawn_launch_check` sleeps three
            // seconds and then talks to the network, and the window is already up.
            //
            // IT IS HERE SO A CHECK CAN KNOW WHEN TO STOP READING, and that is not a
            // convenience. `gui-boot.test.sh` boots this binary under launchd's environment
            // and holds every line it printed to account; without a terminator, "the boot
            // log" would be "whatever had appeared after N seconds", and a check whose input
            // depends on a sleep is a check that goes red for no reason on a slow morning
            // and gets ignored by the third time. The marker makes the boundary a FACT the
            // program states rather than a duration the harness guesses.
            //
            // It is also the honest answer to an operator reading a terminal: the lines
            // above are all of it, so nothing further is coming and a missing line is
            // missing rather than late.
            eprintln!("[richos] boot complete — every line above is what this launch resolved");
            Ok(())
        })
        .plugin(tauri_plugin_updater::Builder::new().build())
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
            // --- which company this copy of Rich works for (slice 4, 2026-09-01) ---
            entity_choice,
            choose_entity,
            memory_status,
            provision_memory,
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
            set_user_name,
            // --- the launch record (2026-08-31) — appended, never reordered ---
            launch_state,
            launch_note_splash_shown,
            // --- the home screen's entity row (2026-09-01) — appended, never reordered ---
            home_entity_row,
            set_home_entity_label,
            set_home_entity_visible,
            // --- the update path (2026-08-31) — appended, never reordered.
            //     These four are the ONLY updater surface the webview has: no
            //     `plugin:updater|*` command is granted to it (capabilities/default.json).
            updates::update_state,
            updates::update_check,
            updates::update_install,
            updates::update_relaunch
        ])
        .build(tauri::generate_context!())
        .expect("error while building RichOS")
        // THE CLEAN-EXIT MARKER, CLEARED HERE AND NOWHERE ELSE.
        //
        // This is the whole of what makes the NEXT launch read as fresh rather than as a
        // crash-restart, and `.run(context)` — which this replaces — gave no place to put
        // it. `RunEvent::Exit` is the last thing Tauri emits before the process ends, so it
        // fires on a quit and, by construction, cannot fire on a kill or a power cut. That
        // is exactly the semantics the record wants: absent marker means he quit, present
        // marker means the app did not get to say so.
        //
        // A write failure here is logged and never fatal. The cost of one is that the next
        // launch is read as a crash-restart — an undercount by one, no splash once — which
        // is not worth refusing to close the app over.
        .run(|handle, event| {
            if let tauri::RunEvent::Exit = event {
                if let Some(state) = handle.try_state::<AppState>() {
                    if let Err(e) = state.launch.lock().unwrap().note_clean_exit() {
                        eprintln!("[richos] launch record: could not mark a clean exit: {e}");
                    }
                }
            }
        });
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

// ---- WHICH COMPANY THIS COPY OF RICH WORKS FOR (slice 4) ------------------------------
//
// The two commands that close the double-click blocker. `create_thread_in` above already
// made an entity choice REAL for a new thread; what did not exist was a way for the CEO to
// answer the question ONCE, durably, for the copy of RichOS on his machine — so a Finder
// launch, whose working directory is `/`, reached no entity at all and refused his first
// sentence.
//
// WHAT IS DELIBERATELY NOT HERE: a default. Nothing below ever picks an entity. `choose_entity`
// refuses an unregistered id, refuses while the environment pins one, and writes only what
// the CEO clicked.

/// One company the CEO can pick, as the picker and the settings row render it.
#[derive(serde::Serialize)]
struct EntityOption {
    id: String,
    display_name: String,
    /// The bound source root(s), so the row can say which is which when two companies have
    /// similar names. Empty when the entity has none registered.
    roots: Vec<String>,
    /// How many threads are already filed here. `0` is a real and renderable answer.
    thread_count: usize,
}

/// The whole state of the question "which company is this copy of Rich for?".
#[derive(serde::Serialize)]
#[serde(rename_all = "camelCase")]
struct EntityChoiceView {
    /// The entity in force right now, or `None` — which is the state that makes the app ask.
    chosen: Option<String>,
    /// Where `chosen` came from: `environment` | `saved-choice` | `working-directory`.
    source: Option<String>,
    /// `RICHOS_ENTITY` decided it, so nothing in this window can change it. The surface
    /// renders a statement and names who owns the fix, rather than a control that does not
    /// work (§21: a state he cannot change has to say who can).
    pinned_by_environment: bool,
    /// Every registered company, in registry order. Never filtered, never re-sorted.
    options: Vec<EntityOption>,
    /// The scope in force, so the caller does not need a second round trip after choosing.
    active: Option<ActiveContext>,
}

/// What the CEO is told when the environment has pinned the company. Same register as
/// `LEASE_UNAVAILABLE_MESSAGE` and `ENTITY_UNRESOLVED_MESSAGE`: it says what it will not
/// do, why, and who owns the fix, and it invents no control.
const ENTITY_PINNED_MESSAGE: &str =
    "This copy of me was told which company it works for when it was started up, from \
     outside this window, so I can't move it from in here. Whoever set RichOS up is the \
     one who changes that.";

/// What he is told when a chosen id is not one of the companies this build knows about.
/// It cannot happen from the picker (the picker's rows ARE the registry); it can happen
/// from a stale saved value or a hand-driven call, and refusing is the fail-closed half of
/// ECS §3.3.
fn unknown_company_message(id: &str) -> String {
    format!(
        "I don't have a company called \"{id}\" on file, so I won't file anything under it. \
         Pick one of the companies I do have, or whoever set RichOS up can add it."
    )
}

fn entity_choice_view(state: &State<AppState>) -> EntityChoiceView {
    // Lock order, everywhere in this file: config, then entity, then spine.
    let chosen = state.entity.lock().unwrap().clone();
    let spine = state.spine.lock().unwrap();
    let registry = spine.entity_registry();
    let summaries = spine.threads();
    let options = registry
        .entities()
        .iter()
        .map(|e| {
            let id = e.id.to_string();
            EntityOption {
                thread_count: summaries
                    .iter()
                    .filter(|s| s.entity_id.as_deref() == Some(id.as_str()))
                    .count(),
                display_name: e.display_name.clone(),
                roots: e.roots.iter().map(|r| r.display().to_string()).collect(),
                id,
            }
        })
        .collect();
    EntityChoiceView {
        chosen: chosen.map(|e| e.to_string()),
        source: state.entity_source.lock().unwrap().map(|s| s.as_str().to_string()),
        pinned_by_environment: state.entity_pinned_by_env,
        options,
        active: active_binding_view(&spine),
    }
}

// ---------------------------------------------------------------------------------------
// FIRST-RUN PROVISIONING — the CEO's memory, on a machine that has none
//
// THE DEFECT THIS CLOSES, in the words of the person who found it: RichOS is installed and
// signed and it reaches his memory ONLY because an engineer created a symlink by hand
// (`docs/verification/installed-app-2026-09-01/README.md` §6). Delete
// `~/Library/Application Support/RichOS/loro-root` and his company memory is gone — measured
// on the installed bundle, in `docs/verification/first-run-provisioning-2026-09-01/`. No
// installer, no first-run flow, nothing in the product creates it.
//
// HIS PART IS ONE CLICK AND NO PATH. `memory_status` carries `offered_location`
// (`~/RichOS/corpus`, pre-filled), the window renders it as a sentence with a button, and
// `provision_memory` takes the target it is GIVEN. There is no branch anywhere below that
// picks a location when nobody named one: `provision` returns `NoTarget` for that, which is
// `loro-structure.md`'s "no silent default" enforced at the only door that can create a
// corpus.
// ---------------------------------------------------------------------------------------

/// Read the state of his memory. The window calls it at boot, and a `state` of `none` is
/// what makes it ask — the same shape `entity_choice`'s `chosen: None` already uses.
#[tauri::command]
fn memory_status(state: State<AppState>) -> MemoryStatus {
    let status = state.memory.lock().unwrap().clone();
    memory::with_offered_location(status, std::env::var_os("HOME").map(PathBuf::from).as_deref())
}

/// THE CEO ANSWERS "yes, set it up". Provision, then wire it into the running spine.
///
/// Four properties this has and must keep:
///
///   1. **It creates nothing outside what it was told.** The target arrives from the caller.
///      A missing one is refused by `provision` rather than defaulted, and the window's
///      pre-filled value is the only place `~/RichOS/corpus` is chosen — by him.
///   2. **It never touches a corpus that exists.** `AlreadyACorpus` is a refusal, not a
///      merge. His live pointer at `richos-hq` with 626 records has to survive this command
///      existing, including being called by accident.
///   3. **It never puts a corpus in the product repo**, matching the refusal
///      `loro/lib/layout.js:441` already makes for reading one.
///   4. **It re-wires BOTH HALVES without a relaunch**, through the same
///      `wire_company_memory` and the same `install_correction_desk` the boot ran, so what
///      he gets after answering is what he would have got by restarting.
///
/// Property 4 said "the read half" until 2026-09-01, and the write half was a printed
/// apology: `AppState::correction` was fixed at boot, so a fresh user provisioned his corpus
/// and then had a Rich that could read it and not correct it until he quit and reopened. The
/// window meanwhile told him *"From now on I'll keep what you tell me in that folder"*,
/// which was not true for the rest of that session. It never showed on the CEO's install —
/// his corpus predates the app — and it showed on every customer's first five minutes. The
/// field is a `Mutex` now and this command installs the desk.
///
/// `(async)` for the reason `choose_entity` is async: it takes the spine's mutex, which
/// `send_message` holds for a whole turn.
#[tauri::command(async)]
fn provision_memory(
    app: tauri::AppHandle,
    state: State<AppState>,
    location: Option<String>,
) -> Result<MemoryStatus, String> {
    let home = std::env::var_os("HOME").map(PathBuf::from);
    // The caller's value, and NOTHING ELSE IS SUBSTITUTED FOR IT. An absent one reaches
    // `provision` as an empty target and is refused there by name.
    let target = PathBuf::from(location.unwrap_or_default().trim());

    // THE COMPANIES THIS BUILD KNOWS. `create-company` is given the registry rather than a
    // list invented here, so the partitions a fresh corpus gets are exactly the entity areas
    // the rail renders — the condition `entities_with_no_lane` warns about at boot is
    // therefore satisfied on the first launch instead of after a manual pass.
    let registry = EntityRegistry::ceos_companies();
    let companies: Vec<(String, String)> = registry
        .entities()
        .iter()
        .map(|e| (e.id.to_string(), e.display_name.clone()))
        .collect();

    let report = richos_core::provision::provision(&richos_core::provision::ProvisionRequest {
        target,
        home: home.clone(),
        companies,
        compiler_source: None,
    })
    .map_err(|e| e.to_string())?;

    // WHAT ACTUALLY HAPPENED, on the operator's line, before anything is claimed to the CEO.
    eprintln!("[richos] provisioned a corpus at {}", report.root.display());
    match &report.git {
        richos_core::provision::GitOutcome::Committed { sha, branch } => {
            eprintln!("[richos] corpus git: {branch} @ {sha}, no remote")
        }
        richos_core::provision::GitOutcome::Unavailable(why) => eprintln!(
            "[richos] corpus git: NOT a git repository — {why}. The record is on disk and is his; \
             what is missing is the history under it."
        ),
    }
    for c in &report.companies {
        if let Some(problem) = &c.problem {
            eprintln!("[richos] corpus company {}: not created — {problem}", c.id);
        }
    }
    if let richos_core::provision::CompilerOutcome::NoSource { looked_in } = &report.compiler {
        eprintln!(
            "[richos] corpus compiler: NOT installed — looked in: {}. The corpus exists and is his; \
             what is missing is the program that reads it.",
            looked_in.join("; ")
        );
    }

    // RE-WIRE, through the same function the boot ran. Lock order everywhere in this file is
    // config, then entity, then spine — nothing above holds any of them.
    let mut spine = state.spine.lock().unwrap();
    // BOTH HALVES, from one resolution, exactly as the boot does it. `wire_company_memory`
    // installs the reader into the spine and hands back the writer; the writer becomes the
    // desk through the same `install_correction_desk` the boot calls.
    let wired = memory::wire_company_memory(&mut spine, &state.loro_provenance);
    let mut status = wired.status;

    // THE WRITE HALF, INTO THE RUNNING APP. The outer lock is taken here and inside the
    // same statement as the spine lock, which is safe because nothing else in this file ever
    // takes `correction` and then `spine` — `desk()` takes `correction`, clones out, and
    // releases before touching anything.
    if let Some(writer) = wired.writer {
        let mut held = state.correction.lock().unwrap();
        if held.is_none() {
            // A CUSTOMER'S FIRST FIVE MINUTES. Until 2026-09-01 this branch printed
            // "corrections become available on the next launch" and left the desk shut.
            match install_correction_desk(&mut spine, &app, &state.data_dir, writer) {
                Some(desk) => {
                    eprintln!(
                        "[richos] loro correction desk: OPEN at {} — installed by provisioning, \
                         no relaunch. Corrections work in this session.",
                        status.root.as_deref().unwrap_or("the corpus just created")
                    );
                    *held = Some(desk);
                }
                // `install_correction_desk` has already said why on its own line. This one
                // says what it MEANS, the same split the boot's CLOSED line uses.
                None => eprintln!(
                    "[richos] loro correction desk: still closed after provisioning — the corpus \
                     exists and the desk's own log could not be opened. Confirming a correction \
                     will refuse and say so rather than appearing to write."
                ),
            }
        }
        // A desk that is ALREADY open is left exactly as it is, and that is not laziness:
        // `provision` refuses `AlreadyACorpus`, so reaching this line with a live desk means
        // the corpus this writer names is the corpus that desk is already writing to.
        // Replacing it would throw away the proposals sitting in its in-memory queue.
    }
    drop(spine);
    status.provisioned_now = true;
    *state.memory.lock().unwrap() = status.clone();
    Ok(memory::with_offered_location(status, home.as_deref()))
}

/// Read the state of the question. The UI calls this at boot: a `chosen` of `None` is what
/// makes it ask, and it is the only signal it needs.
#[tauri::command]
fn entity_choice(state: State<AppState>) -> EntityChoiceView {
    entity_choice_view(&state)
}

/// THE CEO ANSWERS. Validate, remember, and let the app carry on without a relaunch.
///
/// Three properties this has and must keep:
///
///   1. **It never re-homes a thread.** A thread's entity is immutable after creation (ECS
///      §3.2, enforced by `ThreadBinding`'s private fields), so this only ever changes what
///      NEW work is filed under. If a conversation is already open it is left exactly where
///      it is — changing the setting must not move a record and must not yank him out of
///      what he is reading.
///   2. **It writes the durable answer BEFORE it activates anything.** A crash between the
///      two costs an activation, which the next boot redoes; the other order would cost the
///      answer, and he would be asked again having already answered.
///   3. **It refuses rather than guesses.** An unregistered id is refused; an environment
///      pin is refused with the sentence that names who owns it.
/// **`(async)` is load-bearing here for the same reason it is on `send_message`.** A plain
/// `#[tauri::command]` on a non-async fn is dispatched as `ExecutionContext::Blocking` and
/// runs inline on the IPC thread; this one takes the spine's mutex, which `send_message`
/// holds for the whole of a turn. Answering "which company is this copy for?" is something
/// the CEO does WHILE Rich may be working, and a settings row that froze the entire IPC
/// channel until the turn finished would be a settings row nobody touches. The DURABLE
/// write happens before the spine is touched at all, so the answer is never lost to a wait.
#[tauri::command(async)]
fn choose_entity(state: State<AppState>, entity_id: String) -> Result<EntityChoiceView, String> {
    if state.entity_pinned_by_env {
        return Err(ENTITY_PINNED_MESSAGE.to_string());
    }
    let id = EntityId::parse(entity_id.trim()).map_err(|_| unknown_company_message(entity_id.trim()))?;
    if !EntityRegistry::ceos_companies().contains(&id) {
        return Err(unknown_company_message(id.as_str()));
    }

    state
        .config
        .lock()
        .unwrap()
        .set_entity(&id)
        .map_err(|e| format!("I couldn't write that down, so I haven't taken it as your answer: {e}"))?;
    *state.entity.lock().unwrap() = Some(id.clone());
    *state.entity_source.lock().unwrap() = Some(EntitySource::SavedChoice);

    apply_company_choice(&mut state.spine.lock().unwrap(), &id)?;
    Ok(entity_choice_view(&state))
}

/// The spine half of `choose_entity`, as a free function so property 1 above is a TEST
/// rather than a sentence in a doc comment.
///
/// **Activate only when nothing is open.** A thread's entity home is immutable after
/// creation (ECS §3.2), so this could not re-home a conversation even if it tried — but it
/// could switch the CEO out of the one he is reading, mid-sentence, because a setting moved.
/// It does not. With a conversation open, the choice governs the NEXT thread and nothing
/// else; with nothing open — the launch case, which is the one this whole pass exists for —
/// it puts him in a thread in the company he just named, without a relaunch.
fn apply_company_choice(spine: &mut Spine, id: &EntityId) -> Result<(), String> {
    if spine.active_thread().is_some() {
        return Ok(());
    }
    spine.ensure_active_thread_in(id).map(|_| ()).map_err(|e| e.to_string())
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
mod entity_choice_tests {
    //! WHICH COMPANY THIS COPY OF RICH WORKS FOR — the four-step order, the durable answer,
    //! and the refusal that is still a refusal.
    //!
    //! WHY THESE TESTS COULD NOT HAVE EXISTED BEFORE. `boot_entity` read `std::env::var` and
    //! `std::env::current_dir()` inline, so the condition that actually matters — a Finder
    //! launch, whose working directory is `/` and whose environment carries nothing a shell
    //! ever put there — was not expressible. Nothing tested it, and the defect shipped: an
    //! installed bundle built from f44f89a, launched with `open`, refused the first sentence
    //! typed into it with "no active thread, and no entity was named", and wrote nothing to
    //! the ledger. `resolve_boot_entity` takes all four inputs as arguments for exactly this
    //! reason.
    //!
    //! A unit test still does not close it — see
    //! `docs/verification/entity-choice-2026-09-01/` for the real double-click either side.

    use super::*;
    use richos_core::config::ConfigStore;
    use std::path::Path;

    fn reg() -> EntityRegistry {
        EntityRegistry::ceos_companies()
    }

    fn id(s: &str) -> EntityId {
        EntityId::parse(s).unwrap()
    }

    /// A ledger of its own per test, so no two share a file.
    fn spine_for(tag: &str) -> (Spine, PathBuf) {
        let path = std::env::temp_dir().join(format!(
            "richos-company-{tag}-{}-{}.jsonl",
            std::process::id(),
            richos_core::util::now_millis()
        ));
        let _ = std::fs::remove_file(&path);
        let ledger = Ledger::open(&path).expect("open ledger");
        (Spine::new(ledger), path)
    }

    // ---- the order -----------------------------------------------------------------------

    #[test]
    fn the_gui_launch_resolves_nothing_and_says_which_root_it_refused() {
        // THE CONDITION THE CEO LAUNCHES IN. `open` hands the process to launchd: working
        // directory `/`, none of a shell's environment, and on a fresh install nothing saved.
        let out = resolve_boot_entity(&reg(), None, None, Some(Path::new("/")));
        assert_eq!(out.entity, None, "`/` owns no entity and must never resolve to one");
        assert_eq!(out.source, None);
        assert!(
            out.notes.iter().any(|n| n.contains("entity not resolved from /")),
            "the refusal must name the root it refused: {:?}",
            out.notes
        );
    }

    #[test]
    fn a_saved_choice_answers_the_launch_the_working_directory_cannot() {
        // THE FIX, in one line: the same launch, after he has answered once.
        let out = resolve_boot_entity(&reg(), None, Some("richos"), Some(Path::new("/")));
        assert_eq!(out.entity, Some(id("richos")));
        assert_eq!(out.source, Some(EntitySource::SavedChoice));
        assert!(out.notes.is_empty(), "a clean resolution has nothing to report: {:?}", out.notes);
    }

    #[test]
    fn the_choice_is_still_in_force_on_the_next_boot_with_the_same_empty_environment() {
        // PERSISTENCE END TO END, and deliberately not two halves that agree in memory: the
        // store is opened, written, DROPPED, and reopened, and the reopened store is what the
        // resolver is handed — under the GUI condition, which is the only one that matters.
        let path = std::env::temp_dir().join(format!(
            "richos-company-boot-{}-{}.json",
            std::process::id(),
            richos_core::util::now_millis()
        ));
        let _ = std::fs::remove_file(&path);
        {
            let mut store = ConfigStore::open(&path).unwrap();
            let first = resolve_boot_entity(&reg(), None, store.entity_raw(), Some(Path::new("/")));
            assert_eq!(first.entity, None, "before he answers, the launch resolves nothing");
            store.set_entity(&id("deeply")).unwrap();
        }
        let reopened = ConfigStore::open(&path).unwrap();
        let second = resolve_boot_entity(&reg(), None, reopened.entity_raw(), Some(Path::new("/")));
        assert_eq!(second.entity, Some(id("deeply")));
        assert_eq!(second.source, Some(EntitySource::SavedChoice));
        std::fs::remove_file(&path).ok();
    }

    #[test]
    fn an_explicit_environment_value_outranks_a_saved_choice() {
        let out = resolve_boot_entity(&reg(), Some("deeply"), Some("richos"), Some(Path::new("/")));
        assert_eq!(out.entity, Some(id("deeply")));
        assert_eq!(out.source, Some(EntitySource::Environment));
    }

    #[test]
    fn an_unregistered_environment_value_refuses_and_never_falls_through() {
        // Someone who names an entity MEANT it. Quietly resolving a different one — the saved
        // choice, or the working directory — would be worse than stopping, so this refuses
        // even though both of the steps below it would have answered.
        let out = resolve_boot_entity(
            &reg(),
            Some("acme"),
            Some("richos"),
            Some(Path::new("/Users/alex/ab/femcboost")),
        );
        assert_eq!(out.entity, None);
        assert_eq!(out.source, None);
        assert!(out.notes.iter().any(|n| n.contains("RICHOS_ENTITY")), "{:?}", out.notes);
    }

    #[test]
    fn a_stale_saved_choice_is_named_and_falls_through_to_containment() {
        // A saved value that no longer resolves is STALE DATA, not a statement — so unlike
        // the environment it does not short-circuit. It falls through to the deterministic
        // step, and it is named rather than dropped: the CEO believes he has answered.
        let out = resolve_boot_entity(
            &reg(),
            None,
            Some("acme"),
            Some(Path::new("/Users/alex/ab/deeply/src")),
        );
        assert_eq!(out.entity, Some(id("deeply")));
        assert_eq!(out.source, Some(EntitySource::WorkingDirectory));
        assert!(
            out.notes.iter().any(|n| n.contains("\"acme\"")),
            "a discarded saved company must be named: {:?}",
            out.notes
        );
    }

    #[test]
    fn the_dogfood_working_directory_behaves_exactly_as_it_did() {
        // STEP 3 IS UNCHANGED, and this is the guard on that claim. Every dogfood launch has
        // an empty `entity` key — it did not exist before this pass — so step 2 is absent and
        // containment answers, as it always has.
        for (dir, want) in [
            ("/Users/alex/ab/femcboost", "femcboost"),
            ("/Users/alex/ab/richos/app/crates/richos-core", "richos"),
            ("/Users/alex/ab/prospects", "prospects"),
        ] {
            let out = resolve_boot_entity(&reg(), None, None, Some(Path::new(dir)));
            assert_eq!(out.entity, Some(id(want)), "{dir} should resolve to {want}");
            assert_eq!(out.source, Some(EntitySource::WorkingDirectory));
        }
    }

    #[test]
    fn a_launch_with_no_working_directory_at_all_still_fails_closed() {
        let out = resolve_boot_entity(&reg(), None, None, None);
        assert_eq!(out.entity, None);
        assert_eq!(out.source, None);
    }

    // ---- the refusal, which is not weakened -----------------------------------------------

    #[test]
    fn nothing_chosen_and_nothing_resolved_still_refuses_every_send() {
        // THE INVARIANT THIS PASS MUST NOT BREAK. The fix is that he can always REACH a
        // company — never that an unresolved one is allowed through. With nothing resolved
        // the spine has no active context, and both the read path and the write path refuse.
        let (mut spine, path) = spine_for("refuse");
        let boot = resolve_boot_entity(&reg(), None, None, Some(Path::new("/")));
        assert!(boot.entity.is_none());

        assert!(spine.active_thread().is_none(), "boot must not conjure a thread out of nowhere");
        assert!(spine.active_binding().is_none());
        let refused = spine.submit_prompt("file this somewhere", Source::Text);
        assert!(refused.is_err(), "a send with no company must be refused, not filed");
        assert!(
            refused.unwrap_err().to_string().contains("no active thread"),
            "the refusal must be the NoActiveThread one, not something that half-worked"
        );
        std::fs::remove_file(&path).ok();
    }

    // ---- answering it ----------------------------------------------------------------------

    #[test]
    fn choosing_a_company_puts_him_in_a_thread_without_a_relaunch() {
        let (mut spine, path) = spine_for("choose");
        assert!(spine.active_thread().is_none());
        apply_company_choice(&mut spine, &id("richos")).unwrap();
        let binding = spine.active_binding().expect("a company was chosen, so a thread is open");
        assert_eq!(binding.entity_id(), &id("richos"));
        // ...and the send that was refused a moment ago now lands in the ledger.
        let thread = spine.active_thread().unwrap().to_string();
        assert!(spine.messages(&thread).is_ok());
        std::fs::remove_file(&path).ok();
    }

    #[test]
    fn changing_the_company_never_rehomes_or_leaves_an_open_conversation() {
        // ECS §3.2: a thread's home is immutable. Changing the SETTING governs new work; the
        // conversation he is reading does not move and he is not moved out of it.
        let (mut spine, path) = spine_for("rehome");
        let first = spine.create_thread("Acme deal", &id("femcboost")).unwrap();
        spine.switch_thread(&first).unwrap();
        let before = spine.active_binding().unwrap().clone();

        apply_company_choice(&mut spine, &id("deeply")).unwrap();

        let after = spine.active_binding().unwrap();
        assert_eq!(after.thread_id(), first, "the open conversation was switched out from under him");
        assert_eq!(after.entity_id(), &id("femcboost"), "the thread was re-homed — ECS §3.2 forbids it");
        assert_eq!(after.binding_revision(), before.binding_revision(), "the binding was reissued for nothing");
        // And the durable record still says femcboost, not deeply.
        assert_eq!(
            spine.ledger().thread_binding(&first).unwrap().entity_id(),
            &id("femcboost")
        );
        std::fs::remove_file(&path).ok();
    }

    #[test]
    fn an_unregistered_company_is_refused_rather_than_invented() {
        let (mut spine, path) = spine_for("unknown");
        let err = apply_company_choice(&mut spine, &id("acme")).unwrap_err();
        assert!(err.contains("unknown entity"), "{err}");
        assert!(spine.active_thread().is_none(), "a refused choice must not open anything");
        std::fs::remove_file(&path).ok();
    }
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

        // Every registered entity gets its own top-level group (§25 Navigation #1) — SIX
        // since 2026-09-01, when the registry stopped being four directory names and
        // became the CEO's own list. Read off the registry rather than retyped: a nav test
        // that hard-codes the roster fails the day a company is added, which is a true
        // failure worth exactly one line, not a second place to keep the list.
        let ids: Vec<String> = tree.groups.iter().map(|g| g.entity.id.clone()).collect();
        let expected: Vec<String> =
            EntityRegistry::ceos_companies().entities().iter().map(|e| e.id.to_string()).collect();
        assert_eq!(ids, expected);
        assert_eq!(ids.len(), 6, "the CEO named six companies on 2026-09-01");

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
    /// SEEDED, NOT ASSUMED. The shipping registry is `EntityRegistry::ceos_companies()` — SIX
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
/// turn — one turn at a time, and the continuity design's turn-boundary
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
    state.correction.lock().unwrap().is_some()
}

/// The desk, or the sentence explaining why there is not one.
///
/// **The refusal NAMES WHAT WAS LOOKED FOR**, which it did not until 2026-09-01, because
/// until then it was almost never reached honestly: the writer was built from environment
/// variables a Finder launch does not have, so on the installed app this branch fired on
/// every call and said only that no corpus was "configured" — a word that is false when the
/// corpus is sitting at a path the app simply never looked at. A confirm that quietly writes
/// nothing is worse than a refusal, and a refusal that cannot say where it looked is barely
/// better than the silence.
///
/// The candidate list comes from `MemoryStatus`, which is the same resolution the boot line
/// printed — not a second guess about it.
/// It returns the `Arc` and not a guard, and the caller locks. That is forced by the field
/// having become swappable: a guard borrowed out of `state.correction` would hold the OUTER
/// lock for the whole of a `confirm`, and a confirm runs `loro-write` as a child process.
/// `loro_available` would then block behind it, and so would `provision_memory`. Cloning the
/// `Arc` and dropping the outer guard on the way out costs one refcount and keeps the two
/// locks strictly nested rather than held as a pair.
fn desk(state: &State<AppState>) -> Result<SharedCorrectionDesk, String> {
    let held = state.correction.lock().unwrap().clone();
    held.ok_or_else(|| {
        let status = state.memory.lock().unwrap().clone();
        let mut msg = String::from(LORO_DESK_ABSENT_MESSAGE);
        if !status.tried.is_empty() {
            msg.push_str("\n\nLooked for it in:");
            for t in &status.tried {
                msg.push_str("\n  • ");
                msg.push_str(t);
            }
        }
        msg
    })
}

/// "What does loro actually believe?" — the answer is a file. Read-only; no proposal, no
/// confirmation, because reading is not correcting.
#[tauri::command]
fn loro_show_record(state: State<AppState>, record_ref: String) -> Result<WriteOutput, String> {
    desk(&state)?.lock().unwrap().show(&record_ref).map_err(|e| e.to_string())
}

/// Corrections waiting on the CEO, for the entity this launch is bound to. Scoped, not
/// global: a proposal about one entity's memory has no business in another's queue.
#[tauri::command]
fn loro_pending_corrections(state: State<AppState>) -> Result<Vec<Proposal>, String> {
    let entity = state.entity.lock().unwrap().clone().ok_or_else(|| ENTITY_UNRESOLVED_MESSAGE.to_string())?;
    Ok(desk(&state)?.lock().unwrap().pending_for(entity.as_str()).into_iter().cloned().collect())
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
    let entity = state.entity.lock().unwrap().clone().ok_or_else(|| ENTITY_UNRESOLVED_MESSAGE.to_string())?;
    // The thread id is PROVENANCE and comes from the caller. It is deliberately not read
    // off the spine: `send_message` holds that lock for the whole of a turn, so asking the
    // spine which thread is active would freeze a correction panel until Rich finished —
    // the same reason the stop control lives outside the lock (UX §9.3).
    let thread_id = thread_id.unwrap_or_default();
    desk(&state)?.lock().unwrap().propose(entity.as_str(), &thread_id, write, &why).map_err(|e| e.to_string())
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
    let entity = state.entity.lock().unwrap().clone().ok_or_else(|| ENTITY_UNRESOLVED_MESSAGE.to_string())?;
    let done = desk(&state)?.lock().unwrap().confirm(entity.as_str(), &id).map_err(|e| e.to_string())?;
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
    desk(&state)?.lock().unwrap().decline(&id, permanent).map_err(|e| e.to_string())
}

/// The suppression list, inspectable — §7 requires it, "or a term silently refuses to
/// learn with no way to see why".
#[tauri::command]
fn loro_suppressed_records(state: State<AppState>) -> Result<Vec<String>, String> {
    Ok(desk(&state)?.lock().unwrap().suppressed().to_vec())
}

/// ...and liftable. A list you can see and cannot clear is only half of inspectable.
#[tauri::command]
fn loro_unsuppress_record(state: State<AppState>, record_ref: String) -> Result<(), String> {
    desk(&state)?.lock().unwrap().unsuppress(&record_ref).map_err(|e| e.to_string())
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
    // PUMP, THEN READ (techy-mode §1.5). Between-turn traffic is parked by the reader
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


// ---------------------------------------------------------------------------------------
// THE LAUNCH RECORD — the shell's half
//
// CEO ruling 2026-08-31 (`richos-hq/wiki/gamification.md` § "Splash tracking"). The model
// itself, and every word of why, is in `richos_core::launch`; this layer does three things
// and nothing else: it tells the webview what kind of start this is BEFORE the opening
// screen decides whether to draw, it hands the record's contents to a caller that asks, and
// it takes the id of a splash that was actually shown.
//
// NOTHING HERE IS ON THE LAUNCH PATH. The classification and the window are built in
// `setup()` above (see the block comment there); the two commands below are called after
// the app is usable, from the same "dead last on purpose" tail of `main.js` that already
// carries the splash's other bookkeeping.
// ---------------------------------------------------------------------------------------

/// The one line injected into every window before any of its own scripts run.
///
/// A literal object, not a command the page has to call: `splash.js` runs synchronously at
/// the top of `<body>` and cannot await anything, and a splash that appeared on a
/// crash-restart because the answer arrived a tick late would be exactly the wrong ceremony
/// at exactly the wrong moment.
///
/// `Object.freeze` because this is a statement of fact about how the app started, and a
/// later script that could edit it could make a crash-restart claim to be a fresh launch.
///
/// `ordinal` is WHICH START THIS IS, 1-based, and the CEO's v1 splash rule is a table over
/// it: first start shows #1, second shows #2, third and after show #1. It rides here for
/// exactly the same reason `kind` does — `splash.js` chooses on its first synchronous line
/// and cannot await a command — and it is `null` rather than a guess whenever
/// `LaunchStore::start_ordinal` could not honestly name one.
fn launch_init_script(kind: LaunchKind, ordinal: Option<u64>) -> String {
    format!(
        "window.__RICHOS_LAUNCH__ = Object.freeze({{ kind: {:?}, ordinal: {} }});",
        kind.as_str(),
        ordinal.map(|n| n.to_string()).unwrap_or_else(|| "null".to_string())
    )
}

/// The whole record, for a caller that supplies its own UTC offset.
///
/// **The offset is a PARAMETER and not read here**, and that is the design and not a
/// shortcut: the CEO ruled that timestamps are stored in UTC and bucketed against his LOCAL
/// calendar, and the only place in this process that knows what local means is the webview
/// (`-new Date().getTimezoneOffset()`). Reading a timezone in Rust would need a fifth
/// dependency in a crate whose "nothing can reach off this machine" guarantee rests on
/// having four.
#[derive(serde::Serialize)]
#[serde(rename_all = "camelCase")]
struct LaunchStateView {
    /// `"fresh"`, `"crash-restart"` or `"second-window"` — the run's kind, not this
    /// window's. Windows are classified at creation, in `setup()`.
    kind: Option<String>,
    /// `None` when the record on disk could not be read. A zero is a claim about his
    /// history and this refuses to make one it cannot support.
    counts: Option<LaunchCounts>,
    /// First-run marker, epoch millis. Every milestone measured in days is measured from it.
    installed_at: Option<u64>,
    /// The last few splash ids shown, most recent first.
    recent_splashes: Vec<String>,
    /// False when the file on disk exists and this build does not understand it. Nothing is
    /// written in that state.
    readable: bool,
    schema_version: u32,
}

/// Read the launch record. `utc_offset_minutes` is positive east — the NEGATION of
/// JavaScript's `getTimezoneOffset()`, so US Pacific daylight time is `-420`.
#[tauri::command]
fn launch_state(state: State<AppState>, utc_offset_minutes: i32) -> LaunchStateView {
    let launch = state.launch.lock().unwrap();
    LaunchStateView {
        kind: launch.run_kind().map(|k| k.as_str().to_string()),
        counts: launch.counts(richos_core::util::now_millis(), utc_offset_minutes),
        installed_at: launch.installed_at(),
        recent_splashes: launch.recent_splashes().to_vec(),
        readable: launch.readable(),
        schema_version: launch.schema_version(),
    }
}

/// Record that a splash was actually shown, onto the front of the recency ring.
///
/// Called by the surface that drew it, so the ring holds what was on screen rather than
/// what was chosen — the two differ whenever a draw is made and the render then declines
/// (`splash.js` has three such paths, and all three leave `state.shown` false).
#[tauri::command]
fn launch_note_splash_shown(state: State<AppState>, id: String) -> Result<(), String> {
    state.launch.lock().unwrap().note_splash_shown(&id).map_err(|e| e.to_string())
}

// ---------------------------------------------------------------------------------------
// THE HOME SCREEN'S ENTITY ROW (CEO, 2026-09-01)
//
// His words, in the order he gave them:
//
//   "At the very top there should be a slim row with buttons named after the user's
//    entities/companies. For RichOS v1 those buttons don't need to do anything. But
//    eventually the user should be able to 'switch' their loro visual from all companies
//    (which is default) to display the loro for just one of their companies."
//
//   "the company buttons should only appear if the user has more than one company. Not if
//    there's only one. And the user should also be able to customize in the settings the
//    labels on those company buttons and well as which to display on their home screen.
//    So, if the user wanted to anonymize their home screen (for sharing on social media),
//    they could change the label buttons to something like '1', '2', '3' etc."
//
// THREE PROPERTIES THIS LAYER HAS AND MUST KEEP:
//
//   1. **The names come from the REGISTRY.** `EntityRegistry::ceos_companies()` through the
//      spine, in registry order, never filtered and never re-sorted — the same source the
//      company picker reads. A list typed into the UI would be wrong the day he adds a
//      company, and `richos` is ONE entity with two roots, which only the registry knows.
//   2. **A label is a MASK, never a rename.** `id` on the wire is always the registry's id;
//      `label` is what the button says. Nothing downstream keys on `label`, and
//      `config.rs`'s own test `a_label_is_a_mask_and_never_a_rename` is what holds that.
//   3. **An absent override is the registry's display name.** Never blank, never the raw id.
//      That is decided HERE, in `resolve`, so no surface can get it wrong on its own.
//
// WHAT IS DELIBERATELY NOT HERE: any effect on the picture. He was explicit that the buttons
// do nothing in v1, and filtering the field by entity is later work. What IS real is the
// label and the visibility, because those are what he would use before the filtering exists.
// ---------------------------------------------------------------------------------------

/// One button in the home screen's row, resolved.
#[derive(serde::Serialize)]
struct HomeEntityView {
    /// The registry's id. This is the identity and it is never affected by a label.
    id: String,
    /// The registry's own name for the company, so a surface can offer "back to the real
    /// name" without a second round trip.
    display_name: String,
    /// What the button SAYS: his override if he set one, otherwise `display_name`.
    label: String,
    /// His override on its own, or `None` when he has not set one. The settings surface
    /// needs the difference — a field pre-filled with the registry name looks like an
    /// override he made, and clearing it would then be indistinguishable from leaving it.
    custom_label: Option<String>,
    /// Whether this company appears in the row. Absent opinion means yes.
    visible: bool,
}

/// The row, resolved and in registry order.
///
/// **The "only if more than one" rule is NOT applied here**, and that is deliberate: this
/// command reports what IS, and the settings surface has to list every company — including
/// the ones he has hidden — or he could never unhide one. The count that decides whether the
/// home screen draws a row at all is `visible`, and the home screen applies it.
#[tauri::command]
fn home_entity_row(state: State<AppState>) -> Vec<HomeEntityView> {
    // Lock order, everywhere in this file: config, then entity, then spine.
    let config = state.config.lock().unwrap();
    let spine = state.spine.lock().unwrap();
    spine
        .entity_registry()
        .entities()
        .iter()
        .map(|e| {
            let id = e.id.to_string();
            let custom = config.home_entity_label(&id).map(|s| s.to_string());
            HomeEntityView {
                label: custom.clone().unwrap_or_else(|| e.display_name.clone()),
                visible: config.home_entity_visible(&id),
                display_name: e.display_name.clone(),
                custom_label: custom,
                id,
            }
        })
        .collect()
}

/// Set (or clear) his own label for one company.
///
/// `None` or an all-whitespace string CLEARS the override and the button goes back to the
/// registry's name. That is not a convenience: it is how he un-anonymizes the screen, and a
/// one-way override would have made an anonymized home screen permanent.
///
/// It REFUSES an unregistered id rather than storing a key nothing will ever read — the same
/// fail-closed posture `choose_entity` takes, and for the same reason.
#[tauri::command]
fn set_home_entity_label(
    state: State<AppState>,
    entity_id: String,
    label: Option<String>,
) -> Result<Vec<HomeEntityView>, String> {
    let id = registered_entity(&entity_id)?;
    state
        .config
        .lock()
        .unwrap()
        .set_home_entity_label(id.as_str(), label.as_deref())
        .map_err(|e| format!("I couldn't write that down, so I haven't changed the button: {e}"))?;
    Ok(home_entity_row(state))
}

/// Show or hide one company in the home screen's row. Display only — the company, its
/// threads and its records are untouched, and it is still everywhere else in the app.
#[tauri::command]
fn set_home_entity_visible(
    state: State<AppState>,
    entity_id: String,
    visible: bool,
) -> Result<Vec<HomeEntityView>, String> {
    let id = registered_entity(&entity_id)?;
    state
        .config
        .lock()
        .unwrap()
        .set_home_entity_visible(id.as_str(), visible)
        .map_err(|e| format!("I couldn't write that down, so I haven't changed the row: {e}"))?;
    Ok(home_entity_row(state))
}

/// Parse and check an id against the registry, or refuse with the sentence the CEO reads.
/// Shared by both setters so the two cannot drift apart on what they accept. It reads the
/// registry as a CONSTANT rather than through the spine: `ceos_companies` is compiled in and
/// asking for the spine lock here would put a settings write behind a running turn.
fn registered_entity(entity_id: &str) -> Result<EntityId, String> {
    let id = EntityId::parse(entity_id.trim()).map_err(|_| unknown_company_message(entity_id.trim()))?;
    if !EntityRegistry::ceos_companies().contains(&id) {
        return Err(unknown_company_message(id.as_str()));
    }
    Ok(id)
}
