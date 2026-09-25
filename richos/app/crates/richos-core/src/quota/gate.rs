//! Desktop hook wrapper. A hold keeps the provider's tool call pending, so the
//! worker retains its context and never emits a false SubagentStop receipt.
use super::{Admission, Policy, ReadError, Snapshot, View};
use serde_json::Value;
use std::{
    fs,
    io::{self, Read, Write},
    path::Path,
    process::{Command, Stdio},
    time::{Duration, Instant},
};

fn read_json<T: serde::de::DeserializeOwned>(path: &Path) -> io::Result<T> {
    let mut bytes = Vec::new();
    fs::File::open(path)?.take(262145).read_to_end(&mut bytes)?;
    if bytes.len() > 262144 {
        return Err(io::Error::other("oversized quota state"));
    }
    serde_json::from_slice(&bytes).map_err(io::Error::other)
}

fn admission(state: &Path, now: u64) -> Admission {
    let Ok(view) = read_json::<View>(&state.join("claude-quota.json")) else {
        return Admission::Unknown;
    };
    // Read the persisted switch separately: a publication failure must not leave
    // an old disabled snapshot admitting work after the policy was enabled.
    let policy = state
        .parent()
        .and_then(|p| read_json::<Policy>(&p.join("claude-quota-policy.json")).ok())
        .unwrap_or(view.policy);
    if !policy.enabled {
        return Admission::Disabled;
    }
    if policy.validate().is_err() || view.checked_at.is_some_and(|t| t > now) {
        return Admission::Unknown;
    }
    Snapshot {
        windows: view.windows,
        checked_at: view.checked_at,
        retry_at: view.retry_at,
        error: view.message.map(|_| ReadError::Failed),
    }
    .view(policy, now)
    .admission
}

fn authorized(scope: &Path, worker: bool) -> bool {
    read_json::<Value>(scope).is_ok_and(|v| {
        v["version"] == 1
            && (v["actions_allowed"] == true || (worker && v["background_work_allowed"] == true))
    })
}

fn wait(
    payload: &Value,
    state: &Path,
    scope: &Path,
    tick: Duration,
    budget: Duration,
) -> io::Result<()> {
    let worker = payload
        .get("agent_id")
        .and_then(Value::as_str)
        .is_some_and(|id| !id.is_empty());
    if !worker && payload["tool_name"] != "Agent" {
        return Ok(());
    }
    let started = Instant::now();
    loop {
        if !authorized(scope, worker) {
            return Err(io::Error::other(
                "This app work was stopped. New actions are unavailable.",
            ));
        }
        if admission(state, crate::util::now_millis()).allows_work() {
            return Ok(());
        }
        if started.elapsed() >= budget {
            return Err(io::Error::other(
                "Still waiting for a current allowance reading. No tool action was run.",
            ));
        }
        std::thread::sleep(tick);
    }
}

