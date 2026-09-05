//! Desktop commands for the shared run controller. The conversation still
//! streams through Spine; run state is a separate durable projection.
use crate::AppState;
use richos_core::run::{read_snapshot, RunController, RunPlan, RunSnapshot, RunState};
use richos_core::run_spine::{SpineRunHost, EVENT_RUN_UPDATED};
use std::path::PathBuf;
use std::sync::{
    atomic::{AtomicBool, Ordering},
    Arc, Mutex,
};
use tauri::{AppHandle, Emitter, State};

#[derive(Default)]
pub struct ManagedRuns {
    selected: Mutex<std::collections::HashMap<String, String>>,
    pub(crate) active: Mutex<Option<(String, PathBuf, Arc<AtomicBool>)>>,
}

impl ManagedRuns {
    pub fn pause_active(&self, _data_dir: &std::path::Path) -> Result<(), String> {
        if let Some((_, path, flag)) = self.active.lock().unwrap().as_ref() {
            let f =
                std::fs::File::create(path.with_extension("pause")).map_err(|e| e.to_string())?;
            f.sync_all().map_err(|e| e.to_string())?;
            flag.store(true, Ordering::SeqCst);
        }
        Ok(())
    }
}

#[derive(Clone, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct RunView {
    thread_id: String,
    run_id: String,
    updated_at: u64,
    created_at: u64,
    revision: u64,
    goal: String,
    autonomous: bool,
    preparing: bool,
    workspace: String,
    max_attempts: u32,
    turn_timeout_seconds: u64,
    state: RunState,
    tasks: Vec<TaskView>,
}

#[derive(Clone, serde::Serialize)]
pub struct TaskView {
    id: String,
    description: String,
    state: richos_core::run::TaskState,
    checks: Vec<String>,
    commands: Vec<Vec<String>>,
    attempts: u32,
    evidence: Vec<String>,
    decision: Option<richos_core::run::RunDecision>,
}

pub(crate) fn view(thread: &str, snapshot: &RunSnapshot) -> RunView {
    RunView {
        thread_id: thread.into(),
        run_id: snapshot.id.clone(),
        updated_at: snapshot.updated_at,
        created_at: snapshot.created_at,
        revision: snapshot.revision,
        goal: snapshot.plan.display_goal().into(),
        autonomous: snapshot.plan.autonomous(),
        preparing: false,
        workspace: snapshot.plan.workspace.display().to_string(),
        max_attempts: snapshot.plan.max_attempts,
        turn_timeout_seconds: snapshot.plan.turn_timeout_seconds,
        state: snapshot.state(),
        tasks: snapshot
            .plan
            .tasks
            .iter()
            .zip(&snapshot.tasks)
            .enumerate()
            .map(|(i, (t, p))| TaskView {
                id: t.id.clone(),
                description: t.prompt.clone(),
                state: p.state.clone(),
                checks: t.checks.iter().map(|c| c.name.clone()).collect(),
                commands: t.checks.iter().map(|c| c.argv.clone()).collect(),
                attempts: p.attempts,
                evidence: p.evidence.clone(),
                decision: snapshot.decision(i),
            })
            .collect(),
    }
}

pub(crate) fn journals(state: &AppState, thread: &str) -> Result<Vec<PathBuf>, String> {
    if thread.is_empty()
        || !thread
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_')
    {
        return Err("Invalid task identity.".into());
    }
    let mut paths = vec![];
    for entry in std::fs::read_dir(state.data_dir.join("runs")).map_err(|e| e.to_string())? {
        let path = entry.map_err(|e| e.to_string())?.path();
        let name = path.file_name().and_then(|n| n.to_str()).unwrap_or("");
        if name == format!("{thread}.jsonl")
            || (name
                .strip_prefix(&format!("{thread}--"))
                .and_then(|n| n.strip_suffix(".jsonl"))
                .map(|id| id.len() == 36 && id.chars().all(|c| c.is_ascii_hexdigit() || c == '-'))
                .unwrap_or(false))
        {
            paths.push(path);
        }
    }
    paths.sort();
    Ok(paths)
}

