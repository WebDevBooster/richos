//! Durable execution behind Rich's normal conversation. Workers never lease the
//! conversation Spine or hold its mutex across execution or independent review.
use crate::AppState;
use richos_core::{
    autonomy::{self, Handoff},
    cognition::{Cognition, TurnItem},
    ledger::{Source, TurnState},
    native::{resolve_claude_bin, NativeCognition},
    run::{RunController, RunSnapshot, RunState},
    run_host::CognitionRunHost,
    run_spine::EVENT_RUN_UPDATED,
};
use serde::{Deserialize, Serialize};
use std::{
    path::{Path, PathBuf},
    sync::{
        atomic::{AtomicBool, Ordering},
        Arc,
    },
    time::Duration,
};
use tauri::{Emitter, Manager};

#[derive(Clone, Serialize, Deserialize)]
struct Request {
    id: String,
    source_turn: Option<String>,
    thread: String,
    workspace: PathBuf,
    text: String,
    conversation: String,
    #[serde(default)]
    onboarding_tool_result: bool,
    #[serde(default)]
    disposition: Option<richos_core::work_disposition::Disposition>,
    /// Retained even after successful omission recovery; never a handoff.
    #[serde(default)]
    disposition_diagnostic: Option<String>,
    done: bool,
    retry_at: u64,
    #[serde(default)]
    created_at: u64,
    error: String,
    #[serde(default)]
    directive: Option<Handoff>,
    #[serde(default)]
    target_run_id: Option<String>,
    #[serde(default)]
    answer_binding: Option<AnswerBinding>,
    #[serde(default)]
    attempts: u32,
    #[serde(default)]
    application_failures: u32,
    #[serde(default)]
    halted: bool,
    #[serde(default)]
    scope_repaired: bool,
    #[serde(default)]
    preserve_pause: Option<bool>,
    #[serde(default)]
    tail: String,
}
/// A conversational answer must retain the question that existed when the CEO
/// spoke. Retrying registration cannot turn yesterday's yes into today's grant.
#[derive(Clone, Serialize, Deserialize)]
struct AnswerBinding {
    task_id: String,
    decision_id: String,
    resource: bool,
}

fn bind_answer(journal: &Path, request: &mut Request) -> Result<(), String> {
    if request.answer_binding.is_some() { return Ok(()); }
    if request.created_at == 0 { return Err("The original decision-answer time is unavailable.".into()); }
    let snapshot = richos_core::run::read_snapshot_at(journal, request.created_at)
        .map_err(|e|e.to_string())?.ok_or("No saved decision predates the original CEO answer.")?;
    if request.target_run_id.as_deref() != Some(snapshot.id.as_str()) {
        return Err("The historical question does not belong to the original target assignment.".into());
    }
    // Timestamp equality does not prove whether the question or answer came first.
    if snapshot.updated_at >= request.created_at {
        return Err("The original answer and decision have ambiguous event ordering.".into());
    }
    let mut pending = snapshot.tasks.iter().enumerate().filter_map(|(i, _)|
        snapshot.decision(i).map(|d| AnswerBinding {
            task_id: snapshot.plan.tasks[i].id.clone(), decision_id: d.id, resource: d.resource,
        }));
    let binding = pending.next().ok_or("No question was pending when the CEO answered.")?;
    if pending.next().is_some() { return Err("The original CEO answer does not identify one of the pending questions.".into()); }
    request.answer_binding = Some(binding);
    Ok(())
}

fn apply_bound_answer(journal: &Path, request: &Request) -> Result<(), String> {
    let binding = request.answer_binding.as_ref().ok_or("The original decision answer is not bound to a question.")?;
    let mut ctl = RunController::open(journal).map_err(|e|e.to_string())?;
    ctl.answer_bound_decision(&request.id, &binding.task_id, &binding.decision_id, &request.text)
        .map_err(|e|e.to_string())

}

impl Request {
    /// Classification needs a target before successful registration has created
    /// a run. This view is never journaled or eligible for worker execution.
    fn pending_assignment(&self) -> RunSnapshot {
        let goal = match &self.directive {
            Some(Handoff::Work { goal, .. } | Handoff::Amend { goal, .. }) => goal.clone(),
            _ => richos_core::registration::source_scope(&self.text, &self.tail),
        };
        RunSnapshot {
            version: 1, revision: 0, id: self.id.clone(),
            plan: richos_core::run::RunPlan {
                goal, workspace: self.workspace.clone(), max_attempts: 20,
                turn_timeout_seconds: 1800, tasks: vec![],
            },
            plan_revision: 0, tasks: vec![], paused: false, canceled: false,
            updated_at: self.created_at, created_at: self.created_at,
            decisions: vec![], decision_receipts: vec![], permissions: vec![],
        }
    }
}

/// A later instruction might revoke or narrow an unstarted request. Classify it
/// first, even when the older request's retry deadline has arrived.
fn pending_followup(request: &Request, pending: &[Request]) -> bool {
    pending.iter().any(|later| later.thread == request.thread
        && later.created_at > request.created_at && !later.done
        && (later.directive.is_none() || later.target_run_id.as_ref() == Some(&request.id)))
}

fn now() -> u64 {
    richos_core::util::now_millis()
}
fn save<T: Serialize>(path: &Path, value: &T) -> Result<(), String> {
    use std::io::Write;
    let temporary = path.with_extension("tmp");
    let mut options = std::fs::OpenOptions::new();
    options.write(true).create(true).truncate(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }
    let mut file = options.open(&temporary).map_err(|e| e.to_string())?;
    file.write_all(&serde_json::to_vec(value).map_err(|e| e.to_string())?)
        .map_err(|e| e.to_string())?;
    file.sync_all().map_err(|e| e.to_string())?;
    std::fs::rename(temporary, path).map_err(|e| e.to_string())?;
    std::fs::File::open(path.parent().unwrap())
        .and_then(|f| f.sync_all())
        .map_err(|e| e.to_string())
}

/// Installing this feature does not retroactively execute historical conversations.
/// After installation the existing ledger itself is the durable handoff inbox.
pub fn initialize(state: &AppState) -> Result<(), String> {
    for name in ["requests", "runs", "run-notices"] {
        std::fs::create_dir_all(state.data_dir.join(name)).map_err(|e| e.to_string())?;
    }
    let baseline = state.data_dir.join("owned-work-baseline.json");
    if !baseline.exists() {
        let ids: Vec<_> = state
            .spine
            .lock()
            .unwrap()
            .ledger()
            .turns()
            .iter()
            .map(|t| t.id.clone())
            .collect();
        save(&baseline, &ids)?;
    }
    Ok(())
}

/// Unfinished durable work is independent of the conversation's live lease.
/// The updater must include queued registration, retry waits and paused work.
/// A read failure is unknown, never evidence that the app is idle.
pub(crate) fn update_liveness(state: &AppState) -> richos_core::work_gate::Liveness {
    use richos_core::work_gate::Liveness;
    match state.managed_runs.active.try_lock() {
        Ok(active) if active.is_none() => {},
        Ok(_) => return Liveness::Busy,
        Err(_) => return Liveness::Unknown,
    }
    let read = || -> Result<bool, Box<dyn std::error::Error>> {
        // Cover the handoff gap before the next intake scan creates its request.
        let baseline: std::collections::HashSet<String> = serde_json::from_slice(
            &std::fs::read(state.data_dir.join("owned-work-baseline.json"))?
        )?;
        let spine = state.spine.try_lock().map_err(|_| std::io::Error::other("spine unavailable"))?;
        for turn in spine.ledger().turns() {
            if !baseline.contains(&turn.id) && !turn.quarantined
                && matches!(turn.source, Source::Text | Source::Jam)
                && matches!(turn.state, TurnState::Completed | TurnState::Interrupted)
            {
                let id = autonomy::turn_request_id(&turn.id).map_err(std::io::Error::other)?;
                if !state.data_dir.join("requests").join(format!("{id}.json")).try_exists()? {
                    return Ok(true);
                }
            }
        }
        drop(spine);
        for entry in std::fs::read_dir(state.data_dir.join("requests"))? {
            let path = entry?.path();
            if path.extension().and_then(|s| s.to_str()) == Some("json") {
                let request: Request = serde_json::from_slice(&std::fs::read(path)?)?;
                if !request.done { return Ok(true); }
            }
        }
        for entry in std::fs::read_dir(state.data_dir.join("runs"))? {
            let path = entry?.path();
            if path.extension().and_then(|s| s.to_str()) == Some("jsonl") {
                let snapshot = richos_core::run::read_snapshot(&path)?;
                if !matches!(snapshot.state(), RunState::Completed | RunState::Canceled) {
                    return Ok(true);
                }
            }
        }
        Ok(false)
    };
    match read() { Ok(true) => Liveness::Busy, Ok(false) => Liveness::Clear, Err(_) => Liveness::Unknown }
}

/// The updater's explanation of its durable-work reading.
pub(crate) fn ceo_message(liveness: richos_core::work_gate::Liveness) -> Option<String> {
    use richos_core::work_gate::Liveness;
    match liveness {
        Liveness::Busy => Some("Rich has unfinished assignments. The update will wait.".into()),
        Liveness::Unknown => Some("Rich cannot confirm that all assignments have finished. The update will wait.".into()),
        Liveness::Clear => None,
    }
}

struct IntakeIndex {
    baseline: std::collections::HashSet<String>,
    cursor: usize,
    unresolved: std::collections::BTreeSet<usize>,
    pending: std::collections::HashSet<PathBuf>,
}
impl IntakeIndex {
    fn load(state: &AppState) -> Result<Self, String> {
        let baseline = serde_json::from_slice(
            &std::fs::read(state.data_dir.join("owned-work-baseline.json"))
                .map_err(|e| e.to_string())?,
        )
        .map_err(|e| e.to_string())?;
        let pending = std::fs::read_dir(state.data_dir.join("requests"))
            .map_err(|e| e.to_string())?
            .filter_map(|e| e.ok().map(|e| e.path()))
            .filter(|p| p.extension().and_then(|s| s.to_str()) == Some("json"))
            .collect();
        Ok(Self {
            baseline,
            cursor: 0,
            unresolved: Default::default(),
            pending,
        })
    }
}

