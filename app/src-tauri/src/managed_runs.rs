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
    active: Mutex<Option<(String, Arc<AtomicBool>)>>,
}

impl ManagedRuns {
    pub fn pause_active(&self, data_dir: &std::path::Path) -> Result<(), String> {
        if let Some((id, flag)) = self.active.lock().unwrap().as_ref() {
            let f = std::fs::File::create(data_dir.join("runs").join(format!("{id}.pause")))
                .map_err(|e| e.to_string())?;
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
    revision: u64,
    goal: String,
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
}

fn view(thread: &str, snapshot: &RunSnapshot) -> RunView {
    RunView {
        thread_id: thread.into(),
        run_id: snapshot.id.clone(),
        updated_at: snapshot.updated_at,
        revision: snapshot.revision,
        goal: snapshot.plan.goal.clone(),
        workspace: snapshot.plan.workspace.display().to_string(),
        max_attempts: snapshot.plan.max_attempts,
        turn_timeout_seconds: snapshot.plan.turn_timeout_seconds,
        state: snapshot.state(),
        tasks: snapshot
            .plan
            .tasks
            .iter()
            .zip(&snapshot.tasks)
            .map(|(t, p)| TaskView {
                id: t.id.clone(),
                description: t.prompt.clone(),
                state: p.state.clone(),
                checks: t.checks.iter().map(|c| c.name.clone()).collect(),
                commands: t.checks.iter().map(|c| c.argv.clone()).collect(),
                attempts: p.attempts,
                evidence: p.evidence.clone(),
            })
            .collect(),
    }
}

fn path(state: &AppState, thread: &str) -> Result<PathBuf, String> {
    if thread.is_empty()
        || !thread
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_')
    {
        return Err("Invalid task identity.".into());
    }
    Ok(state.data_dir.join("runs").join(format!("{thread}.jsonl")))
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
            RunState::Completed | RunState::Cancelled
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
        return Ok(None);
    }
    if active.is_none() {
        let mut ctl = RunController::open(&path).map_err(|e| e.to_string())?;
        if path.with_extension("pause").exists() {
            ctl.pause(true).map_err(|e| e.to_string())?;
        }
        return Ok(Some(view(&thread_id, ctl.snapshot())));
    }
    Ok(Some(view(
        &thread_id,
        &read_snapshot(&path).map_err(|e| e.to_string())?,
    )))
}

#[tauri::command(async)]
pub fn drive_run(
    app: AppHandle,
    state: State<AppState>,
    thread_id: String,
) -> Result<RunView, String> {
    let pause = Arc::new(AtomicBool::new(false));
    {
        let mut active = state.managed_runs.active.lock().unwrap();
        if active.is_some() {
            return Err("A run is already active.".into());
        }
        *active = Some((thread_id.clone(), pause.clone()));
    }
    let result = (|| {
        let path = path(&state, &thread_id)?;
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
    let mut ctl = RunController::open(&path(&state, &thread_id)?).map_err(|e| e.to_string())?;
    ctl.retry(&task_id).map_err(|e| e.to_string())?;
    Ok(view(&thread_id, ctl.snapshot()))
}

#[tauri::command(async)]
pub fn end_run(state: State<AppState>, thread_id: String) -> Result<RunView, String> {
    let active = state.managed_runs.active.lock().unwrap();
    if active.is_some() {
        return Err("Pause the run before ending it.".into());
    }
    let spine = state.spine.lock().unwrap();
    if spine.active_binding().map(|b| b.thread_id()) != Some(thread_id.as_str()) {
        return Err("The selected task changed.".into());
    }
    let mut ctl = RunController::open(&path(&state, &thread_id)?).map_err(|e| e.to_string())?;
    ctl.cancel().map_err(|e| e.to_string())?;
    Ok(view(&thread_id, ctl.snapshot()))
}

#[tauri::command(async)]
pub fn pause_run(state: State<AppState>, thread_id: String) -> Result<(), String> {
    let active = state.managed_runs.active.lock().unwrap();
    if let Some((id, flag)) = active.as_ref() {
        if id != &thread_id {
            return Err("A different task is running.".into());
        }
        // Persist intent outside the busy spine lock before cancelling.
        let pause_path = path(&state, &thread_id)?.with_extension("pause");
        let f = std::fs::File::create(pause_path).map_err(|e| e.to_string())?;
        f.sync_all().map_err(|e| e.to_string())?;
        flag.store(true, Ordering::SeqCst);
        return Ok(());
    }
    drop(active);
    RunController::open(&path(&state, &thread_id)?)
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
