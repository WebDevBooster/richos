//! The desktop owns accepted requests independently of model turns and the
//! selected conversation. One scheduler services durable company-scoped jobs.
use crate::AppState;
use richos_core::{
    autonomy,
    entity::EntityRegistry,
    run::{RunController, RunState},
    run_spine::{SpineRunHost, EVENT_RUN_UPDATED},
};
use serde::{Deserialize, Serialize};
use std::{
    path::{Path, PathBuf},
    sync::{atomic::AtomicBool, Arc},
    time::Duration,
};
use tauri::{Emitter, Manager};

#[derive(Serialize, Deserialize, Clone)]
struct Request {
    id: String,
    #[serde(default)]
    source_turn: Option<String>,
    thread: String,
    workspace: PathBuf,
    text: String,
    conversation: String,
    done: bool,
    #[serde(default)]
    classified_work: bool,
    retry_at: u64,
    #[serde(default)]
    created_at: u64,
    error: String,
}
fn now() -> u64 {
    richos_core::util::now_millis()
}
fn save(path: &Path, request: &Request) -> Result<(), String> {
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
    file.write_all(&serde_json::to_vec(request).map_err(|e| e.to_string())?)
        .map_err(|e| e.to_string())?;
    file.sync_all().map_err(|e| e.to_string())?;
    std::fs::rename(temporary, path).map_err(|e| e.to_string())?;
    std::fs::File::open(path.parent().unwrap())
        .and_then(|f| f.sync_all())
        .map_err(|e| e.to_string())
}

pub fn enqueue(state: &AppState, thread: &str, text: &str) -> Result<(), String> {
    enqueue_from(state, thread, text, None)
}

fn enqueue_from(
    state: &AppState,
    thread: &str,
    text: &str,
    source_turn: Option<String>,
) -> Result<(), String> {
    // Registry then spine is the app's established lock order. A company with
    // no project folder gets its own app-owned workspace without a file picker.
    let mut registry = state.registry.lock().unwrap();
    let mut spine = state.spine.lock().unwrap();
    let binding = spine
        .ledger()
        .thread_binding(thread)
        .map_err(|e| e.to_string())?;
    let entity = registry
        .get(binding.entity_id())
        .ok_or("The company is unavailable")?;
    let workspace = if let Some(root) = entity.roots.first() {
        root.clone()
    } else {
        let workspace = state.data_dir.join("workspaces").join(entity.id.as_str());
        std::fs::create_dir_all(&workspace).map_err(|e| e.to_string())?;
        let mut entities = registry.entities().to_vec();
        entities
            .iter_mut()
            .find(|e| &e.id == binding.entity_id())
            .unwrap()
            .roots
            .push(workspace.clone());
        let updated = EntityRegistry::new(entities).map_err(|e| e.to_string())?;
        updated
            .save(&state.registry_path)
            .map_err(|e| e.to_string())?;
        spine.set_entity_registry(updated.clone());
        *registry = updated;
        workspace
    };
    let conversation = spine
        .messages(thread)
        .map_err(|e| e.to_string())?
        .into_iter()
        .map(|m| format!("{}: {}", m.role, m.text))
        .collect::<Vec<_>>()
        .join("\n");
    let directory = state.data_dir.join("requests");
    std::fs::create_dir_all(&directory).map_err(|e| e.to_string())?;
    if let Some(ref turn) = source_turn {
        // The source turn is globally unique. Find an already committed transfer
        // after a crash between writing the spool and acknowledging the turn.
        for entry in std::fs::read_dir(&directory)
            .map_err(|e| e.to_string())?
            .flatten()
        {
            if let Ok(bytes) = std::fs::read(entry.path()) {
                if let Ok(existing) = serde_json::from_slice::<Request>(&bytes) {
                    if existing.source_turn.as_ref() == Some(turn) {
                        return spine
                            .record_owned_message(&binding, turn, Some(text), "")
                            .map_err(|e| e.to_string());
                    }
                }
            }
        }
    }
    let request = Request {
        id: autonomy::request_id(),
        source_turn,
        thread: thread.into(),
        workspace,
        text: text.into(),
        conversation,
        done: false,
        classified_work: false,
        retry_at: 0,
        created_at: now(),
        error: String::new(),
    };
    std::fs::create_dir_all(state.data_dir.join("runs")).map_err(|e| e.to_string())?;
    save(&directory.join(format!("{}.json", request.id)), &request)?;
    spine
        .record_owned_message(
            &binding,
            &request
                .source_turn
                .clone()
                .unwrap_or_else(|| format!("request-{}", request.id)),
            Some(text),
            "",
        )
        .map_err(|e| e.to_string())
}

