//! THE OPERATOR HOST — one lead per conversation, relaying and never holding (operator back-end
//! spec r3 §4 (g), (c), (d), (o), (q), (r), (s), e4, with r4 §1-§3; richos-hq
//! `docs/plans/2026-09-25-operator-back-end-spec-r4.md`).
//!
//! **What it is for, in his words.** Two Riches: *"each conversation thread always holds one
//! front desk Rich and one back-end Rich. Regardless of the number of assignments"*, and his
//! choice for this Mac (§86): *"Your setup as-is"*. So each conversation given work gets its own
//! lead — his `claude`, seated in his entity with his rules — and this host is the only thing
//! between the front desk and it.
//!
//! **The rules, each a test in this file:**
//!
//! 1. **Relay, never hold ((g)).** A message is written to the lead the moment it arrives; the
//!    CLI queues it and takes it after the running turn (P13's control). There is no host queue
//!    and no "one assignment at a time" — that is the product runner's shape, not his.
//! 2. **Only a report settles an assignment ((c)).** A turn ending never does. An `outcome` or
//!    `failed` report on a handle closes that obligation through the engine's `operator-complete`
//!    verb ([`Settle`]), with every land already checked in Git by the report server.
//! 3. **His lead's own words reach him ((c), B5 edge).** A turn's final text is delivered —
//!    on the handle whose message started the turn, or on the conversation for a turn the
//!    platform started — unless it is the text of that turn's last report.
//! 4. **Phone words never become work (s), and answers are not phone words (§88).** An
//!    assignment from an origin the declaration does not list is not relayed; a turn with no
//!    origin relays nothing; a stop is accepted from every channel; and an answer to his team's
//!    question reaches the lead from any channel through [`OperatorHost::deliver_answer`], the
//!    seam PRD S6's question store calls.
//! 5. **A named stop stops the name and nothing else ((d), §67),** then tells his registry
//!    (r4 §2.1, item 3a) once the stream says `stopped` AND `agent-liveness.sh` says NOT-ALIVE.
//! 6. **Nothing but a positive signal ends a lead ((q)).** Errors are reported and the lead is
//!    kept; an end not caused by quit or retirement is logged with its cause.
//! 7. **An alarm reaches him once, across every lead ((r)).**
//!
//! **What it deliberately does not do.** It never sets `priority` (r4 §1.3), never closes a
//! lead's input while an agent of it is alive (r4 §1.2), never re-dispatches anything after a
//! crash (reference ledger row §2.6), and never decides the land: the lead and his engine do.
use crate::assignment::{self, AssignmentState, NoticeKind};
use crate::operator_declaration::Declaration;
use crate::operator_frames::{banner_in, Alarm, AlarmDeduper};
use crate::operator_lead::{InterruptReply, LeadError, LeadEvent, LeadSink, Quit, TaskBook, TaskStatus, TurnEnd};
use crate::operator_profile::{init_check, EngineBanner, InitVerdict, LeadStart};
use crate::operator_report::{read_outbox, ReportRecord};
use crate::operator_snapshot::snapshot_digest;
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::{BTreeSet, HashMap, VecDeque};
use std::path::{Path, PathBuf};
use std::sync::mpsc::{channel, Sender};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant, SystemTime};

/// r3 (q) item 4: a lead with nothing running is retired after this long idle.
pub const LEAD_IDLE: Duration = Duration::from_secs(30 * 60);
/// r3 (d) item 3: "Still ALIVE after 10 s: he hears so and the stop is sent once more."
pub const STOP_WAIT: Duration = Duration::from_secs(10);
/// (s) rule 1, verbatim from r3.
pub const PHONE_ASSIGNMENT: &str = "Your team only takes work from the Mac. I've noted it; ask me at your desk.";
/// How many of a conversation's last turn texts the front desk's read shows ((o)).
pub const LAST_TEXTS: usize = 3;
/// The ECS store's status for a withdrawn obligation, which only an answer can close (zach's
/// `operator-complete` contract §2.5). It is the store's protocol value, spelled as the store
/// spells it.
const ECS_WITHDRAWN: &str = "cancelled"; // dialect-exempt: the ECS store's own protocol literal, engine-rest-2026-09-25.md §2.5

// =============================================================================================
// identities and channels
// =============================================================================================

/// One conversation, as the ledger bound it.
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub struct ConversationKey {
    pub entity_id: String,
    pub thread_id: String,
}

/// Where the words came from ((s)). The declaration's `origins` lists which may give work.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Origin {
    DeskTyped,
    DeskVoice,
    DeskFile,
    Phone,
    /// A mouth this build has never heard of, recorded on the turn by its intake record (r3
    /// (s): *"any future origin is unlisted until declared"*). Refused as work with the same
    /// sentence as the phone, because it is not the Mac.
    Undeclared,
    /// A notice, a proactive turn, an internal re-prime, or a turn whose mouth was never
    /// recorded: no intake origin, (s) rule 4. It relays nothing.
    NoOrigin,
}

impl Origin {
    /// The declaration's word for this origin.
    pub fn declared(self) -> Option<&'static str> {
        match self {
            Self::DeskTyped => Some("desk-typed"),
            Self::DeskVoice => Some("desk-voice"),
            Self::DeskFile => Some("desk-file"),
            Self::Phone => Some("phone"),
            Self::Undeclared => Some("undeclared"),
            Self::NoOrigin => None,
        }
    }

    /// **Where a front-desk turn's words came from, read off the ledger** (r3 (s); the
    /// operator-client record's §7 item 3: *"so the host receives `Origin` instead of the
    /// walk handing it in"*). `channel` is `Turn::channel`, which a spine on an operator
    /// install records for every sentence of his (`spine::DESK_CHANNEL` or the intake
    /// record's own mouth).
    ///
    /// **An unrecorded mouth is no origin, never the desk.** A turn recorded before keeping
    /// began, by a build that did not keep it, carries `None`; reading that as "typed at the
    /// Mac" would let a phone sentence from yesterday become work today. Internal and
    /// proactive turns carry no words of his and are no origin whatever they carry.
    pub fn of_turn(source: crate::ledger::Source, channel: Option<&str>) -> Origin {
        use crate::ledger::Source;
        match (source, channel) {
            (Source::Internal | Source::Proactive, _) | (_, None) => Origin::NoOrigin,
            (_, Some("phone")) => Origin::Phone,
            (Source::Text, Some(crate::spine::DESK_CHANNEL)) => Origin::DeskTyped,
            (Source::Jam, Some(crate::spine::DESK_CHANNEL)) => Origin::DeskVoice,
            (_, Some(_)) => Origin::Undeclared,
        }
    }
}

/// What happened to one relay.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Relayed {
    /// Written to the lead; the uuid the CLI will echo when it takes it.
    Sent { uuid: String },
    /// Not relayed. `sentence` is what the front desk tells him, when there is one to tell.
    Not { sentence: Option<String> },
}

/// What a lead said, on which lane.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Lane {
    Handle(String),
    Conversation,
}

/// What kind of thing is being said, so a surface never parses a sentence to decide.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum Say {
    /// Progress, or a turn's own final words.
    Update,
    /// His team asks him something.
    Question,
    Answer,
    Outcome,
    Failed,
    /// One of his engine's alarms, verbatim.
    Alarm,
    /// Something about his team itself: it ended, it was refused, a stop's result.
    Team,
}

// =============================================================================================
// the seams: what the host is given
// =============================================================================================

/// One running lead, as the host drives it. [`crate::operator_lead::OperatorLead`] in
/// production; a fake in the tests.
pub trait LeadHandle: Send + Sync {
    fn session_id(&self) -> String;
    fn send(&self, text: &str) -> Result<String, LeadError>;
    fn stop_task(&self, task_id: &str) -> Result<(), LeadError>;
    fn interrupt(&self) -> Result<InterruptReply, LeadError>;
    fn tasks(&self) -> TaskBook;
    fn exited(&self) -> bool;
    /// The quit path: SIGTERM to the supervisor, then its group after the grace (r3 (q) item 2).
    fn quit(&self) -> Quit;
}

/// Where one conversation's files live, under the install's own operator folder.
#[derive(Clone, Debug)]
pub struct ConversationPaths {
    pub dir: PathBuf,
    /// The report server's scope file and outbox ((c)).
    pub scope: PathBuf,
    pub outbox: PathBuf,
    pub attachments: PathBuf,
    /// The supervisor's snapshot of descendants outside the lead's group (G8).
    pub reap_state: PathBuf,
    /// The host's own record of this conversation's lead (last session, what was read).
    pub record: PathBuf,
}

impl ConversationPaths {
    pub fn under(root: &Path, key: &ConversationKey) -> Self {
        let dir = root.join(safe_segment(&key.entity_id)).join(safe_segment(&key.thread_id));
        ConversationPaths {
            scope: dir.join("report-scope.json"),
            outbox: dir.join("outbox.jsonl"),
            attachments: dir.join("attachments"),
            reap_state: dir.join("reap-state.json"),
            record: dir.join("lead.json"),
            dir,
        }
    }
}

/// A path segment that cannot climb out of its folder. Ids are uuids in practice; anything
/// else is kept readable and made unique by its digest.
fn safe_segment(raw: &str) -> String {
    let clean: String = raw.chars().map(|c| if c.is_ascii_alphanumeric() || c == '-' || c == '_' { c } else { '-' }).collect();
    if clean == raw && !clean.is_empty() && clean.len() <= 80 {
        return clean;
    }
    use sha2::Digest;
    let digest = format!("{:x}", sha2::Sha256::digest(raw.as_bytes()));
    format!("{}-{}", &clean[..clean.len().min(40)], &digest[..12])
}

/// How a lead is started for one conversation. The real one builds the operator profile, takes
/// the claim and opens the process; the tests hand back fakes.
pub trait LeadLauncher: Send + Sync {
    /// Start a lead (new or resumed). `title` is the conversation's title, which the claim and
    /// the land lease name it by. `Err` is one sentence to him.
    fn launch(&self, key: &ConversationKey, title: &str, start: &LeadStart, paths: &ConversationPaths,
              sink: Arc<dyn LeadSink>) -> Result<Arc<dyn LeadHandle>, String>;
    /// The fence status the init check needs (r3 (b), §11 item 4). Asked at every lead start.
    fn fences(&self) -> Result<(), String>;
}

/// `agent-liveness.sh`'s three answers (exit 0, 10, 11).
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum AgentLiveness {
    Alive,
    NotAlive,
    Indeterminate(String),
}

/// His engine's scripts, run from the DECLARED root with his environment (r3 (b), B9).
pub trait OperatorEngine: Send + Sync {
    /// `stop.sh <names> --entity <root> --ceo-word '<his words>'` (r3 (d) item 1).
    fn stop_words(&self, names: &[String], words: &str) -> Result<String, String>;
    /// `agent-liveness.sh --entity <root> --json <agent id>`. **The target is the agent's id,
    /// which is the stream's `task_id`, never its name:** the resolver takes an id, `agent-<id>`
    /// or a worktree path, and a name matches nothing and reads NOT-ALIVE ("absent/unregistered",
    /// `agent-liveness.py:490-507`) — measured in the r4 probe run, where a live agent read
    /// NOT-ALIVE by name and ALIVE by its worktree. r3 (d) item 3's `agent-liveness.sh <name>` is
    /// corrected here.
    fn liveness(&self, agent_id: &str) -> AgentLiveness;
    /// `RICHOS_SESSION_ID=<lead session> workspaces.sh stop <name> --why '<his words>'` (r4 §2.1).
    fn registry_stop(&self, session_id: &str, name: &str, words: &str) -> Result<String, String>;
    /// `land-lease.sh status --repo <r>` for each fenced repository: the lines of held leases.
    fn held_leases(&self) -> Vec<String>;
}

/// Closing an obligation through the engine (r3 (c); zach's `operator-complete`, contract §2.5).
pub trait Settle: Send + Sync {
    fn complete(&self, key: &ConversationKey, obligation_id: &str, source_ref: &str, status: &str,
                evidence: &[String], answer_text: &str) -> Result<(), String>;
}

/// Saying something to him.
pub trait OperatorDelivery: Send + Sync {
    fn say(&self, key: &ConversationKey, lane: &Lane, kind: Say, text: &str);
}

/// **The §88 seam, outward half.** His team asked him something (`report(kind: question)`). PRD
/// S6 routes it into the one question store; until that lands, [`SayQuestions`] says it to him
/// on its lane. Nothing here holds, confirms or withdraws an answer: r4 §3 removed the hold.
pub trait QuestionSink: Send + Sync {
    fn asked(&self, key: &ConversationKey, record: &ReportRecord);
}

