//! Worker-lifecycle events — the CONSUMER half of the engine's worker stream.
//!
//! The engine landed four emitters at `d14bc54`
//! (`engine/scripts/hooks/worker-{created,started,updated,ended}-handoff.sh`) writing one
//! append-only JSONL stream:
//!
//! ```text
//! ~/.claude/teams/session-<first8>/worker-events.jsonl
//! fallback: ~/.claude/worker-events.jsonl
//! ```
//!
//! Contract: `engine/docs/worker-lifecycle-events.md`. This module parses that stream and
//! derives ONE thing from it — which worker runs are open — so `worker_status.rs` can stop
//! reporting `active: 0` structurally. It derives nothing else.
//!
//! # The four states, and the three this module refuses to have
//!
//! The UX design (§7.1) names seven worker states. The engine can witness FOUR things, and
//! [`ObservedWorkerState`] has exactly four variants for exactly that reason:
//!
//! | Variant | Witness | Emitter |
//! |---|---|---|
//! | [`ObservedWorkerState::Created`] | `PostToolUse[Agent]`, gated on the async-launch ack AND an extractable `agentId` | `worker-created-handoff.sh` |
//! | [`ObservedWorkerState::Started`] | `SubagentStart` — fires inside the worker's own run, carries `agent_id` | `worker-started-handoff.sh` |
//! | [`ObservedWorkerState::Updated`] | `PostToolUse[SendMessage]` carrying `agent_id` (a WORKER sent it, not the lead) | `worker-updated-handoff.sh` |
//! | [`ObservedWorkerState::RunEnded`] | `SubagentStop` — the run stopped; **the reason is not in the payload** | `worker-ended-handoff.sh` |
//!
//! There is deliberately **no `Waiting`, no `Interrupted`, no `Failed` and no `Completed`**
//! in this enum. Not "not yet implemented" — not representable, on purpose:
//!
//! - **`waiting`** — the only candidate is `TeammateIdle`, whose payload cannot separate a
//!   worker paused for input from one finished for good. Calling it waiting asserts it will
//!   resume; calling it completed asserts it will not. Both are sometimes false. A consumer
//!   may treat idle as terminal-for-this-run; it must never render a REASON.
//! - **`interrupted`** — the only candidate is a `shutdown_request`, which is an
//!   *instruction* issued before anything happens, not an observation. The worker may finish
//!   normally, ignore it, or never receive it.
//! - **`failed`** — no payload in the worker path carries an outcome. `SubagentStop` has
//!   `stop_hook_active`, a transcript path and a last assistant message; none is a verdict.
//!   Classifying from the last message is text-scraping a guess and presenting it as a state.
//!
//! ## `RunEnded` is a superset — keep it that way
//!
//! [`ObservedWorkerState::RunEnded`] means *this run is over and the reason is not
//! observable here*. It is the honest superset of completed, interrupted and failed. It is
//! **not** `Completed`, and it must not be allowed to decay into `Completed` in a type, a
//! projection, a field name or a serialization — roughly two thirds of the time that would
//! be wrong, and §7.4 of the UX design renders failure and recovery completely differently
//! from success. `run_ended_is_never_serialized_as_a_completion` pins this.
//!
//! `RunEnded` is also not "this worker is gone forever": a background teammate can be woken
//! again, producing another `started`/`run_ended` pair for the same `agent_id`. The stream
//! is a SEQUENCE, not a set of flags, and [`open_runs`] walks it as one.
//!
//! # Deriving open runs
//!
//! Verbatim from the contract's "Deriving an active count honestly":
//!
//! ```text
//! open = a created/started with no LATER run_ended, for that agent_id
//! ```
//!
//! Two deliberate refusals inside that one line:
//!
//! 1. **`Updated` does not open a run.** It is evidence a worker authored something, and it
//!    is tempting to read a message as proof of execution. The contract names `created` and
//!    `started` as the openers and nothing else; treating `updated` as a third opener would
//!    be this module's inference rather than the engine's observation. It is recorded (it
//!    carries the latest authored summary, UX §7.2 item 4) and it never re-opens a run.
//! 2. **Nothing is inferred from time.** No timeout, no "recently modified", no last-write
//!    age. A run closes when a terminal event says so, never when a clock says so.
//!
//! # Liveness: a real test, not a timeout
//!
//! An open run is not the same as a live worker. If the host CLI died mid-run, its workers
//! died with it and their `created` rows were never closed out — the stream cannot self-heal,
//! because the process that would have written the terminal event is the one that died. So
//! each open run is reconciled against the `host_pid` the emitter recorded, via
//! [`probe_host`], which signals pid 0 and reads the result. That is a real liveness test.
//! A timeout would be a guess wearing a number, and is not used anywhere in this module.
//!
//! The probe is TRI-state ([`HostLiveness`]) because the underlying syscall is:
//!
//! - exit 0 ⇒ the process exists and is ours ⇒ [`HostLiveness::Alive`]
//! - `No such process` (ESRCH) ⇒ [`HostLiveness::Dead`]
//! - `Operation not permitted` (EPERM) ⇒ [`HostLiveness::Unknown`]. EPERM proves *a* process
//!   exists at that pid, but also proves it is **not ours to signal** — and our own host CLI
//!   would be. That makes a recycled pid the likelier reading than a live host, so neither
//!   "alive as our host" nor "dead" is established, and the honest answer is unknown.
//! - no `host_pid` on the row at all (the harness did not export `CLAUDE_PID`) ⇒
//!   [`HostLiveness::Unknown`].
//!
//! `Unknown` is never folded into either bucket. The contract's own words: *"If neither can
//! be established, the honest render is `unknown`, not a count."*
//!
//! # Session scope
//!
//! The contract's constraint 1 is *"scope to the session — do not carry a previous session's
//! `created` forward."* The team-dir path satisfies that by construction (a new session gets
//! a new directory). The **fallback path does not**: `~/.claude/worker-events.jsonl` is a
//! single file that accumulates across every session that ever missed a team dir, so a
//! `created` in it may belong to a host that exited days ago.
//!
//! Therefore rows are filtered by [`SessionScope`] before anything is derived, and
//! [`worker_events_path`] resolves the team-dir stream ONLY. The fallback is readable
//! through [`read_stream`] for callers that can supply a real session id, and is never
//! counted blind. See `worker_status.rs` for what that means for `active`.