#[cfg(debug_assertions)]
fn discover(state: &AppState) -> Result<(), String> {
    discover_cached(state, &mut IntakeIndex::load(state)?)
}

/// Scope failures prohibit dispatch. Receipt failures only remove the optional
/// Rich-authored hint: the original CEO source remains eligible for private,
/// tool-free registration, with the failed receipt retained as a diagnostic.
fn source_disposition(
    spine: &richos_core::spine::Spine,
    turn: &str,
) -> Result<(PathBuf, Option<richos_core::work_disposition::Disposition>, Option<String>), String> {
    let scope = spine.work_disposition_scope(turn)
        .map_err(|e| format!("The original work scope is unavailable: {e}"))?;
    let (disposition, diagnostic) = match richos_core::work_disposition::read_bound_receipt(&scope) {
        Ok(receipt) => (receipt.map(|r| r.disposition), None),
        Err(error) => (None, Some(format!("The work disposition receipt was rejected: {error}"))),
    };
    Ok((scope.workspace, disposition, diagnostic))
}

fn discover_cached(state: &AppState, index: &mut IntakeIndex) -> Result<(), String> {
    let spine = state.spine.lock().unwrap();
    index
        .unresolved
        .extend(index.cursor..spine.ledger().turns().len());
    index.cursor = spine.ledger().turns().len();
    for i in index.unresolved.clone() {
        let turn = &spine.ledger().turns()[i];
        if index.baseline.contains(&turn.id)
            || turn.quarantined
            || !matches!(turn.source, Source::Text | Source::Jam)
        {
            index.unresolved.remove(&i);
            continue;
        }
        if !matches!(turn.state, TurnState::Completed | TurnState::Interrupted) {
            continue;
        }
        let id = autonomy::turn_request_id(&turn.id)?;
        let path = state.data_dir.join("requests").join(format!("{id}.json"));
        if path.exists() {
            index.unresolved.remove(&i);
            continue;
        }
        // Preserve each source before attempting recovery. A corrupt receipt must
        // not abort discovery for unrelated conversations or guess an execution root.
        let (workspace, disposition, disposition_diagnostic) =
            match source_disposition(&spine, &turn.id) {
                Ok(bound) => bound,
                Err(error) => (PathBuf::new(), None, Some(error)),
            };
        save(
            &path,
            &Request {
                id,
                source_turn: Some(turn.id.clone()),
                thread: turn.thread_id.clone(),
                workspace,
                text: turn.user_text.clone(),
                conversation: turn.assistant_text.clone(),
                onboarding_tool_result: spine.machinery_journal().map(|journal|
                    richos_core::onboarding_tools::handled_in_turn(journal.read_thread(&turn.thread_id), &turn.id)
                ).unwrap_or(false),
                disposition,
                disposition_diagnostic,
                done: false,
                retry_at: 0,
                created_at: turn.created_at,
                error: String::new(),
                directive: None,
                target_run_id: None,
                answer_binding: None,
                attempts: 0,
                application_failures: 0,
                halted: false,
                scope_repaired: false,
                preserve_pause: None,
                tail: spine
                    .ledger()
                    .turns()
                    .iter()
                    .filter(|t| {
                        t.thread_id == turn.thread_id
                            && t.created_at < turn.created_at
                            && matches!(t.source, Source::Text | Source::Jam)
                    })
                    .rev()
                    .take(6)
                    .collect::<Vec<_>>()
                    .into_iter()
                    .rev()
                    .map(|t| format!("CEO: {}\nRich: {}", t.user_text, t.assistant_text))
                    .collect::<Vec<_>>()
                    .join("\n"),
            },
        )?;
        index.pending.insert(path);
        index.unresolved.remove(&i);
    }
    Ok(())
}

fn requests(state: &AppState, index: &mut IntakeIndex) -> Result<(), String> {
    discover_cached(state, index)?;
    let mut queued = vec![];
    let mut all_pending = vec![];
    for path in index.pending.clone() {
        let request: Request =
            serde_json::from_slice(&std::fs::read(&path).map_err(|e| e.to_string())?)
                .map_err(|e| format!("Cannot read saved handoff {}: {e}", path.display()))?;
        if request.done {
            index.pending.remove(&path);
            continue;
        }
        all_pending.push(request.clone());
        if request.retry_at <= now() {
            queued.push((path, request));
        }
    }
    queued.retain(|(_, request)| !pending_followup(request, &all_pending));
    queued.sort_by_key(|(_, r)| (r.retry_at, r.created_at));
    if let Some((path, mut request)) = queued.into_iter().next() {
        // Charge before inference so process crashes cannot reset the ceiling.
        let registering = request.directive.is_none();
        // Legacy halted requests re-enter owned recovery. Persisted counters and
        // backoff survive restarts; neither requires another CEO message.
        request.halted = false;
        {
            if registering {
                request.attempts = request.attempts.saturating_add(1);
            } else {
                request.application_failures = request.application_failures.saturating_add(1);
            }
            // Reserve the next deadline before inference/application. A crash
            // cannot turn every restart into an immediate extra attempt.
            request.retry_at = now() + richos_core::registration::recovery_delay_ms(
                request.attempts.max(request.application_failures));
            save(&path, &request)?;
            match process_request(state, &path, &mut request) {
                Ok(done) => {
                    if !registering { request.application_failures = request.application_failures.saturating_sub(1); }
                    request.done = done;
                    request.retry_at = now() + 2000;
                    request.error.clear();
                }
                Err(error) => {
                    request.error = error;
                    if registering && request.directive.is_some() {
                        request.application_failures = request.application_failures.saturating_add(1);
                    }
                    request.retry_at = now() + richos_core::registration::recovery_delay_ms(
                        request.attempts.max(request.application_failures));
                    if request.error.starts_with("MISSING_SCOPE:") && !request.scope_repaired {
                        request.scope_repaired = true;
                        save(&path, &request)?;
                        let mut spine = state.spine.lock().unwrap();
                        let binding = spine
                            .ledger()
                            .thread_binding(&request.thread)
                            .map_err(|e| e.to_string())?;
                        let id = format!("scope-{}", request.id);
                        spine.report_owned_work(&binding, &id, &format!("Your accepted assignment needs a complete scope. State the deliverable and essential constraints in one concise prose paragraph, preserving prohibitions and previous requirements. No headings, lists or filesystem paths. Resolve routine details yourself; do not ask the CEO to plan. No work has been executed for this registration. Authorized source and reference context: {}", richos_core::registration::source_scope(&request.text, &request.tail))).map_err(|e|e.to_string())?;
                        request.conversation = spine
                            .ledger()
                            .turn(&id)
                            .ok_or("Scope repair missing")?
                            .assistant_text
                            .clone();
                    }
                }
            }
        }
        save(&path, &request)?;
    }
    // Notice delivery never restarts classification. Receipts survive app restarts.
    for path in index.pending.clone() {
        let request: Request =
            serde_json::from_slice(&std::fs::read(&path).map_err(|e| e.to_string())?)
                .map_err(|e| e.to_string())?;
        if !request.done && !request.error.is_empty() && request.attempts.max(request.application_failures) >= richos_core::registration::MAX_ATTEMPTS {
            // Diagnostics stay in the saved request. Do not send component names
            // or raw errors to the conversational model, including its fallback.
            let status = if request.directive.is_none() { "The work has not started." } else { "I could not confirm that the work started successfully." };
            let evidence = format!("{status} The request is saved and remains unfinished. Automatic recovery remains scheduled with a slower retry interval. Explain this briefly and take responsibility. The CEO does not need to resend the request or approve routine recovery. Do not claim execution has started.");
            report(state, &request.thread, &format!("registration-failed-{}", request.id), &evidence)?;
        }
    }
    Ok(())
}

/// Apply a correction/cancellation to work that has not acquired a run yet.
/// Return true only when the instruction itself is complete (cancellation).
fn apply_pending_instruction(requests_dir: &Path, path: &Path, request: &mut Request, target: &str) -> Result<bool, String> {
    let pending_path = requests_dir.join(format!("{target}.json"));
    let mut pending: Request = serde_json::from_slice(&std::fs::read(&pending_path).map_err(|e| e.to_string())?)
        .map_err(|e| e.to_string())?;
    if pending.thread != request.thread || pending.created_at >= request.created_at {
        return Err("The pending assignment does not precede this instruction".into());
    }
    match request.directive.clone().ok_or("Missing pending assignment action")? {
        Handoff::Cancel => {
            // The durable marker wins even if the process stops before either
            // request JSON is updated. A retry never resurrects this request.
            save(&pending_path.with_extension("cancel"), &true)?;
            pending.done = true;
            save(&pending_path, &pending)?;
            request.directive = Some(Handoff::Cancel);
            return Ok(true);
        }
        Handoff::Amend { goal, tasks } => {
            save(&pending_path.with_extension("cancel"), &true)?;
            pending.done = true;
            save(&pending_path, &pending)?;
            // The registrar's amended contract includes the original scope.
            // No original run exists, so this becomes the first executable one.
            request.directive = Some(Handoff::Work { goal, tasks });
            request.target_run_id = None;
            save(path, request)?;
        }
        other => {
            request.directive = Some(other);
            return Err("This action requires an existing run".into());
        }
    }
    Ok(false)
}

/// Registration can overlap a new conversational instruction. Fence creation
/// against the ledger too, before the next discovery pass materializes its file.
fn creation_has_unresolved_followup(state: &AppState, request: &Request) -> Result<bool, String> {
    let spine = state.spine.lock().unwrap();
    for turn in spine.ledger().turns() {
        if turn.thread_id != request.thread || turn.created_at <= request.created_at
            || turn.quarantined || !matches!(turn.source, Source::Text | Source::Jam) { continue; }
        let id = autonomy::turn_request_id(&turn.id)?;
        let path = state.data_dir.join("requests").join(format!("{id}.json"));
        if !path.try_exists().map_err(|e| e.to_string())? { return Ok(true); }
        let later: Request = serde_json::from_slice(&std::fs::read(path).map_err(|e| e.to_string())?)
            .map_err(|e| e.to_string())?;
        if pending_followup(request, &[later]) { return Ok(true); }
    }
    Ok(false)
}

