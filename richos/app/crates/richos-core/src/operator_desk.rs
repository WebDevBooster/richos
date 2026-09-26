//! THE OPERATOR DESK — his team, wired into the running app (operator back-end spec r3 (g),
//! (d), (m), (o), (q), (s), with r4 winning where they differ; the app side's record, richos-hq
//! `docs/verification/2026-09-25-operator-client/README.md` §7 items 1-3).
//!
//! **What it is for, in his words.** §86: *"Your setup as-is"* — his existing team runs behind
//! the app, so the app can be his daily driver instead of the terminal. `operator_host.rs`
//! decides how one lead per conversation is driven. This file is what the SHELL holds: it takes
//! each assignment the front desk writes down and hands it to that conversation's lead instead
//! of a work lease, it carries his stops, his Esc and his reads to the host, it retires idle
//! leads on a timer, and it ends his team at quit.
//!
//! **Operator mode is decided once, at launch.** The shell builds a desk only when
//! `operator.json` passed the gate as the app started, so an install without the file runs the
//! product path byte for byte (N1). After launch the gate is read again for every assignment,
//! and a declaration that broke, changed or disappeared refuses the assignment in one sentence.
//! **Nothing here ever falls back to the customer's work lease** (Frank's B8): a present
//! declaration never becomes the product path by accident, and a declaration that appears after
//! launch is refused by the shell's own gate arm (`spawn_work`), never half-honored.
//!
//! **The rules, each a test in this file:**
//!
//! 1. **An assignment is relayed with its handle, his own words, and the origin the ledger
//!    recorded for the turn that gave it** (item 3: the host receives `Origin` from the spine,
//!    not from the walk). Words the register's digest does not attest are never relayed, the
//!    product's own rule (`work_host.rs` `instruction_for`: *"The original request could not
//!    be verified. Nothing was started."*).
//! 2. **Relayed off the caller's thread.** A lead's first start (claim, process, handshake) is
//!    seconds; it never sits inside his send. Order within the desk is kept.
//! 3. **Work from a mouth that is not listed, or never recorded, is not relayed** ((s) rules 1
//!    and 4), and the assignment is closed with the sentence, its obligation withdrawn.
//! 4. **The gate is re-read per assignment**: broken, changed or gone refuses; never a fallback.
//! 5. **The per-assignment Stop stops exactly that assignment's agents** ((d) item 5) and says
//!    so; it marks the assignment stopped only when every one of them is NOT-ALIVE.
//! 6. **Quit ends every lead by the quit path, then releases the claim, once** ((q) item 2, e
//!    item 3); nothing is taken after it.
//! 7. **A lead with nothing running is retired on a timer** ((q) item 4), and the timer spends
//!    nothing while no lead runs.
use crate::assignment::{self, Assignment, AssignmentState, NoticeKind};
use crate::ledger::Source;
use crate::operator_declaration::{Declaration, Gate};
use crate::operator_host::{ConversationKey, ConversationRead, Lane, LeadLauncher, OperatorDelivery, OperatorEngine,
                           OperatorHost, Origin, Relayed, Say, SayQuestions, Settle, StopResult, TeamReading, LEAD_IDLE};
use crate::operator_lead::Quit;
use crate::operator_runtime::{DurableDelivery, NoticePush, OperatorNotice};
use std::collections::VecDeque;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Condvar, Mutex, Weak};
use std::time::{Duration, Instant};

/// What an assignment's record says once his team has it.
pub const HANDED_OVER: &str = "Your team has it.";
/// (s) rule 4 as it applies to an assignment: its turn's mouth was never recorded.
pub const NO_ORIGIN_WORK: &str =
    "I can't tell where this was asked from, so I didn't hand it to your team. Ask me again at your desk.";
/// The turn the register names is not in the ledger, or its words are not the ones the
/// register attested.
pub const UNVERIFIED: &str = "I couldn't confirm your original words, so I didn't hand this to your team. Ask me again.";
/// The declaration on disk is no longer the one this launch opened his team with.
pub const CHANGED_SINCE_LAUNCH: &str = "Your team's settings changed after RichOS started, so I didn't hand this to \
                                         your team. Quit RichOS and open it again, then ask me again.";
/// The declaration is gone since launch.
pub const OFF_SINCE_LAUNCH: &str = "Your team was switched off after RichOS started, so I didn't hand this to your \
                                     team. Quit RichOS and open it again, then ask me again.";
/// Quit has begun.
pub const CLOSING: &str = "RichOS is closing, so I didn't hand this to your team.";
/// The per-assignment Stop found no agent on that assignment.
pub const NOTHING_ON_IT: &str = "None of your team's agents is working on this one. To stop what your team is \
                                  doing in this conversation, press Stop there.";
/// What the engine records as his words for a Stop pressed on an assignment, where there are
/// no spoken words to carry (`stop.sh --ceo-word`, `workspaces.sh stop --why`).
pub const STOP_CONTROL_WORDS: &str = "Stop, pressed on this assignment in RichOS";
/// How often the idle timer looks. A lead is retired after [`LEAD_IDLE`]; a minute's lag on a
/// thirty-minute period is the cost of not waking more often.
pub const RETIRE_EVERY: Duration = Duration::from_secs(60);
/// How long quit waits for a hand-over already under way (a lead mid-start) before it ends
/// every lead, so a lead that finishes starting after quit began is still ended by it.
const QUIT_WAITS_FOR_HAND_OVER: Duration = Duration::from_secs(45);
/// The ECS store's status for a withdrawn obligation (zach's contract §2.5).
const ECS_WITHDRAWN: &str = "cancelled"; // dialect-exempt: the ECS store's own protocol literal, engine-rest-2026-09-25.md §2.5

/// What the ledger recorded of the turn an assignment was given in.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct TurnFacts {
    pub source: Source,
    /// `Turn::channel`: the mouth, or `None` when it was never recorded.
    pub channel: Option<String>,
    /// His words, exactly as the ledger holds them.
    pub text: String,
}

