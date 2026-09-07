//! Durable execution behind Rich's normal conversation. Workers never lease the
//! conversation Spine or hold its mutex across execution or independent review.
use crate::AppState;
use richos_core::{
    autonomy::{self, Handoff},
    cognition::TurnItem,
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

#[derive(Serialize, Deserialize)]
struct Request {
    id: String,
    source_turn: Option<String>,
    thread: String,
    workspace: PathBuf,
    text: String,
    conversation: String,
    #[serde(default)]
    onboarding_tool_result: bool,
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
    attempts: u32,
    #[serde(default)]
    application_failures: u32,
    #[serde(default)]
    halted: bool,
    #[serde(default)]
    scope_repaired: bool,
    #[serde(default)]
    tail: String,
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

fn discover_cached(state: &AppState, index: &mut IntakeIndex) -> Result<(), String> {
    let registry = state.registry.lock().unwrap();
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
        let binding = spine
            .ledger()
            .thread_binding(&turn.thread_id)
            .map_err(|e| e.to_string())?;
        let entity = registry
            .get(binding.entity_id())
            .ok_or("The company is unavailable")?;
        // A private execution directory is not a new user-selected project root.
        let workspace = entity
            .roots
            .first()
            .cloned()
            .unwrap_or_else(|| state.data_dir.join("workspaces").join(entity.id.as_str()));
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
                done: false,
                retry_at: 0,
                created_at: turn.created_at,
                error: String::new(),
                directive: None,
                target_run_id: None,
                attempts: 0,
                application_failures: 0,
                halted: false,
                scope_repaired: false,
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
    for path in index.pending.clone() {
        let request: Request =
            serde_json::from_slice(&std::fs::read(&path).map_err(|e| e.to_string())?)
                .map_err(|e| format!("Cannot read saved handoff {}: {e}", path.display()))?;
        if request.done {
            index.pending.remove(&path);
            continue;
        }
        if !request.halted && request.retry_at <= now() {
            queued.push((path, request));
        }
    }
    queued.sort_by_key(|(_, r)| (r.retry_at, r.created_at));
    if let Some((path, mut request)) = queued.into_iter().next() {
        // Charge before inference so process crashes cannot reset the ceiling.
        let registering = request.directive.is_none();
        if (registering && request.attempts >= richos_core::registration::MAX_ATTEMPTS)
            || request.application_failures >= 3
        {
            request.halted = true;
            save(&path, &request)?;
        } else {
            if registering {
                request.attempts += 1;
            }
            save(&path, &request)?;
            match process_request(state, &path, &mut request) {
                Ok(done) => {
                    request.done = done;
                    request.retry_at = now() + 2000;
                    request.error.clear();
                }
                Err(error) => {
                    request.error = error;
                    request.retry_at = now() + 30_000;
                    if request.directive.is_some() {
                        request.application_failures += 1;
                    }
                    request.halted = (request.directive.is_none()
                        && request.attempts >= richos_core::registration::MAX_ATTEMPTS)
                        || request.application_failures >= 3;
                    if request.error.starts_with("MISSING_SCOPE:") && !request.scope_repaired {
                        request.scope_repaired = true;
                        save(&path, &request)?;
                        let mut spine = state.spine.lock().unwrap();
                        let binding = spine
                            .ledger()
                            .thread_binding(&request.thread)
                            .map_err(|e| e.to_string())?;
                        let id = format!("scope-{}", request.id);
                        spine.report_owned_work(&binding, &id, &format!("Your accepted assignment needs a complete scope. State the deliverable and essential constraints in one concise prose paragraph, preserving prohibitions and previous requirements. No headings, lists or filesystem paths. Resolve routine details yourself; do not ask the CEO to plan. No work has been executed for this registration. CEO request: {}\nPrevious reply: {}\nConversation: {}", request.text, request.conversation, request.tail)).map_err(|e|e.to_string())?;
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
        if request.halted && !request.done {
            // Diagnostics stay in the saved request. Do not send component names
            // or raw errors to the conversational model, including its fallback.
            let status = if request.directive.is_none() { "The work has not started." } else { "I could not confirm that the work started successfully." };
            let evidence = format!("{status} The request is saved and remains unfinished. Automatic attempts have stopped. Explain this briefly and take responsibility. If the CEO wants another attempt, they can send the request again in their own words. Do not demand a shorter brief, imply their original request was wrong or promise recovery is already underway.");
            if report(state, &request.thread, &format!("registration-failed-{}", request.id), &evidence)? { index.pending.remove(&path); }
        }
    }
    Ok(())
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
    if request.directive.is_none() {
        let (directive, target) = richos_core::registration::register_with_onboarding(
            &request.text,
            &request.conversation,
            &request.tail,
            &current,
            &request.error,
            request.onboarding_tool_result,
        )?;
        request.directive = Some(directive);
        request.target_run_id = target;
        save(path, request)?;
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
    if matches!(request.directive, Some(Handoff::None)) {
        return Ok(true);
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
                ctl.amend(&request.id, plan).map_err(|e| e.to_string())?;
                let pause = journal.with_extension("pause");
                if pause.exists() {
                    std::fs::remove_file(pause).map_err(|e| e.to_string())?;
                }
            } else {
                RunController::create_from_handoff(&journal, plan, request.id.clone())
                    .map_err(|e| e.to_string())?;
            }
            Ok(true)
        }
        Handoff::AnswerDecision => {
            let mut ctl = RunController::open(&journal).map_err(|e| e.to_string())?;
            ctl.answer_decision(&request.id, &request.text)
                .map_err(|e| e.to_string())?;
            ctl.pause(false).map_err(|e| e.to_string())?;
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
                    context: String,
                    pause: Arc<AtomicBool>,
                    app: tauri::AppHandle,
                    thread: String,
                }
                impl richos_core::run::RunHost for Host {
                    fn execute(
                        &mut self,
                        plan: &richos_core::run::RunPlan,
                        task: &richos_core::run::TaskSpec,
                        previous: &[String],
                    ) -> Result<(), String> {
                        let mut model =
                            NativeCognition::start_managed(&resolve_claude_bin(), &plan.workspace)
                                .map_err(|e| e.to_string())?;
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
                && (r.halted
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
            if mode == "registration-failures" || mode == "registration-failures-restart" {
                let thread = if mode == "registration-failures" {
                    let thread = crate::create_thread_in(
                        app.state(),
                        "fixture".into(),
                        "Failed registration".into(),
                    )?;
                    debug_send_message(
                        app.state(),
                        "Handle malformed: deliver the document.".into(),
                    )?;
                    debug_send_message(
                        app.state(),
                        "Question inconsistent: what is the plan?".into(),
                    )?;
                    thread
                } else {
                    state
                        .spine
                        .lock()
                        .unwrap()
                        .threads()
                        .into_iter()
                        .find(|t| t.title == "Failed registration")
                        .ok_or("Failure test thread missing")?
                        .id
                };
                let start = std::time::Instant::now();
                while start.elapsed() < Duration::from_secs(95) {
                    let saved: Vec<Request> = std::fs::read_dir(state.data_dir.join("requests"))
                        .unwrap()
                        .flatten()
                        .filter_map(|e| std::fs::read(e.path()).ok())
                        .filter_map(|b| serde_json::from_slice(&b).ok())
                        .filter(|r: &Request| r.thread == thread)
                        .collect();
                    let spine = state.spine.lock().unwrap();
                    let notices = spine
                        .ledger()
                        .turns()
                        .iter()
                        .filter(|t| {
                            t.thread_id == thread
                                && t.id.starts_with("registration-failed-")
                                && t.state == TurnState::Completed
                        })
                        .count();
                    drop(spine);
                    if saved.len() == 2
                        && saved.iter().all(|r| r.halted && !r.done && r.attempts == 3)
                        && notices == 2
                    {
                        if !crate::managed_runs::journals(&state, &thread)?.is_empty() {
                            return Err("Invalid registration launched a worker".into());
                        }
                        std::thread::sleep(Duration::from_secs(4));
                        return Ok(
                            serde_json::json!({"passed":true,"halted":2,"reports":notices,"workers":0}),
                        );
                    }
                    std::thread::sleep(Duration::from_millis(100));
                }
                return Err("Registration failures did not stop and report".into());
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