/// The question sink until S6 lands: the question is said to him, as a question.
pub struct SayQuestions(pub Arc<dyn OperatorDelivery>);

impl QuestionSink for SayQuestions {
    fn asked(&self, key: &ConversationKey, record: &ReportRecord) {
        let lane = record.handle.clone().map(Lane::Handle).unwrap_or(Lane::Conversation);
        self.0.say(key, &lane, Say::Question, &record.text);
    }
}

// =============================================================================================
// e4: what changed since a lead's last message
// =============================================================================================

/// The files whose change every lead must hear about (r3 e4): his memory directory, and the two
/// record files that carry his rules. **Stated gap:** the schema-1 declaration has no field
/// naming "declared record files", so this set is his memory plus `CLAUDE.md` and
/// `orchestration.config`; a declaration field is the way to widen it.
pub fn watched_paths(declaration: &Declaration) -> Vec<PathBuf> {
    let slug: String = declaration.entity_root.display().to_string()
        .chars().map(|c| if c.is_ascii_alphanumeric() { c } else { '-' }).collect();
    let claude = declaration.claim.file.parent().and_then(Path::parent).map(Path::to_path_buf)
        .unwrap_or_else(|| declaration.home.join(".claude"));
    vec![claude.join("projects").join(slug).join("memory"),
         declaration.entity_root.join("CLAUDE.md"),
         declaration.entity_root.join("orchestration.config")]
}

/// Every file under `watched` (a directory is read one level deep, as the memory folder is
/// flat) modified after `since`.
pub fn changed_since(watched: &[PathBuf], since: SystemTime) -> Vec<PathBuf> {
    let mut out = Vec::new();
    let newer = |p: &Path| std::fs::metadata(p).and_then(|m| m.modified()).is_ok_and(|t| t > since);
    for path in watched {
        if path.is_dir() {
            if let Ok(entries) = std::fs::read_dir(path) {
                let mut files: Vec<PathBuf> = entries.flatten().map(|e| e.path()).filter(|p| p.is_file() && newer(p)).collect();
                files.sort();
                out.extend(files);
            }
        } else if newer(path) {
            out.push(path.clone());
        }
    }
    out
}

/// r3 e4, verbatim shape: "Changed since your last message: <paths>. Read them before you act."
pub fn changed_line(changed: &[PathBuf]) -> Option<String> {
    (!changed.is_empty()).then(|| format!("Changed since your last message: {}. Read them before you act.",
        changed.iter().map(|p| p.display().to_string()).collect::<Vec<_>>().join(", ")))
}

/// Is this `land-lease.sh status` line a lease held by the conversation titled `title`? The
/// engine names an app lead's lease by the title the claim lists for its pid, exactly as
/// `the conversation "<title>"`, the title cut to 120 characters (`operator_fences.holder_label`,
/// `_app_conversation_title`). A bare substring would let a short title match any line.
pub fn lease_held_by(line: &str, title: &str) -> bool {
    let title: String = title.chars().filter(|c| !c.is_control()).take(120).collect();
    !title.is_empty() && line.contains(&format!("the conversation \"{title}\""))
}

/// The supervisor's count of descendants alive OUTSIDE the lead's own group (G8): tool shells
/// and background commands. `None` when there is no current snapshot, which is never "zero".
pub fn live_descendants(reap_state: &Path) -> Option<usize> {
    let value: Value = serde_json::from_str(&std::fs::read_to_string(reap_state).ok()?).ok()?;
    value.get("outside_provider_group").and_then(Value::as_array).map(Vec::len)
}

// =============================================================================================
// the host's own durable record of one conversation's lead
// =============================================================================================

#[derive(Clone, Debug, Default, Serialize, Deserialize)]
struct LeadRecord {
    /// The session a relaunch resumes (r3 (l)).
    last_session: Option<String>,
    /// How many outbox records have been acted on. Survives a relaunch, so a report is never
    /// said or settled twice.
    outbox_read: usize,
    /// Handles open when the lead last ended (r3 (l): "the first message lists the handles open
    /// when the lead last ended").
    open_handles: BTreeSet<String>,
    /// §88 seam: answer deliveries already relayed, by S6's delivery identity.
    answers: Vec<AnswerRelay>,
}

/// One answer relayed to the lead. `answer_to` is the handle whose question it answers (r1
/// (c)'s `answer_to`, kept on the relay rather than in the product register: `Assignment` is
/// `deny_unknown_fields`, so a new field there would make every older build refuse the record).
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
struct AnswerRelay {
    delivery_id: String,
    answer_to: Option<String>,
    uuid: String,
}

fn read_record(path: &Path) -> LeadRecord {
    std::fs::read_to_string(path).ok().and_then(|t| serde_json::from_str(&t).ok()).unwrap_or_default()
}

fn write_record(path: &Path, record: &LeadRecord) -> Result<(), String> {
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent).map_err(|e| e.to_string())?;
    }
    let tmp = path.with_extension("json.tmp");
    std::fs::write(&tmp, serde_json::to_vec_pretty(record).map_err(|e| e.to_string())?).map_err(|e| e.to_string())?;
    std::fs::rename(&tmp, path).map_err(|e| e.to_string())
}

// =============================================================================================
// the host
// =============================================================================================

/// One conversation's lead and what the host knows about it.
struct Conversation {
    key: ConversationKey,
    title: String,
    paths: ConversationPaths,
    lead: Option<Arc<dyn LeadHandle>>,
    record: LeadRecord,
    /// uuid → the handle its message was about.
    sent: HashMap<String, Option<String>>,
    /// uuids written and not yet taken into an ended turn.
    awaiting: BTreeSet<String>,
    in_turn: bool,
    last_relay: Option<SystemTime>,
    last_activity: Instant,
    texts: VecDeque<String>,
    /// The text of this turn's last report, for the B5 edge.
    turn_report: Option<String>,
    /// Handle → the names seen starting on its turns, and those its reports named ((d) item 5).
    handle_agents: HashMap<String, BTreeSet<String>>,
    /// The handle the running turn belongs to, if one does.
    turn_handle: Option<String>,
    banner: Option<EngineBanner>,
    /// An init frame that arrived before the engine's banner: the check waits for the banner,
    /// or for the turn's end, whichever comes first (measured order: the banner's SessionStart
    /// response came 0.6-1.5 s before init in P1, P10, P16 and P17, but order is not a contract).
    pending_init: Option<Value>,
    fences: Result<(), String>,
    checked: bool,
    /// A quit or retirement the host itself started: the end that follows is expected.
    quitting: bool,
    started_digest: String,
    told_protocol: bool,
    first_after_resume: bool,
    /// Questions his team asked and nothing has answered yet, by handle ((o), until S6).
    questions: Vec<(Option<String>, String)>,
}

/// One named stop's result (r3 (d) item 3, r4 §2.1).
#[derive(Clone, Debug, PartialEq)]
pub enum StopResult {
    /// NOT-ALIVE, in `seconds`; `registry` is whether his registry was told (r4 item 3a).
    Stopped { name: String, seconds: f64, registry: Result<(), String> },
    StillAlive { name: String },
    Indeterminate { name: String, why: String },
    NotFound { name: String },
    Failed { name: String, why: String },
}

impl StopResult {
    /// The sentence he hears. "stopped" is said only on NOT-ALIVE (r3 (d) item 3).
    pub fn sentence(&self) -> String {
        match self {
            Self::Stopped { name, .. } => format!("Stopped {name}."),
            Self::StillAlive { name } => format!("{name} is still running after the stop was sent twice."),
            Self::Indeterminate { name, why } => format!("I can't tell whether {name} stopped: {why}"),
            Self::NotFound { name } => format!("{name} isn't one of your team's agents in this app."),
            Self::Failed { name, why } => format!("The stop for {name} could not be sent: {why}"),
        }
    }
}

/// The front desk's read of one conversation ((o), with r4 §1.1 and §3).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ConversationRead {
    pub key: ConversationKey,
    pub lead_running: bool,
    /// Each named agent with its last status from the stream.
    pub agents: Vec<(String, String)>,
    /// The last three turn texts, oldest first.
    pub texts: Vec<String>,
    /// Open questions and whether an answer has been relayed. S2's status listing replaces this.
    pub open_questions: Vec<String>,
    /// Land leases held by this conversation's lead, as `land-lease.sh status` says them.
    pub leases: Vec<String>,
}

/// (m): what his team is doing, for the update gate, the keep-alive and the quit sheet.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct TeamReading {
    /// Conversations whose lead is in a turn, or has his messages still queued: his team is
    /// working even with no agent and no command running. **Not in r3 (m)'s wording, and
    /// needed:** without it a lead mid-turn with nothing but its own thinking reads as idle,
    /// and closing the window would quit the app and end that turn (found wiring the
    /// keep-alive; recorded in the operator-client record).
    pub working: Vec<String>,
    pub alive: Vec<String>,
    pub unknown: Vec<String>,
    /// Descendants outside the leads' own groups (tool shells, background commands).
    pub descendants: usize,
    /// Running leads whose supervisor snapshot could not be read.
    pub descendants_unknown: usize,
}

pub struct OperatorHost {
    declaration: Declaration,
    /// `<engine-state>`: the assignment register lives under it.
    state: PathBuf,
    /// `<app data>/operator`: this install's operator files.
    root: PathBuf,
    launcher: Arc<dyn LeadLauncher>,
    engine: Arc<dyn OperatorEngine>,
    settle: Arc<dyn Settle>,
    delivery: Arc<dyn OperatorDelivery>,
    questions: Arc<dyn QuestionSink>,
    conversations: Mutex<HashMap<ConversationKey, Arc<Mutex<Conversation>>>>,
    alarms: Mutex<AlarmDeduper>,
}

/// The sink a lead's reader writes to: a channel into this conversation's own worker, so a slow
/// step (an engine call, a Git read) never stalls the lead's stdout.
struct ConversationSink(Mutex<Sender<LeadEvent>>);

impl LeadSink for ConversationSink {
    fn event(&self, event: LeadEvent) {
        // A closed channel means the conversation's worker has ended; the event has nowhere to go.
        self.0.lock().unwrap().send(event).ok();
    }
}

impl OperatorHost {
    #[allow(clippy::too_many_arguments)]
    pub fn new(declaration: Declaration, state: &Path, root: &Path, launcher: Arc<dyn LeadLauncher>,
               engine: Arc<dyn OperatorEngine>, settle: Arc<dyn Settle>, delivery: Arc<dyn OperatorDelivery>,
               questions: Arc<dyn QuestionSink>) -> Arc<Self> {
        Arc::new(OperatorHost {
            declaration,
            state: state.to_path_buf(),
            root: root.to_path_buf(),
            launcher,
            engine,
            settle,
            delivery,
            questions,
            conversations: Mutex::new(HashMap::new()),
            alarms: Mutex::new(AlarmDeduper::default()),
        })
    }

    /// The operator log is where every other failure goes, so its own failure goes to stderr.
    pub(crate) fn log(&self, line: &str) {
        let stamp = crate::operator_claim::iso_utc(
            SystemTime::now().duration_since(SystemTime::UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0));
        let written = std::fs::create_dir_all(&self.root)
            .and_then(|_| std::fs::OpenOptions::new().create(true).append(true).open(self.log_path()))
            .and_then(|mut file| {
                use std::io::Write;
                writeln!(file, "{stamp} host: {line}")
            });
        if let Err(e) = written {
            eprintln!("{stamp} operator host: the operator log could not be written ({e}): {line}");
        }
    }

    /// The lead record is what a restart resumes from; a record that could not be saved is logged,
    /// never passed over (the conversation still runs on what is in memory).
    fn save(&self, path: &Path, record: &LeadRecord) {
        if let Err(e) = write_record(path, record) {
            self.log(&format!("the lead record {} could not be saved ({e})", path.display()));
        }
    }

    /// The operator log, shared with the supervisors (`RICHOS_OPERATOR_REAP_LOG`).
    pub fn log_path(&self) -> PathBuf {
        self.root.join("operator.log")
    }