/// The spine's side of the desk, read WITHOUT the spine's lock (the shell reads its
/// `SpineReader` snapshot): the lock is held for whole turns, and a relay must not wait on one.
pub trait TurnOrigins: Send + Sync {
    /// The turn an assignment's `instruction_ledger_ref` (`ledger:<thread>:<turn>`) names.
    fn turn(&self, ledger_ref: &str) -> Option<TurnFacts>;
    /// The conversation's title, which the claim and the land lease name its lead by.
    fn title(&self, thread_id: &str) -> Option<String>;
}

/// The turn id a register reference names, when it is in the register's own shape.
pub fn turn_of_ledger_ref(ledger_ref: &str) -> Option<&str> {
    let rest = ledger_ref.strip_prefix("ledger:")?;
    let (_thread, turn) = rest.split_once(':')?;
    (!turn.is_empty()).then_some(turn)
}

/// Everything the desk is given. The shell passes the real ones ([`OperatorDesk::for_app`]);
/// the tests pass fakes.
pub struct DeskParts {
    pub launcher: Arc<dyn LeadLauncher>,
    /// Gives the claim up at quit, after every lead has quit ([`crate::operator_runtime::ProfileLauncher::release`]).
    pub release: Box<dyn Fn() + Send + Sync>,
    pub engine: Arc<dyn OperatorEngine>,
    pub settle: Arc<dyn Settle>,
    /// A live surface to push each notice to as it is said (the webview), when there is one.
    pub push: Option<NoticePush>,
    pub origins: Arc<dyn TurnOrigins>,
    /// The declaration gate, read again for every assignment.
    pub gate: Box<dyn Fn() -> Gate + Send + Sync>,
}

/// The assignments waiting to be handed over, served by one thread so their order holds.
struct Inbox {
    state: Mutex<InboxState>,
    wake: Condvar,
}

struct InboxState {
    items: VecDeque<Assignment>,
    busy: bool,
    closing: bool,
}

pub struct OperatorDesk {
    declaration: Declaration,
    state_root: PathBuf,
    host: Arc<OperatorHost>,
    delivery: Arc<DurableDelivery>,
    settle: Arc<dyn Settle>,
    origins: Arc<dyn TurnOrigins>,
    gate: Box<dyn Fn() -> Gate + Send + Sync>,
    release: Box<dyn Fn() + Send + Sync>,
    inbox: Arc<Inbox>,
    quit: Mutex<bool>,
}

impl Drop for OperatorDesk {
    fn drop(&mut self) {
        self.inbox.state.lock().unwrap().closing = true;
        self.inbox.wake.notify_all();
    }
}

impl OperatorDesk {
    /// A desk over `<data_dir>/engine-state` (the register) and `<data_dir>/operator` (his
    /// team's files), with the thread that hands assignments over already running.
    pub fn new(declaration: Declaration, data_dir: &Path, parts: DeskParts) -> Arc<Self> {
        let state_root = data_dir.join("engine-state");
        let root = data_dir.join("operator");
        let delivery = Arc::new(DurableDelivery::new(&root, parts.push));
        let said: Arc<dyn OperatorDelivery> = delivery.clone();
        let host = OperatorHost::new(declaration.clone(), &state_root, &root, parts.launcher, parts.engine,
                                     parts.settle.clone(), said.clone(), Arc::new(SayQuestions(said)));
        let inbox = Arc::new(Inbox { state: Mutex::new(InboxState { items: VecDeque::new(), busy: false, closing: false }),
                                     wake: Condvar::new() });
        let desk = Arc::new(OperatorDesk {
            declaration, state_root, host, delivery, settle: parts.settle, origins: parts.origins, gate: parts.gate,
            release: parts.release, inbox: inbox.clone(), quit: Mutex::new(false),
        });
        let weak = Arc::downgrade(&desk);
        let spawned = std::thread::Builder::new()
            .name("richos-operator-desk".into())
            .spawn(move || Self::hand_over_loop(inbox, weak));
        if let Err(e) = spawned {
            desk.host.log(&format!("the desk's hand-over thread could not start ({e}); assignments will be refused"));
            desk.inbox.state.lock().unwrap().closing = true;
        }
        desk
    }

    /// The desk the app runs: his engine's scripts from the declared root, the launcher with
    /// the claim, and the gate read from this install's data folder.
    pub fn for_app(declaration: Declaration, data_dir: &Path, executable: &Path, settle: Arc<dyn Settle>,
                   origins: Arc<dyn TurnOrigins>, push: Option<NoticePush>,
                   route: Arc<dyn crate::operator_lead::ControlRoute>) -> Arc<Self> {
        let state_root = data_dir.join("engine-state");
        let log = data_dir.join("operator").join("operator.log");
        let launcher = Arc::new(crate::operator_runtime::ProfileLauncher::new(declaration.clone(), executable, &state_root,
                                                                               &log, route));
        let releaser = launcher.clone();
        let gate_dir = data_dir.to_path_buf();
        Self::new(declaration.clone(), data_dir, DeskParts {
            launcher,
            release: Box::new(move || releaser.release()),
            engine: Arc::new(crate::operator_runtime::EngineScripts::new(declaration)),
            settle,
            push,
            origins,
            gate: Box::new(move || crate::operator_declaration::gate(&gate_dir)),
        })
    }

    fn hand_over_loop(inbox: Arc<Inbox>, desk: Weak<OperatorDesk>) {
        loop {
            let next = {
                let mut state = inbox.state.lock().unwrap();
                loop {
                    if state.closing {
                        return;
                    }
                    if let Some(item) = state.items.pop_front() {
                        state.busy = true;
                        break item;
                    }
                    state = inbox.wake.wait(state).unwrap();
                }
            };
            match desk.upgrade() {
                Some(desk) => desk.hand_over(&next),
                None => return,
            }
            inbox.state.lock().unwrap().busy = false;
            inbox.wake.notify_all();
        }
    }

