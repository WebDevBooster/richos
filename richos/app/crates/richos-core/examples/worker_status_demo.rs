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
//! cargo run -p richos-core --example worker_status_demo -- --session <claude-session-id>
//! ```
//!
//! A unit test over a fixture proves the arithmetic. This proves the whole path: real
//! emitters -> real file -> real parse -> real syscall -> a count.
//!
//! `--session` proves the half that a fixture cannot: THE ATTRIBUTION, against the real
//! `~/.claude/teams` on this machine, with however many session directories it actually
//! holds. Pass the session id RichOS's compute lease is on and it prints which directory
//! that identity names — or nothing at all, and why, when the identity names none.

use richos_core::worker_events::{self, SessionScope};
use richos_core::worker_status;

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let dir = match args.first().map(String::as_str) {
        Some("--session") => {
            let session = args.get(1).map(String::as_str);
            println!("-- ATTRIBUTION (identity-derived; there is no mtime fallback) --");
            println!("session     : {}", session.unwrap_or("<none — no lease>"));
            println!(
                "names dir   : {}",
                session
                    .and_then(worker_status::team_dir_name)
                    .unwrap_or_else(|| "<cannot name a directory>".into())
            );
            // Everything on this machine that COULD have been picked by the old
            // max_by_key(mtime), printed so the choice below can be seen to be a choice.
            let teams = std::env::var_os("HOME")
                .map(std::path::PathBuf::from)
                .map(|h| h.join(".claude").join("teams"));
            if let Some(teams) = &teams {
                let mut present: Vec<String> = std::fs::read_dir(teams)
                    .map(|rd| {
                        rd.filter_map(|e| e.ok())
                            .filter(|e| e.path().is_dir())
                            .map(|e| e.file_name().to_string_lossy().into_owned())
                            .filter(|n| n.starts_with("session-"))
                            .collect()
                    })
                    .unwrap_or_default();
                present.sort();
                println!("candidates  : {} on disk -> {}", present.len(), present.join(", "));
            }
            match worker_status::resolve_team_dir(session) {
                Ok(d) => {
                    println!("resolved    : {}", d.display());
                    d
                }
                Err(reason) => {
                    println!("resolved    : NOTHING — {}", reason.reason());
                    println!("\n-- WorkerStatusView --");
                    let status = worker_status::current_status(session);
                    println!("{}", serde_json::to_string_pretty(&status).unwrap());
                    println!(
                        "\nactive={}  needs_you={}  liveness_unknown={}  attributed={}",
                        status.active,
                        status.needs_you,
                        status.liveness_unknown,
                        status.is_attributed()
                    );
                    return;
                }
            }
        }
        Some(d) => std::path::PathBuf::from(d),
        None => {
            eprintln!("usage: worker_status_demo <team-session-dir> | --session <claude-session-id>");
            std::process::exit(2);
        }
    };
    println!();

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
