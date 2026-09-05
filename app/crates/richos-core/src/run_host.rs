//! Concrete adapters for the portable run controller.
use crate::cognition::{Cognition, TurnItem};
use crate::run::{Check, RunHost, RunPlan, TaskSpec};
use std::path::Path;
use std::process::{Command, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{mpsc, Arc};
use std::time::{Duration, Instant};

/// A model lease plus independently executed acceptance checks. Hosts may
/// replace either half by implementing RunHost directly.
pub struct CognitionRunHost<'a> {
    pub cognition: &'a mut dyn Cognition,
    pub on_item: &'a mut dyn FnMut(TurnItem),
    pub pause: Arc<AtomicBool>,
}

pub fn task_prompt(plan: &RunPlan, task: &TaskSpec, previous: &[String]) -> String {
    format!("Work on this task within the authorized run.\nGoal: {}\nTask {}: {}\nWorkspace: {}\nAcceptance checks (executed by the host after you return):\n{}\nPrevious attempt evidence:\n{}\nA turn ending does not finish the task. Complete the requested work. Do not weaken acceptance checks, change the run journal or expand the authorized scope. Make routine decisions yourself. Inspect existing effects before acting, especially after interruption. Continue until every deliverable is complete. Only a material business tradeoff or missing authority may require a CEO decision. Explain that decision with options and a recommendation. Missing tools, tests and implementation choices are your work to resolve. Record concrete result evidence in the workspace for independent review. Report progress without asking the CEO to review routine assumptions. Do not claim the overall job is finished; the host will report that after independent verification.\n",
        plan.goal, task.id, task.prompt, plan.workspace.display(),
        task.checks.iter().map(|c| format!("{}: {:?}", c.name, c.argv)).collect::<Vec<_>>().join("\n"),
        previous.join("\n"))
}

impl RunHost for CognitionRunHost<'_> {
    fn execute(
        &mut self,
        plan: &RunPlan,
        task: &TaskSpec,
        previous: &[String],
    ) -> Result<(), String> {
        self.cognition
            .prepare_managed(&plan.workspace)
            .map_err(|e| e.to_string())?;
        let cancel = self
            .cognition
            .cancel_handle()
            .ok_or("This model adapter cannot enforce the run's timeout or pause control.")?;
        let pause = self.pause.clone();
        let expired = Arc::new(AtomicBool::new(false));
        let timer_expired = expired.clone();
        let (tx, rx) = mpsc::channel::<()>();
        let timeout = Duration::from_secs(plan.turn_timeout_seconds);
        let timer = std::thread::spawn(move || {
            let start = Instant::now();
            loop {
                match rx.recv_timeout(Duration::from_millis(100)) {
                    Ok(()) | Err(mpsc::RecvTimeoutError::Disconnected) => return,
                    Err(mpsc::RecvTimeoutError::Timeout) => (),
                }
                if pause.load(Ordering::SeqCst) || start.elapsed() >= timeout {
                    timer_expired.store(true, Ordering::SeqCst);
                    cancel.cancel();
                    return;
                }
            }
        });
        let result = self
            .cognition
            .prompt(&task_prompt(plan, task, previous), self.on_item);
        let _ = tx.send(());
        let _ = timer.join();
        if expired.load(Ordering::SeqCst) {
            return Err("The attempt was paused or reached its time limit. Inspect its effects before retrying.".into());
        }
        match result {
            Ok(reason) if reason == "end_turn" => Ok(()),
            Ok(reason) => Err(format!(
                "The model stopped with {reason}; this is not task completion."
            )),
            Err(e) => Err(e.to_string()),
        }
    }

    fn verify(&mut self, workspace: &Path, check: &Check) -> Result<String, String> {
        verify_command(workspace, check, &self.pause)
    }

    fn paused(&self) -> bool {
        self.pause.load(Ordering::SeqCst)
    }
}

/// Bounded checks use files rather than pipes, so a verbose child cannot
/// deadlock the controller. Output is retained as capped evidence in the run.
/// Verifiers must own and clean up any children they create.
pub fn verify_command(
    workspace: &Path,
    check: &Check,
    pause: &AtomicBool,
) -> Result<String, String> {
    if check.argv.first().map(String::as_str) == Some(crate::autonomy::REVIEW) {
        return crate::autonomy::verify(workspace, check, pause);
    }
    let path = std::env::temp_dir().join(format!("richos-check-{}", uuid::Uuid::new_v4()));
    let mut options = std::fs::OpenOptions::new();
    options.create_new(true).read(true).write(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }
    let file = options.open(&path).map_err(|e| e.to_string())?;
    let result = (|| {
        let mut cmd = Command::new(&check.argv[0]);
        cmd.args(&check.argv[1..])
            .current_dir(workspace)
            .stdin(Stdio::null())
            .stdout(file.try_clone().map_err(|e| e.to_string())?)
            .stderr(file.try_clone().map_err(|e| e.to_string())?);
        let mut child = cmd
            .spawn()
            .map_err(|e| format!("Could not start verifier: {e}"))?;
        let start = Instant::now();
        let status = loop {
            match child.try_wait() {
                Ok(Some(s)) => break Ok(s),
                Ok(None) => (),
                Err(e) => {
                    let _ = child.kill();
                    let _ = child.wait();
                    break Err(e.to_string());
                }
            }
            if pause.load(Ordering::SeqCst)
                || start.elapsed() >= Duration::from_secs(check.timeout_seconds)
                || file
                    .metadata()
                    .map(|m| m.len() > 2 * 1024 * 1024)
                    .unwrap_or(true)
            {
                let _ = child.kill();
                let _ = child.wait();
                break Err("Verifier paused or exceeded its time/output limit.".into());
            }
            std::thread::sleep(Duration::from_millis(25));
        };
        use std::io::Read;
        let mut output = String::new();
        std::fs::File::open(&path)
            .map_err(|e| e.to_string())?
            .take(8192)
            .read_to_string(&mut output)
            .map_err(|e| e.to_string())?;
        match status {
            Ok(s) if s.success() => Ok(format!("exit 0\n{output}")),
            Ok(s) => Err(format!("exit {:?}\n{output}", s.code())),
            Err(e) => Err(format!("{e}\n{output}")),
        }
    })();
    drop(file);
    let _ = std::fs::remove_file(path);
    result
}