fn requests(state: &AppState, pause: &AtomicBool) {
    let Ok(entries) = std::fs::read_dir(state.data_dir.join("requests")) else {
        return;
    };
    let mut queued: Vec<_> = entries
        .flatten()
        .map(|e| e.path())
        .filter(|p| p.extension().and_then(|s| s.to_str()) == Some("json"))
        .filter_map(|path| {
            let bytes = std::fs::read(&path).ok()?;
            let request = serde_json::from_slice::<Request>(&bytes).ok()?;
            Some((path, request))
        })
        .collect();
    // Deferred intake must not monopolize every pass. In particular a later
    // CEO answer must be able to unblock the job that an earlier request awaits.
    queued.sort_by_key(|(_, r)| (r.retry_at, r.created_at));
    for (path, mut request) in queued {
        if request.done
            || request.retry_at > now()
            || state
                .data_dir
                .join("runs")
                .join(format!("{}.pause", request.thread))
                .exists()
        {
            continue;
        }
        if let Some((thread, _)) = state.managed_runs.active.lock().unwrap().as_mut() {
            *thread = request.thread.clone();
        }
        let result = process_request(state, &mut request, pause);
        match result {
            Ok(true) => request.done = true,
            Ok(false) => request.retry_at = now() + 2000,
            Err(error) => {
                request.error = error;
                request.retry_at = now() + 30_000;
            }
        }
        if let Err(error) = save(&path, &request) {
            eprintln!("Could not persist request state: {error}");
        }
        // Bound each intake pass so existing jobs cannot starve behind messages.
        break;
    }
}

