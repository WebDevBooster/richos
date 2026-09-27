//! The declared engine owns both the predicate and witness algorithm.
use crate::questions::{AskScope, Question, QuestionInput};
use serde_json::{json, Value};
use std::{
    io::{Read, Write},
    process::{Command, Stdio},
    time::{Duration, Instant},
};

fn invoke(scope: &AskScope, hook: &str, input: Value, budget: Duration) -> Result<String, String> {
    let (engine, root) = match (&scope.engine, &scope.entity_root) {
        (None, None) => return Ok(String::new()),
        (Some(engine), Some(root)) => (engine, root),
        _ => return Err("The declared question engine has no complete entity scope.".into()),
    };
    let path = engine.join("scripts/hooks").join(hook);
    if !path.is_file() {
        return Err("The declared engine's question guard is unavailable.".into());
    }
    let mut command = Command::new("bash");
    command
        .arg(path)
        .current_dir(root)
        .env("CLAUDE_PLUGIN_ROOT", engine)
        .env("RICHOS_ENTITY_ROOT", root)
        .env("CLAUDE_PROJECT_DIR", root)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    crate::owned_process::OwnedChild::configure(&mut command);
    let mut child = command.spawn().map_err(|e| e.to_string())?;
    let mut stdin = child
        .stdin
        .take()
        .ok_or("The question guard has no input channel.")?;
    let stdout = child.stdout.take().unwrap();
    let stderr = child.stderr.take().unwrap();
    let read = |pipe: Box<dyn Read + Send>| {
        std::thread::spawn(move || {
            let mut text = String::new();
            let _ = pipe.take(65536).read_to_string(&mut text);
            text
        })
    };
    let out = read(Box::new(stdout));
    let err = read(Box::new(stderr));
    let mut child = crate::owned_process::OwnedChild::new(child);
    let deadline = Instant::now() + budget;
    // A broken hook may never read stdin. Bound that case too, including a set
    // larger than the OS pipe buffer, instead of blocking before the timer starts.
    let write = std::thread::spawn(move || stdin.write_all(input.to_string().as_bytes()));
    let status = loop {
        if let Some(status) = child.try_wait().map_err(|e| e.to_string())? {
            break Some(status);
        }
        if Instant::now() >= deadline {
            let _ = child.kill();
            let _ = child.wait();
            break None;
        }
        std::thread::sleep(Duration::from_millis(5));
    };
    let out = out.join().unwrap_or_default();
    let err = err.join().unwrap_or_default();
    let _ = write.join();
    match status {
        Some(s) if s.success() => Ok(out),
        Some(_) => Err(if err.trim().is_empty() { out } else { err }),
        None => Err("The question guard did not finish in time. Nothing was shown.".into()),
    }
}
pub fn check(
    scope: &AskScope,
    questions: &[QuestionInput],
    budget: Duration,
) -> Result<(), String> {
    let questions: Vec<_> = questions
        .iter()
        .map(|q| json!({"question":q.text,"options":q.options,"multiSelect":q.multiple}))
        .collect();
    let output = invoke(
        scope,
        "guard-ceo-ruled-ask.sh",
        json!({"hook_event_name":"PreToolUse","tool_name":"AskUserQuestion","session_id":scope.session_id,"cwd":scope.entity_root,"tool_input":{"questions":questions}}),
        budget,
    )?;
    // A broken declared guard may report a systemMessage with exit 0. Do not mistake
    // that degraded result for a verified pass on the app-owned question path.
    if output.lines().any(|line| {
        serde_json::from_str::<Value>(line)
            .ok()
            .is_some_and(|v| v.get("systemMessage").is_some())
    }) {
        return Err(output);
    }
    Ok(())
}
pub fn witness(scope: &AskScope, q: &Question) -> Result<(), String> {
    if scope.engine.is_none() && scope.entity_root.is_none() {
        return Ok(());
    }
    invoke(scope,"notice-ceo-asks.sh",json!({"hook_event_name":"PostToolUse","tool_name":"AskUserQuestion","session_id":scope.session_id,"cwd":scope.entity_root,"app_question_id":q.id,"tool_input":{"questions":[{"question":q.text,"options":q.options,"multiSelect":q.multiple}]}}),Duration::from_secs(5)).and_then(|output| {
        if output.lines().any(|line|serde_json::from_str::<Value>(line).ok().is_some_and(|v|v["app_question_id"]==q.id && (v["witness"]=="written" || v["witness"]=="not_applicable"))) {Ok(())} else {Err("The engine did not confirm this question’s display witness.".into())}
    })
}