use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::fs;
use std::path::{Path, PathBuf};

/// The file name the four emitters append to, in whichever directory they resolved.
pub const WORKER_EVENTS_FILE: &str = "worker-events.jsonl";

// ---------------------------------------------------------------------------
// THE FOUR OBSERVABLE STATES
// ---------------------------------------------------------------------------

/// Exactly the four things the engine can witness about a worker. See the module doc for
/// the three states that are deliberately absent and why each one is unwitnessable.
///
/// Serialized with the emitters' own `lifecycle_state` spellings, so a round-trip through
/// this type is byte-identical to the stream it came from.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ObservedWorkerState {
    /// The harness accepted a spawn and returned an agent id. NOT "is executing".
    Created,
    /// The harness began running the subagent. NOT "is still running" — that is only ever
    /// "opened, with no later terminal event", which is [`open_runs`]'s job.
    Started,
    /// A worker authored an update. Evidence of authorship, not of liveness, and NOT an
    /// opener — see the module doc.
    Updated,
    /// The run stopped. **The reason is not observable.** Never `Completed`.
    RunEnded,
}

impl ObservedWorkerState {
    /// The two states the contract names as opening a run. `Updated` is not one of them.
    pub fn opens_run(self) -> bool {
        matches!(self, ObservedWorkerState::Created | ObservedWorkerState::Started)
    }

    /// The one terminal state in this stream.
    ///
    /// Named `terminal` and not `completed` on purpose: it closes a RUN, and says nothing
    /// whatsoever about the outcome of the work.
    pub fn is_terminal(self) -> bool {
        matches!(self, ObservedWorkerState::RunEnded)
    }

    /// The emitters' `lifecycle_state` string, verbatim.
    pub fn as_str(self) -> &'static str {
        match self {
            ObservedWorkerState::Created => "created",
            ObservedWorkerState::Started => "started",
            ObservedWorkerState::Updated => "updated",
            ObservedWorkerState::RunEnded => "run_ended",
        }
    }
}

// ---------------------------------------------------------------------------
// ONE ROW
// ---------------------------------------------------------------------------

