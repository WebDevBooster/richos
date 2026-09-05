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
    done: bool,
    retry_at: u64,
    #[serde(default)]
    created_at: u64,
    error: String,
    #[serde(default)]
    directive: Option<Handoff>,
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
    for name in ["requests", "runs"] {
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

fn discover(state: &AppState) -> Result<(), String> {
    let baseline: Vec<String> = serde_json::from_slice(
        &std::fs::read(state.data_dir.join("owned-work-baseline.json"))
            .map_err(|e| e.to_string())?,
    )
    .map_err(|e| e.to_string())?;
    let registry = state.registry.lock().unwrap();
    let spine = state.spine.lock().unwrap();
    for turn in spine.ledger().turns() {
        if baseline.contains(&turn.id)
            || turn.quarantined
            || !matches!(turn.source, Source::Text | Source::Jam)
            || !matches!(turn.state, TurnState::Completed | TurnState::Interrupted)
        {
            continue;
        }
        let id = autonomy::turn_request_id(&turn.id)?;
        let path = state.data_dir.join("requests").join(format!("{id}.json"));
        if path.exists() {
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
                done: false,
                retry_at: 0,
                created_at: turn.created_at,
                error: String::new(),
                directive: None,
            },
        )?;
    }
    Ok(())
}

fn requests(state: &AppState) -> Result<(), String> {
    discover(state)?;
    let mut queued = vec![];
    for entry in std::fs::read_dir(state.data_dir.join("requests")).map_err(|e| e.to_string())? {
        let path = entry.map_err(|e| e.to_string())?.path();
        if path.extension().and_then(|s| s.to_str()) != Some("json") {
            continue;
        }
        let request: Request =
            serde_json::from_slice(&std::fs::read(&path).map_err(|e| e.to_string())?)
                .map_err(|e| format!("Cannot read saved handoff {}: {e}", path.display()))?;
        if !request.done && request.retry_at <= now() {
            queued.push((path, request));
        }
    }
    queued.sort_by_key(|(_, r)| (r.retry_at, r.created_at));
    if let Some((path, mut request)) = queued.into_iter().next() {
        match process_request(state, &path, &mut request) {
            Ok(done) => {
                request.done = done;
                request.retry_at = now() + 2000;
                request.error.clear();
            }
            Err(error) => {
                request.error = error;
                request.retry_at = now() + 30_000;
            }
        }
        save(&path, &request)?;
    }
    Ok(())
}