fn process_request(state: &AppState, path: &Path, request: &mut Request) -> Result<bool, String> {
    if path.with_extension("cancel").exists() {
        return Ok(true);
    }
    let paths = crate::managed_runs::journals(state, &request.thread)?;
    let current: Vec<_> = paths
        .iter()
        .map(|p| richos_core::run::read_snapshot(p).map_err(|e| e.to_string()))
        .collect::<Result<_, _>>()?;
    if current
        .iter()
        .any(|s| s.id == request.id || s.decision_receipts.contains(&request.id))
    {
        return Ok(true);
    }
    if let Some(turn) = &request.source_turn {
        let bound = source_disposition(&state.spine.lock().unwrap(), turn);
        match bound {
            Ok((workspace, disposition, diagnostic)) => {
                // The durable host scope is the authority for the execution root.
                request.workspace = workspace;
                if request.directive.is_none() { request.disposition = disposition; }
                if diagnostic.is_some() { request.disposition_diagnostic = diagnostic; }
            }
            Err(error) => {
                request.workspace = PathBuf::new();
                request.disposition = None;
                request.disposition_diagnostic = Some(error.clone());
                save(path, request)?;
                return Err(error);
            }
        }
        save(path, request)?;
    }
    if request.directive.is_none() {
        if request.disposition.as_ref().is_some_and(|d| d.kind == richos_core::work_disposition::DispositionKind::Discussion) {
            request.directive = Some(Handoff::None);
            save(path, request)?;
            return Ok(true);
        }
        let mut targets = current.clone();
        for entry in std::fs::read_dir(state.data_dir.join("requests")).map_err(|e| e.to_string())? {
            let pending_path = entry.map_err(|e| e.to_string())?.path();
            if pending_path.extension().and_then(|s| s.to_str()) != Some("json") { continue; }
            let pending: Request = serde_json::from_slice(&std::fs::read(&pending_path).map_err(|e| e.to_string())?)
                .map_err(|e| e.to_string())?;
            if !pending.done && pending.thread == request.thread && pending.created_at < request.created_at
                && !pending_path.with_extension("cancel").exists()
                && !targets.iter().any(|s| s.id == pending.id) {
                targets.push(pending.pending_assignment());
            }
        }
        let (directive, target) = richos_core::registration::register_disposition(
            &request.text,
            &request.conversation,
            &request.tail,
            &targets,
            &request.error,
            request.onboarding_tool_result,
            request.disposition.as_ref(),
        )?;
        request.directive = Some(directive);
        request.target_run_id = target;
        save(path, request)?;
    }
    if let Some(target) = request.target_run_id.clone().filter(|id| !current.iter().any(|s| &s.id == id)) {
        if apply_pending_instruction(&state.data_dir.join("requests"), path, request, &target)? {
            return Ok(true);
        }
    }
    let journal = if let Some(target) = &request.target_run_id {
        paths
            .iter()
            .zip(&current)
            .find(|(_, s)| &s.id == target)
            .map(|(p, _)| p.clone())
            .ok_or("The target assignment is unavailable")?
    } else {
        let primary = state
            .data_dir
            .join("runs")
            .join(format!("{}.jsonl", request.thread));
        if primary.exists() {
            state
                .data_dir
                .join("runs")
                .join(format!("{}--{}.jsonl", request.thread, request.id))
        } else {
            primary
        }
    };
    if matches!(request.directive, Some(Handoff::AnswerDecision)) {
        bind_answer(&journal, request)?;
        save(path, request)?;
    }
    if matches!(request.directive, Some(Handoff::Amend { .. })) && request.preserve_pause.is_none() {
        // Capture user pause before the transient interruption used for a live
        // correction. The worker persists that interruption as paused too.
        request.preserve_pause = Some(journal.with_extension("pause").exists()
            || current.iter().find(|s| Some(&s.id) == request.target_run_id.as_ref()).is_some_and(|s| s.paused));
        save(path, request)?;
    }
    if matches!(request.directive, Some(Handoff::None)) {
        return Ok(true);
    }
    if matches!(request.directive, Some(Handoff::Work { .. }))
        && creation_has_unresolved_followup(state, request)? {
        return Ok(false);
    }
    let changes_current = matches!(
        request.directive,
        Some(Handoff::Amend { .. } | Handoff::AnswerDecision | Handoff::Cancel)
    );
    if let Some((_, active_path, pause)) = state.managed_runs.active.lock().unwrap().as_ref() {
        if active_path == &journal {
            if changes_current {
                pause.store(true, Ordering::SeqCst);
            }
            return Ok(false);
        }
    }
    // The same slot prevents a worker starting between the active check and the
    // journal mutation. A different company's worker need not be interrupted.
    let active = state.managed_runs.active.lock().unwrap();
    if active
        .as_ref()
        .map(|(_, p, _)| p == &journal)
        .unwrap_or(false)
    {
        return Ok(false);
    }
    match request.directive.as_ref().unwrap() {
        Handoff::None => Ok(true),
        Handoff::Work { goal, tasks } | Handoff::Amend { goal, tasks } => {
            let tasks = serde_json::from_value(serde_json::to_value(tasks).unwrap())
                .map_err(|e| e.to_string())?;
            if request
                .workspace
                .starts_with(state.data_dir.join("workspaces"))
            {
                std::fs::create_dir_all(&request.workspace).map_err(|e| e.to_string())?;
            }
            let plan = autonomy::plan(&request.workspace, &request.text, goal, tasks)?;
            if matches!(request.directive, Some(Handoff::Amend { .. })) {
                let mut ctl = RunController::open(&journal).map_err(|e| e.to_string())?;
                let preserve_pause = request.preserve_pause == Some(true) || journal.with_extension("pause").exists();
                ctl.amend_with_pause(&request.id, plan, preserve_pause).map_err(|e| e.to_string())?;
            } else {
                RunController::create_from_handoff(&journal, plan, request.id.clone())
                    .map_err(|e| e.to_string())?;
            }
            Ok(true)
        }
        Handoff::AnswerDecision => {
            apply_bound_answer(&journal, request)?;
            Ok(true)
        }
        Handoff::Cancel => {
            RunController::open(&journal)
                .map_err(|e| e.to_string())?
                .cancel()
                .map_err(|e| e.to_string())?;
            Ok(true)
        }
    }
}

/// Reporting also has a budget. A broken conversational lease cannot turn one
/// checkpoint into an unlimited inference loop. The fallback is an honest host notice.
fn report(state: &AppState, thread: &str, id: &str, evidence: &str) -> Result<bool, String> {
    let mut spine = state.spine.lock().unwrap();
    if spine
        .ledger()
        .turn(id)
        .map(|t| t.state == TurnState::Completed)
        .unwrap_or(false)
    {
        return Ok(true);
    }
    let binding = spine
        .ledger()
        .thread_binding(thread)
        .map_err(|e| e.to_string())?;
    let ticket = state
        .data_dir
        .join("run-notices")
        .join(format!("{id}.json"));
    let (attempts, retry_at): (u32, u64) = if ticket.exists() {
        serde_json::from_slice(&std::fs::read(&ticket).map_err(|e| e.to_string())?)
            .map_err(|e| e.to_string())?
    } else {
        (0, 0)
    };
    if attempts >= 3 {
        spine
            .record_owned_message(
                &binding,
                &format!("fallback-{id}"),
                None,
                &format!(
                    "Rich's spoken report could not be delivered. Saved work status: {evidence}"
                ),
            )
            .map_err(|e| e.to_string())?;
        return Ok(true);
    }
    if retry_at > now() {
        return Ok(false);
    }
    save(&ticket, &(attempts + 1, now() + 30_000))?;
    spine
        .report_owned_work(&binding, id, evidence)
        .map_err(|e| e.to_string())?;
    Ok(true)
}

fn publish_outcome(state: &AppState, thread: &str, snapshot: &RunSnapshot) -> Result<(), String> {
    let mut notices = vec![];
    for (index, receipt) in snapshot.decision_receipts.iter().enumerate() {
        let Some(encoded) = receipt.strip_prefix("panel:") else { continue; };
        let Ok((_, _, action)) = serde_json::from_str::<(String, String, richos_core::run::DecisionAction)>(encoded) else { continue; };
        let choice = match action {
            richos_core::run::DecisionAction::Continue => "The CEO explicitly authorized the displayed additional work allowance.".to_string(),
            richos_core::run::DecisionAction::Answer { text } => format!("The CEO answered (verbatim): {text}"),
            richos_core::run::DecisionAction::ChangeScope { text } => format!("The CEO changed the instructions (verbatim): {text}"),
            richos_core::run::DecisionAction::End => "The CEO ended the assignment without completing it.".to_string(),
        };
        notices.push((format!("panel-decision-{}-{index}", snapshot.id), format!("The assignment panel has already saved this CEO action. Acknowledge it briefly in the conversation. Do not ask for it again or claim the work is complete. {choice} Assignment: {}", snapshot.plan.display_goal())));
    }
    for (i, task) in snapshot.tasks.iter().enumerate() {
        if let Some(decision) = snapshot.decision(i) {
            notices.push((
                format!("decision-{}-{}-{i}-{}", snapshot.id, snapshot.plan_revision, format!("{}-{}", task.attempts, snapshot.decision_receipts.len())),
                format!("A CEO decision is required for this task. {} {} Recommendation: {} Options: {}", decision.question, decision.why_ceo, decision.recommendation, decision.options.join("; ")),
            ));
        }
    }
    if snapshot.state() == RunState::Completed {
        notices.push((
            format!("finished-{}-{}", snapshot.id, snapshot.plan_revision),
            format!(
                "Finished and checked: {}\nEvidence: {:?}",
                snapshot.plan.display_goal(),
                snapshot.tasks
            ),
        ));
    }
    // Surface repeated failures as Rich's operational report, not a demand that
    // the CEO troubleshoot. Space subsequent recovery cycles rather than burn
    // two cold sessions every few minutes forever.
    for (i, task) in snapshot.tasks.iter().enumerate() {
        let failures = task.recovery_cycles;
        if task.state == richos_core::run::TaskState::Pending
            && failures == richos_core::run::RECOVERY_CHECKPOINT
        {
            notices.push((format!("recovery-{}-{}-{i}-{failures}",snapshot.id,format!("{}-{}",snapshot.plan_revision,snapshot.decision_receipts.len())),format!("Work remains owned and unfinished after repeated failures. Diagnose these results, explain the changed approach and any external dependency. No CEO retry approval is needed. Automatic recovery is spaced one hour apart at this checkpoint. Goal: {}\nEvidence: {:?}",snapshot.plan.display_goal(),task.evidence)));
        }
    }
    for (id, evidence) in notices {
        report(state, thread, &id, &evidence)?;
    }
    Ok(())
}