    fn conversation(&self, key: &ConversationKey, title: &str) -> Arc<Mutex<Conversation>> {
        let mut all = self.conversations.lock().unwrap();
        if let Some(existing) = all.get(key) {
            if !title.is_empty() {
                existing.lock().unwrap().title = title.to_string();
            }
            return existing.clone();
        }
        let paths = ConversationPaths::under(&self.root, key);
        let record = read_record(&paths.record);
        let first_after_resume = record.last_session.is_some();
        let conversation = Arc::new(Mutex::new(Conversation {
            key: key.clone(), title: title.to_string(), paths, lead: None, record, sent: HashMap::new(),
            awaiting: BTreeSet::new(), in_turn: false, last_relay: None, last_activity: Instant::now(),
            texts: VecDeque::new(), turn_report: None, handle_agents: HashMap::new(), turn_handle: None, banner: None,
            pending_init: None, fences: Ok(()), checked: false, quitting: false, started_digest: String::new(), told_protocol: false,
            first_after_resume, questions: Vec::new(),
        }));
        all.insert(key.clone(), conversation.clone());
        conversation
    }

    /// Start (or resume) the lead of `conversation` if none is running. Lazy: a lead starts on
    /// its conversation's next message, never all at once at relaunch (r3 (l)).
    fn ensure_lead(self: &Arc<Self>, conversation: &mut Conversation) -> Result<Arc<dyn LeadHandle>, String> {
        if let Some(lead) = &conversation.lead {
            if !lead.exited() {
                return Ok(lead.clone());
            }
            conversation.lead = None;
        }
        let start = match &conversation.record.last_session {
            Some(session) => LeadStart::Resume(session.clone()),
            None => LeadStart::New(uuid::Uuid::new_v4().to_string()),
        };
        std::fs::create_dir_all(&conversation.paths.dir).map_err(|e| format!("Your team's folder could not be made ({e})."))?;
        let (tx, rx) = channel::<LeadEvent>();
        let sink: Arc<dyn LeadSink> = Arc::new(ConversationSink(Mutex::new(tx)));
        let fences = self.launcher.fences();
        let lead = self.launcher.launch(&conversation.key, &conversation.title, &start, &conversation.paths, sink)?;
        let host = Arc::clone(self);
        let key = conversation.key.clone();
        std::thread::Builder::new()
            .name(format!("richos-operator-host:{}", &key.thread_id[..key.thread_id.len().min(16)]))
            .spawn(move || {
                for event in rx {
                    host.handle(&key, event);
                }
            })
            .map_err(|e| format!("Your team could not be started ({e})."))?;
        conversation.fences = fences;
        conversation.checked = false;
        conversation.banner = None;
        conversation.pending_init = None;
        conversation.quitting = false;
        conversation.started_digest = snapshot_digest(&self.declaration);
        conversation.record.last_session = Some(lead.session_id());
        self.save(&conversation.paths.record, &conversation.record);
        conversation.lead = Some(lead.clone());
        self.log(&format!("lead started for {}/{} ({})", conversation.key.entity_id, conversation.key.thread_id,
                          match &start { LeadStart::New(s) => format!("new session {s}"), LeadStart::Resume(s) => format!("resumed {s}") }));
        Ok(lead)
    }

    /// **Relay his words to this conversation's lead, now** ((g), (s)). `handle` is the
    /// assignment the words are about, when they are about one.
    pub fn relay(self: &Arc<Self>, key: &ConversationKey, title: &str, handle: Option<&str>, text: &str, origin: Origin)
                 -> Result<Relayed, String> {
        // (s) rule 4: a turn with no intake origin never relays, whatever it contains.
        let Some(declared) = origin.declared() else {
            self.log(&format!("not relayed: no intake origin ({}/{})", key.entity_id, key.thread_id));
            return Ok(Relayed::Not { sentence: None });
        };
        // (s) rule 1: work only from a channel the declaration lists.
        if !self.declaration.origins.iter().any(|o| o == declared) {
            self.log(&format!("not relayed: origin {declared} is not declared ({}/{})", key.entity_id, key.thread_id));
            return Ok(Relayed::Not { sentence: Some(PHONE_ASSIGNMENT.into()) });
        }
        self.write(key, title, handle, text, None)
    }

    /// Write one message to the lead, prefixed as e4 and (l) say. Shared by [`Self::relay`] and
    /// [`Self::deliver_answer`], which is the only other way words reach a lead.
    fn write(self: &Arc<Self>, key: &ConversationKey, title: &str, handle: Option<&str>, text: &str,
             answer: Option<(&str, Option<&str>)>) -> Result<Relayed, String> {
        let conversation = self.conversation(key, title);
        let mut c = conversation.lock().unwrap();
        let lead = self.ensure_lead(&mut c)?;
        let mut lines = Vec::new();
        if c.first_after_resume {
            if !c.record.open_handles.is_empty() {
                lines.push(format!("Open when you last ended: {}.",
                                   c.record.open_handles.iter().cloned().collect::<Vec<_>>().join(", ")));
            }
            c.first_after_resume = false;
        }
        if let Some(since) = c.last_relay {
            if let Some(line) = changed_line(&changed_since(&watched_paths(&self.declaration), since)) {
                lines.push(line);
            }
        }
        if let Some(handle) = handle {
            lines.push(format!("Assignment handle: {handle}. Report on it with richos_operator.report and this handle."));
        }
        lines.push(text.to_string());
        let uuid = lead.send(&lines.join("\n\n")).map_err(|e| {
            // Kept on error (r3 (q) item 1): the lead is not touched; he is told the relay failed.
            self.log(&format!("relay failed for {}/{}: {e}", key.entity_id, key.thread_id));
            format!("Your message did not reach your team ({e}). Your team is still running.")
        })?;
        c.sent.insert(uuid.clone(), handle.map(str::to_string));
        c.awaiting.insert(uuid.clone());
        c.last_relay = Some(SystemTime::now());
        c.last_activity = Instant::now();
        if let Some(h) = handle {
            c.record.open_handles.insert(h.to_string());
        }
        if let Some((delivery_id, answer_to)) = answer {
            c.record.answers.push(AnswerRelay { delivery_id: delivery_id.to_string(),
                                                answer_to: answer_to.map(str::to_string), uuid: uuid.clone() });
            if let Some(h) = answer_to {
                c.questions.retain(|(q, _)| q.as_deref() != Some(h));
            }
        }
        self.save(&c.paths.record, &c.record);
        Ok(Relayed::Sent { uuid })
    }

    /// **The §88 seam, inward half.** PRD S6 calls this with a resolved answer set for a
    /// question his team asked on `handle` (or on the conversation). It reaches the lead from ANY
    /// channel, with no hold and no confirmation (r4 §3). `delivery_id` is S6's durable delivery
    /// identity: the same one twice relays once. Returns whether it was relayed now.
    pub fn deliver_answer(self: &Arc<Self>, key: &ConversationKey, title: &str, handle: Option<&str>,
                          delivery_id: &str, answer: &str) -> Result<bool, String> {
        {
            let conversation = self.conversation(key, title);
            let c = conversation.lock().unwrap();
            if c.record.answers.iter().any(|a| a.delivery_id == delivery_id) {
                return Ok(false);
            }
        }
        let text = match handle {
            Some(h) => format!("His answer to your question on {h}:\n\n{answer}"),
            None => format!("His answer to your question:\n\n{answer}"),
        };
        self.write(key, title, handle, &text, Some((delivery_id, handle))).map(|_| true)
    }

    // ---- events ----------------------------------------------------------------------------

    /// One event from a lead's stream, on that conversation's worker.
    pub(crate) fn handle(&self, key: &ConversationKey, event: LeadEvent) {
        let Some(conversation) = self.conversations.lock().unwrap().get(key).cloned() else { return };
        match event {
            LeadEvent::Alarm(alarm) => self.alarm(&conversation, alarm),
            LeadEvent::Init(init) => self.init(&conversation, &init),
            // The turn belongs to the handle of the first message it took that had one (r3 (d)
            // item 5): every agent it starts from here is that assignment's.
            LeadEvent::Took(uuid) => {
                let mut c = conversation.lock().unwrap();
                c.last_activity = Instant::now();
                c.in_turn = true;
                if c.turn_handle.is_none() {
                    c.turn_handle = c.sent.get(&uuid).cloned().flatten();
                }
            }
            LeadEvent::Agent(task) => {
                let mut c = conversation.lock().unwrap();
                c.last_activity = Instant::now();
                c.in_turn = true;
                if task.status == TaskStatus::Running {
                    if let Some(h) = c.turn_handle.clone() {
                        c.handle_agents.entry(h).or_default().insert(task.name.clone());
                    }
                }
            }
            LeadEvent::TurnEnded(end) => self.turn_ended(&conversation, end),
            // A report mid-turn reaches him now; the turn's end still compares against it.
            LeadEvent::Reported => self.take_reports(&conversation),
            LeadEvent::Protocol(what) => {
                self.log(&format!("{}/{}: {what}; the lead is kept", key.entity_id, key.thread_id));
                let mut c = conversation.lock().unwrap();
                if !c.told_protocol {
                    c.told_protocol = true;
                    drop(c);
                    self.delivery.say(key, &Lane::Conversation, Say::Team,
                        "Your team's connection in this conversation sent something RichOS could not read. Your team is still running.");
                }
            }
            LeadEvent::Ended => self.ended(&conversation),
        }
    }

    fn alarm(&self, conversation: &Arc<Mutex<Conversation>>, alarm: Alarm) {
        if let Some(banner) = banner_in(&alarm) {
            let waiting = {
                let mut c = conversation.lock().unwrap();
                c.banner = Some(banner);
                c.pending_init.take()
            };
            if let Some(init) = waiting {
                self.check(conversation, &init);
            }
        }
        let key = conversation.lock().unwrap().key.clone();
        if self.alarms.lock().unwrap().admit(&alarm, Instant::now()) {
            self.delivery.say(&key, &Lane::Conversation, Say::Alarm, &alarm.text);
        }
    }

    fn init(&self, conversation: &Arc<Mutex<Conversation>>, init: &Value) {
        {
            let mut c = conversation.lock().unwrap();
            if c.checked {
                return;
            }
            if c.banner.is_none() {
                c.pending_init = Some(init.clone());
                return;
            }
        }
        self.check(conversation, init);
    }

    /// The init check (r3 (b)), once per lead.
    fn check(&self, conversation: &Arc<Mutex<Conversation>>, init: &Value) {
        let mut c = conversation.lock().unwrap();
        if c.checked {
            return;
        }
        c.checked = true;
        c.pending_init = None;
        match init_check(&self.declaration, init, c.banner.as_ref(), &c.fences) {
            InitVerdict::Open { announce } => {
                let key = c.key.clone();
                drop(c);
                if let Some(sentence) = announce {
                    self.delivery.say(&key, &Lane::Conversation, Say::Team, &sentence);
                }
            }
            InitVerdict::Refuse(refusal) => {
                c.quitting = true;
                let lead = c.lead.take();
                let key = c.key.clone();
                drop(c);
                self.log(&format!("{}/{}: init check refused the lead: {}", key.entity_id, key.thread_id, refusal.what));
                if let Some(lead) = lead {
                    let quit = lead.quit();
                    self.log(&format!("{}/{}: refused lead quit: {quit:?}", key.entity_id, key.thread_id));
                }
                self.delivery.say(&key, &Lane::Conversation, Say::Team, &refusal.sentence());
            }
        }
    }

    /// Read what the report server appended since the last read, and act on each record.
    fn take_reports(&self, conversation: &Arc<Mutex<Conversation>>) {
        let (key, outbox, from) = {
            let c = conversation.lock().unwrap();
            (c.key.clone(), c.paths.outbox.clone(), c.record.outbox_read)
        };
        let records = match read_outbox(&outbox) {
            Ok(records) => records,
            Err(e) => {
                self.log(&format!("{}/{}: the outbox could not be read ({e})", key.entity_id, key.thread_id));
                return;
            }
        };
        for (index, record) in records.iter().enumerate().skip(from) {
            self.report(conversation, &key, record);
            let mut c = conversation.lock().unwrap();
            c.record.outbox_read = index + 1;
            self.save(&c.paths.record, &c.record);
        }
    }

    fn report(&self, conversation: &Arc<Mutex<Conversation>>, key: &ConversationKey, record: &ReportRecord) {
        {
            let mut c = conversation.lock().unwrap();
            c.turn_report = Some(record.text.clone());
            if let Some(h) = &record.handle {
                c.handle_agents.entry(h.clone()).or_default().extend(record.agents.iter().cloned());
            }
        }
        let lane = record.handle.clone().map(Lane::Handle).unwrap_or(Lane::Conversation);
        let mut text = record.text.clone();
        for land in &record.lands {
            text.push_str("\n\n");
            text.push_str(&land.says);
        }
        match record.kind.as_str() {
            "question" => {
                conversation.lock().unwrap().questions.push((record.handle.clone(), record.text.clone()));
                self.questions.asked(key, record);
            }
            "outcome" | "failed" => match &record.handle {
                Some(handle) => self.settle_handle(conversation, key, handle, record, &text),
                None => self.delivery.say(key, &lane, if record.kind == "failed" { Say::Failed } else { Say::Outcome }, &text),
            },
            "answer" => self.delivery.say(key, &lane, Say::Answer, &text),
            _ => self.delivery.say(key, &lane, Say::Update, &text),
        }
    }