fn process_request(
    state: &AppState,
    request: &mut Request,
    pause: &AtomicBool,
) -> Result<bool, String> {
    if state
        .data_dir
        .join("requests")
        .join(format!("{}.cancel", request.id))
        .exists()
    {
        return Ok(true);
    }
    let journal = state
        .data_dir
        .join("runs")
        .join(format!("{}.jsonl", request.thread));
    if journal.exists() {
        let previous = RunController::open(&journal).map_err(|e| e.to_string())?;
        if previous.snapshot().id == request.id
            || previous.snapshot().decision_receipts.contains(&request.id)
        {
            return Ok(true);
        }
        if previous
            .snapshot()
            .tasks
            .iter()
            .any(|t| t.state == richos_core::run::TaskState::NeedsDecision)
        {
            #[derive(Deserialize)]
            #[serde(deny_unknown_fields)]
            struct Answer {
                answers_decision: bool,
            }
            let question = previous
                .snapshot()
                .tasks
                .iter()
                .flat_map(|t| t.evidence.iter())
                .cloned()
                .collect::<Vec<_>>()
                .join("\n");
            let prompt = format!("Does the following CEO message actually answer the pending business decision? Questions about status, general agreement and unrelated requests are not authorization. Return only {{\"answers_decision\":true}} or {{\"answers_decision\":false}}.\nPending decision: {question}\nCEO message: {}", request.text);
            let answer: Answer =
                autonomy::parse(&autonomy::inspect(&request.workspace, &prompt, pause, 180)?)?;
            if answer.answers_decision {
                drop(previous);
                RunController::open(&journal)
                    .map_err(|e| e.to_string())?
                    .answer_decision(&request.id, &request.text)
                    .map_err(|e| e.to_string())?;
                return Ok(true);
            }
        }
        if !matches!(
            previous.snapshot().state(),
            RunState::Completed | RunState::Cancelled
        ) {
            if request.classified_work {
                return Ok(false);
            }
            let result = autonomy::intake(
                &request.workspace,
                &request.text,
                &format!(
                    "{}\nOwned work state: {:?}\nEvidence: {:?}",
                    request.conversation,
                    previous.snapshot().state(),
                    previous.snapshot().tasks
                ),
                pause,
            )?;
            if let autonomy::Intake::Reply { text } = result {
                let mut spine = state.spine.lock().unwrap();
                let binding = spine
                    .ledger()
                    .thread_binding(&request.thread)
                    .map_err(|e| e.to_string())?;
                spine
                    .record_owned_message(&binding, &format!("reply-{}", request.id), None, &text)
                    .map_err(|e| e.to_string())?;
                return Ok(true);
            }
            request.classified_work = true;
            return Ok(false);
        }
    }
    {
        let mut spine = state.spine.lock().unwrap();
        let binding = spine
            .ledger()
            .thread_binding(&request.thread)
            .map_err(|e| e.to_string())?;
        spine
            .record_owned_message(
                &binding,
                &request
                    .source_turn
                    .clone()
                    .unwrap_or_else(|| format!("request-{}", request.id)),
                Some(&request.text),
                "",
            )
            .map_err(|e| e.to_string())?;
    }
    match autonomy::intake(
        &request.workspace,
        &request.text,
        &request.conversation,
        pause,
    )? {
        autonomy::Intake::Reply { text } => {
            if text.trim().is_empty() {
                return Err("Intake returned an empty answer".into());
            }
            let mut spine = state.spine.lock().unwrap();
            let binding = spine
                .ledger()
                .thread_binding(&request.thread)
                .map_err(|e| e.to_string())?;
            spine
                .record_owned_message(&binding, &format!("reply-{}", request.id), None, &text)
                .map_err(|e| e.to_string())?;
        }
        autonomy::Intake::Work { goal, tasks } => {
            if state
                .data_dir
                .join("requests")
                .join(format!("{}.cancel", request.id))
                .exists()
            {
                return Ok(true);
            }
            let plan = autonomy::plan(&request.workspace, &request.text, &goal, tasks)?;
            std::fs::create_dir_all(journal.parent().unwrap()).map_err(|e| e.to_string())?;
            if journal.exists() {
                richos_core::run::archive_journal(&journal).map_err(|e| e.to_string())?;
            }
            RunController::create_named(&journal, plan, request.id.clone())
                .map_err(|e| e.to_string())?;
        }
    }
    Ok(true)
}

fn publish_outcome(
    spine: &mut richos_core::Spine,
    thread: &str,
    snapshot: &richos_core::run::RunSnapshot,
) -> Result<(), String> {
    let binding = spine
        .ledger()
        .thread_binding(thread)
        .map_err(|e| e.to_string())?;
    for (index, task) in snapshot.tasks.iter().enumerate() {
        if task.state == richos_core::run::TaskState::NeedsDecision {
            for evidence in &task.evidence {
                if let Some((_, encoded)) = evidence.split_once(autonomy::DECISION) {
                    if let Ok(autonomy::Review::Decision {
                        question,
                        why_ceo,
                        recommendation,
                        options,
                    }) = autonomy::parse(encoded)
                    {
                        spine.record_owned_message(&binding, &format!("decision-{}-{index}-{}", snapshot.id, task.attempts), None,
                                    &format!("{question}\n\n{why_ceo}\n\nMy recommendation: {recommendation}\n\nOptions: {}", options.join("; "))).map_err(|e| e.to_string())?;
                    }
                }
            }
        }
    }
    if snapshot.state() == RunState::Completed {
        spine
            .record_owned_message(
                &binding,
                &format!("finished-{}", snapshot.id),
                None,
                &format!("Finished and checked: {}", snapshot.plan.display_goal()),
            )
            .map_err(|e| e.to_string())?;
    }
    Ok(())
}

