use richos_core::run::*;
use richos_core::run_host::verify_command;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};

// Controlled lease whose permission/workspace contract is explicit in the fixture.
struct ManagedMock {
    inner: richos_core::cognition::CancellableMockCognition,
    workspace: PathBuf,
}
impl richos_core::cognition::Cognition for ManagedMock {
    fn session_id(&self) -> &str {
        self.inner.session_id()
    }
    fn reprime(
        &mut self,
        text: &str,
        sink: &mut dyn FnMut(richos_core::cognition::TurnItem),
    ) -> Result<(), richos_core::cognition::CognitionError> {
        self.inner.reprime(text, sink)
    }
    fn prompt(
        &mut self,
        text: &str,
        sink: &mut dyn FnMut(richos_core::cognition::TurnItem),
    ) -> Result<String, richos_core::cognition::CognitionError> {
        self.inner.prompt(text, sink)
    }
    fn cancel_handle(&self) -> Option<std::sync::Arc<dyn richos_core::steering::TurnCancel>> {
        self.inner.cancel_handle()
    }
    fn prepare_managed(
        &self,
        workspace: &Path,
    ) -> Result<(), richos_core::cognition::CognitionError> {
        if workspace == self.workspace {
            Ok(())
        } else {
            Err(richos_core::cognition::CognitionError::Protocol(
                "Wrong fixture workspace".into(),
            ))
        }
    }
}
fn worker(workspace: &Path) -> Box<dyn richos_core::cognition::Cognition> {
    Box::new(ManagedMock {
        inner: richos_core::cognition::CancellableMockCognition::new(
            "managed-worker",
            vec!["All done"],
            std::time::Duration::from_millis(1),
        ),
        workspace: workspace.into(),
    })
}

#[derive(Clone, Default)]
struct RunLive(std::sync::Arc<std::sync::Mutex<Vec<(String, serde_json::Value)>>>);
impl richos_core::live::LiveObserver for RunLive {
    fn on_live_event(&self, event: &richos_core::live::LiveEvent) {
        self.0
            .lock()
            .unwrap()
            .push((event.event_name().into(), event.payload()));
    }
}