/// One parsed line of `worker-events.jsonl`.
///
/// Field names mirror the emitters exactly. Anything the emitters may omit is `Option` or
/// `#[serde(default)]` rather than defaulted to a value that would read as a claim — an
/// absent `host_pid` is `None` (liveness unknown), never `0`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct WorkerEventRow {
    /// RFC-3339, as written by the emitter. A LABEL for display, never an ordering key and
    /// never a liveness input — stream order is the order.
    #[serde(default)]
    pub timestamp: String,
    /// The only state field. Parsed from `lifecycle_state`; a row whose value is not one of
    /// the four is DROPPED by [`parse_stream`] rather than coerced.
    pub lifecycle_state: ObservedWorkerState,
    /// Which hook witnessed it — kept for provenance (UX §22 "source provenance").
    #[serde(default)]
    pub source_hook: String,
    /// THE JOIN KEY. Every emitter refuses to write a row without one, so this is never
    /// empty in a well-formed stream; [`parse_stream`] drops a row that has an empty one.
    pub agent_id: String,
    /// The spawn-time display name. Present on `created` rows only — the other three
    /// payloads do not carry it, and no emitter invents it.
    #[serde(default)]
    pub worker_name: String,
    #[serde(default)]
    pub agent_type: String,
    #[serde(default)]
    pub session_id: String,
    /// The SendMessage `summary` on an `updated` row (UX §7.2 item 4, "latest authored
    /// update"). Never the message body — the emitter does not log content.
    #[serde(default)]
    pub summary: String,
    /// The host CLI's pid, when the harness exported `CLAUDE_PID`. `None` ⇒ liveness cannot
    /// be established for this row.
    #[serde(default)]
    pub host_pid: Option<u32>,
}

impl WorkerEventRow {
    /// Does this row belong to the given session scope?
    pub fn in_scope(&self, scope: &SessionScope) -> bool {
        scope.admits(&self.session_id)
    }
}

// ---------------------------------------------------------------------------
// SESSION SCOPE
// ---------------------------------------------------------------------------

/// Which session's rows a consumer may count. See the module doc's "Session scope".
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SessionScope {
    /// Match on the `session-<first8>` prefix a team directory is named for. The emitters
    /// write the FULL session id into each row, and the directory carries only the first 8
    /// characters, so the prefix is the only join available — and it is the same one the
    /// emitters used to choose the directory.
    Prefix(String),
    /// An exact session id, for a caller that knows it (e.g. the ACP session the app is on).
    Exact(String),
    /// No filtering. Only for an explicit test seam or a directory that is not named for a
    /// session; never used for the home-fallback file.
    Any,
}

impl SessionScope {
    /// Derive the scope from a team-directory path named `session-<first8>`. Returns
    /// [`SessionScope::Any`] for a directory that is not so named (an explicit override).
    pub fn from_team_dir(dir: &Path) -> SessionScope {
        match dir.file_name().and_then(|n| n.to_str()).and_then(|n| n.strip_prefix("session-")) {
            Some(prefix) if !prefix.is_empty() => SessionScope::Prefix(prefix.to_string()),
            _ => SessionScope::Any,
        }
    }

    pub fn admits(&self, session_id: &str) -> bool {
        match self {
            SessionScope::Any => true,
            SessionScope::Exact(id) => session_id == id,
            // An empty session_id cannot be shown to belong to this session, so it is not
            // admitted. Silence beats a row counted into the wrong session's active total.
            SessionScope::Prefix(p) => !session_id.is_empty() && session_id.starts_with(p.as_str()),
        }
    }
}

// ---------------------------------------------------------------------------
// PARSING
// ---------------------------------------------------------------------------

/// Parse a whole stream. Malformed lines, unknown `lifecycle_state` values and rows with no
/// `agent_id` are SKIPPED, never coerced — the same fail-open posture the emitters have on
/// the write side. Order is preserved, because order is the derivation.
pub fn parse_stream(contents: &str) -> Vec<WorkerEventRow> {
    contents
        .lines()
        .map(str::trim)
        .filter(|l| !l.is_empty())
        .filter_map(|l| serde_json::from_str::<WorkerEventRow>(l).ok())
        .filter(|r| !r.agent_id.is_empty())
        .collect()
}

/// Read and parse one stream file. A missing or unreadable file is an empty stream, not an
/// error: "no worker events" is a true and common state, not a failure.
pub fn read_stream(path: &Path) -> Vec<WorkerEventRow> {
    match fs::read_to_string(path) {
        Ok(contents) => parse_stream(&contents),
        Err(_) => Vec::new(),
    }
}

