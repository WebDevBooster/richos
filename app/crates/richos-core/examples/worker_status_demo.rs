//! Read a real `worker-events.jsonl` and print the derived status.
//!
//! The end-to-end harness for the worker-lifecycle consumer: point it at a genuine
//! team-session directory written by the engine's four emitters
//! (`engine/scripts/hooks/worker-*-handoff.sh`) and it prints the same
//! [`richos_core::worker_status::WorkerStatusView`] the Tauri command returns — including
//! the REAL `/bin/kill -0` liveness probe against each row's recorded `host_pid`.
//!
//! ```text
//! cargo run -p richos-core --example worker_status_demo -- <team-dir>
//! ```
//!
//! A unit test over a fixture proves the arithmetic. This proves the whole path: real
//! emitters -> real file -> real parse -> real syscall -> a count.

use richos_core::worker_events::{self, SessionScope};
use richos_core::worker_status;

fn main() {
    let dir = match std::env::args().nth(1) {
        Some(d) => std::path::PathBuf::from(d),
        None => {
            eprintln!("usage: worker_status_demo <team-session-dir>");
            std::process::exit(2);
        }
    };

    let scope = SessionScope::from_team_dir(&dir);
    let path = worker_events::worker_events_path(&dir);
    let rows = worker_events::read_stream(&path);

    println!("stream      : {}", path.display());
    println!("session     : {scope:?}");
    println!("rows parsed : {}", rows.len());

    let in_scope = rows.iter().filter(|r| r.in_scope(&scope)).count();
    println!("rows in scope: {in_scope}");

    println!("\n-- open runs, liveness-reconciled --");
    for run in worker_events::open_runs(&rows, &scope, worker_events::probe_host) {
        println!(
            "  {:<18} name={:<22} opened_by={:<8} host_pid={:<8} liveness={:?} active={}",
            run.agent_id,
            if run.worker_name.is_empty() { "-" } else { &run.worker_name },
            run.opened_by.as_str(),
            run.host_pid.map(|p| p.to_string()).unwrap_or_else(|| "-".into()),
            run.host_liveness,
            run.is_active(),
        );
    }

    let status = worker_status::read_from_dir(&dir);
    println!("\n-- WorkerStatusView --");
    println!("{}", serde_json::to_string_pretty(&status).unwrap());
    println!("\nactive={}  needs_you={}  liveness_unknown={}", status.active, status.needs_you, status.liveness_unknown);
}