    /// Only a report settles ((c)): close the obligation through the engine, then the register.
    fn settle_handle(&self, conversation: &Arc<Mutex<Conversation>>, key: &ConversationKey, handle: &str,
                     record: &ReportRecord, text: &str) {
        let lane = Lane::Handle(handle.to_string());
        let item = match assignment::read(&self.state, &key.entity_id, &key.thread_id, handle) {
            Ok(item) => item,
            Err(e) => {
                self.log(&format!("{}/{}: report on {handle} names no readable assignment ({e})", key.entity_id, key.thread_id));
                self.delivery.say(key, &lane, Say::Update, text);
                return;
            }
        };
        let failed = record.kind == "failed";
        let mut evidence: Vec<String> = record.lands.iter().filter(|l| l.landed)
            .map(|l| format!("git:{}:{}:{}", l.repository.display(), l.into, l.commit)).collect();
        use sha2::Digest;
        evidence.push(format!("answer:{:x}", sha2::Sha256::digest(record.text.as_bytes())));
        evidence.truncate(20);
        let status = if failed { ECS_WITHDRAWN } else { "completed" };
        let source = format!("operator-report:{}:{}", record.lead, record.at_ms);
        match self.settle.complete(key, &item.obligation_id, &source, status, &evidence, &record.text) {
            Ok(()) => {
                let (to, kind) = if failed {
                    (AssignmentState::Failed, NoticeKind::Failed)
                } else if item.kind.is_question() {
                    (AssignmentState::Settled, NoticeKind::Answer)
                } else {
                    (AssignmentState::Settled, NoticeKind::Settled)
                };
                let detail = if failed { "Your team reported that it could not be done." } else { "Your team reported it done." };
                if let Err(e) = assignment::advance(&self.state, &key.entity_id, &key.thread_id, handle, to, detail)
                    .and_then(|_| assignment::raise_notice(&self.state, &key.entity_id, &key.thread_id, handle, kind, text)) {
                    self.log(&format!("{}/{}: {handle} settled in the engine; the register could not be updated ({e})",
                                      key.entity_id, key.thread_id));
                }
                let mut c = conversation.lock().unwrap();
                c.record.open_handles.remove(handle);
                c.questions.retain(|(q, _)| q.as_deref() != Some(handle));
                self.save(&c.paths.record, &c.record);
                drop(c);
                self.delivery.say(key, &lane, if failed { Say::Failed } else { Say::Outcome }, text);
            }
            Err(why) => {
                self.log(&format!("{}/{}: operator-complete refused {handle}: {why}", key.entity_id, key.thread_id));
                self.delivery.say(key, &lane, Say::Team,
                    &format!("{text}\n\nYour team reported this, but RichOS could not record it as closed ({why}). It stays open."));
            }
        }
    }

    fn turn_ended(&self, conversation: &Arc<Mutex<Conversation>>, end: TurnEnd) {
        // A turn ended and the banner never came: the check decides now, and refuses.
        let waiting = conversation.lock().unwrap().pending_init.take();
        if let Some(init) = waiting {
            self.check(conversation, &init);
            let refused = { let c = conversation.lock().unwrap(); c.quitting && c.lead.is_none() };
            if refused {
                // A lead the check refused: its first turn's words are not his team's words.
                return;
            }
        }
        self.take_reports(conversation);
        let mut c = conversation.lock().unwrap();
        for uuid in &end.started_by {
            c.awaiting.remove(uuid);
        }
        // The lane is the handle of the first message the CLI took into this turn, if it had
        // one; a turn the platform started itself is the conversation's (r3 (c)).
        let lane = end.started_by.iter().find_map(|u| c.sent.get(u).cloned().flatten())
            .map(Lane::Handle).unwrap_or(Lane::Conversation);
        let last_report = c.turn_report.take();
        c.turn_handle = None;
        c.in_turn = false;
        c.last_activity = Instant::now();
        let key = c.key.clone();
        let deliver = end.text.filter(|t| last_report.as_deref().map(str::trim) != Some(t.trim()));
        if let Some(text) = &deliver {
            c.texts.push_back(text.clone());
            while c.texts.len() > LAST_TEXTS {
                c.texts.pop_front();
            }
        }
        drop(c);
        if let Some(text) = deliver {
            self.delivery.say(&key, &lane, Say::Update, &text);
        }
    }

    /// A positive end: the lead's output closed. Confirmed with `waitid` before anything is
    /// said; an expected end (quit, retirement, refusal) is not news.
    fn ended(&self, conversation: &Arc<Mutex<Conversation>>) {
        let (key, lead, quitting) = {
            let mut c = conversation.lock().unwrap();
            (c.key.clone(), c.lead.take(), c.quitting)
        };
        let Some(lead) = lead else { return };
        let deadline = Instant::now() + Duration::from_secs(2);
        while !lead.exited() && Instant::now() < deadline {
            std::thread::sleep(Duration::from_millis(20));
        }
        let quit = lead.quit();
        if quitting {
            self.log(&format!("{}/{}: lead ended as expected ({quit:?})", key.entity_id, key.thread_id));
            return;
        }
        // r3 (q) item 5: every end not caused by quit or retirement, with its cause, counted.
        self.log(&format!("LEAD ENDED UNEXPECTEDLY {}/{}: its output closed ({quit:?})", key.entity_id, key.thread_id));
        self.delivery.say(&key, &Lane::Conversation, Say::Team,
            "Your team in this conversation has ended. Speak to me here and I'll start it again, resumed where it was.");
    }

    // ---- (d): stops -------------------------------------------------------------------------

    /// **Stop the named agents, and nothing else** (r3 (d) items 1-4 and 7; §67). Accepted from
    /// every channel: a stop only removes (§67), so `origin` is recorded and never gates it.
    pub fn stop_named(&self, names: &[String], words: &str, origin: Origin) -> Vec<StopResult> {
        self.log(&format!("stop of {} from {:?}: {words:?}", names.join(", "), origin));
        if let Err(why) = self.engine.stop_words(names, words) {
            // The ack line is the engine's record of his stop; the stop itself still goes out.
            self.log(&format!("stop.sh did not run cleanly: {why}"));
        }
        names.iter().map(|name| self.stop_one(name, words)).collect()
    }

    fn owner_of(&self, name: &str) -> Option<(Arc<dyn LeadHandle>, String)> {
        let all: Vec<Arc<Mutex<Conversation>>> = self.conversations.lock().unwrap().values().cloned().collect();
        let mut best: Option<(Arc<dyn LeadHandle>, String, bool)> = None;
        for conversation in all {
            let lead = conversation.lock().unwrap().lead.clone();
            let Some(lead) = lead else { continue };
            if let Some(task) = lead.tasks().latest(name).cloned() {
                let running = task.status.is_running();
                if best.as_ref().is_none_or(|(_, _, r)| !r && running) {
                    best = Some((lead, task.task_id, running));
                }
            }
        }
        best.map(|(lead, task, _)| (lead, task))
    }

    fn stop_one(&self, name: &str, words: &str) -> StopResult {
        let Some((lead, task_id)) = self.owner_of(name) else {
            return StopResult::NotFound { name: name.to_string() };
        };
        let began = Instant::now();
        for attempt in 0..2 {
            if let Err(e) = lead.stop_task(&task_id) {
                return StopResult::Failed { name: name.to_string(), why: e.to_string() };
            }
            let deadline = Instant::now() + STOP_WAIT;
            loop {
                match self.engine.liveness(&task_id) {
                    AgentLiveness::NotAlive => {
                        let seconds = (began.elapsed().as_millis() as f64) / 1000.0;
                        let registry = self.registry_step(&lead, name, &task_id, words);
                        return StopResult::Stopped { name: name.to_string(), seconds, registry };
                    }
                    AgentLiveness::Indeterminate(why) if Instant::now() >= deadline => {
                        return StopResult::Indeterminate { name: name.to_string(), why };
                    }
                    _ if Instant::now() >= deadline => break,
                    _ => std::thread::sleep(Duration::from_millis(250)),
                }
            }
            self.log(&format!("{name} still ALIVE {} s after stop attempt {}", STOP_WAIT.as_secs(), attempt + 1));
        }
        StopResult::StillAlive { name: name.to_string() }
    }

    /// r4 §2.1, item 3a: once the stream says `stopped` for the task this host stopped AND the
    /// resolver says NOT-ALIVE, tell his registry what happened, never before it happened.
    fn registry_step(&self, lead: &Arc<dyn LeadHandle>, name: &str, task_id: &str, words: &str) -> Result<(), String> {
        let deadline = Instant::now() + Duration::from_secs(5);
        loop {
            let stopped = lead.tasks().agents().into_iter()
                .any(|a| a.task_id == task_id && matches!(a.status, TaskStatus::Stopped | TaskStatus::Killed));
            if stopped {
                break;
            }
            if Instant::now() >= deadline {
                let why = "the stream never said it stopped, so the registry was not told".to_string();
                self.log(&format!("{name}: {why}"));
                return Err(why);
            }
            std::thread::sleep(Duration::from_millis(100));
        }
        self.engine.registry_stop(&lead.session_id(), name, words).map(|_| ())
            .inspect_err(|why| self.log(&format!("{name}: workspaces.sh stop failed: {why}")))
    }

    /// (d) item 5: the per-assignment Stop stops exactly the names seen starting on that
    /// assignment's turns, plus the names its reports named.
    pub fn stop_assignment(&self, key: &ConversationKey, handle: &str, words: &str, origin: Origin) -> Vec<StopResult> {
        let names: Vec<String> = self.conversations.lock().unwrap().get(key)
            .and_then(|c| c.lock().unwrap().handle_agents.get(handle).cloned())
            .map(|set| set.into_iter().collect()).unwrap_or_default();
        if names.is_empty() {
            return Vec::new();
        }
        self.stop_named(&names, words, origin)
    }

    /// (d) item 6, his Esc: end the lead's running turn, never its agents (P3). Returns the
    /// sentence the front desk says, with how many of his messages still run next (r4 §1.2).
    pub fn interrupt(&self, key: &ConversationKey) -> String {
        let lead = self.conversations.lock().unwrap().get(key).and_then(|c| c.lock().unwrap().lead.clone());
        let Some(lead) = lead else { return "Your team isn't doing anything in this conversation.".into() };
        match lead.interrupt() {
            Ok(reply) => match reply.still_queued.len() {
                0 => "Stopped what your team was doing here. Its agents keep running.".into(),
                1 => "Stopped what your team was doing here. Its agents keep running, and 1 of your messages is still queued and runs next.".into(),
                n => format!("Stopped what your team was doing here. Its agents keep running, and {n} of your messages are still queued and run next."),
            },
            Err(e) => format!("Your team could not be interrupted ({e}). It is still running."),
        }
    }

    // ---- (o) and (m): reads -----------------------------------------------------------------

    fn read_one(&self, conversation: &Arc<Mutex<Conversation>>, leases: &[String]) -> ConversationRead {
        let c = conversation.lock().unwrap();
        let agents = c.lead.as_ref().map(|l| l.tasks().agents().into_iter()
            .map(|a| (a.name, a.status.as_str().to_string())).collect()).unwrap_or_default();
        let title = c.title.clone();
        ConversationRead {
            key: c.key.clone(),
            lead_running: c.lead.as_ref().is_some_and(|l| !l.exited()),
            agents,
            texts: c.texts.iter().cloned().collect(),
            open_questions: c.questions.iter().map(|(h, q)| match h {
                Some(h) => format!("on {h}: {q} (asked, no answer relayed yet)"),
                None => format!("{q} (asked, no answer relayed yet)"),
            }).collect(),
            leases: leases.iter().filter(|l| lease_held_by(l, &title)).cloned().collect(),
        }
    }

    /// (o): this conversation's read, or every conversation's on request. A read adds no
    /// capability, so it is answered on every channel.
    pub fn read(&self, key: &ConversationKey, every: bool) -> Vec<ConversationRead> {
        let leases = self.engine.held_leases();
        let all: Vec<Arc<Mutex<Conversation>>> = self.conversations.lock().unwrap().iter()
            .filter(|(k, _)| every || *k == key).map(|(_, c)| c.clone()).collect();
        all.iter().map(|c| self.read_one(c, &leases)).collect()
    }