/// The stream file inside a team-session directory. **The team dir only** — see the module
/// doc: the home fallback cannot be session-scoped, so it is never resolved for counting.
pub fn worker_events_path(team_dir: &Path) -> PathBuf {
    team_dir.join(WORKER_EVENTS_FILE)
}

// ---------------------------------------------------------------------------
// LIVENESS
// ---------------------------------------------------------------------------

/// The result of a real liveness test against a recorded `host_pid`. Tri-state because the
/// syscall is — see the module doc for why EPERM is `Unknown` rather than `Alive`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum HostLiveness {
    Alive,
    Dead,
    /// Neither could be established. Never folded into either bucket.
    Unknown,
}

/// Signal pid 0 at `pid` and classify the result.
///
/// Signal 0 performs the error checking of a real signal delivery without delivering one,
/// which is the standard way to ask "does this process exist and may I signal it". This is
/// the whole liveness mechanism: no timeout, no age, no filesystem stat.
///
/// Spawns `/bin/kill` rather than linking `libc`, because this crate is deliberately
/// native-dependency-free (`lib.rs`) and the probe runs at most once per distinct host pid
/// per poll — in practice exactly once, since every row of one session shares one host.
/// A probe that cannot be spawned at all is [`HostLiveness::Unknown`], never a guess.
pub fn probe_host(pid: u32) -> HostLiveness {
    // pid 0 addresses the caller's whole process group in POSIX signal semantics; it is
    // never a host CLI's pid and must never be probed as one.
    if pid == 0 {
        return HostLiveness::Unknown;
    }
    let output = match std::process::Command::new("/bin/kill").arg("-0").arg(pid.to_string()).output() {
        Ok(o) => o,
        Err(_) => return HostLiveness::Unknown,
    };
    if output.status.success() {
        return HostLiveness::Alive;
    }
    let stderr = String::from_utf8_lossy(&output.stderr);
    if stderr.contains("No such process") {
        HostLiveness::Dead
    } else {
        // EPERM ("Operation not permitted") and anything unrecognized. See the module doc.
        HostLiveness::Unknown
    }
}

/// The probe as a swappable function, so tests can drive `Alive`/`Dead`/`Unknown`
/// deterministically without hunting for a pid in the right state.
pub type HostProbe = fn(u32) -> HostLiveness;

// ---------------------------------------------------------------------------
// OPEN RUNS
// ---------------------------------------------------------------------------

/// One worker run that the stream shows OPEN — a `created`/`started` with no later
/// `run_ended` — together with the liveness verdict on the host that owned it.
///
/// "Open" is a statement about the EVENT STREAM. "Active" additionally requires
/// [`HostLiveness::Alive`]; the two are separate fields here so a consumer can never
/// accidentally read one as the other.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct OpenRun {
    pub agent_id: String,
    /// From the `created` row when one was observed. Empty when only `started` was seen —
    /// that payload has no name and nothing invents one.
    pub worker_name: String,
    pub agent_type: String,
    pub session_id: String,
    /// The state of the row that opened this run.
    pub opened_by: ObservedWorkerState,
    pub opened_at: String,
    /// The latest `summary` a worker authored on an `updated` row, if any.
    pub latest_update: Option<String>,
    /// The host pid recorded on the opening row. `None` ⇒ liveness unknown by omission.
    pub host_pid: Option<u32>,
    pub host_liveness: HostLiveness,
}

impl OpenRun {
    /// The one honest definition of active: the stream shows the run open AND the host that
    /// owned it is witnessed alive. Anything else is not counted.
    pub fn is_active(&self) -> bool {
        self.host_liveness == HostLiveness::Alive
    }
}