fn jobs(app: &tauri::AppHandle, state: &AppState) -> Result<(), String> {
    let threads: Vec<_> = state
        .spine
        .lock()
        .unwrap()
        .threads()
        .into_iter()
        .map(|t| t.id)
        .collect();
    for thread in threads {
        for path in crate::managed_runs::journals(state, &thread)? {
            let pause = Arc::new(AtomicBool::new(path.with_extension("pause").exists()));
            {
                let mut active = state.managed_runs.active.lock().unwrap();
                if active.is_some() {
                    return Ok(());
                }
                *active = Some((thread.clone(), path.clone(), pause.clone()));
            }
            let result = (|| -> Result<(), String> {
                let mut ctl = RunController::open(&path).map_err(|e| e.to_string())?;
                if !ctl.snapshot().plan.autonomous() {
                    return Ok(());
                }
                if state
                    .data_dir
                    .join("requests")
                    .join(format!("{}.cancel", ctl.snapshot().id))
                    .exists()
                {
                    ctl.cancel().map_err(|e| e.to_string())?;
                }
                if path.with_extension("cancel").exists() {
                    ctl.cancel().map_err(|e| e.to_string())?;
                }
                if path.with_extension("pause").exists() {
                    ctl.pause(true).map_err(|e| e.to_string())?;
                }
                publish_outcome(state, &thread, ctl.snapshot())?;
                if ctl.snapshot().state() != RunState::Ready {
                    return Ok(());
                }
                let context = {
                    let mut spine = state.spine.lock().unwrap();
                    let binding = spine
                        .ledger()
                        .thread_binding(&thread)
                        .map_err(|e| e.to_string())?;
                    spine
                        .owned_worker_context(&binding)
                        .map_err(|e| e.to_string())?
                };
                // No Spine borrow survives this scope. Rich can answer and revise work
                // while this independently governed worker executes.
                struct Host {
                    permission_context: Option<richos_core::permission::Context>,
                    context: String,
                    pause: Arc<AtomicBool>,
                    app: tauri::AppHandle,
                    thread: String,
                }
                impl richos_core::run::RunHost for Host {
                    fn permission_context(&mut self, context: richos_core::permission::Context) -> Result<(), String> {
                        self.permission_context = Some(context);
                        Ok(())
                    }
                    fn execute(
                        &mut self,
                        plan: &richos_core::run::RunPlan,
                        task: &richos_core::run::TaskSpec,
                        previous: &[String],
                    ) -> Result<(), String> {
                        let mut model =
                            NativeCognition::start_managed(&resolve_claude_bin(), &plan.workspace)
                                .map_err(|e| e.to_string())?;
                        if let Some(context) = self.permission_context.clone() {
                            model.set_managed_permission_context(context).map_err(|e| e.to_string())?;
                        }
                        // Priming is part of the bounded worker prompt, not an unbounded
                        // extra call before the timeout watcher starts.
                        let mut effective = plan.clone();
                        effective.goal =
                            format!("{}\nScoped Rich context:\n{}", plan.goal, self.context);
                        let mut sink = |_: TurnItem<'_>| {};
                        richos_core::run::RunHost::execute(
                            &mut CognitionRunHost {
                                cognition: &mut model,
                                on_item: &mut sink,
                                pause: self.pause.clone(),
                            },
                            &effective,
                            task,
                            previous,
                        )
                    }
                    fn verify(
                        &mut self,
                        workspace: &Path,
                        check: &richos_core::run::Check,
                    ) -> Result<String, String> {
                        richos_core::run_host::verify_command(workspace, check, &self.pause)
                    }
                    fn paused(&self) -> bool {
                        self.pause.load(Ordering::SeqCst)
                    }
                    fn updated(&mut self, s: &RunSnapshot) {
                        let _ = self.app.emit(
                            EVENT_RUN_UPDATED,
                            crate::managed_runs::view(&self.thread, s),
                        );
                    }
                }
                ctl.tick(&mut Host {
                    permission_context: None,
                    context,
                    pause,
                    app: app.clone(),
                    thread: thread.clone(),
                })
                .map_err(|e| e.to_string())?;
                if path.with_extension("cancel").exists() {
                    ctl.cancel().map_err(|e| e.to_string())?;
                }
                publish_outcome(state, &thread, ctl.snapshot())?;
                Ok(())
            })();
            *state.managed_runs.active.lock().unwrap() = None;
            if let Err(error) = result {
                eprintln!("Owned execution recovery for {thread}: {error}");
            }
        }
    }
    Ok(())
}

pub fn start(app: tauri::AppHandle) {
    let intake_app = app.clone();
    std::thread::spawn(move || {
        let mut index = None;
        loop {
            std::thread::sleep(Duration::from_secs(2));
            let state = intake_app.state::<AppState>();
            if index.is_none() {
                match IntakeIndex::load(&state) {
                    Ok(i) => index = Some(i),
                    Err(e) => {
                        eprintln!("Owned inbox index: {e}");
                        continue;
                    }
                }
            }
            if let Err(error) = requests(&state, index.as_mut().unwrap()) {
                eprintln!("Owned handoff recovery: {error}");
            }
        }
    });
    std::thread::spawn(move || loop {
        std::thread::sleep(Duration::from_secs(2));
        let state = app.state::<AppState>();
        if let Err(error) = jobs(&app, &state) {
            eprintln!("Owned execution recovery: {error}");
        }
    });
}

pub fn pending(state: &AppState, thread: &str) -> Option<(String, String, String, PathBuf)> {
    let entries = std::fs::read_dir(state.data_dir.join("requests")).ok()?;
    let mut requests: Vec<Request> = entries
        .flatten()
        .filter_map(|e| std::fs::read(e.path()).ok())
        .filter_map(|b| serde_json::from_slice(&b).ok())
        .filter(|r: &Request| {
            r.thread == thread
                && !r.done
                && (r.halted || !r.error.is_empty()
                    || matches!(
                        r.directive,
                        Some(Handoff::Work { .. } | Handoff::Amend { .. })
                    ))
        })
        .collect();
    requests.sort_by_key(|r| r.created_at);
    requests
        .into_iter()
        .next()
        .map(|r| (r.id, r.text, r.error, r.workspace))
}

pub fn cancel_pending(state: &AppState, thread: &str) -> Result<bool, String> {
    let Some((id, _, _, _)) = pending(state, thread) else {
        return Ok(false);
    };
    let file = std::fs::File::create(state.data_dir.join("requests").join(format!("{id}.cancel")))
        .map_err(|e| e.to_string())?;
    file.sync_all().map_err(|e| e.to_string())?;
    let path = state.data_dir.join("requests").join(format!("{id}.json"));
    let mut request: Request =
        serde_json::from_slice(&std::fs::read(&path).map_err(|e| e.to_string())?)
            .map_err(|e| e.to_string())?;
    request.done = true;
    save(&path, &request)?;
    let pause = state.data_dir.join("runs").join(format!("{thread}.pause"));
    if pause.exists() {
        std::fs::remove_file(pause).map_err(|e| e.to_string())?;
    }
    Ok(true)
}