    /// (m): his team counts as running while any agent of any lead is ALIVE, or any lead's
    /// supervisor records a live descendant outside the lead's own group.
    pub fn team(&self) -> TeamReading {
        self.team_reading(|agent| self.engine.liveness(&agent.task_id))
    }

    /// **(m) without a subprocess**, for a caller that must answer at once: the app's exit
    /// decision runs inside the runtime's own callback, whose answer is read the instant it
    /// returns (background-work spec §2.5a), so it cannot wait on `agent-liveness.sh`. An agent
    /// counts as running while its own stream says so (`task_started` without a later end, the
    /// platform's positive signals, r4 §1.1): an agent the stream has not seen end is never
    /// read as gone. The update gate, which is not in a callback, keeps [`Self::team`].
    pub fn team_from_stream(&self) -> TeamReading {
        self.team_reading(|agent| if agent.status.is_running() { AgentLiveness::Alive } else { AgentLiveness::NotAlive })
    }

    fn team_reading(&self, liveness: impl Fn(&crate::operator_lead::AgentTask) -> AgentLiveness) -> TeamReading {
        let mut reading = TeamReading::default();
        let all: Vec<Arc<Mutex<Conversation>>> = self.conversations.lock().unwrap().values().cloned().collect();
        for conversation in all {
            let (lead, state, busy, name) = {
                let c = conversation.lock().unwrap();
                let name = if c.title.is_empty() { c.key.thread_id.clone() } else { c.title.clone() };
                (c.lead.clone(), c.paths.reap_state.clone(), c.in_turn || !c.awaiting.is_empty(), name)
            };
            let Some(lead) = lead else { continue };
            if busy && !lead.exited() {
                reading.working.push(name);
            }
            for agent in lead.tasks().agents() {
                match liveness(&agent) {
                    AgentLiveness::Alive => reading.alive.push(agent.name),
                    AgentLiveness::Indeterminate(_) => reading.unknown.push(agent.name),
                    AgentLiveness::NotAlive => {}
                }
            }
            match live_descendants(&state) {
                Some(n) => reading.descendants += n,
                None if !lead.exited() => reading.descendants_unknown += 1,
                None => {}
            }
        }
        reading
    }

    // ---- (q): retirement and quit -----------------------------------------------------------

    /// How many conversations have a lead running right now. The idle timer asks this first,
    /// so an app with no lead running spends nothing on his engine's scripts every minute.
    pub fn running_leads(&self) -> usize {
        let all: Vec<Arc<Mutex<Conversation>>> = self.conversations.lock().unwrap().values().cloned().collect();
        all.iter().filter(|c| c.lock().unwrap().lead.as_ref().is_some_and(|l| !l.exited())).count()
    }

    /// (q) item 4: retire every lead with nothing running that has been idle `idle_after`, or
    /// at once when its start-time snapshot is stale. Returns the conversations retired. The
    /// next message resumes each (r3 (l)).
    pub fn retire_idle(&self, idle_after: Duration) -> Vec<ConversationKey> {
        let digest = snapshot_digest(&self.declaration);
        let leases = self.engine.held_leases();
        let all: Vec<Arc<Mutex<Conversation>>> = self.conversations.lock().unwrap().values().cloned().collect();
        let mut retired = Vec::new();
        for conversation in all {
            let mut c = conversation.lock().unwrap();
            let Some(lead) = c.lead.clone() else { continue };
            let stale = c.started_digest != digest;
            if c.in_turn || !c.awaiting.is_empty() || (!stale && c.last_activity.elapsed() < idle_after) {
                continue;
            }
            // Nothing running: no ALIVE (or undecided) agent, no live descendant outside the
            // lead's own group (G8: language servers and MCP servers share its group and do not
            // count), and no land lease held by this conversation.
            let agents_busy = lead.tasks().agents().iter().any(|a| self.engine.liveness(&a.task_id) != AgentLiveness::NotAlive);
            let descendants = live_descendants(&c.paths.reap_state);
            let lease = leases.iter().any(|l| lease_held_by(l, &c.title));
            if agents_busy || descendants != Some(0) || lease {
                continue;
            }
            c.quitting = true;
            c.lead = None;
            c.first_after_resume = true;
            let key = c.key.clone();
            drop(c);
            let quit = lead.quit();
            self.log(&format!("{}/{}: retired idle{} ({quit:?})", key.entity_id, key.thread_id,
                              if stale { ", its start snapshot was stale" } else { "" }));
            retired.push(key);
        }
        retired
    }

    /// The quit path: every lead by SIGTERM to its supervisor (r3 (q) item 2).
    pub fn quit_all(&self) -> Vec<(ConversationKey, Quit)> {
        let all: Vec<Arc<Mutex<Conversation>>> = self.conversations.lock().unwrap().values().cloned().collect();
        let mut out = Vec::new();
        for conversation in all {
            let lead = {
                let mut c = conversation.lock().unwrap();
                c.quitting = true;
                c.lead.take().map(|l| (c.key.clone(), l))
            };
            if let Some((key, lead)) = lead {
                let quit = lead.quit();
                self.log(&format!("{}/{}: quit ({quit:?})", key.entity_id, key.thread_id));
                out.push((key, quit));
            }
        }
        out
    }
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;
    use crate::assignment::{AssignmentKind, Registration};
    use crate::operator_declaration::ClaimPaths;
    use crate::operator_lead::AgentTask;
    use serde_json::json;
    use std::collections::BTreeMap;

    // ---- fakes -----------------------------------------------------------------------------

    #[derive(Default)]
    pub(crate) struct FakeLead {
        pub(crate) session: String,
        pub(crate) sent: Mutex<Vec<String>>,
        pub(crate) stops: Mutex<Vec<String>>,
        pub(crate) book: Mutex<TaskBook>,
        pub(crate) exited: Mutex<bool>,
        pub(crate) quits: Mutex<usize>,
        pub(crate) fail_send: Mutex<bool>,
        pub(crate) queued: usize,
    }
    impl FakeLead {
        pub(crate) fn feed(&self, frame: Value) {
            self.book.lock().unwrap().observe(&frame);
        }
    }
    impl LeadHandle for FakeLead {
        fn session_id(&self) -> String { self.session.clone() }
        fn send(&self, text: &str) -> Result<String, LeadError> {
            if *self.fail_send.lock().unwrap() {
                return Err(LeadError::Io("Broken pipe".into()));
            }
            self.sent.lock().unwrap().push(text.to_string());
            Ok(format!("u-{}", self.sent.lock().unwrap().len()))
        }
        fn stop_task(&self, task_id: &str) -> Result<(), LeadError> {
            self.stops.lock().unwrap().push(task_id.to_string());
            Ok(())
        }
        fn interrupt(&self) -> Result<InterruptReply, LeadError> {
            Ok(InterruptReply { still_queued: (0..self.queued).map(|i| format!("q-{i}")).collect() })
        }
        fn tasks(&self) -> TaskBook { self.book.lock().unwrap().clone() }
        fn exited(&self) -> bool { *self.exited.lock().unwrap() }
        fn quit(&self) -> Quit {
            *self.quits.lock().unwrap() += 1;
            *self.exited.lock().unwrap() = true;
            Quit::Terminated { waited: Duration::ZERO }
        }
    }

    #[derive(Default)]
    pub(crate) struct FakeLauncher {
        pub(crate) leads: Mutex<Vec<(ConversationKey, LeadStart, Arc<FakeLead>)>>,
        pub(crate) queued: usize,
    }
    impl LeadLauncher for FakeLauncher {
        fn launch(&self, key: &ConversationKey, _title: &str, start: &LeadStart, _paths: &ConversationPaths,
                  _sink: Arc<dyn LeadSink>) -> Result<Arc<dyn LeadHandle>, String> {
            let session = match start { LeadStart::New(s) | LeadStart::Resume(s) => s.clone() };
            let lead = Arc::new(FakeLead { session, queued: self.queued, ..Default::default() });
            self.leads.lock().unwrap().push((key.clone(), start.clone(), lead.clone()));
            Ok(lead)
        }
        fn fences(&self) -> Result<(), String> { Ok(()) }
    }

    /// `not_alive` holds AGENT IDS (task ids), as the real resolver is asked.
    #[derive(Default)]
    pub(crate) struct FakeEngine {
        pub(crate) stop_words: Mutex<Vec<(Vec<String>, String)>>,
        pub(crate) registry: Mutex<Vec<(String, String, String)>>,
        pub(crate) not_alive: Mutex<BTreeSet<String>>,
        pub(crate) asked: Mutex<Vec<String>>,
        pub(crate) leases: Mutex<Vec<String>>,
    }
    impl OperatorEngine for FakeEngine {
        fn stop_words(&self, names: &[String], words: &str) -> Result<String, String> {
            self.stop_words.lock().unwrap().push((names.to_vec(), words.to_string()));
            Ok(String::new())
        }
        fn liveness(&self, agent_id: &str) -> AgentLiveness {
            self.asked.lock().unwrap().push(agent_id.to_string());
            if self.not_alive.lock().unwrap().contains(agent_id) { AgentLiveness::NotAlive } else { AgentLiveness::Alive }
        }
        fn registry_stop(&self, session: &str, name: &str, words: &str) -> Result<String, String> {
            self.registry.lock().unwrap().push((session.into(), name.into(), words.into()));
            Ok("stopped".into())
        }
        fn held_leases(&self) -> Vec<String> { self.leases.lock().unwrap().clone() }
    }

    #[derive(Default)]
    pub(crate) struct FakeSettle {
        pub(crate) calls: Mutex<Vec<(String, String, Vec<String>)>>,
        pub(crate) refuse: Mutex<Option<String>>,
    }
    impl Settle for FakeSettle {
        fn complete(&self, _key: &ConversationKey, obligation: &str, _source: &str, status: &str, evidence: &[String],
                    _answer: &str) -> Result<(), String> {
            if let Some(why) = self.refuse.lock().unwrap().clone() {
                return Err(why);
            }
            self.calls.lock().unwrap().push((obligation.into(), status.into(), evidence.to_vec()));
            Ok(())
        }
    }

    #[derive(Default)]
    pub(crate) struct Said(pub(crate) Mutex<Vec<(ConversationKey, Lane, Say, String)>>);
    impl OperatorDelivery for Said {
        fn say(&self, key: &ConversationKey, lane: &Lane, kind: Say, text: &str) {
            self.0.lock().unwrap().push((key.clone(), lane.clone(), kind, text.to_string()));
        }
    }
    impl Said {
        pub(crate) fn all(&self) -> Vec<(ConversationKey, Lane, Say, String)> { self.0.lock().unwrap().clone() }
    }

    struct Rig {
        root: PathBuf,
        host: Arc<OperatorHost>,
        launcher: Arc<FakeLauncher>,
        engine: Arc<FakeEngine>,
        settle: Arc<FakeSettle>,
        said: Arc<Said>,
        state: PathBuf,
        declaration: Declaration,
    }
    impl Drop for Rig {
        fn drop(&mut self) {
            if let Err(error) = std::fs::remove_dir_all(&self.root) { eprintln!("fixture cleanup: {error}"); }
        }
    }

    pub(crate) fn declaration(root: &Path, origins: &[&str]) -> Declaration {
        let home = root.join("home");
        let entity = home.join("ab/femcboost");
        std::fs::create_dir_all(&entity).unwrap();
        std::fs::write(entity.join("CLAUDE.md"), "rules\n").unwrap();
        std::fs::write(entity.join("orchestration.config"), "OPERATOR_FENCES=\"on\"\n").unwrap();
        let mut environment = BTreeMap::new();
        environment.insert("PATH".to_string(), "/usr/bin:/bin".to_string());
        Declaration {
            entity_root: entity, engine_root: home.join("ab/richos/richos/engine"), home: home.clone(),
            claim: ClaimPaths { file: home.join(".claude/state/operator-lead.json"), lock: home.join(".claude/state/operator-lead.lock") },
            permission_mode: "bypassPermissions".into(), environment,
            origins: origins.iter().map(|s| s.to_string()).collect(), file_roots: vec![home.join("ab")],
            contract_path: home.join("ab/contract.md"), contract_sha256: "0".repeat(64),
        }
    }