/// Walk the stream in order and return the open runs, liveness-reconciled.
///
/// The derivation, verbatim from the contract:
/// `open = a created/started with no LATER run_ended, for that agent_id`.
///
/// Implemented as a sequence walk rather than a set of flags, because a woken teammate
/// produces a second `started` after its first `run_ended` and must read as open again.
/// Every host pid is probed at most once.
pub fn open_runs(rows: &[WorkerEventRow], scope: &SessionScope, probe: HostProbe) -> Vec<OpenRun> {
    // Insertion-ordered accumulator: agent_id -> the currently open run, if any.
    let mut order: Vec<String> = Vec::new();
    let mut state: HashMap<String, Option<OpenRun>> = HashMap::new();
    let mut latest_update: HashMap<String, String> = HashMap::new();
    let mut names: HashMap<String, String> = HashMap::new();

    for row in rows.iter().filter(|r| r.in_scope(scope)) {
        if !state.contains_key(&row.agent_id) {
            order.push(row.agent_id.clone());
            state.insert(row.agent_id.clone(), None);
        }
        // A name is only ever learned from a row that actually carried one.
        if !row.worker_name.is_empty() {
            names.insert(row.agent_id.clone(), row.worker_name.clone());
        }
        match row.lifecycle_state {
            ObservedWorkerState::RunEnded => {
                // The terminal event closes the run. It says nothing about why, and this
                // code records nothing about why.
                state.insert(row.agent_id.clone(), None);
            }
            ObservedWorkerState::Updated => {
                if !row.summary.is_empty() {
                    latest_update.insert(row.agent_id.clone(), row.summary.clone());
                }
                // Deliberately NOT an opener. See the module doc.
            }
            opener => {
                let entry = state.get_mut(&row.agent_id).expect("inserted above");
                // A second opener for an already-open run does not restart it: the run was
                // opened by the FIRST observation and is still the same run.
                if entry.is_none() {
                    *entry = Some(OpenRun {
                        agent_id: row.agent_id.clone(),
                        worker_name: String::new(),
                        agent_type: row.agent_type.clone(),
                        session_id: row.session_id.clone(),
                        opened_by: opener,
                        opened_at: row.timestamp.clone(),
                        latest_update: None,
                        host_pid: row.host_pid,
                        host_liveness: HostLiveness::Unknown,
                    });
                }
            }
        }
    }

    // One probe per distinct pid, not one per run.
    let mut probed: HashMap<u32, HostLiveness> = HashMap::new();
    let mut out = Vec::new();
    for agent_id in order {
        let Some(Some(mut run)) = state.remove(&agent_id) else { continue };
        run.worker_name = names.get(&agent_id).cloned().unwrap_or_default();
        run.latest_update = latest_update.get(&agent_id).cloned();
        run.host_liveness = match run.host_pid {
            Some(pid) => *probed.entry(pid).or_insert_with(|| probe(pid)),
            // No pid on the row: liveness cannot be established. Not alive, not dead.
            None => HostLiveness::Unknown,
        };
        out.push(run);
    }
    out
}