fn process_request(state: &AppState, path: &Path, request: &mut Request) -> Result<bool, String> {
    if path.with_extension("cancel").exists() {
        return Ok(true);
    }
    let journal = state
        .data_dir
        .join("runs")
        .join(format!("{}.jsonl", request.thread));
    let current = if journal.exists() {
        Some(richos_core::run::read_snapshot(&journal).map_err(|e| e.to_string())?)
    } else {
        None
    };
    if current
        .as_ref()
        .map(|s| s.id == request.id || s.decision_receipts.contains(&request.id))
        .unwrap_or(false)
    {
        return Ok(true);
    }
    if request.directive.is_none() {
        let mut spine = state.spine.lock().unwrap();
        let binding = spine
            .ledger()
            .thread_binding(&request.thread)
            .map_err(|e| e.to_string())?;
        let current_text = serde_json::to_string(&current).map_err(|e| e.to_string())?;
        request.directive = Some(
            spine
                .register_owned_work(
                    &binding,
                    &request.text,
                    &request.conversation,
                    &current_text,
                )
                .map_err(|e| e.to_string())?,
        );
        drop(spine);
        // Commit Rich's actual decision before attempting any journal mutation.
        save(path, request)?;
    }
    if matches!(request.directive, Some(Handoff::None)) {
        return Ok(true);
    }
    let changes_current = matches!(
        request.directive,
        Some(Handoff::Amend { .. } | Handoff::AnswerDecision | Handoff::Cancel)
    );
    if let Some((thread, pause)) = state.managed_runs.active.lock().unwrap().as_ref() {
        if thread == &request.thread {
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
        .map(|(t, _)| t == &request.thread)
        .unwrap_or(false)
    {
        return Ok(false);
    }
    match request.directive.as_ref().unwrap() {
        Handoff::None => Ok(true),
        Handoff::Work { goal, tasks } | Handoff::Amend { goal, tasks } => {
            let tasks = serde_json::from_value(serde_json::to_value(tasks).unwrap())
                .map_err(|e| e.to_string())?;
            if request.workspace.starts_with(state.data_dir.join("workspaces")) {
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
                if let Some(ref previous) = current {
                    if !matches!(previous.state(), RunState::Completed | RunState::Cancelled) {
                        return Ok(false);
                    }
                    richos_core::run::archive_journal(&journal).map_err(|e| e.to_string())?;
                }
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

fn publish_outcome(state: &AppState, thread: &str, snapshot: &RunSnapshot) -> Result<(), String> {
    let mut notices = vec![];
    for (i, task) in snapshot.tasks.iter().enumerate() {
        if task.state == richos_core::run::TaskState::NeedsDecision {
            notices.push((
                format!(
                    "decision-{}-{}-{i}-{}",
                    snapshot.id, snapshot.plan_revision, task.attempts
                ),
                format!(
                    "A CEO decision is required for this task. {}",
                    task.evidence.join("\n")
                ),
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
        let failures = task.attempts.max(task.review_failures);
        if task.state == richos_core::run::TaskState::Pending && failures >= 5 && failures % 5 == 0
        {
            notices.push((format!("recovery-{}-{}-{i}-{failures}",snapshot.id,snapshot.plan_revision),format!("Work remains owned and unfinished after repeated failures. Diagnose these results, explain the changed approach and any external dependency. No CEO retry approval is needed. Automatic recovery is spaced one hour apart at this checkpoint. Goal: {}\nEvidence: {:?}",snapshot.plan.display_goal(),task.evidence)));
        }
    }
    for (id, evidence) in notices {
        let mut spine = state.spine.lock().unwrap();
        let binding = spine
            .ledger()
            .thread_binding(thread)
            .map_err(|e| e.to_string())?;
        spine
            .report_owned_work(&binding, &id, &evidence)
            .map_err(|e| e.to_string())?;
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
        let path = state.data_dir.join("runs").join(format!("{thread}.jsonl"));
        if !path.exists() {
            continue;
        }
        let pause = Arc::new(AtomicBool::new(path.with_extension("pause").exists()));
        {
            let mut active = state.managed_runs.active.lock().unwrap();
            if active.is_some() {
                return Ok(());
            }
            *active = Some((thread.clone(), pause.clone()));
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
            if ctl.snapshot().tasks.iter().any(|t| {
                t.state == richos_core::run::TaskState::Pending
                    && t.attempts.max(t.review_failures) >= 5
                    && t.attempts.max(t.review_failures) % 5 == 0
            }) {
                ctl.defer_recovery(3600).map_err(|e| e.to_string())?;
            }
            publish_outcome(state, &thread, ctl.snapshot())?;
            Ok(())
        })();
        *state.managed_runs.active.lock().unwrap() = None;
        if let Err(error) = result { eprintln!("Owned execution recovery for {thread}: {error}"); }
    }
    Ok(())
}

pub fn start(app: tauri::AppHandle) {
    let intake_app = app.clone();
    std::thread::spawn(move || loop {
        std::thread::sleep(Duration::from_secs(2));
        let state = intake_app.state::<AppState>();
        if let Err(error) = requests(&state) {
            eprintln!("Owned handoff recovery: {error}");
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
        .filter(|r: &Request| r.thread == thread && !r.done && matches!(r.directive, Some(Handoff::Work {..} | Handoff::Amend {..})))
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
            if mode == "native-handoff" {
                let thread = crate::create_thread_in(app.state(), "fixture".into(), "Native handoff".into())?;
                crate::send_message(app.state(), "Handle this: create hello.txt containing exactly Hello Rich with no trailing newline. Do not create other files.".into())?;
                let deadline=std::time::Instant::now();
                while deadline.elapsed()<Duration::from_secs(240) {
                    let journal=state.data_dir.join("runs").join(format!("{thread}.jsonl"));
                    if let Ok(snapshot)=richos_core::run::read_snapshot(&journal) {
                        if snapshot.state()==RunState::Completed {
                            let spine=state.spine.lock().unwrap();
                            if spine.ledger().turns().iter().any(|t|t.id.starts_with("finished-") && t.thread_id==thread && t.state==TurnState::Completed) {
                                let bytes=std::fs::read(snapshot.plan.workspace.join("hello.txt")).map_err(|e|e.to_string())?;
                                if bytes != b"Hello Rich" { return Err("Native handoff produced incorrect bytes".into()); }
                                return Ok(serde_json::json!({"nativeHandoffCompleted":true,"attempts":snapshot.tasks[0].attempts,"messages":spine.messages(&thread).map_err(|e|e.to_string())?}));
                            }
                        }
                    }
                    std::thread::sleep(Duration::from_millis(200));
                }
                return Err("Native handoff did not complete before the test deadline".into());
            }
            if mode == "correct-live" {
                let thread = crate::create_thread_in(
                    app.state(),
                    "fixture".into(),
                    "Live correction".into(),
                )?;
                crate::send_message(
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
                crate::send_message(app.state(), "How is work going?".into())?;
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
                crate::send_message(app.state(), "Revise the assignment: write revised.txt containing Revised. instead. Do not produce original.txt.".into())?;
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
                crate::send_message(
                    app.state(),
                    "Handle this: produce deliverable.txt containing Finished.".into(),
                )?;
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