    fn rig_with(origins: &[&str], queued: usize) -> Rig {
        let root = std::env::temp_dir().join(format!("operator-host-{}", uuid::Uuid::new_v4()));
        let root = { std::fs::create_dir_all(&root).unwrap(); std::fs::canonicalize(&root).unwrap() };
        let declaration = declaration(&root, origins);
        let launcher = Arc::new(FakeLauncher { queued, ..Default::default() });
        let engine = Arc::new(FakeEngine::default());
        let settle = Arc::new(FakeSettle::default());
        let said = Arc::new(Said::default());
        let state = root.join("engine-state");
        let host = OperatorHost::new(declaration.clone(), &state, &root.join("operator"), launcher.clone(), engine.clone(),
                                     settle.clone(), said.clone(), Arc::new(SayQuestions(said.clone())));
        Rig { root, host, launcher, engine, settle, said, state, declaration }
    }

    fn rig() -> Rig {
        rig_with(&["desk-typed", "desk-voice", "desk-file"], 0)
    }

    fn key(thread: &str) -> ConversationKey {
        ConversationKey { entity_id: "femcboost".into(), thread_id: thread.into() }
    }

    fn lead_of(r: &Rig, thread: &str) -> Arc<FakeLead> {
        r.launcher.leads.lock().unwrap().iter().rev().find(|(k, _, _)| k.thread_id == thread).unwrap().2.clone()
    }

    fn register(r: &Rig, thread: &str, kind: AssignmentKind) -> String {
        assignment::register_kind(&r.state, &Registration {
            entity_id: "femcboost".into(), thread_id: thread.into(), obligation_id: format!("ob-{}", uuid::Uuid::new_v4()),
            instruction_ledger_ref: format!("ledger:{thread}:1"), instruction_sha256: "a".repeat(64),
            title: "Fixture work".into(), repositories: vec![], needs_screen: false,
        }, kind).unwrap().id
    }

    fn outbox(r: &Rig, thread: &str, records: &[Value]) {
        let path = ConversationPaths::under(&r.root.join("operator"), &key(thread)).outbox;
        let mut text = std::fs::read_to_string(&path).unwrap_or_default();
        for v in records {
            text.push_str(&v.to_string());
            text.push('\n');
        }
        std::fs::write(path, text).unwrap();
    }

    fn report(handle: Option<&str>, kind: &str, text: &str) -> Value {
        json!({"version":1,"at_ms":1,"lead":"claim-1","entity_id":"femcboost","thread_id":"t","handle":handle,"kind":kind,
               "text":text,"attachment":null,"lands":[],"files":[],"agents":[]})
    }

    fn turn(started_by: &[&str], text: Option<&str>) -> LeadEvent {
        LeadEvent::TurnEnded(TurnEnd { started_by: started_by.iter().map(|s| s.to_string()).collect(),
                                       text: text.map(str::to_string), is_error: false, subtype: "success".into() })
    }

    pub(crate) fn agent(lead: &FakeLead, tool: &str, name: &str, task: &str) {
        lead.feed(json!({"type":"assistant","message":{"content":[{"type":"tool_use","id":tool,"name":"Agent","input":{"name":name}}]}}));
        lead.feed(json!({"type":"system","subtype":"task_started","task_id":task,"tool_use_id":tool}));
    }

    // ---- (g) relay, never hold; (s) the origin rule -----------------------------------------

    #[test]
    fn every_message_is_relayed_at_once_and_one_lead_serves_the_conversation() {
        let r = rig();
        for i in 0..3 {
            let got = r.host.relay(&key("a"), "Conversation A", None, &format!("message {i}"), Origin::DeskTyped).unwrap();
            assert!(matches!(got, Relayed::Sent { .. }), "nothing is held behind a running turn");
        }
        assert_eq!(r.launcher.leads.lock().unwrap().len(), 1, "one lead per conversation");
        assert_eq!(lead_of(&r, "a").sent.lock().unwrap().len(), 3);
        r.host.relay(&key("b"), "Conversation B", None, "other", Origin::DeskVoice).unwrap();
        assert_eq!(r.launcher.leads.lock().unwrap().len(), 2, "a second conversation gets its own lead");
    }

    #[test]
    fn a_phone_assignment_is_not_relayed_and_a_turn_with_no_origin_relays_nothing() {
        let r = rig();
        assert_eq!(r.host.relay(&key("a"), "A", Some("h-1"), "land it", Origin::Phone).unwrap(),
                   Relayed::Not { sentence: Some(PHONE_ASSIGNMENT.into()) });
        assert_eq!(r.host.relay(&key("a"), "A", None, "proactive words", Origin::NoOrigin).unwrap(),
                   Relayed::Not { sentence: None });
        assert!(r.launcher.leads.lock().unwrap().is_empty(), "no lead was even started");
        // Opening the phone is one line in the declaration, and his call.
        let open = rig_with(&["desk-typed", "phone"], 0);
        assert!(matches!(open.host.relay(&key("a"), "A", None, "x", Origin::Phone).unwrap(), Relayed::Sent { .. }));
    }

    #[test]
    fn a_turn_s_origin_is_its_recorded_mouth_and_an_unrecorded_one_is_no_origin() {
        use crate::ledger::Source::{Internal, Jam, Proactive, Text};
        assert_eq!(Origin::of_turn(Text, Some("desk")), Origin::DeskTyped);
        assert_eq!(Origin::of_turn(Jam, Some("desk")), Origin::DeskVoice);
        assert_eq!(Origin::of_turn(Text, Some("phone")), Origin::Phone);
        assert_eq!(Origin::of_turn(Jam, Some("phone")), Origin::Phone, "a voice note from the phone is the phone");
        assert_eq!(Origin::of_turn(Text, Some("watch")), Origin::Undeclared);
        assert_eq!(Origin::of_turn(Text, None), Origin::NoOrigin, "not recorded is never the desk");
        assert_eq!(Origin::of_turn(Jam, None), Origin::NoOrigin);
        assert_eq!(Origin::of_turn(Internal, Some("desk")), Origin::NoOrigin, "an internal turn carries none of his words");
        assert_eq!(Origin::of_turn(Proactive, Some("desk")), Origin::NoOrigin);
    }

    #[test]
    fn an_undeclared_mouth_is_refused_as_work_with_the_sentence() {
        let r = rig_with(&["desk-typed", "desk-voice", "desk-file"], 0);
        let said = r.host.relay(&key("t"), "T", None, "do the thing", Origin::Undeclared).unwrap();
        assert_eq!(said, Relayed::Not { sentence: Some(PHONE_ASSIGNMENT.into()) });
        assert!(r.launcher.leads.lock().unwrap().is_empty(), "no lead was started for it");
    }

    #[test]
    fn a_relay_that_cannot_be_written_is_said_and_the_lead_is_kept() {
        let r = rig();
        r.host.relay(&key("a"), "A", None, "first", Origin::DeskTyped).unwrap();
        let lead = lead_of(&r, "a");
        *lead.fail_send.lock().unwrap() = true;
        let why = r.host.relay(&key("a"), "A", None, "second", Origin::DeskTyped).unwrap_err();
        assert!(why.contains("still running"), "{why}");
        assert_eq!(*lead.quits.lock().unwrap(), 0, "r3 (q) item 1: an error never ends a lead");
    }

    #[test]
    fn the_handle_goes_with_the_words_and_the_changed_since_line_with_the_next_relay() {
        let r = rig();
        r.host.relay(&key("a"), "A", Some("h-1"), "Land the phone fix.", Origin::DeskTyped).unwrap();
        let memory = watched_paths(&r.declaration)[0].clone();
        std::fs::create_dir_all(&memory).unwrap();
        std::thread::sleep(Duration::from_millis(1100));
        std::fs::write(memory.join("MEMORY.md"), "- a new rule\n").unwrap();
        r.host.relay(&key("a"), "A", None, "Next.", Origin::DeskTyped).unwrap();
        let sent = lead_of(&r, "a").sent.lock().unwrap().clone();
        assert!(sent[0].contains("Assignment handle: h-1."), "{}", sent[0]);
        assert!(!sent[0].contains("Changed since"), "nothing changed before the first relay");
        assert!(sent[1].starts_with("Changed since your last message: ") && sent[1].contains("MEMORY.md")
                && sent[1].contains("Read them before you act."), "{}", sent[1]);
        r.host.relay(&key("a"), "A", None, "And again.", Origin::DeskTyped).unwrap();
        let sent = lead_of(&r, "a").sent.lock().unwrap().clone();
        assert!(!sent[2].contains("Changed since"), "said once, not at every relay: {}", sent[2]);
    }

    // ---- (c) reports settle; the last text ---------------------------------------------------

    #[test]
    fn only_a_report_settles_and_its_lands_are_the_evidence() {
        let r = rig();
        let handle = register(&r, "a", AssignmentKind::Task);
        r.host.relay(&key("a"), "A", Some(&handle), "Land it.", Origin::DeskTyped).unwrap();
        r.host.handle(&key("a"), turn(&["u-1"], Some("Working on it.")));
        let item = assignment::read(&r.state, "femcboost", "a", &handle).unwrap();
        assert_eq!(item.state, AssignmentState::Registered, "a turn ending never settles");
        let mut rec = report(Some(&handle), "outcome", "Landed and pushed.");
        rec["lands"] = json!([{"repository":"/r","commit":"a".repeat(40),"branch":"x","into":"main","landed":true,
                              "pushed":true,"why":null,"says":"Landed and pushed x in r."},
                             {"repository":"/r","commit":"b".repeat(40),"branch":"y","into":"main","landed":false,
                              "pushed":null,"why":"commit bbbb is not on main","says":"y in r could not be confirmed as landed."}]);
        outbox(&r, "a", &[rec]);
        r.host.handle(&key("a"), turn(&[], None));
        let calls = r.settle.calls.lock().unwrap().clone();
        assert_eq!(calls.len(), 1);
        assert_eq!(calls[0].1, "completed");
        assert_eq!(calls[0].2.len(), 2, "the confirmed land and the answer, never the unconfirmed land: {:?}", calls[0].2);
        assert_eq!(calls[0].2[0], format!("git:/r:main:{}", "a".repeat(40)));
        assert!(calls[0].2[1].starts_with("answer:"));
        let item = assignment::read(&r.state, "femcboost", "a", &handle).unwrap();
        assert_eq!(item.state, AssignmentState::Settled);
        let outcome = r.said.all().into_iter().find(|x| x.2 == Say::Outcome).unwrap();
        assert!(outcome.3.contains("could not be confirmed as landed"), "{}", outcome.3);
        // A second read of the same outbox settles nothing twice.
        r.host.handle(&key("a"), turn(&[], None));
        assert_eq!(r.settle.calls.lock().unwrap().len(), 1);
    }

    #[test]
    fn a_failed_report_closes_as_withdrawn_and_a_question_kind_settles_as_an_answer() {
        let r = rig();
        let job = register(&r, "a", AssignmentKind::Task);
        let ask = register(&r, "a", AssignmentKind::Check);
        r.host.relay(&key("a"), "A", Some(&job), "Try it.", Origin::DeskTyped).unwrap();
        outbox(&r, "a", &[report(Some(&job), "failed", "It cannot be done: the remote refuses."),
                          report(Some(&ask), "outcome", "Yes, 42 of them.")]);
        r.host.handle(&key("a"), turn(&[], None));
        let calls = r.settle.calls.lock().unwrap().clone();
        assert_eq!(calls[0].1, ECS_WITHDRAWN);
        assert_eq!(assignment::read(&r.state, "femcboost", "a", &job).unwrap().state, AssignmentState::Failed);
        let answered = assignment::read(&r.state, "femcboost", "a", &ask).unwrap();
        assert_eq!(answered.state, AssignmentState::Settled);
        assert_eq!(answered.notices.last().unwrap().kind, NoticeKind::Answer, "§58: an answer is never 'done'");
    }

    #[test]
    fn a_refused_settlement_leaves_the_assignment_open_and_says_so() {
        let r = rig();
        let handle = register(&r, "a", AssignmentKind::Task);
        r.host.relay(&key("a"), "A", Some(&handle), "Land it.", Origin::DeskTyped).unwrap();
        *r.settle.refuse.lock().unwrap() = Some("obligation not open".into());
        outbox(&r, "a", &[report(Some(&handle), "outcome", "Done.")]);
        r.host.handle(&key("a"), turn(&[], None));
        assert_eq!(assignment::read(&r.state, "femcboost", "a", &handle).unwrap().state, AssignmentState::Registered);
        assert!(r.said.all().iter().any(|(_, _, k, t)| *k == Say::Team && t.contains("could not record it as closed")));
    }