/// The latest observed state per `agent_id`, in scope — the join a timeline item needs.
///
/// This is the LAST thing witnessed, not a verdict. A worker whose last row is
/// [`ObservedWorkerState::RunEnded`] has ended a run for an unobservable reason.
pub fn latest_states(rows: &[WorkerEventRow], scope: &SessionScope) -> HashMap<String, ObservedWorkerState> {
    let mut out = HashMap::new();
    for row in rows.iter().filter(|r| r.in_scope(scope)) {
        out.insert(row.agent_id.clone(), row.lifecycle_state);
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn always_alive(_pid: u32) -> HostLiveness {
        HostLiveness::Alive
    }
    fn always_dead(_pid: u32) -> HostLiveness {
        HostLiveness::Dead
    }
    fn always_unknown(_pid: u32) -> HostLiveness {
        HostLiveness::Unknown
    }

    fn row(state: &str, agent: &str, extra: &str) -> String {
        format!(
            r#"{{"timestamp":"2026-08-29T04:00:00+00:00","event":"X","lifecycle_state":"{state}","source_hook":"h","agent_id":"{agent}","agent_type":"dev","session_id":"abcd1234-ffff","decision":"logged"{extra}}}"#
        )
    }

    fn scope() -> SessionScope {
        SessionScope::Prefix("abcd1234".into())
    }

    #[test]
    fn the_four_emitter_spellings_parse_and_nothing_else_does() {
        let stream = [
            row("created", "a1", r#","worker_name":"dev-sonnet-1","host_pid":10"#),
            row("started", "a1", r#","host_pid":10"#),
            row("updated", "a1", r#","summary":"landed the parser fix","host_pid":10"#),
            row("run_ended", "a1", r#","host_pid":10"#),
            // Not one of the four: a state nobody witnesses. Dropped, never coerced.
            row("failed", "a1", ""),
            row("waiting", "a1", ""),
            row("interrupted", "a1", ""),
            row("completed", "a1", ""),
        ]
        .join("\n");
        let rows = parse_stream(&stream);
        assert_eq!(rows.len(), 4, "only the four observable states survive parsing");
        let states: Vec<_> = rows.iter().map(|r| r.lifecycle_state).collect();
        assert_eq!(
            states,
            vec![
                ObservedWorkerState::Created,
                ObservedWorkerState::Started,
                ObservedWorkerState::Updated,
                ObservedWorkerState::RunEnded
            ]
        );
    }

    #[test]
    fn run_ended_is_never_serialized_as_a_completion() {
        // The decay this slice exists to prevent: run_ended quietly becoming "completed"
        // in a type, a field or a wire format. §7.4 renders failure differently from
        // success, so a wrong label here is a product defect, not a cosmetic one.
        let json = serde_json::to_string(&ObservedWorkerState::RunEnded).unwrap();
        assert_eq!(json, "\"run_ended\"");
        for forbidden in ["completed", "complete", "done", "success", "failed", "interrupted"] {
            assert!(!json.contains(forbidden), "run_ended must not serialize as {forbidden}");
        }
        assert!(ObservedWorkerState::RunEnded.is_terminal());
        // And there is no variant to decay INTO.
        assert!(serde_json::from_str::<ObservedWorkerState>("\"completed\"").is_err());
        assert!(serde_json::from_str::<ObservedWorkerState>("\"failed\"").is_err());
        assert!(serde_json::from_str::<ObservedWorkerState>("\"waiting\"").is_err());
        assert!(serde_json::from_str::<ObservedWorkerState>("\"interrupted\"").is_err());
    }

    #[test]
    fn an_open_run_is_created_or_started_with_no_later_run_ended() {
        let stream = [
            row("created", "a1", r#","worker_name":"dev-1","host_pid":10"#),
            row("started", "a1", r#","host_pid":10"#),
            row("created", "a2", r#","worker_name":"dev-2","host_pid":10"#),
            row("run_ended", "a2", r#","host_pid":10"#),
        ]
        .join("\n");
        let runs = open_runs(&parse_stream(&stream), &scope(), always_alive);
        assert_eq!(runs.len(), 1, "a2 was closed by its terminal event");
        assert_eq!(runs[0].agent_id, "a1");
        assert_eq!(runs[0].worker_name, "dev-1");
        assert_eq!(runs[0].opened_by, ObservedWorkerState::Created);
        assert!(runs[0].is_active());
    }

    #[test]
    fn a_reopened_run_is_open_again_because_the_stream_is_a_sequence() {
        // A background teammate that stops can be woken; run_ended is never "gone forever".
        let stream = [
            row("started", "a1", r#","host_pid":10"#),
            row("run_ended", "a1", r#","host_pid":10"#),
            row("started", "a1", r#","host_pid":10"#),
        ]
        .join("\n");
        let runs = open_runs(&parse_stream(&stream), &scope(), always_alive);
        assert_eq!(runs.len(), 1, "the later start reopened the run");
        assert_eq!(runs[0].opened_by, ObservedWorkerState::Started);
    }

    #[test]
    fn updated_does_not_open_a_run() {
        // The tempting third opener. The contract names created/started and nothing else,
        // so an update after a terminal event records its summary and stays closed.
        let stream = [
            row("started", "a1", r#","host_pid":10"#),
            row("run_ended", "a1", r#","host_pid":10"#),
            row("updated", "a1", r#","summary":"still talking","host_pid":10"#),
        ]
        .join("\n");
        let runs = open_runs(&parse_stream(&stream), &scope(), always_alive);
        assert!(runs.is_empty(), "an update is authorship evidence, not a lifecycle opener");
    }

    #[test]
    fn a_dead_host_pid_makes_an_open_run_inactive() {
        // THE LIVENESS TEST DOING ITS JOB. The host died mid-run, so the terminal event was
        // never written by the process that would have written it. The stream still shows
        // the run open; the pid says otherwise, and the pid wins.
        let stream = row("started", "a1", r#","host_pid":424242"#);
        let runs = open_runs(&parse_stream(&stream), &scope(), always_dead);
        assert_eq!(runs.len(), 1, "the run is still OPEN in the stream");
        assert_eq!(runs[0].host_liveness, HostLiveness::Dead);
        assert!(!runs[0].is_active(), "open but not active — the host is gone");
    }

    #[test]
    fn unknown_liveness_is_never_folded_into_alive_or_dead() {
        let stream = row("started", "a1", r#","host_pid":7"#);
        let runs = open_runs(&parse_stream(&stream), &scope(), always_unknown);
        assert_eq!(runs[0].host_liveness, HostLiveness::Unknown);
        assert!(!runs[0].is_active(), "unknown is not active");
        assert_ne!(runs[0].host_liveness, HostLiveness::Dead, "and it is not dead either");
    }

    #[test]
    fn a_row_with_no_host_pid_is_unknown_not_alive() {
        let stream = row("started", "a1", "");
        let runs = open_runs(&parse_stream(&stream), &scope(), always_alive);
        assert_eq!(runs[0].host_pid, None);
        assert_eq!(runs[0].host_liveness, HostLiveness::Unknown, "absent pid means unestablished, never 0 and never alive");
        assert!(!runs[0].is_active());
    }

    #[test]
    fn another_sessions_rows_are_not_carried_forward() {
        // Contract constraint 1. A previous session's unclosed `created` must never inflate
        // this session's count.
        let mine = row("started", "mine", r#","host_pid":10"#);
        let theirs = r#"{"timestamp":"t","lifecycle_state":"started","agent_id":"theirs","session_id":"99999999-other","host_pid":10}"#;
        let rows = parse_stream(&format!("{mine}\n{theirs}"));
        assert_eq!(rows.len(), 2, "both rows parse");
        let runs = open_runs(&rows, &scope(), always_alive);
        assert_eq!(runs.len(), 1, "only this session's run counts");
        assert_eq!(runs[0].agent_id, "mine");
    }

    #[test]
    fn a_row_with_no_session_id_is_not_admitted_by_a_prefix_scope() {
        assert!(!scope().admits(""));
        assert!(scope().admits("abcd1234-full-id"));
        assert!(!scope().admits("abcd1235-full-id"));
        assert!(SessionScope::Any.admits(""));
        assert!(SessionScope::Exact("x".into()).admits("x"));
        assert!(!SessionScope::Exact("x".into()).admits("xy"));
    }

    #[test]
    fn session_scope_is_derived_from_the_team_dir_name() {
        assert_eq!(
            SessionScope::from_team_dir(Path::new("/t/teams/session-abcd1234")),
            SessionScope::Prefix("abcd1234".into())
        );
        assert_eq!(SessionScope::from_team_dir(Path::new("/t/some-override-dir")), SessionScope::Any);
    }

    #[test]
    fn malformed_and_unattributable_lines_are_skipped_not_fatal() {
        let stream = [
            "not json at all",
            r#"{"lifecycle_state":"started","agent_id":"","session_id":"abcd1234-x"}"#,
            r#"{"lifecycle_state":"started","session_id":"abcd1234-x"}"#,
            &row("started", "ok", r#","host_pid":10"#),
            "",
        ]
        .join("\n");
        let rows = parse_stream(&stream);
        assert_eq!(rows.len(), 1, "an unattributable row is dropped — no agent_id, no row");
        assert_eq!(rows[0].agent_id, "ok");
    }

    #[test]
    fn a_missing_stream_file_is_empty_not_an_error() {
        assert!(read_stream(Path::new("/definitely/not/here/worker-events.jsonl")).is_empty());
    }

    #[test]
    fn the_real_probe_classifies_this_process_alive_and_a_free_pid_dead() {
        // Not a fixture: the actual syscall, against this test process.
        assert_eq!(probe_host(std::process::id()), HostLiveness::Alive);
        // pid 0 is the caller's process group in POSIX signal semantics, never a host.
        assert_eq!(probe_host(0), HostLiveness::Unknown);
    }

    #[test]
    fn latest_state_is_the_last_row_never_a_verdict() {
        let stream = [
            row("created", "a1", ""),
            row("started", "a1", ""),
            row("run_ended", "a1", ""),
        ]
        .join("\n");
        let states = latest_states(&parse_stream(&stream), &scope());
        assert_eq!(states.get("a1"), Some(&ObservedWorkerState::RunEnded));
        // It is NOT completed. There is no such state to be.
        assert_eq!(states.get("a1").unwrap().as_str(), "run_ended");
    }
}