/// Debug-only integration harness. It calls the real desktop commands against
/// an explicitly isolated data directory, including a restart before inference.
#[cfg(debug_assertions)]
pub fn selftest(app: tauri::AppHandle) {
    let Ok(mode) = std::env::var("RICHOS_OWNED_SELFTEST") else {
        return;
    };
    if std::env::var_os("RICHOS_TEST_DATA_DIR").is_none() {
        return;
    }
    std::thread::spawn(move || {
        let result = (|| -> Result<serde_json::Value, String> {
            let state = app.state::<AppState>();
            if mode == "disposition-corrupt" {
                let cases = [
                    ("Corrupt disposition", "Handle corrupt receipt: produce corrupt-disposition.txt containing Finished.", true),
                    ("Stale disposition", "Handle stale receipt: produce stale-disposition.txt containing Finished.", true),
                    ("Invalid disposition scope", "Handle invalid scope: produce invalid-scope.txt containing Finished.", true),
                    ("Unrelated valid disposition", "Handle unrelated receipt: produce unrelated-disposition.txt containing Finished.", false),
                ];
                let mut threads = vec![];
                for (title, text, damaged) in cases {
                    let thread = crate::create_thread_in(app.state(), "fixture".into(), title.into())?;
                    debug_send_message(app.state(), text.into())?;
                    // Discovery itself must preserve this source and continue past it.
                    discover(&state)?;
                    threads.push((thread, text, damaged));
                }
                let deadline = std::time::Instant::now();
                while deadline.elapsed() < Duration::from_secs(80) {
                    let mut recovered = 0;
                    let mut parked = 0;
                    let mut source_turns = 0;
                    for (thread, text, damaged) in &threads {
                        let spine = state.spine.lock().unwrap();
                        let sources: Vec<_> = spine.ledger().turns().iter()
                            .filter(|t| t.thread_id == *thread && matches!(t.source, Source::Text | Source::Jam)).collect();
                        if sources.len() != 1 || sources[0].user_text != *text {
                            return Err("Receipt corruption lost or duplicated the original source".into());
                        }
                        source_turns += sources.len();
                        let id = autonomy::turn_request_id(&sources[0].id)?;
                        let expected = spine.work_disposition_scope(&sources[0].id);
                        drop(spine);
                        let request: Request = serde_json::from_slice(&std::fs::read(state.data_dir.join("requests").join(format!("{id}.json"))).map_err(|e|e.to_string())?).map_err(|e|e.to_string())?;
                        if request.text != *text || request.source_turn.is_none() {
                            return Err("Receipt recovery replaced the original CEO request".into());
                        }
                        if !request.conversation.is_empty() && request.tail.contains(&request.conversation) {
                            return Err("The current acknowledgment leaked into prior conversation context".into());
                        }
                        let paths = crate::managed_runs::journals(&state, thread)?;
                        if text.starts_with("Handle invalid scope:") {
                            if expected.is_ok() || request.workspace != PathBuf::new() || request.done || request.directive.is_some()
                                || !paths.is_empty() || request.disposition.is_some() || request.disposition_diagnostic.is_none() {
                                return Err("Invalid host scope dispatched work or supplied a guessed workspace".into());
                            }
                            if request.attempts > 0 && request.retry_at > now() && !request.error.is_empty() { parked += 1; }
                        } else {
                            let expected = expected.map_err(|e|e.to_string())?;
                            if request.workspace != expected.workspace || (*damaged && (request.disposition.is_some() || request.disposition_diagnostic.is_none())) {
                                return Err("Corrupt receipt became a trusted handoff or changed the host workspace".into());
                            }
                            if paths.len() > 1 { return Err("Receipt recovery duplicated an assignment".into()); }
                            if request.done && paths.first().is_some_and(|p| richos_core::run::read_snapshot(p).is_ok_and(|s| s.state() == RunState::Completed)) { recovered += 1; }
                        }
                    }
                    if recovered == 3 && parked == 1 {
                        return Ok(serde_json::json!({"passed":true,"recovered":recovered,"parked":parked,"sourceTurns":source_turns}));
                    }
                    std::thread::sleep(Duration::from_millis(100));
                }
                return Err("Receipt isolation did not recover unrelated work before the deadline".into());
            }
            if mode.starts_with("disposition-") {
                let interrupted = mode.contains("interrupted");
                let discussion = mode == "disposition-discussion";
                let title = if discussion { "Disposition discussion" } else if interrupted { "Interrupted disposition" } else { "Missing disposition" };
                let request_text = if discussion { "How is disposition work going?" }
                    else if interrupted { "Handle interrupted disposition: produce interrupted-disposition.txt containing Finished." }
                    else { "Handle missing disposition: produce missing-disposition.txt containing Finished." };
                let thread = if discussion || mode.ends_with("-enqueue") {
                    let thread = crate::create_thread_in(app.state(), "fixture".into(), title.into())?;
                    // The interrupted fake native process hangs before returning a receipt.
                    // Its parent harness kills only this disposable app process group.
                    debug_send_message(app.state(), request_text.into())?;
                    if interrupted { return Err("Expected the harness to interrupt the app before this turn returned".into()); }
                    discover(&state)?;
                    thread
                } else {
                    state.spine.lock().unwrap().threads().into_iter().find(|t|t.title==title)
                        .ok_or("The original disposition conversation disappeared on restart")?.id
                };
                if mode.ends_with("-enqueue") {
                    let saved: Vec<Request> = std::fs::read_dir(state.data_dir.join("requests")).map_err(|e|e.to_string())?
                        .flatten().filter_map(|e|std::fs::read(e.path()).ok())
                        .filter_map(|b|serde_json::from_slice(&b).ok())
                        .filter(|r:&Request|r.thread==thread).collect();
                    if saved.len()!=1 || saved[0].text!=request_text || saved[0].disposition.is_some() {
                        return Err("Missing disposition was lost or fabricated before restart".into());
                    }
                    return Ok(serde_json::json!({"passed":true,"thread":thread,"requestPersisted":true,"receiptMissing":true}));
                }
                let deadline=std::time::Instant::now();
                while deadline.elapsed()<Duration::from_secs(80) {
                    let saved: Vec<Request> = std::fs::read_dir(state.data_dir.join("requests")).map_err(|e|e.to_string())?
                        .flatten().filter_map(|e|std::fs::read(e.path()).ok())
                        .filter_map(|b|serde_json::from_slice(&b).ok())
                        .filter(|r:&Request|r.thread==thread).collect();
                    let paths=crate::managed_runs::journals(&state,&thread)?;
                    let spine=state.spine.lock().unwrap();
                    let sources: Vec<_>=spine.ledger().turns().iter().filter(|t|t.thread_id==thread && matches!(t.source,Source::Text|Source::Jam)).collect();
                    if sources.len()!=1 || sources[0].user_text!=request_text {
                        return Err("Disposition recovery lost or duplicated the original CEO source".into());
                    }
                    let source_state=sources[0].state;
                    let interruption_reason=sources[0].stop_reason.clone().unwrap_or_default();
                    drop(spine);
                    if saved.len()==1 && saved[0].done {
                        if discussion {
                            if !paths.is_empty() || !saved[0].disposition.as_ref().is_some_and(|d|d.kind==richos_core::work_disposition::DispositionKind::Discussion) {
                                return Err("Discussion did not finish through its explicit receipt only".into());
                            }
                            return Ok(serde_json::json!({"passed":true,"thread":thread,"requests":1,"runs":0,"sourceTurns":1}));
                        }
                        if paths.len()>1 { return Err("Recovery duplicated the owned run".into()); }
                        if let Some(path)=paths.first() {
                            let snapshot=richos_core::run::read_snapshot(path).map_err(|e|e.to_string())?;
                            if snapshot.state()==RunState::Completed {
                                if saved[0].disposition.is_some() || (interrupted && source_state!=TurnState::Interrupted) {
                                    return Err("The omitted or interrupted disposition was not recovered from its actual source state".into());
                                }
                                if interrupted && (interruption_reason.contains("send it again") || !interruption_reason.contains("recover any unfinished assignment automatically")) {
                                    return Err("The restart notice incorrectly asks the CEO to resubmit owned work".into());
                                }
                                return Ok(serde_json::json!({"passed":true,"thread":thread,"requests":1,"runs":1,"sourceTurns":1,"interruptedSource":interrupted,"interruptionReason":interruption_reason,"snapshot":snapshot}));
                            }
                        }
                    }
                    std::thread::sleep(Duration::from_millis(100));
                }
                return Err("Disposition recovery did not complete before the test deadline".into());
            }
            if mode == "update-owned" {
                use richos_core::work_gate::Liveness;
                let mut checks = 0;
                let mut check = |ok: bool| { assert!(ok); checks += 1; };
                check(!crate::updates::update_state(app.clone()).busy);
                check(update_liveness(&state) == Liveness::Clear);
                let workspace = state.data_dir.join("update-gate-fixture");
                std::fs::create_dir(&workspace).map_err(|e| e.to_string())?;
                let plan = autonomy::plan(&workspace, "Prepare a report", "Prepare a report", vec![autonomy::WorkItem {
                    id: "deliver".into(), description: "Prepare a report".into(), depends_on: vec![], criteria: "The report is complete".into()
                }])?;
                let path = state.data_dir.join("runs").join("update-gate.jsonl");
                let mut ctl = RunController::create(&path, plan).map_err(|e| e.to_string())?;
                check(crate::updates::update_state(app.clone()).busy);
                ctl.pause(true).map_err(|e| e.to_string())?;
                check(crate::updates::update_state(app.clone()).busy);
                ctl.cancel().map_err(|e| e.to_string())?;
                check(update_liveness(&state) == Liveness::Clear);
                let request = state.data_dir.join("requests").join("update-gate.json");
                let mut value = serde_json::json!({"id":"gate", "thread":"gate", "workspace":workspace, "text":"Prepare a report", "conversation":"I will prepare it.", "done":false, "retry_at":u64::MAX, "error":""});
                save(&request, &value)?;
                check(crate::updates::update_state(app.clone()).busy);
                value["done"] = true.into(); save(&request, &value)?;
                check(update_liveness(&state) == Liveness::Clear);
                *state.managed_runs.active.lock().unwrap() = Some(("gate".into(), path.clone(), Arc::new(AtomicBool::new(false))));
                check(crate::updates::update_state(app.clone()).busy);
                *state.managed_runs.active.lock().unwrap() = None;
                std::fs::write(&request, b"damaged").map_err(|e| e.to_string())?;
                check(update_liveness(&state) == Liveness::Unknown);
                check(crate::updates::update_state(app.clone()).busy);
                std::fs::remove_file(request).map_err(|e| e.to_string())?;
                std::fs::remove_file(path).map_err(|e| e.to_string())?;
                check(update_liveness(&state) == Liveness::Clear);
                check(!crate::updates::update_state(app.clone()).busy);
                return Ok(serde_json::json!({"updateOwned":true,"checks":checks}));
            }
            if mode == "panel-decisions" {
                use richos_core::run::{DecisionAction, TaskState};
                let thread = crate::create_thread_in(app.state(), "fixture".into(), "Panel decisions".into())?;
                let workspace = state.registry.lock().unwrap()
                    .get(&richos_core::EntityId::parse("fixture").unwrap()).unwrap().roots[0].clone();
                let mut results = vec![];
                for action in [DecisionAction::Continue, DecisionAction::ChangeScope { text: "Deliver the summary only. Do not send it.".into() }, DecisionAction::End] {
                    let plan = autonomy::plan(&workspace, "Prepare a report", "Prepare the report", vec![autonomy::WorkItem {
                        id: "deliver".into(), description: "Prepare a report".into(), depends_on: vec![], criteria: "The report exists and is correct".into()
                    }])?;
                    let id = autonomy::request_id();
                    let path = state.data_dir.join("runs").join(format!("{thread}--{id}.jsonl"));
                    let ctl = RunController::create_from_handoff(&path, plan, id).map_err(|e|e.to_string())?;
                    let mut snapshot = ctl.snapshot().clone(); drop(ctl);
                    snapshot.paused = true;
                    snapshot.tasks[0].state = TaskState::NeedsDecision;
                    snapshot.tasks[0].recovery_cycles = 10;
                    snapshot.tasks[0].evidence = vec!["CEO_DECISION:Recovery resource limit reached: 10 cycles".into()];
                    std::fs::write(&path, format!("{}\n",serde_json::to_string(&snapshot).unwrap())).map_err(|e|e.to_string())?;
                    let d = snapshot.decision(0).unwrap();
                    if crate::managed_runs::respond_run_decision(app.clone(), app.state(), thread.clone(), snapshot.id.clone(), "deliver".into(), "stale".into(), action.clone()).is_ok() {
                        return Err("A stale panel decision was accepted".into());
                    }
                    // Hold the actual desktop ownership slot until the command asks its
                    // writer to yield. This exercises the boundary without external work.
                    let yielded = Arc::new(AtomicBool::new(false));
                    if matches!(action, DecisionAction::Continue) {
                        let pause = Arc::new(AtomicBool::new(false));
                        *state.managed_runs.active.lock().unwrap() = Some((thread.clone(), path.clone(), pause.clone()));
                        let app_copy = app.clone(); let yielded_copy = yielded.clone();
                        std::thread::spawn(move || {
                            let deadline = std::time::Instant::now();
                            while !pause.load(Ordering::SeqCst) && deadline.elapsed() < Duration::from_secs(5) { std::thread::sleep(Duration::from_millis(10)); }
                            yielded_copy.store(pause.load(Ordering::SeqCst), Ordering::SeqCst);
                            *app_copy.state::<AppState>().managed_runs.active.lock().unwrap() = None;
                        });
                    }
                    let result = crate::managed_runs::respond_run_decision(app.clone(), app.state(), thread.clone(), snapshot.id.clone(), "deliver".into(), d.id, action.clone())?;
                    if matches!(action, DecisionAction::Continue) && !yielded.load(Ordering::SeqCst) {
                        return Err("Panel decision did not wait for its writer boundary".into());
                    }
                    let value = serde_json::to_value(result).unwrap();
                    match action {
                        DecisionAction::Continue if value["state"] != "ready" => return Err("Panel continue did not resume owned work".into()),
                        DecisionAction::ChangeScope { .. } if !value["instructionChanges"].as_array().unwrap().iter().any(|v| v.as_str() == Some("Deliver the summary only. Do not send it.")) => return Err("Panel scope correction was lost".into()),
                        DecisionAction::End if value["state"] != "canceled" => return Err("Panel end did not cancel".into()),
                        _ => {}
                    }
                    if let DecisionAction::ChangeScope { text } = &action {
                        let saved = richos_core::run::read_snapshot(&path).map_err(|e| e.to_string())?;
                        assert!(saved.plan.tasks.iter().all(|t| t.prompt.contains(text) && t.checks.iter().all(|c| c.argv[1].contains(text))));
                    }
                    results.push(value);
                    crate::managed_runs::end_run(app.state(), thread.clone(), Some(snapshot.id))?;
                }
                let deadline = std::time::Instant::now();
                while deadline.elapsed() < Duration::from_secs(30) {
                    let delivered = state.spine.lock().unwrap().ledger().turns().iter()
                        .filter(|t| t.thread_id == thread && t.id.starts_with("panel-decision-") && t.state == TurnState::Completed).count();
                    if delivered == 3 { return Ok(serde_json::json!({"panelActions":results.len(),"staleRejected":results.len(),"acknowledgments":delivered,"writerBoundary":true})); }
                    std::thread::sleep(Duration::from_millis(100));
                }
                return Err("Panel decision acknowledgments were not delivered".into());
            }
            if mode == "native-handoff" {
                let central = state.data_dir.join("native-test-central");
                std::fs::create_dir_all(&central).map_err(|e|e.to_string())?;
                state.spine.lock().unwrap().set_central_root(central);
                let thread = crate::create_thread_in(
                    app.state(),
                    "fixture".into(),
                    "Native handoff".into(),
                )?;
                debug_send_message(app.state(), "Handle this: create hello.txt containing exactly Hello Rich with no trailing newline. Do not create other files.".into())?;
                let deadline = std::time::Instant::now();
                while deadline.elapsed() < Duration::from_secs(240) {
                    let journal = state.data_dir.join("runs").join(format!("{thread}.jsonl"));
                    if let Ok(snapshot) = richos_core::run::read_snapshot(&journal) {
                        if snapshot.state() == RunState::Completed {
                            let spine = state.spine.lock().unwrap();
                            if spine.ledger().turns().iter().any(|t| {
                                t.id.starts_with("finished-")
                                    && t.thread_id == thread
                                    && t.state == TurnState::Completed
                            }) {
                                let bytes =
                                    std::fs::read(snapshot.plan.workspace.join("hello.txt"))
                                        .map_err(|e| e.to_string())?;
                                if bytes != b"Hello Rich" {
                                    return Err("Native handoff produced incorrect bytes".into());
                                }
                                return Ok(
                                    serde_json::json!({"nativeHandoffCompleted":true,"attempts":snapshot.tasks[0].attempts,"messages":spine.messages(&thread).map_err(|e|e.to_string())?}),
                                );
                            }
                        }
                    }
                    std::thread::sleep(Duration::from_millis(200));
                }
                return Err("Native handoff did not complete before the test deadline".into());
            }
            if mode == "end-live" {
                let thread = crate::create_thread_in(
                    app.state(),
                    "fixture".into(),
                    "End active assignment".into(),
                )?;
                let root = state
                    .registry
                    .lock()
                    .unwrap()
                    .get(&richos_core::EntityId::parse("fixture").unwrap())
                    .unwrap()
                    .roots[0]
                    .clone();
                let marker = root.join("correction-worker-started");
                if marker.exists() {
                    std::fs::remove_file(&marker).map_err(|e| e.to_string())?;
                }
                debug_send_message(
                    app.state(),
                    "Handle correction test: write original.txt.".into(),
                )?;
                let start = std::time::Instant::now();
                while !marker.exists() {
                    if start.elapsed() > Duration::from_secs(30) {
                        return Err("Correction fixture worker never started".into());
                    }
                    std::thread::sleep(Duration::from_millis(50));
                }
                let journal = state.data_dir.join("runs").join(format!("{thread}.jsonl"));
                let id = richos_core::run::read_snapshot(&journal)
                    .map_err(|e| e.to_string())?
                    .id;
                let began = std::time::Instant::now();
                let result = crate::managed_runs::end_run(app.state(), thread, Some(id))?;
                if began.elapsed() > Duration::from_secs(3)
                    || serde_json::to_value(result).unwrap()["state"] != "canceled"
                {
                    return Err("End selected the wrong assignment".into());
                }
                while start.elapsed() < Duration::from_secs(45) {
                    if richos_core::run::read_snapshot(&journal)
                        .map_err(|e| e.to_string())?
                        .state()
                        == RunState::Canceled
                    {
                        return Ok(serde_json::json!({"passed":true,"endWithoutPause":true}));
                    }
                    std::thread::sleep(Duration::from_millis(100));
                }
                return Err("End selected the wrong assignment".into());
            }
            if mode == "pending-cancel" {
                let thread = crate::create_thread_in(app.state(), "fixture".into(), "Cancel pending registration".into())?;
                let marker = PathBuf::from(std::env::var("RICHOS_FIXTURE_ROOT").unwrap()).join("registration-started");
                if marker.exists() { std::fs::remove_file(&marker).map_err(|e| e.to_string())?; }
                debug_send_message(app.state(), "Handle slow registration: cancel-before-start.".into())?;
                let start = std::time::Instant::now();
                while !marker.exists() {
                    if start.elapsed() > Duration::from_secs(20) { return Err("Registrar never started".into()); }
                    std::thread::sleep(Duration::from_millis(50));
                }
                debug_send_message(app.state(), "Cancel pending assignment.".into())?;
                while start.elapsed() < Duration::from_secs(40) {
                    let saved: Vec<Request> = std::fs::read_dir(state.data_dir.join("requests")).unwrap()
                        .flatten().filter_map(|e| std::fs::read(e.path()).ok())
                        .filter_map(|b| serde_json::from_slice(&b).ok())
                        .filter(|r: &Request| r.thread == thread).collect();
                    if !crate::managed_runs::journals(&state, &thread)?.is_empty() {
                        return Err("Canceled pending work acquired an executable run".into());
                    }
                    if saved.len() == 2 && saved.iter().all(|r| r.done) {
                        let original = saved.iter().find(|r| r.text.starts_with("Handle")).unwrap();
                        if !state.data_dir.join("requests").join(format!("{}.cancel", original.id)).exists() {
                            return Err("Pending cancellation was not durable".into());
                        }
                        return Ok(serde_json::json!({"passed":true,"canceledDuringRegistration":true,"runsStarted":0}));
                    }
                    std::thread::sleep(Duration::from_millis(100));
                }
                return Err("Pending cancellation did not complete".into());
            }
            if mode == "slow-registration" {
                let _thread = crate::create_thread_in(
                    app.state(),
                    "fixture".into(),
                    "Slow registration".into(),
                )?;
                debug_send_message(
                    app.state(),
                    "Handle slow registration: produce deliverable.txt containing Finished.".into(),
                )?;
                let marker = PathBuf::from(std::env::var("RICHOS_FIXTURE_ROOT").unwrap())
                    .join("registration-started");
                let start = std::time::Instant::now();
                while !marker.exists() {
                    if start.elapsed() > Duration::from_secs(20) {
                        return Err("Registrar never started".into());
                    }
                    std::thread::sleep(Duration::from_millis(50));
                }
                let start = std::time::Instant::now();
                debug_send_message(app.state(), "How is work going?".into())?;
                if start.elapsed() > Duration::from_secs(3) {
                    return Err("Busy registration blocked Rich".into());
                }
                // Let the slow child exit before stopping this test process.
                std::thread::sleep(Duration::from_secs(9));
                return Ok(serde_json::json!({"passed":true,"busyRegistrationResponsive":true}));
            }
            if mode == "independent-work" {
                let thread = crate::create_thread_in(
                    app.state(),
                    "fixture".into(),
                    "Independent assignments".into(),
                )?;
                let workspace = state
                    .registry
                    .lock()
                    .unwrap()
                    .get(&richos_core::EntityId::parse("fixture").unwrap())
                    .unwrap()
                    .roots[0]
                    .clone();
                let primary = state.data_dir.join("runs").join(format!("{thread}.jsonl"));
                let plan = autonomy::plan(
                    &workspace,
                    "An earlier assignment",
                    "Earlier paused work",
                    vec![autonomy::WorkItem {
                        id: "old".into(),
                        description: "Earlier paused work".into(),
                        depends_on: vec![],
                        criteria: "Old result".into(),
                    }],
                )?;
                let mut ctl = RunController::create(&primary, plan).map_err(|e| e.to_string())?;
                ctl.pause(true).map_err(|e| e.to_string())?;
                let old_id = ctl.snapshot().id.clone();
                drop(ctl);
                debug_send_message(
                    app.state(),
                    "Handle this: produce deliverable.txt containing Finished.".into(),
                )?;
                let start = std::time::Instant::now();
                while start.elapsed() < Duration::from_secs(40) {
                    let paths = crate::managed_runs::journals(&state, &thread)?;
                    if paths.len() == 2
                        && paths
                            .iter()
                            .filter_map(|p| richos_core::run::read_snapshot(p).ok())
                            .any(|s| s.id != old_id && s.state() == RunState::Completed)
                    {
                        if richos_core::run::read_snapshot(&primary)
                            .map_err(|e| e.to_string())?
                            .state()
                            != RunState::Paused
                        {
                            return Err("Independent work changed the old assignment".into());
                        }
                        let view = crate::managed_runs::select_run(
                            app.state(),
                            thread.clone(),
                            old_id.clone(),
                        )?;
                        let _ = view;
                        // Control must end this selected job even after the newer one finishes.
                        while state.managed_runs.active.lock().unwrap().is_some() {
                            std::thread::sleep(Duration::from_millis(50));
                        }
                        crate::managed_runs::end_run(app.state(), thread.clone(), Some(old_id))?;
                        if richos_core::run::read_snapshot(&primary)
                            .map_err(|e| e.to_string())?
                            .state()
                            != RunState::Canceled
                        {
                            return Err("End selected the wrong assignment".into());
                        }
                        return Ok(
                            serde_json::json!({"passed":true,"independentWorkCompleted":true,"selectedControlCorrect":true}),
                        );
                    }
                    std::thread::sleep(Duration::from_millis(100));
                }
                return Err("New assignment waited behind paused work".into());
            }
            if mode == "registration-recovery" {
                let start = std::time::Instant::now();
                while start.elapsed() < Duration::from_secs(40) {
                    let saved: Vec<Request> = std::fs::read_dir(state.data_dir.join("requests")).unwrap()
                        .flatten().filter_map(|e| std::fs::read(e.path()).ok())
                        .filter_map(|b| serde_json::from_slice(&b).ok())
                        .filter(|r: &Request| r.text.starts_with("Handle malformed:") || r.text.starts_with("Question inconsistent:")).collect();
                    if saved.len() == 2 && saved.iter().all(|r| r.done && !r.halted && r.attempts == 4) {
                        let work = saved.iter().find(|r| r.text.starts_with("Handle malformed:")).unwrap();
                        if crate::managed_runs::journals(&state, &work.thread)?.iter()
                            .filter_map(|p| richos_core::run::read_snapshot(p).ok())
                            .any(|s| s.id == work.id && s.state() == RunState::Completed) {
                            return Ok(serde_json::json!({"passed":true,"recoveredWithoutResubmission":2,"attemptsPreserved":true}));
                        }
                    }
                    std::thread::sleep(Duration::from_millis(100));
                }
                return Err("Scheduled registration did not recover without a CEO message".into());
            }
            if mode == "registration-failures" || mode == "registration-failures-restart" {
                let threads = if mode == "registration-failures" {
                    let first = crate::create_thread_in(
                        app.state(), "fixture".into(), "Failed registration".into(),
                    )?;
                    debug_send_message(app.state(), "Handle malformed: deliver the document.".into())?;
                    // These are independent provider-failure cases. A later
                    // unclassified instruction in the same conversation correctly
                    // fences an earlier request that it might cancel or narrow.
                    let second = crate::create_thread_in(
                        app.state(), "fixture".into(), "Inconsistent registration".into(),
                    )?;
                    debug_send_message(app.state(), "Question inconsistent: what is the plan?".into())?;
                    vec![first, second]
                } else {
                    let all = state.spine.lock().unwrap().threads();
                    ["Failed registration", "Inconsistent registration"].iter().map(|title|
                        all.iter().find(|t| t.title == *title).map(|t| t.id.clone())
                            .ok_or_else(|| format!("Failure test thread missing: {title}"))
                    ).collect::<Result<Vec<_>, _>>()?
                };
                let start = std::time::Instant::now();
                while start.elapsed() < Duration::from_secs(95) {
                    let saved: Vec<Request> = std::fs::read_dir(state.data_dir.join("requests"))
                        .unwrap()
                        .flatten()
                        .filter_map(|e| std::fs::read(e.path()).ok())
                        .filter_map(|b| serde_json::from_slice(&b).ok())
                        .filter(|r: &Request| threads.contains(&r.thread))
                        .collect();
                    let spine = state.spine.lock().unwrap();
                    let notices = spine
                        .ledger()
                        .turns()
                        .iter()
                        .filter(|t| {
                            threads.contains(&t.thread_id)
                                && t.id.starts_with("registration-failed-")
                                && t.state == TurnState::Completed
                        })
                        .count();
                    drop(spine);
                    if saved.len() == 2
                        && saved.iter().all(|r| !r.halted && !r.done && r.attempts == 3 && r.retry_at > now())
                        && notices == 2
                    {
                        for thread in &threads {
                            if !crate::managed_runs::journals(&state, thread)?.is_empty() {
                                return Err("Invalid registration launched a worker".into());
                            }
                        }
                        std::thread::sleep(Duration::from_secs(4));
                        return Ok(
                            serde_json::json!({"passed":true,"recovering":2,"reports":notices,"workers":0}),
                        );
                    }
                    std::thread::sleep(Duration::from_millis(100));
                }
                return Err("Registration failures did not retain scheduled recovery and report".into());
            }
            if mode == "correct-live" {
                let thread = crate::create_thread_in(
                    app.state(),
                    "fixture".into(),
                    "Live correction".into(),
                )?;
                debug_send_message(
                    app.state(),
                    "Handle correction test: write original.txt.".into(),
                )?;
                let root = state
                    .registry
                    .lock()
                    .unwrap()
                    .get(&richos_core::EntityId::parse("fixture").unwrap())
                    .unwrap()
                    .roots[0]
                    .clone();
                let deadline = std::time::Instant::now();
                while !root.join("correction-worker-started").exists() {
                    if deadline.elapsed() > Duration::from_secs(45) {
                        return Err("Correction fixture worker never started".into());
                    }
                    std::thread::sleep(Duration::from_millis(50));
                }
                let other = crate::create_thread_in(
                    app.state(),
                    "other".into(),
                    "Responsive conversation".into(),
                )?;
                let began = std::time::Instant::now();
                debug_send_message(app.state(), "How is work going?".into())?;
                let responsive = began.elapsed() < Duration::from_secs(3);
                if !responsive {
                    return Err("Background worker blocked the conversation".into());
                }
                state
                    .spine
                    .lock()
                    .unwrap()
                    .switch_thread(&thread)
                    .map_err(|e| e.to_string())?;
                debug_send_message(app.state(), "Revise the assignment: write revised.txt containing Revised. instead. Do not produce original.txt.".into())?;
                while deadline.elapsed() < Duration::from_secs(80) {
                    let journal = state.data_dir.join("runs").join(format!("{thread}.jsonl"));
                    if let Ok(snapshot) = richos_core::run::read_snapshot(&journal) {
                        if snapshot.state() == RunState::Completed
                            && snapshot.plan.goal.contains("revised.txt")
                        {
                            return Ok(
                                serde_json::json!({"conversationResponsive":responsive,"correctionApplied":true,"other":other}),
                            );
                        }
                    }
                    std::thread::sleep(Duration::from_millis(100));
                }
                return Err("Live correction did not finish".into());
            }
            if mode == "enqueue" {
                let thread =
                    crate::create_thread_in(app.state(), "fixture".into(), "Handle this".into())?;
                debug_send_message(
                    app.state(),
                    "Handle this: produce deliverable.txt containing Finished.".into(),
                )?;
                assert!(crate::updates::update_state(app.clone()).busy, "Update must wait across the registration handoff gap");
                discover(&state)?;
                return Ok(
                    serde_json::json!({"phase":"accepted","thread":thread,"requestPersisted":std::fs::read_dir(state.data_dir.join("requests")).map_err(|e|e.to_string())?.count() > 0}),
                );
            }
            let thread = state
                .spine
                .lock()
                .unwrap()
                .threads()
                .into_iter()
                .find(|t| t.title == "Handle this")
                .ok_or("Accepted conversation disappeared on restart")?
                .id;
            let elsewhere =
                crate::create_thread_in(app.state(), "other".into(), "Elsewhere".into())?;
            let started = std::time::Instant::now();
            loop {
                if started.elapsed() > Duration::from_secs(90) {
                    return Err(
                        "Desktop job did not finish within the integration-test deadline".into(),
                    );
                }
                let journal = state.data_dir.join("runs").join(format!("{thread}.jsonl"));
                if let Ok(snapshot) = richos_core::run::read_snapshot(&journal) {
                    if snapshot.state() == RunState::Completed {
                        let spine = state.spine.lock().unwrap();
                        if spine.active_thread() != Some(elsewhere.as_str()) {
                            return Err("Worker changed the selected conversation".into());
                        }
                        if !spine
                            .messages(&elsewhere)
                            .map_err(|e| e.to_string())?
                            .is_empty()
                        {
                            return Err("Worker output leaked into the selected company".into());
                        }
                        let messages = spine.messages(&thread).map_err(|e| e.to_string())?;
                        if !messages
                            .iter()
                            .any(|m| m.text.starts_with("Finished and checked:"))
                        {
                            drop(spine);
                            std::thread::sleep(Duration::from_millis(100));
                            continue;
                        }
                        return Ok(
                            serde_json::json!({"phase":"completed","attempts":snapshot.tasks[0].attempts,"messages":messages,"backgroundScopePreserved":true,"snapshot":snapshot}),
                        );
                    }
                }
                std::thread::sleep(Duration::from_millis(100));
            }
        })();
        let state = app.state::<AppState>();
        let (report, code) = match result {
            Ok(value) => (value, 0),
            Err(error) => (serde_json::json!({"error":error}), 1),
        };
        let path = state.data_dir.join(format!("selftest-{mode}.json"));
        let write = std::fs::write(path, serde_json::to_vec_pretty(&report).unwrap());
        app.exit(if write.is_ok() { code } else { 2 });
    });
}