fn path(state: &AppState, thread: &str) -> Result<PathBuf, String> {
    let selected = state
        .managed_runs
        .selected
        .lock()
        .unwrap()
        .get(thread)
        .cloned();
    let paths = journals(state, thread)?;
    if paths.len() == 1 {
        return Ok(paths[0].clone());
    }
    let mut choices = vec![];
    for path in paths {
        let snapshot = read_snapshot(&path).map_err(|e| e.to_string())?;
        if selected.as_ref() == Some(&snapshot.id) {
            return Ok(path);
        }
        choices.push((snapshot.created_at, path));
    }
    choices.sort();
    Ok(choices
        .pop()
        .map(|(_, p)| p)
        .unwrap_or_else(|| state.data_dir.join("runs").join(format!("{thread}.jsonl"))))
}

fn command_path(state: &AppState, thread: &str, run: Option<&str>) -> Result<PathBuf, String> {
    if let Some(id) = run {
        for p in journals(state, thread)? {
            if read_snapshot(&p).map_err(|e| e.to_string())?.id == id {
                return Ok(p);
            }
        }
        if crate::owned_work::pending(state, thread)
            .map(|p| p.0 == id)
            .unwrap_or(false)
        {
            return Ok(state
                .data_dir
                .join("runs")
                .join(format!("{thread}--{id}.jsonl")));
        }
        return Err("This assignment is no longer available. Refresh the work plan.".into());
    }
    path(state, thread)
}

#[tauri::command(async)]
pub fn list_runs(state: State<AppState>, thread_id: String) -> Result<Vec<RunView>, String> {
    journals(&state, &thread_id)?
        .iter()
        .map(|p| {
            read_snapshot(p)
                .map(|s| view(&thread_id, &s))
                .map_err(|e| e.to_string())
        })
        .collect()
}

#[tauri::command(async)]
pub fn select_run(
    state: State<AppState>,
    thread_id: String,
    run_id: String,
) -> Result<RunView, String> {
    for p in journals(&state, &thread_id)? {
        let s = read_snapshot(&p).map_err(|e| e.to_string())?;
        if s.id == run_id {
            state
                .managed_runs
                .selected
                .lock()
                .unwrap()
                .insert(thread_id.clone(), run_id);
            return Ok(view(&thread_id, &s));
        }
    }
    Err("The selected assignment is unavailable.".into())
}

fn pending_view(state: &AppState, thread_id: &str) -> Option<RunView> {
    crate::owned_work::pending(state, thread_id).map(|(id, goal, error, workspace)| RunView {
        thread_id: thread_id.to_string(),
        run_id: id,
        updated_at: 0,
        created_at: 0,
        revision: 0,
        goal: goal.clone(),
        autonomous: true,
        preparing: true,
        workspace: workspace.display().to_string(),
        max_attempts: 0,
        turn_timeout_seconds: 0,
        state: if state
            .data_dir
            .join("runs")
            .join(format!("{thread_id}.jsonl"))
            .with_extension("pause")
            .exists()
        {
            RunState::Paused
        } else if error.is_empty() {
            RunState::Ready
        } else {
            RunState::Waiting
        },
        tasks: vec![TaskView {
            id: "intake".into(),
            description: "Plan the complete work".into(),
            state: richos_core::run::TaskState::Pending,
            checks: vec![],
            commands: vec![],
            attempts: 0,
            decision: None,
            evidence: if error.is_empty() {
                vec![]
            } else {
                vec![error]
            },
        }],
    })
}