fn jobs(app: &tauri::AppHandle, state: &AppState) {
    let Ok(entries) = std::fs::read_dir(state.data_dir.join("runs")) else {
        return;
    };
    // The request UUID is in the snapshot. Only the current per-thread path is
    // runnable; archived snapshots are never interpreted as another job.
    let threads: Vec<_> = state
        .spine
        .lock()
        .unwrap()
        .threads()
        .into_iter()
        .map(|t| t.id)
        .collect();
    let paths: Vec<_> = entries
        .flatten()
        .map(|e| e.path())
        .filter(|p| {
            p.file_stem()
                .and_then(|s| s.to_str())
                .map(|id| threads.iter().any(|t| t == id))
                .unwrap_or(false)
                && p.extension().and_then(|s| s.to_str()) == Some("jsonl")
        })
        .collect();
    for path in paths {
        let thread = path.file_stem().unwrap().to_string_lossy().to_string();
        let pause = Arc::new(AtomicBool::new(path.with_extension("pause").exists()));
        {
            let mut active = state.managed_runs.active.lock().unwrap();
            if active.is_some() {
                return;
            }
            *active = Some((thread.clone(), pause.clone()));
        }
        let result = (|| -> Result<(), String> {
            let mut controller = RunController::open(&path).map_err(|e| e.to_string())?;
            if !controller.snapshot().plan.autonomous() {
                return Ok(());
            }
            if state
                .data_dir
                .join("requests")
                .join(format!("{}.cancel", controller.snapshot().id))
                .exists()
            {
                controller.cancel().map_err(|e| e.to_string())?;
            }
            if path.with_extension("pause").exists() {
                controller.pause(true).map_err(|e| e.to_string())?;
            }
            let mut spine = state.spine.lock().unwrap();
            publish_outcome(&mut spine, &thread, controller.snapshot())?;
            if controller.snapshot().state() != RunState::Ready {
                return Ok(());
            }
            let binding = spine
                .ledger()
                .thread_binding(&thread)
                .map_err(|e| e.to_string())?;
            let mut host = SpineRunHost {
                spine: &mut spine,
                binding: binding.clone(),
                worker: None,
                pause,
                on_update: Some(Box::new(|snapshot| {
                    let _ = app.emit(
                        EVENT_RUN_UPDATED,
                        crate::managed_runs::view(&thread, snapshot),
                    );
                })),
            };
            controller.tick(&mut host).map_err(|e| e.to_string())?;
            drop(host);
            publish_outcome(&mut spine, &thread, controller.snapshot())?;
            Ok(())
        })();
        *state.managed_runs.active.lock().unwrap() = None;
        if let Err(error) = result {
            eprintln!("Owned work {thread} remains unfinished: {error}");
        }
    }
}

pub fn start(app: tauri::AppHandle) {
    std::thread::spawn(move || loop {
        std::thread::sleep(Duration::from_secs(2));
        let state = app.state::<AppState>();
        // Claim the same execution slot used by manual plans. Intake and jobs
        // cannot race a second driver or replace a journal under its writer.
        let pause = Arc::new(AtomicBool::new(false));
        {
            let mut active = state.managed_runs.active.lock().unwrap();
            if active.is_some() {
                continue;
            }
            *active = Some(("intake".into(), pause.clone()));
        }
        let pending = state.spine.lock().unwrap().pending_owned_intake();
        if let Ok(pending) = pending {
            for (turn, thread, text) in pending {
                if let Err(error) = enqueue_from(&state, &thread, &text, Some(turn)) {
                    eprintln!("Steering remains queued: {error}");
                    break;
                }
            }
        }
        requests(&state, &pause);
        *state.managed_runs.active.lock().unwrap() = None;
        jobs(&app, &state);
    });
}

pub fn pending(state: &AppState, thread: &str) -> Option<(String, String, String, PathBuf)> {
    let entries = std::fs::read_dir(state.data_dir.join("requests")).ok()?;
    let mut requests: Vec<Request> = entries
        .flatten()
        .filter_map(|e| std::fs::read(e.path()).ok())
        .filter_map(|b| serde_json::from_slice(&b).ok())
        .filter(|r: &Request| r.thread == thread && !r.done)
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
            if mode == "enqueue" {
                let thread =
                    crate::create_thread_in(app.state(), "fixture".into(), "Handle this".into())?;
                crate::send_message(
                    app.state(),
                    "Handle this: produce deliverable.txt containing Finished.".into(),
                )?;
                return Ok(
                    serde_json::json!({"phase":"accepted","thread":thread,"requestPersisted":pending(&state, &thread).is_some()}),
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