#[cfg(debug_assertions)]
fn debug_send_message(state: tauri::State<AppState>, text: String) -> Result<Vec<richos_core::ledger::Message>, String> {
    let thread = state.spine.lock().unwrap().active_thread()
        .ok_or("Open a conversation first.")?.to_string();
    crate::send_message(state, text, thread)
}

#[cfg(test)]
mod pending_instruction_tests {
    use super::*;

    struct Temp(PathBuf);
    impl Temp {
        fn new() -> Self {
            let path = std::env::temp_dir().join(format!("richos-pending-test-{}", autonomy::request_id()));
            std::fs::create_dir(&path).unwrap();
            Self(path)
        }
        fn path(&self) -> &Path { &self.0 }
    }
    impl Drop for Temp { fn drop(&mut self) { let _ = std::fs::remove_dir_all(&self.0); } }

    fn request(id: &str, created_at: u64, workspace: &Path) -> Request {
        serde_json::from_value(serde_json::json!({
            "id": id, "source_turn": null, "thread": "company", "workspace": workspace,
            "text": "Repair the local defect. Do not publish.", "conversation": "Recorded.",
            "done": false, "retry_at": 0, "created_at": created_at, "error": ""
        })).unwrap()
    }

    fn decision_snapshot(temp: &Temp) -> (PathBuf, RunSnapshot) {
        let plan = autonomy::plan(temp.path(), "Prepare a report", "Prepare a report", vec![autonomy::WorkItem {
            id: "deliver".into(), description: "Prepare a report".into(), depends_on: vec![], criteria: "Report is finished".into(),
        }]).unwrap();
        let journal = temp.path().join("run.jsonl");
        let ctl = RunController::create(&journal, plan).unwrap();
        let mut snapshot = ctl.snapshot().clone();
        drop(ctl);
        snapshot.updated_at = 100;
        snapshot.tasks[0].state = richos_core::run::TaskState::NeedsDecision;
        snapshot.tasks[0].evidence = vec![format!("{}{}", autonomy::DECISION, serde_json::json!({
            "kind":"decision", "question":"Authorize purchase A?", "why_ceo":"Spending authority", "recommendation":"A", "options":["A","Decline"]
        }))];
        std::fs::write(&journal, format!("{}\n", serde_json::to_string(&snapshot).unwrap())).unwrap();
        (journal, snapshot)
    }