#[tauri::command(async)]
pub fn prepare_run(
    state: State<AppState>,
    thread_id: String,
    plan: RunPlan,
) -> Result<RunView, String> {
    // Single-writer ownership includes preparation, so a second click cannot
    // archive or replace the journal a running controller owns.
    let active = state.managed_runs.active.lock().unwrap();
    if active.is_some() {
        return Err("Pause the current run before preparing another.".into());
    }
    let spine = state.spine.lock().unwrap();
    let binding = spine.active_binding().ok_or("Open a task first.")?;
    if binding.thread_id() != thread_id {
        return Err("The selected task changed. Open it again.".into());
    }
    let entity = spine
        .entity_registry()
        .resolve_root(&plan.workspace)
        .map_err(|e| e.to_string())?;
    if &entity.id != binding.entity_id() {
        return Err("This work plan belongs to another company.".into());
    }
    plan.validate().map_err(|e| e.to_string())?;
    let path = path(&state, &thread_id)?;
    std::fs::create_dir_all(path.parent().unwrap()).map_err(|e| e.to_string())?;
    if path.exists() {
        let previous = RunController::open(&path).map_err(|e| e.to_string())?;
        if !matches!(
            previous.snapshot().state(),
            RunState::Completed | RunState::Canceled
        ) {
            return Err("This task already has unfinished work. Resume its run first.".into());
        }
        let archive =
            path.with_file_name(format!("{}-{}.jsonl", thread_id, previous.snapshot().id));
        drop(previous);
        std::fs::rename(&path, archive).map_err(|e| e.to_string())?;
    }
    let mut ctl = RunController::create(&path, plan).map_err(|e| e.to_string())?;
    ctl.pause(true).map_err(|e| e.to_string())?; // preparing never starts execution
    Ok(view(&thread_id, ctl.snapshot()))
}

#[tauri::command(async)]
pub fn get_run(state: State<AppState>, thread_id: String) -> Result<Option<RunView>, String> {
    let active = state.managed_runs.active.lock().unwrap();
    let spine = state.spine.lock().unwrap();
    let binding = spine.active_binding().ok_or("Open a task first.")?;
    if binding.thread_id() != thread_id {
        return Err("The selected task changed.".into());
    }
    let path = path(&state, &thread_id)?;
    if !path.exists() {
        return Ok(pending_view(&state, &thread_id));
    }
    if active.is_none() {
        let mut ctl = RunController::open(&path).map_err(|e| e.to_string())?;
        if path.with_extension("pause").exists() {
            ctl.pause(true).map_err(|e| e.to_string())?;
        }
        if matches!(
            ctl.snapshot().state(),
            RunState::Completed | RunState::Canceled
        ) {
            if let Some(pending) = pending_view(&state, &thread_id) {
                return Ok(Some(pending));
            }
        }
        return Ok(Some(view(&thread_id, ctl.snapshot())));
    }
    let snapshot = read_snapshot(&path).map_err(|e| e.to_string())?;
    if matches!(snapshot.state(), RunState::Completed | RunState::Canceled) {
        if let Some(pending) = pending_view(&state, &thread_id) {
            return Ok(Some(pending));
        }
    }
    Ok(Some(view(&thread_id, &snapshot)))
}

