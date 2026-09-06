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
    assert_eq!(ctl.tick(&mut host).unwrap(), RunState::Canceled);
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
if [ -f attempt-count ]; then read -r count < attempt-count; fi
while IFS= read -r line; do
  case "$line" in
    *'"subtype":"initialize"'*)
      printf '%s\n' '{"type":"control_response","response":{"subtype":"success","request_id":"req_init","response":{"account":{}}}}'
      ;;
    *'"type":"user"'*)
      count=$((count + 1))
      printf "%s\n" "$count" > attempt-count
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
        RunState::Canceled
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
    assert_eq!(args[mode + 1], "acceptEdits");
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
    let doctrine = richos_core::doctrine::ensure_rendered(&tmp.0, &richos_core::doctrine::DoctrineIdentity::default()).unwrap();
    let skills = richos_core::skills::ensure_rendered(&tmp.0).unwrap();
    let legacy = NativeCognition::start(&fake, &tmp.0, &doctrine, &skills).unwrap();
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

fn autonomous_plan(root: &Path) -> RunPlan {
    richos_core::autonomy::plan(root, "Handle the document", "Deliver the completed document", vec![richos_core::autonomy::WorkItem {
        id: "document".into(), description: "Write the requested document".into(), depends_on: vec![], criteria: "The finished document covers all requirements".into(),
    }]).unwrap()
}