    #[test]
    fn delayed_answer_keeps_original_question_and_cannot_answer_replacement() {
        let temp = Temp::new();
        let (journal, first) = decision_snapshot(&temp);
        let mut later = first.clone();
        later.updated_at = 200;
        later.revision += 1;
        later.tasks[0].evidence = vec![format!("{}{}", autonomy::DECISION, serde_json::json!({
            "kind":"decision", "question":"Authorize purchase B?", "why_ceo":"Different spending", "recommendation":"B", "options":["B","Decline"]
        }))];
        std::fs::write(&journal, format!("{}\n{}\n", serde_json::to_string(&first).unwrap(), serde_json::to_string(&later).unwrap())).unwrap();
        let mut answer = request("answer", 150, temp.path());
        answer.text = "Yes, proceed.".into();
        answer.target_run_id = Some(first.id.clone());
        bind_answer(&journal, &mut answer).unwrap();
        assert_eq!(answer.answer_binding.as_ref().unwrap().decision_id, first.decision(0).unwrap().id);
        let path = temp.path().join("answer.json");
        save(&path, &answer).unwrap();
        let mut replay: Request = serde_json::from_slice(&std::fs::read(path).unwrap()).unwrap();
        bind_answer(&journal, &mut replay).unwrap();
        let before = std::fs::read(&journal).unwrap();
        assert!(apply_bound_answer(&journal, &replay).is_err());
        assert_eq!(std::fs::read(&journal).unwrap(), before);
        assert!(richos_core::run::read_snapshot(&journal).unwrap().decisions.is_empty());
    }