#[tauri::command(async)]
pub fn drive_run(
    app: AppHandle,
    state: State<AppState>,
    thread_id: String,
    run_id: Option<String>,
) -> Result<RunView, String> {
    let pause = Arc::new(AtomicBool::new(false));
    {
        let mut active = state.managed_runs.active.lock().unwrap();
        if active.is_some() {
            return Err("A run is already active.".into());
        }
        *active = Some((
            thread_id.clone(),
            command_path(&state, &thread_id, run_id.as_deref())?,
            pause.clone(),
        ));
    }
    let result = (|| {
        let path = command_path(&state, &thread_id, run_id.as_deref())?;
        if !path.exists() {
            if let Some(mut pending) = pending_view(&state, &thread_id) {
                if path.with_extension("pause").exists() {
                    std::fs::remove_file(path.with_extension("pause"))
                        .map_err(|e| e.to_string())?;
                }
                pending.state = RunState::Ready;
                return Ok(pending);
            }
        }
        let mut ctl = RunController::open(&path).map_err(|e| e.to_string())?;
        let binding = {
            let spine = state.spine.lock().unwrap();
            let b = spine.active_binding().ok_or("Open a task first.")?.clone();
            if b.thread_id() != thread_id {
                return Err("The selected task changed.".into());
            }
            b
        };
        if path.with_extension("pause").exists() {
            std::fs::remove_file(path.with_extension("pause")).map_err(|e| e.to_string())?;
        }
        ctl.pause(false).map_err(|e| e.to_string())?;
        if ctl.snapshot().plan.autonomous() {
            return Ok(view(&thread_id, ctl.snapshot()));
        }
        while ctl.snapshot().state() == RunState::Ready {
            let mut spine = state.spine.lock().unwrap();
            ctl.snapshot().plan.validate().map_err(|e| e.to_string())?;
            let worker = richos_core::native::NativeCognition::start_managed(
                &richos_core::native::resolve_claude_bin(),
                &ctl.snapshot().plan.workspace,
            )
            .map_err(|e| e.to_string())?;
            let mut host = SpineRunHost {
                worker: Some(Box::new(worker)),
                spine: &mut spine,
                binding: binding.clone(),
                pause: pause.clone(),
                on_update: Some(Box::new(|snapshot| {
                    let _ = app.emit(EVENT_RUN_UPDATED, view(&thread_id, snapshot));
                })),
            };
            ctl.tick(&mut host).map_err(|e| e.to_string())?;
            drop(host);
            drop(spine);
            if path.with_extension("cancel").exists() {
                ctl.cancel().map_err(|e| e.to_string())?;
            }
        }
        Ok(view(&thread_id, ctl.snapshot()))
    })();
    *state.managed_runs.active.lock().unwrap() = None;
    result
}

#[tauri::command(async)]
pub fn retry_run_task(
    state: State<AppState>,
    thread_id: String,
    run_id: Option<String>,
    task_id: String,
) -> Result<RunView, String> {
    let active = state.managed_runs.active.lock().unwrap();
    if active.is_some() {
        return Err("Pause the run before retrying a task.".into());
    }
    let spine = state.spine.lock().unwrap();
    if spine.active_binding().map(|b| b.thread_id()) != Some(thread_id.as_str()) {
        return Err("Open this task before retrying its work.".into());
    }
    let mut ctl = RunController::open(&command_path(&state, &thread_id, run_id.as_deref())?)
        .map_err(|e| e.to_string())?;
    ctl.retry(&task_id).map_err(|e| e.to_string())?;
    Ok(view(&thread_id, ctl.snapshot()))
}

#[tauri::command(async)]
pub fn end_run(
    state: State<AppState>,
    thread_id: String,
    run_id: Option<String>,
) -> Result<RunView, String> {
    let active = state.managed_runs.active.lock().unwrap();
    let journal = command_path(&state, &thread_id, run_id.as_deref())?;
    if let Some((_, active_path, flag)) = active.as_ref() {
        if active_path == &journal {
            let file = std::fs::File::create(journal.with_extension("cancel"))
                .map_err(|e| e.to_string())?;
            file.sync_all().map_err(|e| e.to_string())?;
            flag.store(true, Ordering::SeqCst);
            let mut snapshot = read_snapshot(&journal).map_err(|e| e.to_string())?;
            snapshot.canceled = true;
            return Ok(view(&thread_id, &snapshot));
        }
    }
    let spine = state.spine.lock().unwrap();
    if spine.active_binding().map(|b| b.thread_id()) != Some(thread_id.as_str()) {
        return Err("The selected task changed.".into());
    }
    if !journal.exists() {
        let mut pending = pending_view(&state, &thread_id).ok_or("There is no work to end.")?;
        crate::owned_work::cancel_pending(&state, &thread_id)?;
        pending.state = RunState::Canceled;
        pending.preparing = false;
        return Ok(pending);
    }
    let mut ctl = RunController::open(&journal).map_err(|e| e.to_string())?;
    ctl.cancel().map_err(|e| e.to_string())?;
    if journal.with_extension("pause").exists() {
        std::fs::remove_file(journal.with_extension("pause")).map_err(|e| e.to_string())?;
    }
    Ok(view(&thread_id, ctl.snapshot()))
}