    /// **Take one assignment the front desk wrote down** (item 1): queued for the hand-over
    /// thread and returned at once. After quit it is refused, never queued.
    pub fn take(&self, record: Assignment) {
        let mut state = self.inbox.state.lock().unwrap();
        if state.closing {
            drop(state);
            self.close(&record, CLOSING);
            return;
        }
        state.items.push_back(record);
        self.inbox.wake.notify_all();
    }

    /// Wait until nothing is waiting or being handed over, for at most `limit`. `true` when
    /// quiet. The walk and the tests use it; the app never needs to.
    pub fn wait_quiet(&self, limit: Duration) -> bool {
        let deadline = Instant::now() + limit;
        let mut state = self.inbox.state.lock().unwrap();
        while !state.items.is_empty() || state.busy {
            let now = Instant::now();
            if now >= deadline {
                return false;
            }
            state = self.inbox.wake.wait_timeout(state, deadline - now).unwrap().0;
        }
        true
    }

    /// Why the gate refuses this assignment now, or `None` when it is the declaration this
    /// launch opened his team with.
    fn gate_refusal(&self) -> Option<String> {
        match (self.gate)() {
            Gate::Operator(declaration) if *declaration == self.declaration => None,
            Gate::Operator(_) => Some(CHANGED_SINCE_LAUNCH.into()),
            Gate::Refused(refusal) => Some(refusal.sentence()),
            Gate::Product => Some(OFF_SINCE_LAUNCH.into()),
        }
    }

    fn hand_over(&self, record: &Assignment) {
        if let Some(sentence) = self.gate_refusal() {
            self.close(record, &sentence);
            return;
        }
        let key = key_of(record);
        let Some(facts) = self.origins.turn(&record.instruction_ledger_ref).filter(|f| attested(record, f)) else {
            self.close(record, UNVERIFIED);
            return;
        };
        let origin = Origin::of_turn(facts.source, facts.channel.as_deref());
        let title = self.origins.title(&record.thread_id).unwrap_or_default();
        let text = format!("{}\n\nHis words, exactly as he said them:\n{}", record.title, facts.text);
        match self.host.relay(&key, &title, Some(&record.id), &text, origin) {
            Ok(Relayed::Sent { .. }) => {
                if let Err(e) = assignment::advance(&self.state_root, &record.entity_id, &record.thread_id, &record.id,
                                                    AssignmentState::Running, HANDED_OVER) {
                    self.host.log(&format!("{} was handed to his team; its record could not say so ({e})", record.id));
                }
            }
            Ok(Relayed::Not { sentence }) => self.close(record, sentence.as_deref().unwrap_or(NO_ORIGIN_WORK)),
            Err(sentence) => self.close(record, &sentence),
        }
    }

    /// Close an assignment his team will not get: its record says why, the sentence is raised
    /// on it, and its obligation is withdrawn with the sentence as the answer. Each failure is
    /// logged, never passed over.
    fn close(&self, record: &Assignment, sentence: &str) {
        self.host.log(&format!("{} not handed to his team: {sentence}", record.id));
        if let Err(e) = assignment::advance(&self.state_root, &record.entity_id, &record.thread_id, &record.id,
                                            AssignmentState::Failed, sentence)
            .and_then(|_| assignment::raise_notice(&self.state_root, &record.entity_id, &record.thread_id, &record.id,
                                                   NoticeKind::Failed, sentence)) {
            self.host.log(&format!("{}: its record could not be closed ({e})", record.id));
        }
        use sha2::Digest;
        let evidence = [format!("answer:{:x}", sha2::Sha256::digest(sentence.as_bytes()))];
        if let Err(why) = self.settle.complete(&key_of(record), &record.obligation_id, &format!("operator-refused:{}", record.id),
                                               ECS_WITHDRAWN, &evidence, sentence) {
            self.host.log(&format!("{}: its obligation could not be withdrawn ({why})", record.id));
        }
    }

    // ---- his controls ---------------------------------------------------------------------

    /// **The per-assignment Stop** ((d) item 5): exactly the agents that assignment's turns
    /// started and its reports named. `Err` is the sentence when none is working on it.
    pub fn stop_assignment(&self, entity: &str, thread: &str, id: &str) -> Result<(), String> {
        let key = ConversationKey { entity_id: entity.to_string(), thread_id: thread.to_string() };
        // A button pressed at the Mac. The origin is recorded, never a gate: a stop only removes.
        let results = self.host.stop_assignment(&key, id, STOP_CONTROL_WORDS, Origin::DeskTyped);
        if results.is_empty() {
            return Err(NOTHING_ON_IT.into());
        }
        let sentence = results.iter().map(StopResult::sentence).collect::<Vec<_>>().join(" ");
        self.delivery.say(&key, &Lane::Handle(id.to_string()), Say::Team, &sentence);
        if results.iter().all(|r| matches!(r, StopResult::Stopped { .. })) {
            if let Err(e) = assignment::advance(&self.state_root, entity, thread, id, AssignmentState::Interrupted, &sentence) {
                self.host.log(&format!("{id} was stopped; its record could not say so ({e})"));
            }
        }
        Ok(())
    }

    /// **A named stop, from any channel** ((d) items 1-4 and 7). `ledger_ref` is the turn his
    /// words were spoken in, for the log's origin; it never gates a stop.
    pub fn stop_named(&self, names: &[String], words: &str, ledger_ref: Option<&str>) -> Vec<StopResult> {
        let origin = ledger_ref.and_then(|r| self.origins.turn(r))
            .map_or(Origin::NoOrigin, |f| Origin::of_turn(f.source, f.channel.as_deref()));
        self.host.stop_named(names, words, origin)
    }

    /// **His Esc** ((d) item 6): the lead's turn ends, its agents keep running. The sentence
    /// is said on the conversation and returned.
    pub fn interrupt(&self, key: &ConversationKey) -> String {
        let sentence = self.host.interrupt(key);
        self.delivery.say(key, &Lane::Conversation, Say::Team, &sentence);
        sentence
    }