    #[test]
    fn a_turn_s_final_text_is_delivered_unless_it_is_the_last_report_s_text() {
        let r = rig();
        r.host.relay(&key("a"), "A", Some("h-1"), "Do it.", Origin::DeskTyped).unwrap();
        outbox(&r, "a", &[report(Some("h-1"), "update", "Half done.")]);
        r.host.handle(&key("a"), turn(&["u-1"], Some("Half done.")));
        let updates: Vec<_> = r.said.all().into_iter().filter(|(_, _, k, _)| *k == Say::Update).collect();
        assert_eq!(updates.len(), 1, "the report was said, and its twin text was not: {updates:?}");
        // A turn that reports and then says more delivers both (r3's B5 edge).
        outbox(&r, "a", &[report(Some("h-1"), "update", "Built.")]);
        r.host.handle(&key("a"), turn(&[], Some("Built. Also: the suite took 19 minutes.")));
        let texts: Vec<String> = r.said.all().into_iter().filter(|(_, _, k, _)| *k == Say::Update).map(|x| x.3).collect();
        assert_eq!(texts, ["Half done.", "Built.", "Built. Also: the suite took 19 minutes."]);
    }

    #[test]
    fn a_platform_turn_speaks_on_the_conversation_and_a_relayed_one_on_its_handle() {
        let r = rig();
        r.host.relay(&key("a"), "A", Some("h-9"), "Do it.", Origin::DeskTyped).unwrap();
        r.host.handle(&key("a"), turn(&["u-1"], Some("Started.")));
        r.host.handle(&key("a"), turn(&[], Some("The teammate finished.")));
        let lanes: Vec<Lane> = r.said.all().into_iter().map(|x| x.1).collect();
        assert_eq!(lanes, [Lane::Handle("h-9".into()), Lane::Conversation]);
        let read = r.host.read(&key("a"), false);
        assert_eq!(read[0].texts, ["Started.", "The teammate finished."]);
    }

    #[test]
    fn a_question_asked_mid_turn_reaches_him_before_the_turn_ends() {
        let r = rig();
        r.host.relay(&key("a"), "A", Some("h-1"), "A long job.", Origin::DeskTyped).unwrap();
        outbox(&r, "a", &[report(Some("h-1"), "question", "Blue or green?")]);
        r.host.handle(&key("a"), LeadEvent::Reported);
        assert!(r.said.all().iter().any(|x| x.2 == Say::Question), "said while the turn still runs");
        // The turn then ends with the same words: said once, not twice.
        r.host.handle(&key("a"), turn(&["u-1"], Some("Blue or green?")));
        assert_eq!(r.said.all().len(), 1, "{:?}", r.said.all());
    }

    // ---- §88 seam: questions out, answers in -------------------------------------------------

    #[test]
    fn a_question_goes_to_the_sink_and_an_answer_reaches_the_lead_once_from_any_channel() {
        let r = rig();
        r.host.relay(&key("a"), "A", Some("h-1"), "Do it.", Origin::DeskTyped).unwrap();
        outbox(&r, "a", &[report(Some("h-1"), "question", "Ship tonight or tomorrow?")]);
        r.host.handle(&key("a"), turn(&[], None));
        assert!(r.said.all().iter().any(|(_, l, k, t)| *k == Say::Question && *l == Lane::Handle("h-1".into())
                                        && t == "Ship tonight or tomorrow?"));
        assert_eq!(r.host.read(&key("a"), false)[0].open_questions.len(), 1);
        assert!(r.host.deliver_answer(&key("a"), "A", Some("h-1"), "delivery-1", "Tomorrow.").unwrap());
        assert!(!r.host.deliver_answer(&key("a"), "A", Some("h-1"), "delivery-1", "Tomorrow.").unwrap(), "deduplicated");
        let sent = lead_of(&r, "a").sent.lock().unwrap().clone();
        assert_eq!(sent.iter().filter(|s| s.contains("His answer to your question on h-1")).count(), 1);
        assert!(r.host.read(&key("a"), false)[0].open_questions.is_empty());
    }

    // ---- (d) stops ---------------------------------------------------------------------------

    #[test]
    fn a_named_stop_stops_that_task_tells_the_registry_and_leaves_the_other() {
        let r = rig();
        r.host.relay(&key("a"), "A", None, "go", Origin::DeskTyped).unwrap();
        let lead = lead_of(&r, "a");
        agent(&lead, "t-a", "mark-sonnet-a", "task-a");
        agent(&lead, "t-b", "mark-sonnet-b", "task-b");
        r.engine.not_alive.lock().unwrap().insert("task-a".into());
        lead.feed(json!({"type":"system","subtype":"task_notification","task_id":"task-a","status":"stopped"}));
        let results = r.host.stop_named(&["mark-sonnet-a".into()], "stop a", Origin::Phone);
        assert!(matches!(&results[0], StopResult::Stopped { name, registry: Ok(()), .. } if name == "mark-sonnet-a"), "{results:?}");
        assert_eq!(*lead.stops.lock().unwrap(), ["task-a"], "only the named task");
        assert!(r.engine.asked.lock().unwrap().iter().all(|t| t == "task-a"), "liveness asked by agent id, never by name");
        assert_eq!(r.engine.stop_words.lock().unwrap()[0], (vec!["mark-sonnet-a".to_string()], "stop a".to_string()));
        let registry = r.engine.registry.lock().unwrap().clone();
        assert_eq!(registry, [(lead.session.clone(), "mark-sonnet-a".to_string(), "stop a".to_string())]);
        assert_eq!(results[0].sentence(), "Stopped mark-sonnet-a.");
    }

    #[test]
    fn no_registry_step_without_the_stream_saying_stopped() {
        let r = rig();
        r.host.relay(&key("a"), "A", None, "go", Origin::DeskTyped).unwrap();
        let lead = lead_of(&r, "a");
        agent(&lead, "t-a", "a", "task-a");
        r.engine.not_alive.lock().unwrap().insert("task-a".into());
        let results = r.host.stop_named(&["a".into()], "stop a", Origin::DeskTyped);
        assert!(matches!(&results[0], StopResult::Stopped { registry: Err(_), .. }), "{results:?}");
        assert!(r.engine.registry.lock().unwrap().is_empty(), "the registry is told only what happened");
    }

    #[test]
    fn a_name_no_lead_holds_is_not_found_and_nothing_is_stopped() {
        let r = rig();
        r.host.relay(&key("a"), "A", None, "go", Origin::DeskTyped).unwrap();
        let results = r.host.stop_named(&["nobody".into()], "stop nobody", Origin::DeskTyped);
        assert_eq!(results, [StopResult::NotFound { name: "nobody".into() }]);
        assert!(lead_of(&r, "a").stops.lock().unwrap().is_empty());
    }

    /// (d) item 5 through the stream alone: the CLI taking a message on a handle makes the
    /// agents its turn starts that handle's, and a turn on no handle (or the next one, on
    /// another) claims nothing for it.
    #[test]
    fn an_agent_started_in_a_turn_the_cli_took_on_a_handle_is_that_assignment_s() {
        let r = rig();
        let uuid = match r.host.relay(&key("a"), "A", Some("h-1"), "go", Origin::DeskTyped).unwrap() {
            Relayed::Sent { uuid } => uuid,
            other => panic!("{other:?}"),
        };
        let lead = lead_of(&r, "a");
        r.host.handle(&key("a"), LeadEvent::Took(uuid.clone()));
        agent(&lead, "t-a", "started-on-h1", "task-a");
        r.host.handle(&key("a"), LeadEvent::Agent(AgentTask { name: "started-on-h1".into(), task_id: "task-a".into(),
                                                             tool_use_id: "t-a".into(), status: TaskStatus::Running }));
        r.host.handle(&key("a"), turn(&[uuid.as_str()], None));
        // The next turn is the platform's own: what it starts is nobody's assignment.
        agent(&lead, "t-o", "after-the-turn", "task-o");
        r.host.handle(&key("a"), LeadEvent::Agent(AgentTask { name: "after-the-turn".into(), task_id: "task-o".into(),
                                                             tool_use_id: "t-o".into(), status: TaskStatus::Running }));
        r.engine.not_alive.lock().unwrap().insert("task-a".into());
        let results = r.host.stop_assignment(&key("a"), "h-1", "stop that job", Origin::DeskTyped);
        assert_eq!(r.engine.stop_words.lock().unwrap()[0].0, ["started-on-h1"]);
        assert_eq!(*lead.stops.lock().unwrap(), ["task-a"], "only that assignment's agent");
        assert_eq!(results.len(), 1);
    }

    #[test]
    fn the_assignment_stop_stops_the_names_its_turns_started_and_its_reports_named() {
        let r = rig();
        r.host.relay(&key("a"), "A", Some("h-1"), "go", Origin::DeskTyped).unwrap();
        let lead = lead_of(&r, "a");
        // A turn attributed to h-1 is running when the agent starts.
        {
            let c = r.host.conversations.lock().unwrap().get(&key("a")).cloned().unwrap();
            c.lock().unwrap().turn_handle = Some("h-1".into());
        }
        agent(&lead, "t-a", "started-on-h1", "task-a");
        r.host.handle(&key("a"), LeadEvent::Agent(AgentTask { name: "started-on-h1".into(), task_id: "task-a".into(),
                                                             tool_use_id: "t-a".into(), status: TaskStatus::Running }));
        agent(&lead, "t-o", "other-work", "task-o");
        let mut rec = report(Some("h-1"), "update", "working");
        rec["agents"] = json!(["reported-on-h1"]);
        outbox(&r, "a", &[rec]);
        r.host.handle(&key("a"), turn(&[], None));
        r.engine.not_alive.lock().unwrap().insert("task-a".into());
        let results = r.host.stop_assignment(&key("a"), "h-1", "stop that job", Origin::DeskTyped);
        let names: Vec<String> = r.engine.stop_words.lock().unwrap()[0].0.clone();
        assert_eq!(names, ["reported-on-h1", "started-on-h1"]);
        assert!(!lead.stops.lock().unwrap().contains(&"task-o".to_string()), "other work is never stopped");
        assert_eq!(results.len(), 2);
    }

    #[test]
    fn his_esc_ends_the_turn_and_says_how_many_of_his_messages_still_run() {
        let r = rig_with(&["desk-typed"], 2);
        r.host.relay(&key("a"), "A", None, "go", Origin::DeskTyped).unwrap();
        let said = r.host.interrupt(&key("a"));
        assert!(said.contains("2 of your messages are still queued") && said.contains("agents keep running"), "{said}");
    }

    // ---- (r) alarms; (b) init check; (q) ends ------------------------------------------------

    #[test]
    fn an_alarm_from_three_leads_reaches_him_once() {
        let r = rig();
        for t in ["a", "b", "c"] {
            r.host.relay(&key(t), t, None, "go", Origin::DeskTyped).unwrap();
            let alarm = crate::operator_frames::alarms_in(&json!({"type":"system","subtype":"hook_response","hook_event":"Stop",
                "hook_name":"Stop","stdout":"{\"systemMessage\":\"esc-1 is 24 h old\"}","stderr":""})).remove(0);
            r.host.handle(&key(t), LeadEvent::Alarm(alarm));
        }
        let alarms: Vec<_> = r.said.all().into_iter().filter(|x| x.2 == Say::Alarm).collect();
        assert_eq!(alarms.len(), 1, "{alarms:?}");
        assert_eq!(alarms[0].3, "esc-1 is 24 h old", "verbatim");
    }

    #[test]
    fn a_lead_that_fails_the_init_check_is_quit_and_he_hears_one_sentence() {
        let r = rig();
        r.host.relay(&key("a"), "A", None, "go", Origin::DeskTyped).unwrap();
        // The banner first, as it arrived in every recorded run; then an init with no engine.
        r.host.handle(&key("a"), banner_alarm(&r.declaration.engine_root));
        r.host.handle(&key("a"), LeadEvent::Init(json!({"type":"system","subtype":"init","plugins":[],"tools":[]})));
        let lead = lead_of(&r, "a");
        assert_eq!(*lead.quits.lock().unwrap(), 1);
        let team: Vec<_> = r.said.all().into_iter().filter(|x| x.2 == Say::Team).collect();
        assert_eq!(team.len(), 1);
        assert!(team[0].3.starts_with("Your team is switched off on this Mac because "), "{}", team[0].3);
        // The expected end is not news.
        r.host.handle(&key("a"), LeadEvent::Ended);
        assert_eq!(r.said.all().into_iter().filter(|x| x.2 == Say::Team).count(), 1);
    }