#[tauri::command(async)]
pub fn pause_run(
    state: State<AppState>,
    thread_id: String,
    run_id: Option<String>,
) -> Result<(), String> {
    let active = state.managed_runs.active.lock().unwrap();
    if let Some((id, active_path, flag)) = active.as_ref() {
        if id != &thread_id || *active_path != command_path(&state, &thread_id, run_id.as_deref())?
        {
            return Err("A different task is running.".into());
        }
        // Persist intent outside the busy spine lock before canceling.
        let pause_path =
            command_path(&state, &thread_id, run_id.as_deref())?.with_extension("pause");
        let f = std::fs::File::create(pause_path).map_err(|e| e.to_string())?;
        f.sync_all().map_err(|e| e.to_string())?;
        flag.store(true, Ordering::SeqCst);
        return Ok(());
    }
    let journal = command_path(&state, &thread_id, run_id.as_deref())?;
    if !journal.exists() && crate::owned_work::pending(&state, &thread_id).is_some() {
        let f =
            std::fs::File::create(journal.with_extension("pause")).map_err(|e| e.to_string())?;
        return f.sync_all().map_err(|e| e.to_string());
    }
    RunController::open(&journal)
        .map_err(|e| e.to_string())?
        .pause(true)
        .map_err(|e| e.to_string())
}

#[tauri::command(async)]
pub fn archive_run(state: State<AppState>, thread_id: String) -> Result<(), String> {
    let active = state.managed_runs.active.lock().unwrap();
    if active.is_some() {
        return Err("Pause the run before archiving its journal.".into());
    }
    let spine = state.spine.lock().unwrap();
    if spine.active_binding().map(|b| b.thread_id()) != Some(thread_id.as_str()) {
        return Err("The selected task changed.".into());
    }
    richos_core::run::archive_journal(&path(&state, &thread_id)?).map_err(|e| e.to_string())?;
    Ok(())
}

/// Explicit, journaled CEO actions, fenced to the displayed assignment and question.
#[tauri::command(async)]
pub fn respond_run_decision(
    app: AppHandle,
    state: State<AppState>,
    thread_id: String,
    run_id: String,
    task_id: String,
    decision_id: String,
    action: richos_core::run::DecisionAction,
) -> Result<RunView, String> {
    {
        let spine = state.spine.lock().unwrap();
        if spine.active_binding().map(|b| b.thread_id()) != Some(thread_id.as_str()) {
            return Err("The selected task changed.".into());
        }
    }
    let journal = command_path(&state, &thread_id, Some(&run_id))?;
    // A pending decision can coexist with another task in the same assignment.
    // Interrupt that writer and apply at its boundary rather than asking the CEO
    // to repeat an answer while Rich is speaking or finishing a worker turn.
    let deadline = std::time::Instant::now();
    let _active = loop {
        let active = state.managed_runs.active.lock().unwrap();
        match active.as_ref() {
            Some((_, p, pause)) if p == &journal => pause.store(true, Ordering::SeqCst),
            _ => break active,
        }
        drop(active);
        if deadline.elapsed() >= std::time::Duration::from_secs(30) {
            return Err("This assignment is updating. Refresh and answer again.".into());
        }
        std::thread::sleep(std::time::Duration::from_millis(50));
    };
    let spine = state.spine.lock().unwrap();
    if spine.active_binding().map(|b| b.thread_id()) != Some(thread_id.as_str()) {
        return Err("The selected task changed.".into());
    }
    let mut ctl = RunController::open(&journal).map_err(|e| e.to_string())?;
    ctl.respond_to_decision(&task_id, &decision_id, action).map_err(|e| e.to_string())?;
    if journal.with_extension("pause").exists() {
        std::fs::remove_file(journal.with_extension("pause")).map_err(|e| e.to_string())?;
    }
    let result = view(&thread_id, ctl.snapshot());
    let _ = app.emit(EVENT_RUN_UPDATED, &result);
    Ok(result)
}