/// Runs before Tauri initialization in the desktop executable. The canonical
/// hook still decides permissions, targets and receipts after this gate opens.
pub fn run_cli() -> i32 {
    let result = (|| -> io::Result<i32> {
        let mut bytes = Vec::new();
        io::stdin().take(262145).read_to_end(&mut bytes)?;
        if bytes.len() > 262144 {
            return Err(io::Error::other("oversized tool callback"));
        }
        let payload: Value = serde_json::from_slice(&bytes).map_err(io::Error::other)?;
        let state = std::env::var_os("RICHOS_APP_STATE")
            .ok_or_else(|| io::Error::other("missing desktop state"))?;
        let scope = std::env::var_os("RICHOS_APP_SCOPE")
            .ok_or_else(|| io::Error::other("missing desktop scope"))?;
        if !Path::new(&state).is_absolute() || !Path::new(&scope).is_absolute() {
            return Err(io::Error::other("invalid desktop roots"));
        }
        wait(
            &payload,
            Path::new(&state),
            Path::new(&scope),
            Duration::from_millis(250),
            Duration::from_secs(21500),
        )?;
        let mut args = std::env::args_os().skip(2);
        let program = args
            .next()
            .ok_or_else(|| io::Error::other("missing canonical hook"))?;
        let mut child = Command::new(program)
            .args(args)
            .stdin(Stdio::piped())
            .spawn()?;
        child
            .stdin
            .take()
            .ok_or_else(|| io::Error::other("missing hook input"))?
            .write_all(&bytes)?;
        Ok(child.wait()?.code().unwrap_or(2))
    })();
    match result {
        Ok(code) => code,
        Err(e) => {
            eprintln!("RichOS desktop quota: {e}");
            2
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::quota::{atomic_write, tests::Scratch, Service, Window};
    use serde_json::json;
    fn setup() -> (Scratch, Service, std::path::PathBuf, std::path::PathBuf) {
        let root = Scratch::new();
        let service = Service::open(root.path()).unwrap();
        service
            .set_policy(Policy {
                enabled: true,
                pause_percent: 93,
            })
            .unwrap();
        let state = root.path().join("engine-state");
        let scope = root.path().join("scope.json");
        atomic_write(
            &scope,
            &json!({"version":1,"actions_allowed":false,"background_work_allowed":true}),
        )
        .unwrap();
        (root, service, state, scope)
    }
    fn publish(service: &Service, left: u64) {
        let now = crate::util::now_millis();
        *service.snapshot.lock().unwrap() = Snapshot {
            checked_at: Some(now),
            windows: vec![Window {
                id: "five_hour".into(),
                label: "Five-hour".into(),
                used_percent: 94.,
                resets_at: Some(now + left),
                duration_ms: 18_000_000,
            }],
            ..Default::default()
        };
        service.publish().unwrap();
    }
    #[test]
    fn same_worker_waits_then_resumes_when_reset_is_near() {
        let (_root, service, state, scope) = setup();
        publish(&service, 3_600_000);
        let (tx, rx) = std::sync::mpsc::channel();
        let worker = std::thread::spawn(move || {
            tx.send(wait(
                &json!({"agent_id":"same-worker","tool_name":"Bash"}),
                &state,
                &scope,
                Duration::from_millis(5),
                Duration::from_secs(3),
            ))
            .unwrap();
        });
        assert!(
            rx.recv_timeout(Duration::from_millis(40)).is_err(),
            "worker must stay pending"
        );
        publish(&service, 19 * 60_000);
        rx.recv_timeout(Duration::from_secs(1)).unwrap().unwrap();
        worker.join().unwrap();
    }
    #[test]
    fn disabling_releases_unknown_quota_and_stop_revokes_waiter() {
        let (_root, service, state, scope) = setup();
        service.set_policy(Policy::default()).unwrap();
        wait(
            &json!({"agent_id":"worker"}),
            &state,
            &scope,
            Duration::from_millis(1),
            Duration::ZERO,
        )
        .unwrap();
        service
            .set_policy(Policy {
                enabled: true,
                pause_percent: 93,
            })
            .unwrap();
        atomic_write(
            &scope,
            &json!({"version":1,"actions_allowed":false,"background_work_allowed":false}),
        )
        .unwrap();
        assert!(wait(
            &json!({"agent_id":"worker"}),
            &state,
            &scope,
            Duration::from_millis(1),
            Duration::from_secs(2)
        )
        .is_err());
    }
    #[test]
    fn foreground_tools_are_not_quota_gated_but_new_agents_are() {
        let (_root, _service, state, scope) = setup();
        wait(
            &json!({"tool_name":"Read"}),
            &state,
            &scope,
            Duration::ZERO,
            Duration::ZERO,
        )
        .unwrap();
        atomic_write(&scope, &json!({"version":1,"actions_allowed":true})).unwrap();
        assert!(wait(
            &json!({"tool_name":"Agent"}),
            &state,
            &scope,
            Duration::ZERO,
            Duration::ZERO
        )
        .is_err());
    }
}