    fn banner_alarm(root: &Path) -> LeadEvent {
        let text = format!("RichOS engine 1.2.0: ENFORCEMENT ACTIVE for /f (77/77 guards, engine at {}, root via project-dir).",
                           root.display());
        LeadEvent::Alarm(crate::operator_frames::alarms_in(&json!({"type":"system","subtype":"hook_response",
            "hook_event":"SessionStart","hook_name":"SessionStart","stdout": json!({"systemMessage": text}).to_string(),
            "stderr":""})).remove(0))
    }

    fn good_init() -> LeadEvent {
        LeadEvent::Init(json!({"type":"system","subtype":"init","plugins":[{"name":"richos-engine"}],
                               "tools":[crate::operator_profile::REPORT_TOOL],"claude_code_version":"2.1.282"}))
    }

    #[test]
    fn the_init_check_waits_for_the_banner_whichever_arrives_first() {
        let r = rig();
        r.host.relay(&key("a"), "A", None, "go", Origin::DeskTyped).unwrap();
        r.host.handle(&key("a"), good_init());
        assert_eq!(*lead_of(&r, "a").quits.lock().unwrap(), 0, "no banner yet is not a refusal yet");
        r.host.handle(&key("a"), banner_alarm(&r.declaration.engine_root));
        assert_eq!(*lead_of(&r, "a").quits.lock().unwrap(), 0, "the banner came: the lead opens");
        assert!(!r.said.all().iter().any(|x| x.2 == Say::Team), "{:?}", r.said.all());
        // With no banner by the turn's end, the check decides then, and refuses.
        r.host.relay(&key("b"), "B", None, "go", Origin::DeskTyped).unwrap();
        r.host.handle(&key("b"), good_init());
        r.host.handle(&key("b"), turn(&["u-1"], Some("hi")));
        assert_eq!(*lead_of(&r, "b").quits.lock().unwrap(), 1);
        assert!(r.said.all().iter().any(|x| x.0 == key("b") && x.2 == Say::Team && x.3.contains("banner")));
        assert!(!r.said.all().iter().any(|x| x.0 == key("b") && x.2 == Say::Update), "a refused lead's words are not delivered");
    }

    #[test]
    fn an_unexpected_end_is_said_once_logged_and_the_next_message_resumes_the_session() {
        let r = rig();
        r.host.relay(&key("a"), "A", Some("h-1"), "go", Origin::DeskTyped).unwrap();
        let first = lead_of(&r, "a");
        *first.exited.lock().unwrap() = true;
        r.host.handle(&key("a"), LeadEvent::Ended);
        assert!(r.said.all().iter().any(|x| x.2 == Say::Team && x.3.starts_with("Your team in this conversation has ended.")));
        let log = std::fs::read_to_string(r.host.log_path()).unwrap();
        assert!(log.contains("LEAD ENDED UNEXPECTEDLY"), "{log}");
        r.host.relay(&key("a"), "A", None, "again", Origin::DeskTyped).unwrap();
        let (_, start, _) = r.launcher.leads.lock().unwrap().last().cloned().unwrap();
        assert_eq!(start, LeadStart::Resume(first.session.clone()), "(l): resumed, never a new session");
    }

    #[test]
    fn after_a_relaunch_the_first_message_resumes_and_lists_the_open_handles() {
        let r = rig();
        r.host.relay(&key("a"), "A", Some("h-1"), "go", Origin::DeskTyped).unwrap();
        let first = lead_of(&r, "a");
        // A second host over the same folders stands in for the relaunched app.
        let host = OperatorHost::new(r.declaration.clone(), &r.state, &r.root.join("operator"), r.launcher.clone(),
                                     r.engine.clone(), r.settle.clone(), r.said.clone(), Arc::new(SayQuestions(r.said.clone())));
        assert_eq!(r.launcher.leads.lock().unwrap().len(), 1, "lazy: nothing starts at relaunch");
        host.relay(&key("a"), "A", None, "where are we?", Origin::DeskTyped).unwrap();
        let (_, start, second) = r.launcher.leads.lock().unwrap().last().cloned().unwrap();
        assert_eq!(start, LeadStart::Resume(first.session.clone()));
        assert!(second.sent.lock().unwrap()[0].starts_with("Open when you last ended: h-1."), "{:?}", second.sent);
    }

    #[test]
    fn a_protocol_note_is_said_once_and_the_lead_is_kept() {
        let r = rig();
        r.host.relay(&key("a"), "A", None, "go", Origin::DeskTyped).unwrap();
        for _ in 0..3 {
            r.host.handle(&key("a"), LeadEvent::Protocol("a line that is not JSON was skipped".into()));
        }
        assert_eq!(r.said.all().iter().filter(|x| x.2 == Say::Team).count(), 1);
        assert_eq!(*lead_of(&r, "a").quits.lock().unwrap(), 0);
    }

    // ---- (m), (o), (q) item 4 ----------------------------------------------------------------

    /// A lead in its turn is his team working, agent or no agent; its turn's end is when it
    /// stops counting.
    #[test]
    fn a_lead_in_its_turn_counts_as_working_until_the_turn_ends() {
        let r = rig();
        let uuid = match r.host.relay(&key("a"), "Pricing", None, "think about it", Origin::DeskTyped).unwrap() {
            Relayed::Sent { uuid } => uuid,
            other => panic!("{other:?}"),
        };
        assert_eq!(r.host.team().working, ["Pricing"], "his message is queued with the lead");
        r.host.handle(&key("a"), LeadEvent::Took(uuid.clone()));
        assert_eq!(r.host.team().working, ["Pricing"], "the lead is in the turn");
        r.host.handle(&key("a"), turn(&[uuid.as_str()], Some("Done thinking.")));
        assert!(r.host.team().working.is_empty(), "{:?}", r.host.team());
    }

    /// The reading the exit decision takes never runs a script, and never reads an agent the
    /// stream has not seen end as gone.
    #[test]
    fn the_stream_reading_asks_no_script_and_counts_what_the_stream_has_not_seen_end() {
        let r = rig();
        r.host.relay(&key("a"), "A", None, "go", Origin::DeskTyped).unwrap();
        let lead = lead_of(&r, "a");
        agent(&lead, "t-a", "still-going", "task-a");
        agent(&lead, "t-b", "finished", "task-b");
        lead.feed(json!({"type":"system","subtype":"task_notification","task_id":"task-b","status":"completed"}));
        let reading = r.host.team_from_stream();
        assert_eq!(reading.alive, ["still-going"]);
        assert!(r.engine.asked.lock().unwrap().is_empty(), "no agent-liveness.sh inside the exit callback");
    }

    #[test]
    fn the_team_reading_counts_alive_agents_and_live_descendants() {
        let r = rig();
        r.host.relay(&key("a"), "A", None, "go", Origin::DeskTyped).unwrap();
        let lead = lead_of(&r, "a");
        agent(&lead, "t-a", "alive-one", "task-a");
        agent(&lead, "t-b", "done-one", "task-b");
        r.engine.not_alive.lock().unwrap().insert("task-b".into());
        let reading = r.host.team();
        assert_eq!(reading.alive, ["alive-one"]);
        assert_eq!(reading.descendants_unknown, 1, "no snapshot is never zero");
        let state = ConversationPaths::under(&r.root.join("operator"), &key("a")).reap_state;
        std::fs::write(&state, json!({"outside_provider_group": [4242, 4343]}).to_string()).unwrap();
        assert_eq!(r.host.team().descendants, 2);
    }

    #[test]
    fn idle_retirement_waits_for_nothing_running_and_the_next_message_resumes() {
        let r = rig();
        r.host.relay(&key("a"), "A", None, "go", Origin::DeskTyped).unwrap();
        let state = ConversationPaths::under(&r.root.join("operator"), &key("a")).reap_state;
        // A message is awaiting its turn: not idle.
        assert!(r.host.retire_idle(Duration::ZERO).is_empty());
        r.host.handle(&key("a"), turn(&["u-1"], Some("ok")));
        // No snapshot yet: undecided, not idle.
        assert!(r.host.retire_idle(Duration::ZERO).is_empty());
        std::fs::write(&state, json!({"outside_provider_group": [4242]}).to_string()).unwrap();
        assert!(r.host.retire_idle(Duration::ZERO).is_empty(), "a background command outside the lead's group runs");
        std::fs::write(&state, json!({"outside_provider_group": []}).to_string()).unwrap();
        r.engine.leases.lock().unwrap().push("land-lease: repository /r; lease live, held by the conversation \"A\" for 2 min; at rest.".into());
        assert!(r.host.retire_idle(Duration::ZERO).is_empty(), "a land lease held by this conversation");
        r.engine.leases.lock().unwrap().clear();
        agent(&lead_of(&r, "a"), "t-a", "still-alive", "task-a");
        assert!(r.host.retire_idle(Duration::ZERO).is_empty(), "an ALIVE agent of the lead");
        r.engine.not_alive.lock().unwrap().insert("task-a".into());
        assert!(r.host.retire_idle(Duration::from_secs(3600)).is_empty(), "not idle long enough, snapshot fresh");
        assert_eq!(r.host.retire_idle(Duration::ZERO), [key("a")]);
        let first = lead_of(&r, "a");
        assert_eq!(*first.quits.lock().unwrap(), 1, "by the quit path");
        r.host.relay(&key("a"), "A", None, "again", Origin::DeskTyped).unwrap();
        let (_, start, _) = r.launcher.leads.lock().unwrap().last().cloned().unwrap();
        assert_eq!(start, LeadStart::Resume(first.session.clone()));
    }

    #[test]
    fn a_stale_snapshot_retires_an_idle_lead_at_once() {
        let r = rig();
        r.host.relay(&key("a"), "A", None, "go", Origin::DeskTyped).unwrap();
        r.host.handle(&key("a"), turn(&["u-1"], Some("ok")));
        let state = ConversationPaths::under(&r.root.join("operator"), &key("a")).reap_state;
        std::fs::write(&state, json!({"outside_provider_group": []}).to_string()).unwrap();
        assert!(r.host.retire_idle(Duration::from_secs(3600)).is_empty());
        std::fs::write(r.declaration.entity_root.join("CLAUDE.md"), "rules, edited\n").unwrap();
        assert_eq!(r.host.retire_idle(Duration::from_secs(3600)), [key("a")]);
    }

    #[test]
    fn the_read_names_agents_texts_and_this_conversation_s_leases_only() {
        let r = rig();
        r.host.relay(&key("a"), "Landing the fix", None, "go", Origin::DeskTyped).unwrap();
        r.host.relay(&key("b"), "Other", None, "go", Origin::DeskTyped).unwrap();
        agent(&lead_of(&r, "a"), "t-a", "mark-sonnet-a", "task-a");
        r.engine.leases.lock().unwrap().push("land-lease: repository /r; lease live, held by the conversation \"Landing the fix\" for 1 min; merge in progress.".into());
        r.engine.leases.lock().unwrap().push("land-lease: repository /q; lease live, held by the conversation \"Other\" for 3 min; at rest.".into());
        r.engine.leases.lock().unwrap().push("land-lease: repository /z; lease live, held by your terminal for 9 min; at rest.".into());
        let read = r.host.read(&key("a"), false);
        assert_eq!(read.len(), 1);
        assert_eq!(read[0].agents, [("mark-sonnet-a".to_string(), "running".to_string())]);
        assert_eq!(read[0].leases, ["land-lease: repository /r; lease live, held by the conversation \"Landing the fix\" for 1 min; merge in progress."]);
        assert!(!lease_held_by("held by the conversation \"Landing the fix, part two\"", "Landing the fix"),
                "a longer title is not this one");
        assert!(!lease_held_by("held by your terminal", ""), "no title matches nothing");
        assert_eq!(r.host.read(&key("a"), true).len(), 2, "every conversation's, on request");
    }

    #[test]
    fn quit_ends_every_lead_by_the_quit_path() {
        let r = rig();
        r.host.relay(&key("a"), "A", None, "go", Origin::DeskTyped).unwrap();
        r.host.relay(&key("b"), "B", None, "go", Origin::DeskTyped).unwrap();
        assert_eq!(r.host.quit_all().len(), 2);
        for t in ["a", "b"] {
            assert_eq!(*lead_of(&r, t).quits.lock().unwrap(), 1);
        }
    }

    #[test]
    fn a_path_segment_never_climbs_out() {
        assert_eq!(safe_segment("thread-1_A"), "thread-1_A");
        let odd = safe_segment("../../etc");
        assert!(!odd.contains('/') && !odd.contains(".."), "{odd}");
        assert_ne!(safe_segment("a/b"), safe_segment("a-b"), "distinct ids stay distinct");
    }
}