    /// **The §88 seam, through the desk** (r4 §3): PRD S6's question store calls this with the
    /// resolved answer to a question his team asked, from any channel; `delivery_id` is S6's
    /// durable identity, and the same one twice relays once (the host's rule).
    pub fn deliver_answer(&self, key: &ConversationKey, handle: Option<&str>, delivery_id: &str, answer: &str)
                          -> Result<bool, String> {
        let title = self.origins.title(&key.thread_id).unwrap_or_default();
        self.host.deliver_answer(key, &title, handle, delivery_id, answer)
    }

    /// (o): this conversation's read, or every conversation's.
    pub fn read(&self, key: &ConversationKey, every: bool) -> Vec<ConversationRead> {
        self.host.read(key, every)
    }

    /// (m): what his team is doing, by his engine's resolver, for the update gate.
    pub fn team(&self) -> TeamReading {
        self.host.team()
    }

    /// (m) from the leads' own streams, with no script run: for the app's exit decision, which
    /// runs inside the runtime's callback and must answer at once (the keep-alive, the quit
    /// sheet, the Quit menu).
    pub fn team_from_stream(&self) -> TeamReading {
        self.host.team_from_stream()
    }

    /// Everything said to him on this conversation and not yet taken, oldest first (the seam
    /// the notice surface reads at launch; item 4 is Art's).
    pub fn take_pending(&self, key: &ConversationKey) -> Result<Vec<OperatorNotice>, String> {
        self.delivery.take_pending(key)
    }

    /// (q) item 4, once: retire every idle lead. Spends nothing while no lead runs.
    pub fn retire_idle_now(&self, idle_after: Duration) -> Vec<ConversationKey> {
        if self.host.running_leads() == 0 {
            return Vec::new();
        }
        self.host.retire_idle(idle_after)
    }

    /// Start the idle timer: every `every`, retire the leads idle for `idle_after`, until quit.
    pub fn start_retirement(self: &Arc<Self>, every: Duration, idle_after: Duration) {
        let inbox = self.inbox.clone();
        let desk = Arc::downgrade(self);
        let spawned = std::thread::Builder::new().name("richos-operator-idle".into()).spawn(move || loop {
            {
                let state = inbox.state.lock().unwrap();
                if state.closing {
                    return;
                }
                let (state, _) = inbox.wake.wait_timeout(state, every).unwrap();
                if state.closing {
                    return;
                }
            }
            let Some(desk) = desk.upgrade() else { return };
            let retired = desk.retire_idle_now(idle_after);
            if !retired.is_empty() {
                desk.host.log(&format!("idle timer retired {} lead(s)", retired.len()));
            }
        });
        if let Err(e) = spawned {
            self.host.log(&format!("the idle timer could not start ({e}); idle leads stay until quit"));
        }
    }

    /// Start the idle timer at the spec's period ((q) item 4: [`LEAD_IDLE`]).
    pub fn start_default_retirement(self: &Arc<Self>) {
        self.start_retirement(RETIRE_EVERY, LEAD_IDLE);
    }

    /// **The quit path** ((q) item 2, e item 3): nothing more is taken, a hand-over under way
    /// is let finish (bounded), every lead ends by SIGTERM to its supervisor, and only then is
    /// the claim given up. Once; a second call does nothing.
    pub fn quit(&self) -> Vec<(ConversationKey, Quit)> {
        {
            let mut done = self.quit.lock().unwrap();
            if *done {
                return Vec::new();
            }
            *done = true;
        }
        {
            let mut state = self.inbox.state.lock().unwrap();
            state.closing = true;
            self.inbox.wake.notify_all();
            let deadline = Instant::now() + QUIT_WAITS_FOR_HAND_OVER;
            while state.busy && Instant::now() < deadline {
                state = self.inbox.wake.wait_timeout(state, deadline - Instant::now()).unwrap().0;
            }
        }
        let quits = self.host.quit_all();
        (self.release)();
        quits
    }

    /// The operator log, for a caller that wants to say where to look.
    pub fn log_path(&self) -> PathBuf {
        self.host.log_path()
    }
}

impl crate::work_host::OperatorIntake for OperatorDesk {
    fn take(&self, record: Assignment) {
        OperatorDesk::take(self, record);
    }
    fn stop(&self, entity: &str, thread: &str, id: &str) -> Result<(), String> {
        self.stop_assignment(entity, thread, id)
    }
}

fn key_of(record: &Assignment) -> ConversationKey {
    ConversationKey { entity_id: record.entity_id.clone(), thread_id: record.thread_id.clone() }
}

/// Are these the words the register attested? The register never copies his words; it
/// records their SHA-256 (`assignment_tools.rs`), and only his words in the ledger with that
/// digest, in his own conversation and company, may reach his team.
fn attested(record: &Assignment, facts: &TurnFacts) -> bool {
    use sha2::Digest;
    format!("{:x}", sha2::Sha256::digest(facts.text.as_bytes())) == record.instruction_sha256
}

/// **The origins, read from the conversation ledger on disk** — the same file, the same way,
/// as the product's own check that a request is his (`work_host.rs` `instruction_for`): the
/// spine's lock is held for whole turns, so nothing that runs beside it may take it. A torn last
/// record (a concurrent append) is skipped, never read; a turn named twice, or in another
/// conversation or company than the reference says, is refused.
pub struct LedgerOrigins {
    ledger: PathBuf,
}

impl LedgerOrigins {
    /// `<data_dir>/conversation-ledger.jsonl`.
    pub fn new(ledger: &Path) -> Self {
        LedgerOrigins { ledger: ledger.to_path_buf() }
    }

    fn rows(&self) -> Vec<serde_json::Value> {
        use std::io::BufRead;
        let Ok(file) = std::fs::File::open(&self.ledger) else { return Vec::new() };
        let mut reader = std::io::BufReader::new(file);
        let mut rows = Vec::new();
        let mut line = String::new();
        loop {
            line.clear();
            match reader.read_line(&mut line) {
                Ok(0) | Err(_) => break,
                Ok(_) if !line.ends_with('\n') => break,
                Ok(_) => {
                    if let Ok(row) = serde_json::from_str::<serde_json::Value>(&line) {
                        rows.push(row);
                    }
                }
            }
        }
        rows
    }
}