#[test]
fn generated_plans_cannot_install_executable_acceptance_commands() {
    let tmp = Temp::new();
    let p = autonomous_plan(&tmp.0);
    assert!(p.autonomous());
    assert_eq!(p.tasks[0].checks[0].argv[0], richos_core::autonomy::REVIEW);
    let injected = r#"{"kind":"work","goal":"x","tasks":[{"id":"x","description":"x","depends_on":[],"criteria":"x","argv":["rm","-rf","/"]}]}"#;
    assert!(richos_core::autonomy::parse::<richos_core::autonomy::Intake>(injected).is_err());
    assert!(richos_core::autonomy::parse::<richos_core::autonomy::Review>(r#"{"kind":"complete"}"#).is_err());
}

#[test]
fn autonomous_work_retains_ownership_after_the_advanced_plan_attempt_ceiling() {
    let tmp = Temp::new();
    let ctl = RunController::create(&tmp.journal(), autonomous_plan(&tmp.0)).unwrap();
    let mut snapshot = ctl.snapshot().clone();
    drop(ctl);
    snapshot.tasks[0].attempts = 25;
    std::fs::write(tmp.journal(), format!("{}\n", serde_json::to_string(&snapshot).unwrap())).unwrap();
    let mut ctl = RunController::open(&tmp.journal()).unwrap();
    let mut host = Host { fail_execute: true, fail_checks: 1, ..Host::default() };
    assert_eq!(ctl.tick(&mut host).unwrap(), RunState::Waiting);
    assert_eq!(ctl.snapshot().tasks[0].attempts, 26);
    assert!(ctl.snapshot().tasks[0].retry_at > richos_core::util::now_millis());
    assert_eq!(ctl.tick(&mut host).unwrap(), RunState::Waiting);
    assert_eq!(host.executions.len(), 1, "backoff must not spin the provider");
    drop(ctl);
    assert_eq!(RunController::open(&tmp.journal()).unwrap().snapshot().state(), RunState::Waiting);
}

#[test]
fn autonomous_crash_recovery_is_owned_but_an_explicit_pause_stays_paused() {
    let tmp = Temp::new();
    let ctl = RunController::create(&tmp.journal(), autonomous_plan(&tmp.0)).unwrap();
    let mut snapshot = ctl.snapshot().clone();
    drop(ctl);
    snapshot.tasks[0].state = TaskState::Running;
    snapshot.tasks[0].attempts = 1;
    snapshot.paused = true;
    std::fs::write(tmp.journal(), format!("{}\n", serde_json::to_string(&snapshot).unwrap())).unwrap();
    let mut ctl = RunController::open(&tmp.journal()).unwrap();
    assert_eq!(ctl.snapshot().state(), RunState::Paused);
    assert_eq!(ctl.snapshot().tasks[0].state, TaskState::Pending);
    assert!(ctl.snapshot().tasks[0].evidence.iter().any(|e| e.contains("Reconcile")));
    ctl.pause(false).unwrap();
    assert_eq!(ctl.snapshot().state(), RunState::Ready);
}

#[test]
fn business_decision_does_not_discard_independent_work_and_answer_reaches_verification() {
    struct DecisionHost { calls: usize, saw_answer: bool }
    impl RunHost for DecisionHost {
        fn execute(&mut self, plan: &RunPlan, _: &TaskSpec, _: &[String]) -> Result<(), String> {
            self.saw_answer |= plan.goal.contains("Use option A"); Ok(())
        }
        fn verify(&mut self, _: &Path, check: &Check) -> Result<String, String> {
            self.calls += 1;
            if self.calls == 1 { Err(format!("{}{{\"kind\":\"decision\",\"question\":\"A or B?\",\"why_ceo\":\"Material spending choice\",\"recommendation\":\"A\",\"options\":[\"A\",\"B\"]}}", richos_core::autonomy::DECISION)) }
            else { if self.saw_answer { assert!(check.argv[1].contains("Use option A")); } Ok("Inspected result".into()) }
        }
    }
    let tmp = Temp::new();
    let mut p = autonomous_plan(&tmp.0);
    let mut second = p.tasks[0].clone(); second.id = "independent".into(); p.tasks.push(second);
    let mut ctl = RunController::create(&tmp.journal(), p).unwrap();
    let mut host = DecisionHost { calls: 0, saw_answer: false };
    assert_eq!(ctl.tick(&mut host).unwrap(), RunState::Ready);
    assert_eq!(ctl.snapshot().tasks[0].state, TaskState::NeedsDecision);
    assert_eq!(ctl.tick(&mut host).unwrap(), RunState::NeedsDecision);
    ctl.answer_decision("answer-1", "Use option A").unwrap();
    assert_eq!(ctl.tick(&mut host).unwrap(), RunState::Completed);
    assert!(host.saw_answer);
}

#[test]
fn owned_receipts_replay_once_and_use_the_old_ledger_source_vocabulary() {
    use richos_core::{Entity, EntityId, EntityRegistry, Ledger, Spine};
    let tmp = Temp::new();
    let path = tmp.0.join("conversation.jsonl");
    let mut spine = Spine::new(Ledger::open(&path).unwrap());
    spine.set_entity_registry(EntityRegistry::new(vec![Entity::try_new("company", "Company", vec![tmp.0.clone()]).unwrap()]).unwrap());
    let thread = spine.create_thread("Owned work", &EntityId::parse("company").unwrap()).unwrap();
    let binding = spine.active_binding().unwrap().clone();
    for _ in 0..2 {
        spine.record_owned_message(&binding, "request-fixed", Some("Handle this"), "").unwrap();
        spine.record_owned_message(&binding, "reply-fixed", None, "The result is ready").unwrap();
    }
    assert_eq!(spine.messages(&thread).unwrap().len(), 2);
    drop(spine);
    let ledger = Ledger::open(&path).unwrap();
    assert_eq!(ledger.messages(&thread).unwrap().len(), 2);
    for line in std::fs::read_to_string(&path).unwrap().lines() {
        let event: serde_json::Value = serde_json::from_str(line).unwrap();
        if let Some(source) = event.get("source") { assert!(["text", "jam", "internal", "proactive"].contains(&source.as_str().unwrap())); }
    }
    if let Ok(export) = std::env::var("RICHOS_COMPAT_LEDGER_EXPORT") { std::fs::copy(&path, export).unwrap(); }
}

#[test]
fn an_owned_worker_can_finish_in_its_company_while_another_conversation_is_selected() {
    use richos_core::{Entity, EntityId, EntityRegistry, Ledger, Spine};
    use richos_core::run_spine::SpineRunHost;
    use std::sync::Arc;
    let tmp = Temp::new();
    let mut spine = Spine::new(Ledger::open(tmp.0.join("conversation.jsonl")).unwrap());
    spine.set_entity_registry(EntityRegistry::new(vec![Entity::try_new("company", "Company", vec![tmp.0.clone()]).unwrap()]).unwrap());
    let entity = EntityId::parse("company").unwrap();
    let owned = spine.create_thread("Owned", &entity).unwrap();
    let binding = spine.active_binding().unwrap().clone();
    let selected = spine.create_thread("Selected", &entity).unwrap();
    spine.switch_thread(&selected).unwrap();
    let mut p = plan(&tmp.0); p.tasks.truncate(1); p.tasks[0].checks[0].argv = vec!["/usr/bin/true".into()];
    let mut ctl = RunController::create(&tmp.journal(), p).unwrap();
    let mut host = SpineRunHost { spine: &mut spine, binding, worker: Some(worker(&tmp.0)), pause: Arc::new(AtomicBool::new(false)), on_update: None };
    assert_eq!(ctl.tick(&mut host).unwrap(), RunState::Completed);
    assert_eq!(host.spine.active_thread(), Some(selected.as_str()));
    assert!(host.spine.messages(&selected).unwrap().is_empty());
    assert_eq!(host.spine.messages(&owned).unwrap().last().unwrap().text, "All done");
}

#[test]
fn structured_review_accepts_commentary_but_refuses_ambiguous_or_partial_verdicts() {
    use richos_core::autonomy::{parse, Review};
    assert!(matches!(parse::<Review>("I inspected the file.\n{\"kind\":\"complete\",\"evidence\":\"File checked\"}").unwrap(), Review::Complete { .. }));
    assert!(parse::<Review>("{\"kind\":\"complete\",\"evidence\":\"checked\"} {\"kind\":\"incomplete\",\"remaining\":\"missing\"}").is_err());
    assert!(parse::<Review>("{\"kind\":\"complete\",\"evidence\":").is_err());
}

#[cfg(unix)]
#[test]
fn dropping_a_managed_lease_terminates_its_ordinary_child_processes() {
    use std::os::unix::fs::PermissionsExt;
    use std::process::Command;
    let tmp = Temp::new();
    let script = tmp.0.join("native");
    std::fs::write(&script, r#"#!/usr/bin/env python3
import json, sys, subprocess, os
assert os.environ.get('CLAUDE_CODE_DISABLE_BACKGROUND_TASKS') == '1'
assert os.environ.get('CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS') == '0'
child = subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(60)'])
open('child.pid', 'w').write(str(child.pid))
for line in sys.stdin:
    m = json.loads(line)
    if m.get('type') == 'control_request':
        print(json.dumps({'type':'control_response','response':{'subtype':'success','request_id':m['request_id'],'response':{}}}), flush=True)
"#).unwrap();
    std::fs::set_permissions(&script, std::fs::Permissions::from_mode(0o700)).unwrap();
    let model = richos_core::native::NativeCognition::start_managed(&script, &tmp.0).unwrap();
    let pid = std::fs::read_to_string(tmp.0.join("child.pid")).unwrap();
    assert!(pid.parse::<u32>().unwrap() > 1);
    drop(model);
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(3);
    let dead = loop {
        let state = Command::new("/bin/ps").args(["-p", &pid, "-o", "stat="]).output().unwrap();
        let state_text = String::from_utf8_lossy(&state.stdout);
        if state.status.code() == Some(1) || state_text.trim().starts_with('Z') { break true; }
        if std::time::Instant::now() >= deadline { break false; }
        std::thread::sleep(std::time::Duration::from_millis(25));
    };
    if !dead { let _ = Command::new("/bin/kill").args(["-KILL", &pid]).status(); }
    assert!(dead, "A managed lease must not leave its ordinary child running after drop");
}

#[test]
fn a_broken_review_retries_only_review_after_restart() {
    struct ReviewHost { executions: u32, reviews: u32 }
    impl RunHost for ReviewHost {
        fn execute(&mut self, _: &RunPlan, _: &TaskSpec, _: &[String]) -> Result<(),String> { self.executions += 1; Ok(()) }
        fn verify(&mut self, _: &Path, _: &Check) -> Result<String,String> {
            self.reviews += 1;
            if self.reviews == 1 { Err(format!("{}invalid response",richos_core::autonomy::REVIEW_RETRY)) } else { Ok("Read the correct deliverable".into()) }
        }
    }
    let tmp=Temp::new();
    let mut ctl=RunController::create(&tmp.journal(),autonomous_plan(&tmp.0)).unwrap();
    let mut host=ReviewHost{executions:0,reviews:0};
    assert_eq!(ctl.tick(&mut host).unwrap(),RunState::Waiting);
    assert!(ctl.snapshot().tasks[0].review_pending);
    let mut saved=ctl.snapshot().clone(); drop(ctl);
    saved.tasks[0].retry_at=0;
    std::fs::write(tmp.journal(),format!("{}\n",serde_json::to_string(&saved).unwrap())).unwrap();
    let mut ctl=RunController::open(&tmp.journal()).unwrap();
    assert_eq!(ctl.tick(&mut host).unwrap(),RunState::Completed);
    assert_eq!(host.executions,1,"review transport failure must not repeat external actions");
    assert_eq!(host.reviews,2);
}

#[test]
fn a_correction_rechecks_existing_effects_before_executing_revised_work() {
    let tmp=Temp::new();
    let mut ctl=RunController::create(&tmp.journal(),autonomous_plan(&tmp.0)).unwrap();
    let mut host=Host::default();
    ctl.tick(&mut host).unwrap();
    let mut revised=autonomous_plan(&tmp.0); revised.goal="The revised outcome".into();
    ctl.amend("ceo-correction",revised.clone()).unwrap();
    assert_eq!(ctl.snapshot().state(),RunState::Ready);
    assert!(ctl.snapshot().tasks[0].review_pending);
    ctl.tick(&mut host).unwrap();
    assert_eq!(host.executions.len(),1,"existing effects satisfy revised criteria, so do not execute twice");
    assert_eq!(ctl.snapshot().state(),RunState::Completed);
    ctl.amend("ceo-correction",revised).unwrap();
    assert_eq!(ctl.snapshot().state(),RunState::Completed,"replayed correction must not reopen completed work");
    let mut same_scope = autonomous_plan(&tmp.0); same_scope.goal="The revised outcome".into();
    ctl.amend("second-correction",same_scope).unwrap();
    ctl.tick(&mut host).unwrap();
    drop(ctl);
    let reopened = RunController::open(&tmp.journal()).unwrap();
    assert_eq!(reopened.snapshot().state(),RunState::Completed,"revised contract must remain readable after restart");
    assert_eq!(reopened.snapshot().plan_revision,2,"an explicit same-scope amendment is also a valid journal transition");
}

#[test]
fn response_contracts_refuse_sibling_fields_and_require_each_variants_fields() {
    use richos_core::autonomy::{response_schema,review_schema,parse,Intake,Review};
    for schema in [response_schema(),review_schema()] {
        for variant in schema["properties"]["result"]["anyOf"].as_array().unwrap() {
            let props=variant["properties"].as_object().unwrap();
            let required=variant["required"].as_array().unwrap();
            assert_eq!(variant["additionalProperties"],false);
            assert_eq!(props.len(),required.len());
            assert!(required.iter().all(|k|props.contains_key(k.as_str().unwrap())));
            assert!(props["kind"]["const"].is_string());
        }
    }
    assert!(!response_schema().to_string().contains("answers_decision"));
    assert!(!review_schema().to_string().contains("goal"));
    assert!(parse::<Intake>(r#"{"kind":"work","goal":"g","tasks":[],"answers_decision":true}"#).is_err());
    assert!(parse::<Review>(r#"{"kind":"complete","evidence":"read","goal":"g"}"#).is_err());
}

#[test]
fn recovery_backoff_survives_restart_without_losing_work() {
    let tmp=Temp::new();
    let mut ctl=RunController::create(&tmp.journal(),autonomous_plan(&tmp.0)).unwrap();
    ctl.defer_recovery(3600).unwrap(); drop(ctl);
    let mut ctl=RunController::open(&tmp.journal()).unwrap();
    let mut host=Host::default();
    assert_eq!(ctl.tick(&mut host).unwrap(),RunState::Waiting);
    assert!(host.executions.is_empty());
    assert!(!ctl.snapshot().canceled);
    assert!(!ctl.snapshot().paused);
}

#[test]
fn rich_keeps_voice_and_reports_without_registration_or_redundant_priming() {
    use richos_core::{Entity,EntityId,EntityRegistry,Ledger,Spine};
    use richos_core::cognition::{Cognition,CognitionError,TurnItem};
    use richos_core::stream::{StreamEvent,TurnObserver};
    use richos_core::ledger::Source;
    use std::sync::{Arc,Mutex};
    struct Rich { calls:Arc<Mutex<Vec<String>>> }
    impl Cognition for Rich {
        fn session_id(&self)->&str{"continuous-rich"}
        fn reprime(&mut self,text:&str,sink:&mut dyn FnMut(TurnItem))->Result<(),CognitionError>{
            self.calls.lock().unwrap().push(text.into());
            let _ = sink;
            Ok(())
        }
        fn prompt(&mut self,text:&str,sink:&mut dyn FnMut(TurnItem))->Result<String,CognitionError>{
            self.calls.lock().unwrap().push(text.into());
            sink(TurnItem::Text{text:if text.starts_with("Report this") {"The work is verified."} else {"Here is the answer."},seq:0});
            Ok("end_turn".into())
        }
    }
    #[derive(Clone)] struct Events(Arc<Mutex<Vec<StreamEvent>>>);
    impl TurnObserver for Events {fn on_event(&self,event:&StreamEvent){self.0.lock().unwrap().push(event.clone());}}
    let tmp=Temp::new();let mut spine=Spine::new(Ledger::open(tmp.0.join("ledger.jsonl")).unwrap());
    spine.set_entity_registry(EntityRegistry::new(vec![Entity::try_new("company","Company",vec![tmp.0.clone()]).unwrap()]).unwrap());
    let thread=spine.create_thread("Conversation",&EntityId::parse("company").unwrap()).unwrap();
    let calls=Arc::new(Mutex::new(vec![]));let events=Events(Arc::new(Mutex::new(vec![])));
    spine.attach_lease(Box::new(Rich{calls:calls.clone()}));spine.enable_owned_work();spine.set_observer(Box::new(events.clone()));
    let turn=spine.submit_prompt("What is the plan?",Source::Jam).unwrap();
    let binding=spine.active_binding().unwrap().clone();
    assert_eq!(calls.lock().unwrap().len(),2,"one prime and one answer, with no private registration on Rich");
    spine.report_owned_work(&binding,"finished-test","Verified outcome").unwrap();
    spine.report_owned_work(&binding,"finished-test","Verified outcome").unwrap();
    assert_eq!(calls.lock().unwrap().len(),3,"same-thread reports require no additional prime or private turn");
    assert_eq!(spine.lease_session_id(),Some("continuous-rich"));
    assert_eq!(spine.ledger().turn(&turn).unwrap().source,Source::Jam);
    let messages=spine.messages(&thread).unwrap();
    assert_eq!(messages.iter().filter(|m|m.text=="Here is the answer.").count(),1);
    assert!(!messages.iter().any(|m|m.text.contains("\"kind\"")),"private registration JSON must not enter the conversation");
    let chunks:Vec<_>=events.0.lock().unwrap().iter().filter_map(|e|if let StreamEvent::Chunk{text_delta,..}=e{Some(text_delta.clone())}else{None}).collect();
    assert_eq!(chunks,vec!["Here is the answer.","The work is verified."],"both the answer and report must reach the existing speech listener once");
    // THE WHOLE CONTRACT, not nine words of it. This assertion used to read
    // `.contains("You have a durable execution team")` against a literal that existed twice
    // in `spine.rs`, so the two copies could diverge in 980 of their 989 characters and stay
    // green (inner-doctrine design §2/§5.1). There is one copy now and the test names it.
    assert!(calls.lock().unwrap().iter().any(|p|p.contains(richos_core::spine::OWNED_WORK_CONTRACT)),"Rich must be primed with the actual handoff contract, in full, before answering");
    assert!(calls.lock().unwrap()[0].contains("one prose paragraph"));
    assert!(calls.lock().unwrap()[0].contains("No headings, lists or filesystem paths"));
    let other=spine.create_thread("Other context",&EntityId::parse("company").unwrap()).unwrap();
    spine.switch_thread(&other).unwrap();
    spine.submit_prompt("What about this thread?",Source::Text).unwrap();
    assert_eq!(calls.lock().unwrap().len(),5,"switching context requires one prime and one answer");
    spine.switch_thread(&thread).unwrap();
    spine.submit_prompt("Back to this context",Source::Text).unwrap();
    assert_eq!(calls.lock().unwrap().len(),7,"returning to the earlier context also requires priming");
}

#[test]
fn a_handoff_that_is_already_satisfied_never_executes_a_worker() {
    let tmp=Temp::new();
    let mut ctl=RunController::create_from_handoff(&tmp.journal(),autonomous_plan(&tmp.0),uuid::Uuid::new_v4().to_string()).unwrap();
    drop(ctl);
    ctl=RunController::open(&tmp.journal()).unwrap();
    let mut host=Host::default();
    assert_eq!(ctl.tick(&mut host).unwrap(),RunState::Completed);
    assert!(host.executions.is_empty());
    assert_eq!(host.verifications.len(),1);
}

#[test]
fn recovery_checkpoints_charge_real_cycles_and_stop_at_resource_decision() {
    let tmp=Temp::new();
    let mut ctl=RunController::create(&tmp.journal(),autonomous_plan(&tmp.0)).unwrap();
    let mut host=Host { fail_checks: 100, ..Host::default() };
    for cycle in 1..=RECOVERY_BUDGET {
        ctl.defer_recovery(0).unwrap();
        ctl.tick(&mut host).unwrap();
        assert_eq!(ctl.snapshot().tasks[0].recovery_cycles,cycle);
        if cycle == RECOVERY_CHECKPOINT {
            assert!(ctl.snapshot().tasks[0].retry_at >= richos_core::util::now_millis()+3_590_000,"tick must invoke the hour checkpoint itself");
        }
        drop(ctl); ctl=RunController::open(&tmp.journal()).unwrap();
    }
    assert_eq!(ctl.snapshot().state(),RunState::NeedsDecision);
    assert_eq!(host.executions.len(),10);
    for _ in 0..15 { ctl.tick(&mut host).unwrap(); }
    assert_eq!(host.executions.len(),10,"no inference after the persisted limit");
    assert_eq!(host.verifications.len(),10);
    assert!(ctl.snapshot().decision(0).unwrap().why_ceo.contains("up to 10 more attempts"));
    ctl.pause(false).unwrap();
    ctl.tick(&mut host).unwrap();
    assert_eq!(host.executions.len(),10,"resume is not a resource authorization");
    ctl.answer_decision("ceo-resource-authorization","Authorize ten more cycles.").unwrap();
    ctl.tick(&mut host).unwrap();
    assert_eq!(host.executions.len(),11);
    assert_eq!(ctl.snapshot().tasks[0].recovery_cycles,1);
    assert_eq!(ctl.snapshot().decisions,vec!["Authorize ten more cycles."]);
}

#[test]
fn review_only_failures_exhaust_the_same_persisted_resource_budget() {
    struct Broken { reviews:u32 }
    impl RunHost for Broken {
        fn execute(&mut self,_:&RunPlan,_:&TaskSpec,_:&[String])->Result<(),String>{panic!("review-only retries cannot execute")}
        fn verify(&mut self,_:&Path,_:&Check)->Result<String,String>{self.reviews+=1;Err(format!("{} invalid response",richos_core::autonomy::REVIEW_RETRY))}
    }
    let tmp=Temp::new();let mut ctl=RunController::create_from_handoff(&tmp.journal(),autonomous_plan(&tmp.0),uuid::Uuid::new_v4().to_string()).unwrap();
    let mut host=Broken{reviews:0};
    for _ in 0..RECOVERY_BUDGET {ctl.defer_recovery(0).unwrap();ctl.tick(&mut host).unwrap();drop(ctl);ctl=RunController::open(&tmp.journal()).unwrap();}
    for _ in 0..4 {ctl.tick(&mut host).unwrap();}
    assert_eq!(host.reviews,10);assert_eq!(ctl.snapshot().tasks[0].attempts,0);
    assert_eq!(ctl.snapshot().state(),RunState::NeedsDecision);
}

#[test]
fn a_crash_on_the_last_charged_cycle_cannot_start_an_eleventh() {
    let tmp=Temp::new();let ctl=RunController::create(&tmp.journal(),autonomous_plan(&tmp.0)).unwrap();
    let mut s=ctl.snapshot().clone();drop(ctl);
    s.tasks[0].state=TaskState::Running;s.tasks[0].recovery_cycles=RECOVERY_BUDGET;
    std::fs::write(tmp.journal(),format!("{}\n",serde_json::to_string(&s).unwrap())).unwrap();
    let mut ctl=RunController::open(&tmp.journal()).unwrap();let mut host=Host::default();
    assert_eq!(ctl.tick(&mut host).unwrap(),RunState::NeedsDecision);
    assert!(host.executions.is_empty());assert!(host.verifications.is_empty());
}

// Seed durable pending questions without calling a model or spending money.
fn pending_panel(tmp: &Temp, resource: bool, count: usize) -> RunController {
    let mut plan = autonomous_plan(&tmp.0);
    for n in 1..count { let mut t=plan.tasks[0].clone(); t.id=format!("other-{n}"); plan.tasks.push(t); }
    let ctl=RunController::create(&tmp.journal(),plan).unwrap();
    let mut snapshot=ctl.snapshot().clone(); drop(ctl);
    for t in &mut snapshot.tasks {
        t.state=TaskState::NeedsDecision; t.recovery_cycles=10;
        t.evidence=vec![if resource { "CEO_DECISION:Recovery resource limit reached: 10 cycles without verified completion.".into() }
            else { r#"Result: CEO_DECISION:{"kind":"decision","question":"Buy A or B?","why_ceo":"Spending authority","recommendation":"A","options":["A","B"]}"#.into() }];
    }
    std::fs::write(tmp.journal(),format!("{}\n",serde_json::to_string(&snapshot).unwrap())).unwrap();
    RunController::open(&tmp.journal()).unwrap()
}

#[test]
fn panel_continue_is_bounded_durable_idempotent_and_scoped_to_one_question() {
    let tmp=Temp::new(); let mut ctl=pending_panel(&tmp,true,2);
    let task=ctl.snapshot().plan.tasks[0].id.clone(); let d=ctl.snapshot().decision(0).unwrap();
    assert!(d.resource); assert!(d.why_ceo.contains("charges apply"));
    assert!(ctl.respond_to_decision("wrong-task",&d.id,DecisionAction::Continue).is_err());
    assert!(ctl.respond_to_decision(&task,"stale",DecisionAction::Continue).is_err());
    assert!(ctl.respond_to_decision(&task,&d.id,DecisionAction::Answer{text:"Maybe".into()}).is_err());
    ctl.respond_to_decision(&task,&d.id,DecisionAction::Continue).unwrap();
    assert_eq!(ctl.snapshot().tasks[0].recovery_cycles,0);
    assert_eq!(ctl.snapshot().tasks[1].state,TaskState::NeedsDecision);
    assert_eq!(ctl.snapshot().tasks[1].recovery_cycles,10);
    let revision=ctl.snapshot().revision; drop(ctl);
    let mut ctl=RunController::open(&tmp.journal()).unwrap();
    ctl.respond_to_decision(&task,&d.id,DecisionAction::Continue).unwrap();
    assert_eq!(ctl.snapshot().revision,revision);
    assert_eq!(ctl.snapshot().decision_receipts.len(),1);
    assert!(ctl.respond_to_decision(&task,&d.id,DecisionAction::End).is_err());
    assert!(ctl.snapshot().decisions[0].contains("10 further attempts"));
    let mut host=Host::default(); ctl.tick(&mut host).unwrap();
    assert_eq!(host.executions.len(),1);
}

#[test]
fn panel_business_answer_is_verbatim_and_generic_continue_cannot_authorize_it() {
    let tmp=Temp::new(); let mut ctl=pending_panel(&tmp,false,1);
    let task=ctl.snapshot().plan.tasks[0].id.clone(); let d=ctl.snapshot().decision(0).unwrap();
    assert_eq!(d.options,vec!["A","B"]); assert!(!d.resource);
    assert!(ctl.respond_to_decision(&task,&d.id,DecisionAction::Continue).is_err());
    let answer="Buy B, with a maximum spend of $80.";
    ctl.respond_to_decision(&task,&d.id,DecisionAction::Answer{text:answer.into()}).unwrap();
    assert_eq!(ctl.snapshot().decisions,vec![answer]);
    assert_eq!(ctl.snapshot().state(),RunState::Ready);
}

#[test]
fn panel_scope_change_preserves_contract_and_rechecks_before_execution() {
    let tmp=Temp::new(); let mut ctl=pending_panel(&tmp,true,1);
    let task=ctl.snapshot().plan.tasks[0].id.clone(); let d=ctl.snapshot().decision(0).unwrap();
    let old=ctl.snapshot().plan.clone(); let correction="Deliver only the summary. Do not send it.";
    ctl.respond_to_decision(&task,&d.id,DecisionAction::ChangeScope{text:correction.into()}).unwrap();
    assert!(ctl.snapshot().plan.goal.starts_with(&old.goal));
    assert!(ctl.snapshot().plan.tasks[0].prompt.starts_with(&old.tasks[0].prompt));
    let outcome:richos_core::autonomy::Outcome=serde_json::from_str(&ctl.snapshot().plan.tasks[0].checks[0].argv[1]).unwrap();
    assert!(outcome.criteria.contains(correction));
    assert_eq!(ctl.snapshot().plan_revision,1);
    drop(ctl); let mut ctl=RunController::open(&tmp.journal()).unwrap();
    let mut host=Host::default(); ctl.tick(&mut host).unwrap();
    assert_eq!(host.executions.len(),0,"inspect existing effects before more work");
    assert_eq!(host.verifications.len(),1);
    assert_eq!(ctl.snapshot().state(),RunState::Completed);
}

#[test]
fn panel_end_survives_restart_without_claiming_completion() {
    let tmp=Temp::new(); let mut ctl=pending_panel(&tmp,true,1);
    let task=ctl.snapshot().plan.tasks[0].id.clone(); let d=ctl.snapshot().decision(0).unwrap();
    ctl.respond_to_decision(&task,&d.id,DecisionAction::End).unwrap();
    drop(ctl); let mut ctl=RunController::open(&tmp.journal()).unwrap();
    assert_eq!(ctl.snapshot().state(),RunState::Canceled);
    let mut host=Host::default(); ctl.tick(&mut host).unwrap(); assert_eq!(host.executions.len(),0);
}

#[test]
fn panel_decision_identity_changes_with_question_and_cannot_cross_assignments() {
    let a=Temp::new();let b=Temp::new();let mut first=pending_panel(&a,false,2);let mut second=pending_panel(&b,false,1);
    let id=first.snapshot().decision(0).unwrap().id; let task=first.snapshot().plan.tasks[0].id.clone();
    assert!(first.answer_decision("ambiguous","A").is_err());
    assert!(second.respond_to_decision(&task,&id,DecisionAction::Answer{text:"A".into()}).is_err());
    let mut snapshot=first.snapshot().clone();drop(first);
    snapshot.tasks[0].evidence.push("CEO_DECISION:Different question".into());
    std::fs::write(a.journal(),format!("{}\n",serde_json::to_string(&snapshot).unwrap())).unwrap();
    let mut first=RunController::open(&a.journal()).unwrap();
    assert!(first.respond_to_decision(&task,&id,DecisionAction::Answer{text:"A".into()}).is_err());
}

#[test]
fn answering_a_panel_decision_reconciles_interrupted_independent_work() {
    let tmp=Temp::new();let ctl=pending_panel(&tmp,true,2);
    let mut snapshot=ctl.snapshot().clone();drop(ctl);
    snapshot.tasks[1].state=TaskState::NeedsAttention;snapshot.tasks[1].recovery_cycles=1;snapshot.tasks[1].review_pending=false;snapshot.paused=true;
    std::fs::write(tmp.journal(),format!("{}\n",serde_json::to_string(&snapshot).unwrap())).unwrap();
    let mut ctl=RunController::open(&tmp.journal()).unwrap();
    let d=ctl.snapshot().decision(0).unwrap();let task=ctl.snapshot().plan.tasks[0].id.clone();
    ctl.respond_to_decision(&task,&d.id,DecisionAction::Continue).unwrap();
    assert_eq!(ctl.snapshot().tasks[1].state,TaskState::Pending);
    assert!(ctl.snapshot().tasks[1].review_pending,"interrupted effects must be inspected first");
    let mut host=Host::default();ctl.tick(&mut host).unwrap();ctl.tick(&mut host).unwrap();
    assert_eq!(ctl.snapshot().state(),RunState::Completed);
    assert_eq!(host.executions.len(),1,"the interrupted independent task was checked, not replayed");
}