    #[test]
    fn original_answer_applies_once_but_absent_tied_or_ambiguous_question_is_unresolved() {
        let temp = Temp::new();
        let (journal, first) = decision_snapshot(&temp);
        for at in [0, 50, 100] {
            let mut answer = request("answer", at, temp.path());
            answer.target_run_id = Some(first.id.clone());
            assert!(bind_answer(&journal, &mut answer).is_err());
            assert!(answer.answer_binding.is_none());
        }
        let mut answer = request("answer", 150, temp.path());
        answer.text = "Yes, authorize purchase A.".into();
        answer.target_run_id = Some(first.id.clone());
        bind_answer(&journal, &mut answer).unwrap();
        apply_bound_answer(&journal, &answer).unwrap();
        apply_bound_answer(&journal, &answer).unwrap();
        let applied = richos_core::run::read_snapshot(&journal).unwrap();
        assert_eq!(applied.decisions, vec![answer.text]);
        assert_eq!(applied.decision_receipts.len(), 1);
        let mut ambiguous = first;
        let mut task = ambiguous.plan.tasks[0].clone();
        task.id = "other".into();
        ambiguous.plan.tasks.push(task);
        ambiguous.tasks.push(ambiguous.tasks[0].clone());
        std::fs::write(&journal, format!("{}\n", serde_json::to_string(&ambiguous).unwrap())).unwrap();
        let mut answer = request("answer", 150, temp.path());
        answer.target_run_id = Some(ambiguous.id.clone());
        assert!(bind_answer(&journal, &mut answer).is_err());
        assert!(answer.answer_binding.is_none());
    }

    #[test]
    fn pending_scope_does_not_promote_the_current_unaccepted_interview_offer() {
        let mut pending = request("pending", 1, Path::new("/tmp"));
        pending.conversation = "I will repair the defect. Pick a company interview slot: Tuesday or Friday.".into();
        pending.tail = "CEO: Keep the change private.".into();
        let snapshot = pending.pending_assignment();
        assert!(snapshot.plan.goal.contains(&pending.text));
        assert!(snapshot.plan.goal.contains(&pending.tail));
        assert!(!snapshot.plan.goal.contains("Tuesday or Friday"));
    }

    #[test]
    fn newer_unclassified_instruction_fences_recovery_but_other_company_does_not() {
        let original = request("original", 1, Path::new("/tmp"));
        let mut newer = request("newer", 2, Path::new("/tmp"));
        assert!(pending_followup(&original, &[newer.clone()]));
        newer.thread = "different-company".into();
        assert!(!pending_followup(&original, &[newer.clone()]));
        newer.thread = original.thread.clone();
        newer.directive = Some(Handoff::None);
        assert!(!pending_followup(&original, &[newer.clone()]));
        newer.directive = Some(Handoff::Cancel);
        newer.target_run_id = Some(original.id.clone());
        assert!(pending_followup(&original, &[newer.clone()]));
        newer.done = true;
        assert!(!pending_followup(&original, &[newer]));
    }

    #[test]
    fn pending_cancellation_is_targetable_and_durable_before_recovery() {
        let temp = Temp::new();
        let original = request("original", 1, temp.path());
        let original_path = temp.path().join("original.json");
        save(&original_path, &original).unwrap();
        let mut cancel = request("cancel", 2, temp.path());
        cancel.text = "Cancel that assignment.".into();
        let registration = richos_core::registration::Registration {
            intent: richos_core::registration::Intent::Cancel, rich_committed: false,
            request_quote: cancel.text.clone(), reply_quote: cancel.conversation.clone(),
            scope_complete: false, target_run_id: Some(original.id.clone()),
        };
        let (directive, target) = richos_core::registration::validate(registration, &cancel.text,
            &cancel.conversation, "", &[original.pending_assignment()]).unwrap();
        cancel.directive = Some(directive);
        cancel.target_run_id = target;
        let cancel_path = temp.path().join("cancel.json");
        save(&cancel_path, &cancel).unwrap();
        assert!(apply_pending_instruction(temp.path(), &cancel_path, &mut cancel, "original").unwrap());
        assert!(original_path.with_extension("cancel").exists());
        let persisted: Request = serde_json::from_slice(&std::fs::read(&original_path).unwrap()).unwrap();
        assert!(persisted.done);
        // Replay the saved instruction from before acknowledgment, as after a crash.
        let mut replay: Request = serde_json::from_slice(&std::fs::read(&cancel_path).unwrap()).unwrap();
        assert!(apply_pending_instruction(temp.path(), &cancel_path, &mut replay, "original").unwrap());
        assert!(!temp.path().join("original.jsonl").exists());
    }

    #[test]
    fn pending_correction_supersedes_original_without_losing_its_prohibition() {
        let temp = Temp::new();
        let original = request("original", 1, temp.path());
        save(&temp.path().join("original.json"), &original).unwrap();
        let mut amend = request("amend", 2, temp.path());
        amend.text = "Use the corrected output format.".into();
        let registration = richos_core::registration::Registration {
            intent: richos_core::registration::Intent::Amend, rich_committed: false,
            request_quote: amend.text.clone(), reply_quote: amend.conversation.clone(),
            scope_complete: false, target_run_id: Some(original.id.clone()),
        };
        let (directive, target) = richos_core::registration::validate(registration, &amend.text,
            &amend.conversation, "", &[original.pending_assignment()]).unwrap();
        amend.directive = Some(directive);
        amend.target_run_id = target;
        let path = temp.path().join("amend.json");
        save(&path, &amend).unwrap();
        assert!(!apply_pending_instruction(temp.path(), &path, &mut amend, "original").unwrap());
        assert!(temp.path().join("original.cancel").exists());
        let persisted: Request = serde_json::from_slice(&std::fs::read(path).unwrap()).unwrap();
        assert!(persisted.target_run_id.is_none());
        // Another correction can arrive before this first corrected run starts.
        assert!(persisted.pending_assignment().plan.goal.contains("Do not publish."));
        let Some(Handoff::Work { goal, tasks }) = persisted.directive else { panic!("Not executable corrected work") };
        assert!(goal.contains("Use the corrected output format."));
        assert!(goal.contains("Do not publish."));
        assert!(tasks[0].criteria.contains("Do not publish."));
    }
}