impl TurnOrigins for LedgerOrigins {
    fn turn(&self, ledger_ref: &str) -> Option<TurnFacts> {
        let rest = ledger_ref.strip_prefix("ledger:")?;
        let (thread, turn) = rest.split_once(':')?;
        let mut found = None;
        for row in self.rows() {
            if row["event"] != "PromptReceived" || row["turn_id"] != turn {
                continue;
            }
            if found.is_some() || row["thread_id"] != thread {
                return None;
            }
            let source: Source = serde_json::from_value(row["source"].clone()).ok()?;
            found = Some(TurnFacts { source, channel: row["channel"].as_str().map(str::to_string),
                                     text: row["text"].as_str()?.to_string() });
        }
        found
    }

    fn title(&self, thread_id: &str) -> Option<String> {
        self.rows().into_iter().find(|r| r["event"] == "ThreadCreated" && r["thread_id"] == thread_id)
            .and_then(|r| r["title"].as_str().map(str::to_string))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::assignment::{AssignmentKind, Registration};
    use crate::operator_host::tests::{agent, declaration, FakeEngine, FakeLauncher, FakeSettle};
    use crate::operator_host::{ConversationPaths, LeadHandle};
    use crate::operator_profile::LeadStart;
    use crate::operator_lead::LeadSink;
    use std::collections::HashMap;

    /// The ledger's side, as a table.
    #[derive(Default)]
    struct FakeOrigins {
        turns: Mutex<HashMap<String, TurnFacts>>,
    }
    impl TurnOrigins for FakeOrigins {
        fn turn(&self, ledger_ref: &str) -> Option<TurnFacts> {
            self.turns.lock().unwrap().get(ledger_ref).cloned()
        }
        fn title(&self, thread_id: &str) -> Option<String> {
            Some(format!("Conversation {thread_id}"))
        }
    }

    /// A launcher that holds every launch until the test lets it go.
    struct HeldLauncher {
        inner: FakeLauncher,
        gate: Mutex<bool>,
        open: Condvar,
        entered: Mutex<usize>,
    }
    impl LeadLauncher for HeldLauncher {
        fn launch(&self, key: &ConversationKey, title: &str, start: &LeadStart, paths: &ConversationPaths,
                  sink: Arc<dyn LeadSink>) -> Result<Arc<dyn LeadHandle>, String> {
            *self.entered.lock().unwrap() += 1;
            let mut open = self.gate.lock().unwrap();
            while !*open {
                open = self.open.wait(open).unwrap();
            }
            self.inner.launch(key, title, start, paths, sink)
        }
        fn fences(&self) -> Result<(), String> { Ok(()) }
    }

    struct Desk {
        root: PathBuf,
        desk: Arc<OperatorDesk>,
        launcher: Arc<FakeLauncher>,
        engine: Arc<FakeEngine>,
        settle: Arc<FakeSettle>,
        origins: Arc<FakeOrigins>,
        mode: Arc<Mutex<&'static str>>,
        released: Arc<Mutex<usize>>,
        state: PathBuf,
    }
    impl Drop for Desk {
        fn drop(&mut self) {
            self.desk.quit();
            if let Err(error) = std::fs::remove_dir_all(&self.root) { eprintln!("fixture cleanup: {error}"); }
        }
    }

    fn desk_with(launcher: Arc<dyn LeadLauncher>, fake: Arc<FakeLauncher>) -> Desk {
        let root = std::env::temp_dir().join(format!("operator-desk-{}", uuid::Uuid::new_v4()));
        let root = { std::fs::create_dir_all(&root).unwrap(); std::fs::canonicalize(&root).unwrap() };
        let declared = declaration(&root, &["desk-typed", "desk-voice", "desk-file"]);
        let engine = Arc::new(FakeEngine::default());
        let settle = Arc::new(FakeSettle::default());
        let origins = Arc::new(FakeOrigins::default());
        let mode = Arc::new(Mutex::new("same"));
        let released = Arc::new(Mutex::new(0));
        let (gate_mode, gate_declaration, counter) = (mode.clone(), declared.clone(), released.clone());
        let desk = OperatorDesk::new(declared.clone(), &root, DeskParts {
            launcher,
            release: Box::new(move || *counter.lock().unwrap() += 1),
            engine: engine.clone(),
            settle: settle.clone(),
            push: None,
            origins: origins.clone(),
            gate: Box::new(move || match *gate_mode.lock().unwrap() {
                "same" => Gate::Operator(Box::new(gate_declaration.clone())),
                "changed" => {
                    let mut other = gate_declaration.clone();
                    other.origins.push("phone".into());
                    Gate::Operator(Box::new(other))
                }
                "refused" => Gate::Refused(crate::operator_declaration::Refusal { what: "the land fences are switched off".into() }),
                _ => Gate::Product,
            }),
        });
        Desk { state: root.join("engine-state"), root, desk, launcher: fake, engine, settle, origins, mode, released }
    }

    fn desk() -> Desk {
        let fake = Arc::new(FakeLauncher::default());
        desk_with(fake.clone(), fake)
    }

    /// Register an assignment the way the front desk's register does, with its turn in the
    /// ledger table: `mouth` is the turn's recorded channel.
    fn assignment(d: &Desk, thread: &str, words: &str, source: Source, mouth: Option<&str>) -> Assignment {
        use sha2::Digest;
        let ledger_ref = format!("ledger:{thread}:turn-{}", uuid::Uuid::new_v4());
        d.origins.turns.lock().unwrap().insert(ledger_ref.clone(), TurnFacts {
            source, channel: mouth.map(str::to_string), text: words.to_string() });
        let reg = Registration {
            entity_id: "femcboost".into(), thread_id: thread.into(), obligation_id: format!("ob-{}", uuid::Uuid::new_v4()),
            instruction_ledger_ref: ledger_ref, instruction_sha256: format!("{:x}", sha2::Sha256::digest(words.as_bytes())),
            title: "Land the pricing fix".into(), repositories: vec![], needs_screen: false,
        };
        let receipt = assignment::register_kind(&d.state, &reg, AssignmentKind::Task).unwrap();
        assignment::read(&d.state, "femcboost", thread, &receipt.id).unwrap()
    }

    fn state_of(d: &Desk, a: &Assignment) -> (AssignmentState, String) {
        let now = assignment::read(&d.state, &a.entity_id, &a.thread_id, &a.id).unwrap();
        (now.state, now.detail)
    }

    fn sent(d: &Desk) -> Vec<String> {
        d.launcher.leads.lock().unwrap().iter().flat_map(|(_, _, l)| l.sent.lock().unwrap().clone()).collect()
    }

    // ---- rule 1 ------------------------------------------------------------------------------

    #[test]
    fn an_assignment_given_at_the_desk_goes_to_the_lead_with_its_handle_and_his_words() {
        let d = desk();
        let a = assignment(&d, "t-1", "land the pricing fix on main", Source::Text, Some("desk"));
        d.desk.take(a.clone());
        assert!(d.desk.wait_quiet(Duration::from_secs(10)));
        let sent = sent(&d);
        assert_eq!(sent.len(), 1, "one relay: {sent:?}");
        assert!(sent[0].contains(&format!("Assignment handle: {}.", a.id)), "{}", sent[0]);
        assert!(sent[0].contains("Land the pricing fix"), "{}", sent[0]);
        assert!(sent[0].contains("His words, exactly as he said them:\nland the pricing fix on main"), "{}", sent[0]);
        assert_eq!(state_of(&d, &a), (AssignmentState::Running, HANDED_OVER.into()));
        let (key, _, _) = d.launcher.leads.lock().unwrap()[0].clone();
        assert_eq!(key.thread_id, "t-1");
    }

    #[test]
    fn a_spoken_assignment_at_the_desk_is_relayed_as_the_desk_s_voice() {
        let d = desk();
        let a = assignment(&d, "t-1", "ship it", Source::Jam, Some("desk"));
        d.desk.take(a.clone());
        assert!(d.desk.wait_quiet(Duration::from_secs(10)));
        assert_eq!(sent(&d).len(), 1);
        assert_eq!(state_of(&d, &a).0, AssignmentState::Running);
    }

    /// The product's own rule, kept: words the register did not attest, or a turn the ledger
    /// does not have, never reach his team.
    #[test]
    fn words_the_register_did_not_attest_or_a_turn_the_ledger_lacks_are_never_relayed() {
        let d = desk();
        let altered = assignment(&d, "t-1", "the words he said", Source::Text, Some("desk"));
        d.origins.turns.lock().unwrap().get_mut(&altered.instruction_ledger_ref).unwrap().text = "words he never said".into();
        let missing = assignment(&d, "t-1", "and this", Source::Text, Some("desk"));
        d.origins.turns.lock().unwrap().remove(&missing.instruction_ledger_ref);
        d.desk.take(altered.clone());
        d.desk.take(missing.clone());
        assert!(d.desk.wait_quiet(Duration::from_secs(10)));
        assert!(d.launcher.leads.lock().unwrap().is_empty(), "no lead was started");
        assert_eq!(state_of(&d, &altered), (AssignmentState::Failed, UNVERIFIED.into()));
        assert_eq!(state_of(&d, &missing), (AssignmentState::Failed, UNVERIFIED.into()));
    }

    /// The ledger file, read as the product's own check reads it.
    #[test]
    fn the_ledger_origins_find_the_turn_its_mouth_and_its_conversation_s_title() {
        let root = std::env::temp_dir().join(format!("operator-origins-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&root).unwrap();
        let ledger = root.join("conversation-ledger.jsonl");
        let rows = [
            serde_json::json!({"event":"ThreadCreated","thread_id":"t-1","title":"Pricing","at":1}),
            serde_json::json!({"event":"PromptReceived","turn_id":"turn-1","thread_id":"t-1","text":"from the couch","source":"text","at":2,"channel":"phone"}),
            serde_json::json!({"event":"PromptReceived","turn_id":"turn-2","thread_id":"t-1","text":"aloud","source":"jam","at":3,"channel":"desk"}),
            serde_json::json!({"event":"PromptReceived","turn_id":"turn-3","thread_id":"t-1","text":"old","source":"text","at":4}),
        ];
        let mut body: String = rows.iter().map(|r| r.to_string() + "\n").collect();
        body.push_str(r#"{"event":"PromptReceived","turn_id":"turn-4","thread_id":"t-1","text":"torn"#);
        std::fs::write(&ledger, body).unwrap();
        let origins = LedgerOrigins::new(&ledger);
        let phone = origins.turn("ledger:t-1:turn-1").unwrap();
        assert_eq!((phone.source, phone.channel.as_deref(), phone.text.as_str()), (Source::Text, Some("phone"), "from the couch"));
        assert_eq!(origins.turn("ledger:t-1:turn-2").unwrap().channel.as_deref(), Some("desk"));
        assert_eq!(origins.turn("ledger:t-1:turn-2").unwrap().source, Source::Jam);
        assert_eq!(origins.turn("ledger:t-1:turn-3").unwrap().channel, None, "not recorded stays None");
        assert_eq!(origins.turn("ledger:t-1:turn-4"), None, "a torn last record is never read");
        assert_eq!(origins.turn("ledger:t-2:turn-1"), None, "the turn is in another conversation");
        assert_eq!(origins.turn("not-a-ref"), None);
        assert_eq!(origins.title("t-1").as_deref(), Some("Pricing"));
        std::fs::remove_dir_all(root).unwrap();
    }

    // ---- rule 2 ------------------------------------------------------------------------------

    #[test]
    fn a_hand_over_never_holds_the_caller_while_a_lead_starts() {
        let fake = Arc::new(FakeLauncher::default());
        let held = Arc::new(HeldLauncher { inner: FakeLauncher::default(), gate: Mutex::new(false), open: Condvar::new(),
                                           entered: Mutex::new(0) });
        let d = desk_with(held.clone(), fake);
        let a = assignment(&d, "t-1", "go", Source::Text, Some("desk"));
        d.desk.take(a.clone());
        // The caller is back while the lead is still starting.
        let began = Instant::now();
        while *held.entered.lock().unwrap() == 0 && began.elapsed() < Duration::from_secs(10) {
            std::thread::sleep(Duration::from_millis(5));
        }
        assert_eq!(*held.entered.lock().unwrap(), 1, "the hand-over reached the launcher");
        assert!(!d.desk.wait_quiet(Duration::from_millis(50)), "the hand-over is still under way");
        assert_eq!(state_of(&d, &a).0, AssignmentState::Registered);
        *held.gate.lock().unwrap() = true;
        held.open.notify_all();
        assert!(d.desk.wait_quiet(Duration::from_secs(10)));
        assert_eq!(state_of(&d, &a).0, AssignmentState::Running);
    }

    // ---- rule 3 ------------------------------------------------------------------------------

    #[test]
    fn a_phone_assignment_is_closed_with_the_sentence_and_its_obligation_withdrawn() {
        let d = desk();
        let a = assignment(&d, "t-1", "land it", Source::Text, Some("phone"));
        d.desk.take(a.clone());
        assert!(d.desk.wait_quiet(Duration::from_secs(10)));
        assert!(d.launcher.leads.lock().unwrap().is_empty(), "no lead was started for phone words");
        assert_eq!(state_of(&d, &a), (AssignmentState::Failed, crate::operator_host::PHONE_ASSIGNMENT.into()));
        let now = assignment::read(&d.state, "femcboost", "t-1", &a.id).unwrap();
        assert!(now.notices.iter().any(|n| n.kind == NoticeKind::Failed && n.text == crate::operator_host::PHONE_ASSIGNMENT));
        let calls = d.settle.calls.lock().unwrap().clone();
        assert_eq!(calls.len(), 1);
        assert_eq!(calls[0].0, a.obligation_id);
        assert_eq!(calls[0].1, ECS_WITHDRAWN);
        assert!(calls[0].2[0].starts_with("answer:"));
    }

    #[test]
    fn an_assignment_whose_mouth_was_never_recorded_is_not_handed_over() {
        let d = desk();
        let unrecorded = assignment(&d, "t-1", "land it", Source::Text, None);
        d.desk.take(unrecorded.clone());
        assert!(d.desk.wait_quiet(Duration::from_secs(10)));
        assert!(d.launcher.leads.lock().unwrap().is_empty());
        assert_eq!(state_of(&d, &unrecorded), (AssignmentState::Failed, NO_ORIGIN_WORK.into()));
    }

    // ---- rule 4 ------------------------------------------------------------------------------

    #[test]
    fn a_gate_that_changed_broke_or_went_away_since_launch_refuses_and_never_falls_back() {
        for (mode, sentence) in [("changed", CHANGED_SINCE_LAUNCH.to_string()), ("product", OFF_SINCE_LAUNCH.to_string()),
                                 ("refused", crate::operator_declaration::Refusal { what: "the land fences are switched off".into() }.sentence())] {
            let d = desk();
            *d.mode.lock().unwrap() = mode;
            let a = assignment(&d, "t-1", "land it", Source::Text, Some("desk"));
            d.desk.take(a.clone());
            assert!(d.desk.wait_quiet(Duration::from_secs(10)));
            assert!(d.launcher.leads.lock().unwrap().is_empty(), "{mode}: a lead was started");
            assert_eq!(state_of(&d, &a), (AssignmentState::Failed, sentence), "{mode}");
        }
    }

    // ---- rule 5 ------------------------------------------------------------------------------

    #[test]
    fn the_assignment_stop_stops_its_agents_says_so_and_marks_it_stopped_only_when_all_are_gone() {
        let d = desk();
        let a = assignment(&d, "t-1", "land it", Source::Text, Some("desk"));
        d.desk.take(a.clone());
        assert!(d.desk.wait_quiet(Duration::from_secs(10)));
        // Nothing started on it yet: nothing stopped, the record untouched.
        assert_eq!(d.desk.stop_assignment("femcboost", "t-1", &a.id), Err(NOTHING_ON_IT.into()));
        assert_eq!(state_of(&d, &a).0, AssignmentState::Running);
        // The CLI takes the relayed message (the fake's first uuid), and that turn starts an
        // agent: it is this assignment's, and the stop reaches exactly it.
        let lead = d.launcher.leads.lock().unwrap()[0].2.clone();
        d.desk.host.handle(&key_of(&a), crate::operator_lead::LeadEvent::Took("u-1".into()));
        agent(&lead, "tool-a", "mark-sonnet-a", "task-a");
        d.desk.host.handle(&key_of(&a), crate::operator_lead::LeadEvent::Agent(crate::operator_lead::AgentTask {
            name: "mark-sonnet-a".into(), task_id: "task-a".into(), tool_use_id: "tool-a".into(),
            status: crate::operator_lead::TaskStatus::Running }));
        d.engine.not_alive.lock().unwrap().insert("task-a".into());
        lead.feed(serde_json::json!({"type":"system","subtype":"task_notification","task_id":"task-a","status":"stopped"}));
        assert_eq!(d.desk.stop_assignment("femcboost", "t-1", &a.id), Ok(()));
        assert_eq!(*lead.stops.lock().unwrap(), ["task-a"]);
        let (state, detail) = state_of(&d, &a);
        assert_eq!(state, AssignmentState::Interrupted);
        assert!(detail.contains("Stopped mark-sonnet-a."), "{detail}");
        assert_eq!(d.engine.stop_words.lock().unwrap()[0].1, STOP_CONTROL_WORDS);
    }

    /// A stop that reaches only some of the assignment's agents says what it measured and
    /// leaves the assignment open: one of its names (reported on the handle) is no agent any
    /// lead holds, so not every one is NOT-ALIVE.
    #[test]
    fn a_stop_that_reached_only_some_of_its_agents_leaves_the_assignment_open() {
        let d = desk();
        let a = assignment(&d, "t-1", "land it", Source::Text, Some("desk"));
        d.desk.take(a.clone());
        assert!(d.desk.wait_quiet(Duration::from_secs(10)));
        let lead = d.launcher.leads.lock().unwrap()[0].2.clone();
        d.desk.host.handle(&key_of(&a), crate::operator_lead::LeadEvent::Took("u-1".into()));
        agent(&lead, "tool-a", "mark-sonnet-a", "task-a");
        d.desk.host.handle(&key_of(&a), crate::operator_lead::LeadEvent::Agent(crate::operator_lead::AgentTask {
            name: "mark-sonnet-a".into(), task_id: "task-a".into(), tool_use_id: "tool-a".into(),
            status: crate::operator_lead::TaskStatus::Running }));
        // His team's report on this handle names an agent no lead holds.
        let outbox = ConversationPaths::under(&d.root.join("operator"), &key_of(&a)).outbox;
        std::fs::write(&outbox, serde_json::json!({"version":1,"at_ms":1,"lead":"claim-1","entity_id":"femcboost",
            "thread_id":"t-1","handle":a.id,"kind":"update","text":"two on it","attachment":null,"lands":[],"files":[],
            "agents":["ghost-sonnet-b"]}).to_string() + "\n").unwrap();
        d.desk.host.handle(&key_of(&a), crate::operator_lead::LeadEvent::Reported);
        d.engine.not_alive.lock().unwrap().insert("task-a".into());
        lead.feed(serde_json::json!({"type":"system","subtype":"task_notification","task_id":"task-a","status":"stopped"}));
        assert_eq!(d.desk.stop_assignment("femcboost", "t-1", &a.id), Ok(()));
        let (state, detail) = state_of(&d, &a);
        assert_eq!(state, AssignmentState::Running, "not every agent was stopped, so it is not marked stopped");
        assert_eq!(detail, HANDED_OVER);
    }

    /// The §88 seam reaches the lead through the desk, once per delivery identity.
    #[test]
    fn an_answer_reaches_the_lead_through_the_desk_once_per_delivery() {
        let d = desk();
        let a = assignment(&d, "t-1", "ask me something", Source::Text, Some("desk"));
        d.desk.take(a.clone());
        assert!(d.desk.wait_quiet(Duration::from_secs(10)));
        assert_eq!(d.desk.deliver_answer(&key_of(&a), Some(&a.id), "delivery-1", "Green."), Ok(true));
        assert_eq!(d.desk.deliver_answer(&key_of(&a), Some(&a.id), "delivery-1", "Green."), Ok(false), "once");
        let sent = sent(&d);
        assert_eq!(sent.len(), 2, "the assignment, then the answer: {sent:?}");
        assert!(sent[1].contains(&format!("His answer to your question on {}:", a.id)), "{}", sent[1]);
    }

    // ---- rule 6 ------------------------------------------------------------------------------

    #[test]
    fn quit_ends_every_lead_then_releases_the_claim_once_and_takes_nothing_after() {
        let d = desk();
        for thread in ["t-1", "t-2"] {
            let a = assignment(&d, thread, "go", Source::Text, Some("desk"));
            d.desk.take(a);
        }
        assert!(d.desk.wait_quiet(Duration::from_secs(10)));
        let quits = d.desk.quit();
        assert_eq!(quits.len(), 2);
        assert!(d.launcher.leads.lock().unwrap().iter().all(|(_, _, l)| *l.quits.lock().unwrap() == 1));
        assert_eq!(*d.released.lock().unwrap(), 1);
        assert!(d.desk.quit().is_empty(), "a second quit does nothing");
        assert_eq!(*d.released.lock().unwrap(), 1, "the claim is released once");
        let late = assignment(&d, "t-3", "one more", Source::Text, Some("desk"));
        d.desk.take(late.clone());
        assert_eq!(state_of(&d, &late), (AssignmentState::Failed, CLOSING.into()));
        assert_eq!(d.launcher.leads.lock().unwrap().len(), 2, "nothing was started after quit");
    }

    // ---- rule 7 ------------------------------------------------------------------------------

    #[test]
    fn the_idle_timer_retires_a_lead_with_nothing_running_and_spends_nothing_with_no_lead() {
        let d = desk();
        // No lead: the timer asks his engine nothing, not even the lease status.
        assert!(d.desk.retire_idle_now(Duration::ZERO).is_empty());
        assert!(d.engine.asked.lock().unwrap().is_empty());
        assert_eq!(*d.engine.lease_reads.lock().unwrap(), 0, "no script runs while no lead runs");
        let a = assignment(&d, "t-1", "go", Source::Text, Some("desk"));
        d.desk.take(a.clone());
        assert!(d.desk.wait_quiet(Duration::from_secs(10)));
        // The relayed message ends its turn; the supervisor's snapshot shows nothing outside.
        let lead = d.launcher.leads.lock().unwrap()[0].2.clone();
        d.desk.host.handle(&key_of(&a), crate::operator_lead::LeadEvent::TurnEnded(crate::operator_lead::TurnEnd {
            started_by: vec!["u-1".into()], text: None, is_error: false, subtype: "success".into() }));
        let paths = ConversationPaths::under(&d.root.join("operator"), &key_of(&a));
        std::fs::write(&paths.reap_state, r#"{"outside_provider_group": []}"#).unwrap();
        d.desk.start_retirement(Duration::from_millis(20), Duration::ZERO);
        let began = Instant::now();
        while *lead.quits.lock().unwrap() == 0 && began.elapsed() < Duration::from_secs(10) {
            std::thread::sleep(Duration::from_millis(10));
        }
        assert_eq!(*lead.quits.lock().unwrap(), 1, "the idle lead was retired by the timer");
    }
}