struct Temp(PathBuf);
impl Temp {
    fn new() -> Self {
        let p = std::env::temp_dir().join(format!("richos-run-test-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir(&p).unwrap();
        Self(p)
    }
    fn journal(&self) -> PathBuf {
        self.0.join("run.jsonl")
    }
}
impl Drop for Temp {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

fn plan(root: &Path) -> RunPlan {
    RunPlan {
        goal: "Deliver the two requested changes".into(),
        workspace: root.into(),
        max_attempts: 2,
        turn_timeout_seconds: 30,
        tasks: vec![
            TaskSpec {
                id: "first".into(),
                prompt: "Make the first change".into(),
                depends_on: vec![],
                checks: vec![Check {
                    name: "first acceptance".into(),
                    argv: vec!["verifier".into()],
                    timeout_seconds: 2,
                }],
            },
            TaskSpec {
                id: "second".into(),
                prompt: "Make the dependent change".into(),
                depends_on: vec!["first".into()],
                checks: vec![Check {
                    name: "second acceptance".into(),
                    argv: vec!["verifier".into()],
                    timeout_seconds: 2,
                }],
            },
        ],
    }
}

#[derive(Default)]
struct Host {
    executions: Vec<String>,
    verifications: Vec<String>,
    fail_checks: usize,
    fail_execute: bool,
    paused: AtomicBool,
    pause_in_execute: bool,
}
impl RunHost for Host {
    fn execute(&mut self, _: &RunPlan, task: &TaskSpec, _: &[String]) -> Result<(), String> {
        self.executions.push(task.id.clone());
        if self.pause_in_execute {
            self.paused.store(true, Ordering::SeqCst);
        }
        if self.fail_execute {
            Err("Provider failed after starting work".into())
        } else {
            Ok(())
        }
    }
    fn verify(&mut self, _: &Path, check: &Check) -> Result<String, String> {
        self.verifications.push(check.name.clone());
        if self.fail_checks > 0 {
            self.fail_checks -= 1;
            Err("Actual acceptance failed".into())
        } else {
            Ok("Acceptance passed".into())
        }
    }
    fn paused(&self) -> bool {
        self.paused.load(Ordering::SeqCst)
    }
}

#[test]
fn ending_a_turn_cannot_complete_failed_work_and_the_controller_continues() {
    let tmp = Temp::new();
    let mut ctl = RunController::create(&tmp.journal(), plan(&tmp.0)).unwrap();
    let mut host = Host {
        fail_checks: 1,
        ..Host::default()
    };
    assert_eq!(ctl.tick(&mut host).unwrap(), RunState::Ready);
    assert_eq!(ctl.snapshot().tasks[0].state, TaskState::Pending);
    assert_eq!(ctl.tick(&mut host).unwrap(), RunState::Ready);
    assert_eq!(ctl.tick(&mut host).unwrap(), RunState::Completed);
    assert_eq!(host.executions, ["first", "first", "second"]);
    assert_eq!(
        host.verifications,
        [
            "first acceptance",
            "first acceptance",
            "second acceptance",
            "first acceptance"
        ]
    );
}

#[test]
fn failed_checks_exhaust_budget_without_running_dependents_or_claiming_completion() {
    let tmp = Temp::new();
    let mut ctl = RunController::create(&tmp.journal(), plan(&tmp.0)).unwrap();
    let mut host = Host {
        fail_checks: 9,
        ..Host::default()
    };
    ctl.tick(&mut host).unwrap();
    assert_eq!(ctl.tick(&mut host).unwrap(), RunState::NeedsAttention);
    for _ in 0..10 {
        assert_eq!(ctl.tick(&mut host).unwrap(), RunState::NeedsAttention);
    }
    assert_eq!(host.executions.len(), 2);
    assert!(ctl.retry("first").is_err());
}

#[test]
fn provider_failure_is_not_blindly_retried_but_independent_work_can_continue() {
    let tmp = Temp::new();
    let mut p = plan(&tmp.0);
    p.tasks[1].depends_on.clear();
    let mut ctl = RunController::create(&tmp.journal(), p).unwrap();
    let mut host = Host {
        fail_execute: true,
        ..Host::default()
    };
    assert_eq!(ctl.tick(&mut host).unwrap(), RunState::Ready);
    assert!(host.verifications.is_empty());
    host.fail_execute = false;
    assert_eq!(ctl.tick(&mut host).unwrap(), RunState::NeedsAttention);
    ctl.retry("first").unwrap();
    assert_eq!(ctl.tick(&mut host).unwrap(), RunState::Completed);
}

#[test]
fn pause_is_a_persisted_state_not_a_finished_run() {
    let tmp = Temp::new();
    let mut ctl = RunController::create(&tmp.journal(), plan(&tmp.0)).unwrap();
    ctl.pause(true).unwrap();
    drop(ctl);
    let mut ctl = RunController::open(&tmp.journal()).unwrap();
    let mut host = Host::default();
    assert_eq!(ctl.tick(&mut host).unwrap(), RunState::Paused);
    assert!(host.executions.is_empty());
    ctl.pause(false).unwrap();
    assert_eq!(ctl.tick(&mut host).unwrap(), RunState::Ready);
}

#[test]
fn pausing_during_execution_requires_inspection_before_replay() {
    let tmp = Temp::new();
    let mut ctl = RunController::create(&tmp.journal(), plan(&tmp.0)).unwrap();
    let mut host = Host {
        pause_in_execute: true,
        ..Host::default()
    };
    assert_eq!(ctl.tick(&mut host).unwrap(), RunState::Paused);
    assert_eq!(ctl.snapshot().tasks[0].state, TaskState::NeedsAttention);
    assert!(host.verifications.is_empty());
}

#[test]
fn final_workspace_is_rechecked_so_a_later_task_cannot_break_an_earlier_green() {
    let tmp = Temp::new();
    let mut ctl = RunController::create(&tmp.journal(), plan(&tmp.0)).unwrap();
    struct Regression {
        calls: usize,
    }
    impl RunHost for Regression {
        fn execute(&mut self, _: &RunPlan, _: &TaskSpec, _: &[String]) -> Result<(), String> {
            Ok(())
        }
        fn verify(&mut self, _: &Path, _: &Check) -> Result<String, String> {
            self.calls += 1;
            if self.calls == 3 {
                Err("Second change broke first acceptance".into())
            } else {
                Ok("pass".into())
            }
        }
    }
    let mut host = Regression { calls: 0 };
    ctl.tick(&mut host).unwrap();
    assert_eq!(ctl.tick(&mut host).unwrap(), RunState::Ready);
    assert_eq!(ctl.snapshot().tasks[0].state, TaskState::Pending);
    assert_eq!(ctl.tick(&mut host).unwrap(), RunState::Completed);
}

#[test]
fn a_second_controller_cannot_dispatch_duplicate_work_and_status_reads_do_not_recover_live_tasks() {
    let tmp = Temp::new();
    let ctl = RunController::create(&tmp.journal(), plan(&tmp.0)).unwrap();
    assert!(RunController::open(&tmp.journal()).is_err());
    assert_eq!(
        read_snapshot(&tmp.journal()).unwrap().state(),
        RunState::Ready
    );
    assert!(RunController::create(&tmp.journal(), plan(&tmp.0)).is_err());
    drop(ctl);
    assert!(RunController::open(&tmp.journal()).is_ok());
}

#[test]
fn interrupted_execution_is_not_replayed_on_restart_and_a_torn_append_is_recovered() {
    let tmp = Temp::new();
    let ctl = RunController::create(&tmp.journal(), plan(&tmp.0)).unwrap();
    let mut interrupted = ctl.snapshot().clone();
    drop(ctl);
    interrupted.tasks[0].state = TaskState::Running;
    interrupted.tasks[0].attempts = 1;
    use std::io::Write;
    let mut f = std::fs::OpenOptions::new()
        .append(true)
        .open(tmp.journal())
        .unwrap();
    writeln!(f, "{}", serde_json::to_string(&interrupted).unwrap()).unwrap();
    write!(f, "{{\"version\":").unwrap();
    drop(f);
    let mut ctl = RunController::open(&tmp.journal()).unwrap();
    let mut host = Host::default();
    assert_eq!(ctl.tick(&mut host).unwrap(), RunState::NeedsAttention);
    assert!(host.executions.is_empty());
    ctl.retry("first").unwrap();
    ctl.tick(&mut host).unwrap();
    assert_eq!(ctl.tick(&mut host).unwrap(), RunState::Completed);
}

#[test]
fn corrupt_committed_records_and_mutated_contracts_are_refused() {
    let tmp = Temp::new();
    let ctl = RunController::create(&tmp.journal(), plan(&tmp.0)).unwrap();
    let mut s = ctl.snapshot().clone();
    drop(ctl);
    s.plan.goal = "An unauthorized replacement".into();
    use std::io::Write;
    let mut f = std::fs::OpenOptions::new()
        .append(true)
        .open(tmp.journal())
        .unwrap();
    writeln!(f, "{}", serde_json::to_string(&s).unwrap()).unwrap();
    drop(f);
    assert!(RunController::open(&tmp.journal()).is_err());
    std::fs::write(tmp.journal(), "not-json\n").unwrap();
    assert!(RunController::open(&tmp.journal()).is_err());
}

#[test]
fn invalid_or_unverifiable_work_never_enters_the_run_queue() {
    let tmp = Temp::new();
    let mut p = plan(&tmp.0);
    p.tasks.clear();
    assert!(p.validate().is_err());
    let mut p = plan(&tmp.0);
    p.tasks[0].checks.clear();
    assert!(p.validate().is_err());
    let mut p = plan(&tmp.0);
    p.tasks[0].depends_on.push("second".into());
    assert!(p.validate().is_err());
    let mut p = plan(&tmp.0);
    p.tasks[1].id = "first".into();
    assert!(p.validate().is_err());
    let mut p = plan(&tmp.0);
    p.max_attempts = 0;
    assert!(p.validate().is_err());
    let mut p = plan(&tmp.0);
    p.turn_timeout_seconds = 0;
    assert!(p.validate().is_err());
}

#[cfg(unix)]
#[test]
fn real_verifier_exit_status_output_missing_binary_and_timeout_are_used() {
    let tmp = Temp::new();
    let pause = AtomicBool::new(false);
    let check = |script: &str| Check {
        name: "fixture".into(),
        argv: vec!["/bin/sh".into(), "-c".into(), script.into()],
        timeout_seconds: 1,
    };
    assert!(
        verify_command(&tmp.0, &check("printf actual-evidence"), &pause)
            .unwrap()
            .contains("actual-evidence")
    );
    assert!(
        verify_command(&tmp.0, &check("printf rejection; exit 7"), &pause)
            .unwrap_err()
            .contains("7")
    );
    assert!(verify_command(&tmp.0, &check("exec sleep 10"), &pause)
        .unwrap_err()
        .contains("limit"));
    assert!(verify_command(
        &tmp.0,
        &Check {
            argv: vec!["/no/such/verifier".into()],
            ..check("true")
        },
        &pause
    )
    .is_err());
}

#[cfg(unix)]
#[test]
fn desktop_adapter_uses_real_scoped_spine_turns_and_external_verification() {
    use richos_core::cognition::CancellableMockCognition;
    use richos_core::run_spine::SpineRunHost;
    use richos_core::{Entity, EntityId, EntityRegistry, Ledger, Spine};
    use std::sync::Arc;
    let tmp = Temp::new();
    let mut spine = Spine::new(Ledger::open(tmp.0.join("conversation.jsonl")).unwrap());
    spine.set_entity_registry(
        EntityRegistry::new(vec![Entity::try_new(
            "test-company",
            "Test company",
            vec![tmp.0.clone()],
        )
        .unwrap()])
        .unwrap(),
    );
    let thread = spine
        .create_thread("Managed work", &EntityId::parse("test-company").unwrap())
        .unwrap();
    spine.switch_thread(&thread).unwrap();
    spine.attach_lease(Box::new(CancellableMockCognition::new(
        "test-session",
        vec!["All done"],
        std::time::Duration::from_millis(1),
    )));
    let live = RunLive::default();
    spine.set_live_observer(Box::new(live.clone()));
    let binding = spine.active_binding().unwrap().clone();
    let mut p = plan(&tmp.0);
    p.tasks.truncate(1);
    p.tasks[0].checks[0].argv = vec!["/bin/test".into(), "-f".into(), "deliverable".into()];
    let mut ctl = RunController::create(&tmp.journal(), p).unwrap();
    let mut host = SpineRunHost {
        worker: Some(worker(&tmp.0)),
        spine: &mut spine,
        binding,
        pause: Arc::new(AtomicBool::new(false)),
        on_update: None,
    };
    assert_eq!(
        ctl.tick(&mut host).unwrap(),
        RunState::Ready,
        "The model's All done did not pass the check"
    );
    std::fs::write(tmp.0.join("deliverable"), "the actual artifact").unwrap();
    host.worker = Some(worker(&tmp.0));
    assert_eq!(
        ctl.tick(&mut host).unwrap(),
        RunState::Completed,
        "{:?}",
        ctl.snapshot()
    );
    let attempts = host
        .spine
        .ledger()
        .thread_turns(&thread)
        .unwrap()
        .into_iter()
        .filter(|t| {
            t.user_text
                .starts_with("Work on this task within the authorized run.")
        })
        .count();
    assert_eq!(attempts, 2);
    assert_eq!(
        host.spine.lease_session_id(),
        Some("test-session"),
        "chat lease restored"
    );
    let messages = host.spine.ledger().messages(&thread).unwrap();
    assert_eq!(
        messages
            .iter()
            .filter(|m| m.role == "assistant" && m.text == "All done")
            .count(),
        2
    );
    assert!(
        !messages.iter().any(|m| m.role == "user"),
        "managed prompts must not impersonate the user"
    );
    assert!(
        live.0
            .lock()
            .unwrap()
            .iter()
            .any(|(name, value)| name == "rich://message-delta"
                && value.to_string().contains("All done")),
        "output reaches the live conversation"
    );
    let before = host.spine.timeline(&thread).unwrap();
    drop(host);
    drop(spine);
    let reopened = Spine::new(Ledger::open(tmp.0.join("conversation.jsonl")).unwrap());
    assert_eq!(
        reopened
            .ledger()
            .messages(&thread)
            .unwrap()
            .iter()
            .filter(|m| m.text == "All done")
            .count(),
        2
    );
    assert_eq!(
        reopened.timeline(&thread).unwrap(),
        before,
        "live projection survives reopening"
    );
}

#[test]
fn the_model_timeout_is_enforced_through_the_adapters_cancel_handle() {
    use richos_core::cognition::{CancellableMockCognition, TurnItem};
    use richos_core::run_host::CognitionRunHost;
    use std::sync::Arc;
    let tmp = Temp::new();
    let mut p = plan(&tmp.0);
    p.turn_timeout_seconds = 1;
    let mut ctl = RunController::create(&tmp.journal(), p).unwrap();
    let mut model = ManagedMock {
        workspace: tmp.0.clone(),
        inner: CancellableMockCognition::new(
            "slow-test",
            vec!["still working"; 1000],
            std::time::Duration::from_millis(20),
        ),
    };
    let mut output = |_: TurnItem<'_>| {};
    let mut host = CognitionRunHost {
        cognition: &mut model,
        on_item: &mut output,
        pause: Arc::new(AtomicBool::new(false)),
    };
    let start = std::time::Instant::now();
    assert_eq!(ctl.tick(&mut host).unwrap(), RunState::NeedsAttention);
    assert!(start.elapsed().as_secs() < 5);
    assert!(ctl.snapshot().tasks[0].evidence[0].contains("time limit"));
}

#[test]
fn an_operator_can_end_unfinished_work_without_calling_it_completed() {
    let tmp = Temp::new();
    let mut ctl = RunController::create(&tmp.journal(), plan(&tmp.0)).unwrap();
    ctl.cancel().unwrap();
    drop(ctl);
    let mut ctl = RunController::open(&tmp.journal()).unwrap();
    let mut host = Host::default();
    assert_eq!(ctl.tick(&mut host).unwrap(), RunState::Cancelled);
    assert!(host.executions.is_empty());
    assert!(ctl.retry("first").is_err());
}

#[test]
fn pausing_verification_does_not_automatically_repeat_external_work() {
    struct PausingCheck(bool);
    impl RunHost for PausingCheck {
        fn execute(&mut self, _: &RunPlan, _: &TaskSpec, _: &[String]) -> Result<(), String> {
            Ok(())
        }
        fn verify(&mut self, _: &Path, _: &Check) -> Result<String, String> {
            self.0 = true;
            Err("Paused during verification".into())
        }
        fn paused(&self) -> bool {
            self.0
        }
    }
    let tmp = Temp::new();
    let mut ctl = RunController::create(&tmp.journal(), plan(&tmp.0)).unwrap();
    assert_eq!(
        ctl.tick(&mut PausingCheck(false)).unwrap(),
        RunState::Paused
    );
    ctl.pause(false).unwrap();
    let mut host = Host::default();
    assert_eq!(ctl.tick(&mut host).unwrap(), RunState::NeedsAttention);
    assert!(host.executions.is_empty());
}

#[cfg(unix)]
#[test]
fn terminal_runner_repeats_a_real_native_protocol_turn_until_the_artifact_passes() {
    use std::os::unix::fs::PermissionsExt;
    use std::process::Command;
    let tmp = Temp::new();
    let fake = tmp.0.join("fake-model");
    std::fs::write(&fake, r#"#!/bin/sh
count=0
while IFS= read -r line; do
  case "$line" in
    *'"subtype":"initialize"'*)
      printf '%s\n' '{"type":"control_response","response":{"subtype":"success","request_id":"req_init","response":{"account":{}}}}'
      ;;
    *'"type":"user"'*)
      count=$((count + 1))
      if [ "$count" -eq 2 ]; then printf 'actual work\n' > deliverable; fi
      printf '%s\n' '{"type":"result","subtype":"success","stop_reason":"end_turn","is_error":false}'
      ;;
  esac
done
"#).unwrap();
    std::fs::set_permissions(&fake, std::fs::Permissions::from_mode(0o700)).unwrap();
    let mut p = plan(&tmp.0);
    p.tasks.truncate(1);
    p.tasks[0].checks[0].argv = vec!["/bin/test".into(), "-f".into(), "deliverable".into()];
    let config = tmp.0.join("plan.json");
    std::fs::write(&config, serde_json::to_vec(&p).unwrap()).unwrap();
    let cli = env!("CARGO_BIN_EXE_richos-run");
    let created = Command::new(cli)
        .arg("create")
        .arg(tmp.journal())
        .arg(config)
        .output()
        .unwrap();
    assert!(
        created.status.success(),
        "{}",
        String::from_utf8_lossy(&created.stderr)
    );
    let driven = Command::new(cli)
        .arg("drive")
        .arg(tmp.journal())
        .env("RICHOS_CLAUDE_BIN", &fake)
        .output()
        .unwrap();
    assert!(
        driven.status.success(),
        "{}",
        String::from_utf8_lossy(&driven.stderr)
    );
    let snapshot = read_snapshot(&tmp.journal()).unwrap();
    assert_eq!(snapshot.state(), RunState::Completed);
    assert_eq!(snapshot.tasks[0].attempts, 2);
    assert!(tmp.0.join("deliverable").exists());
}

#[test]
fn unavailable_workspace_can_be_inspected_and_ended_but_never_executed() {
    let tmp = Temp::new();
    let workspace = tmp.0.join("project");
    std::fs::create_dir(&workspace).unwrap();
    let ctl = RunController::create(&tmp.journal(), plan(&workspace)).unwrap();
    drop(ctl);
    std::fs::rename(&workspace, tmp.0.join("moved")).unwrap();
    let mut ctl = RunController::open(&tmp.journal())
        .expect("inspection is independent of workspace availability");
    let mut host = Host::default();
    assert!(ctl.tick(&mut host).is_err());
    assert!(host.executions.is_empty());
    ctl.cancel().unwrap();
    drop(ctl);
    assert_eq!(
        RunController::open(&tmp.journal())
            .unwrap()
            .snapshot()
            .state(),
        RunState::Cancelled
    );
}

#[cfg(unix)]
#[test]
fn managed_native_transport_loads_settings_and_denies_unapproved_tools() {
    use richos_core::cognition::Cognition;
    use richos_core::native::{managed_child_args, NativeCognition};
    use std::os::unix::fs::PermissionsExt;
    let tmp = Temp::new();
    let fake = tmp.0.join("claude-fixture");
    std::fs::write(&fake, r#"#!/usr/bin/env python3
import json, sys, os
open('launch.json', 'w').write(json.dumps({'argv': sys.argv[1:], 'cwd': os.getcwd()}))
for line in sys.stdin:
    msg = json.loads(line)
    if msg.get('type') == 'control_request':
        print(json.dumps({'type':'control_response','response':{'subtype':'success','request_id':msg['request_id'],'response':{}}}), flush=True)
    elif msg.get('type') == 'user':
        print(json.dumps({'type':'control_request','request_id':'approval','request':{'subtype':'can_use_tool','tool_name':'Write','input':{'file_path':'unapproved','content':'bad'}}}), flush=True)
    elif msg.get('type') == 'control_response':
        open('permission-response.json', 'w').write(json.dumps(msg))
        print(json.dumps({'type':'result','subtype':'success','stop_reason':'end_turn','is_error':False}), flush=True)
"#).unwrap();
    std::fs::set_permissions(&fake, std::fs::Permissions::from_mode(0o700)).unwrap();
    let mut model = NativeCognition::start_managed(&fake, &tmp.0).unwrap();
    model.prepare_managed(&tmp.0).unwrap();
    assert!(model
        .prepare_managed(&tmp.0.join("another-project"))
        .is_err());
    let mut p = plan(&tmp.0);
    p.tasks.truncate(1);
    p.tasks[0].checks[0].argv = vec!["/usr/bin/true".into()];
    let mut ctl = RunController::create(&tmp.journal(), p).unwrap();
    let mut sink = |_: richos_core::cognition::TurnItem| {};
    let mut host = richos_core::run_host::CognitionRunHost {
        cognition: &mut model,
        on_item: &mut sink,
        pause: std::sync::Arc::new(AtomicBool::new(false)),
    };
    assert_eq!(ctl.tick(&mut host).unwrap(), RunState::NeedsAttention);
    assert!(ctl.snapshot().tasks[0].evidence[0].contains("permission_denied"));
    let receipt: serde_json::Value =
        serde_json::from_slice(&std::fs::read(tmp.0.join("permission-response.json")).unwrap())
            .unwrap();
    assert_eq!(receipt["response"]["response"]["behavior"], "deny");
    let launch: serde_json::Value =
        serde_json::from_slice(&std::fs::read(tmp.0.join("launch.json")).unwrap()).unwrap();
    let args = launch["argv"].as_array().unwrap();
    let sources = args.iter().position(|v| v == "--setting-sources").unwrap();
    assert_eq!(args[sources + 1], "user,project,local");
    assert!(!args.iter().any(|v| v == "--no-session-persistence"));
    let mode = args.iter().position(|v| v == "--permission-mode").unwrap();
    assert_eq!(args[mode + 1], "default");
    assert_eq!(
        launch["cwd"],
        tmp.0.canonicalize().unwrap().to_str().unwrap()
    );
    assert!(!managed_child_args("fixture")
        .iter()
        .any(|a| a.contains("skip-permissions")));
    drop(host);
    assert!(
        model.reprime("prime", &mut sink).is_err(),
        "permission denial during priming is not swallowed"
    );
    drop(model);
    let legacy = NativeCognition::start(&fake, &tmp.0).unwrap();
    assert!(
        legacy.prepare_managed(&tmp.0).is_err(),
        "the legacy auto-approving adapter cannot enter a run"
    );
}

#[test]
fn unreadable_journal_can_be_archived_verbatim_but_a_live_writer_cannot() {
    let tmp = Temp::new();
    let ctl = RunController::create(&tmp.journal(), plan(&tmp.0)).unwrap();
    assert!(archive_journal(&tmp.journal()).is_err());
    drop(ctl);
    let raw = b"corrupt committed record\n";
    std::fs::write(tmp.journal(), raw).unwrap();
    assert!(RunController::open(&tmp.journal()).is_err());
    let archive = archive_journal(&tmp.journal()).unwrap();
    assert_eq!(std::fs::read(archive).unwrap(), raw);
    let ctl = RunController::create(&tmp.journal(), plan(&tmp.0)).unwrap();
    assert_eq!(ctl.snapshot().state(), RunState::Ready);
}
