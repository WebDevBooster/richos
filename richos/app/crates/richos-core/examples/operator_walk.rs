//! THE OPERATOR WALK'S BACK END — the app side of his team, without the window (operator
//! back-end spec r3 §6 verification 5, W2, as r4 §5 changes it).
//!
//! The switch stays OFF in every build (the shell's `Gate::Operator` arm still answers
//! `NOT_IN_THIS_BUILD`, by design, until everything is in place). So W2 is walked here, in the
//! test VM, against the real engine and a real `claude`: this binary is the app's back end with
//! no webview — the declaration gate, the operator host, the launcher with the claim, his
//! engine's scripts, the report tool. What the walk cannot reach through it (the front desk's
//! tools, the spine's channel field, the notice surface, the quit sheet) is exactly the list of
//! what is left, and the walk says so step by step.
//!
//!   operator_walk --operator-mcp <scope>     the report tool, as the app serves it
//!   operator_walk gate <data dir>            one gate reading, as JSON
//!   operator_walk host <data dir> <engine-state> <operator dir>
//!       reads one JSON command per line on stdin, answers one JSON line each on stdout, and
//!       writes every notice as {"event":"say",…} on stdout as it happens
//!
//! Commands: register, relay, answer, stop, stop-assignment, interrupt, read, team, retire,
//! quit. Nothing here is product code; it is the walk's stand-in for the shell.
use richos_core::operator_declaration::{gate, Gate};
use richos_core::operator_host::{ConversationKey, OperatorHost, OperatorDelivery, Origin, Relayed, Say, SayQuestions,
                                 Settle, StopResult};
use richos_core::operator_lead::NoPermissionDesk;
use richos_core::operator_declaration::{EngineFenceStatus, Refusal};
use richos_core::operator_profile::SessionEnvironment;
use richos_core::operator_runtime::{DurableDelivery, EngineScripts, OperatorNotice, ProfileLauncher, SessionValues};
use serde_json::{json, Value};
use std::io::{BufRead, Write};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::Duration;

fn say_json(kind: Say) -> Value {
    serde_json::to_value(kind).unwrap_or(Value::Null)
}

/// Settlement is the one seam the walk cannot close: `operator-complete` needs the
/// conversation's ECS binding, and only the spine mints one. The walk records the call and
/// answers with that sentence, so the host keeps the assignment open and says so — which is
/// the behavior W2 should show for "not wired yet".
struct RecordedSettle(Mutex<std::fs::File>);

impl Settle for RecordedSettle {
    fn complete(&self, key: &ConversationKey, obligation_id: &str, source_ref: &str, status: &str,
                evidence: &[String], _answer_text: &str) -> Result<(), String> {
        let line = json!({"thread": key.thread_id, "obligation_id": obligation_id, "source_ref": source_ref,
                          "status": status, "evidence": evidence});
        writeln!(self.0.lock().unwrap(), "{line}").map_err(|e| format!("the walk's settle record could not be written ({e})"))?;
        Err("not wired in the walk: operator-complete needs the conversation's ECS binding, which the spine mints".into())
    }
}

/// The per-start values from a named `launchctl`: in the test VM the walk runs over ssh, outside
/// the GUI login's launchd domain, where `launchctl getenv SSH_AUTH_SOCK` is empty (the probe
/// record's harness finding 8). The walk hands in a `launchctl` that prints the GUI session's
/// socket; everything else is `SessionEnvironment::derive_with`, the app's own code.
struct WalkSession(PathBuf);

impl SessionValues for WalkSession {
    fn derive(&self) -> Result<SessionEnvironment, Refusal> {
        SessionEnvironment::derive_with(&self.0)
    }
}

struct Out(Mutex<std::io::Stdout>);

impl Out {
    fn line(&self, value: &Value) {
        let mut out = self.0.lock().unwrap();
        // The harness reads this stream; a line it cannot get is said on stderr, which it keeps.
        if let Err(e) = writeln!(out, "{value}").and_then(|_| out.flush()) {
            eprintln!("operator_walk: stdout: {e}: {value}");
        }
    }
}

fn origin(word: &str) -> Origin {
    match word {
        "desk-typed" => Origin::DeskTyped,
        "desk-voice" => Origin::DeskVoice,
        "desk-file" => Origin::DeskFile,
        "phone" => Origin::Phone,
        _ => Origin::NoOrigin,
    }
}

fn key(v: &Value) -> ConversationKey {
    ConversationKey { entity_id: v["entity"].as_str().unwrap_or("femcboost").to_string(),
                      thread_id: v["thread"].as_str().unwrap_or("").to_string() }
}

fn stop_json(results: &[StopResult]) -> Value {
    Value::Array(results.iter().map(|r| {
        let (state, name, detail) = match r {
            StopResult::Stopped { name, seconds, registry } =>
                ("stopped", name, json!({"seconds": seconds, "registry": registry.clone().err().unwrap_or_else(|| "told".into())})),
            StopResult::StillAlive { name } => ("still-alive", name, Value::Null),
            StopResult::Indeterminate { name, why } => ("indeterminate", name, json!(why)),
            StopResult::NotFound { name } => ("not-found", name, Value::Null),
            StopResult::Failed { name, why } => ("failed", name, json!(why)),
        };
        json!({"name": name, "state": state, "detail": detail, "sentence": r.sentence()})
    }).collect())
}

fn gate_json(data: &Path) -> Value {
    match gate(data) {
        Gate::Product => json!({"gate": "product"}),
        Gate::Refused(r) => json!({"gate": "refused", "sentence": r.sentence()}),
        Gate::Operator(d) => json!({"gate": "operator", "entity": d.entity_root, "engine": d.engine_root}),
    }
}

fn host(data: &Path, state: &Path, root: &Path) -> Result<(), String> {
    let declaration = match gate(data) {
        Gate::Operator(d) => *d,
        Gate::Refused(r) => return Err(r.sentence()),
        Gate::Product => return Err("no declaration: the product path".into()),
    };
    std::fs::create_dir_all(root).map_err(|e| e.to_string())?;
    let out = Arc::new(Out(Mutex::new(std::io::stdout())));
    let push_out = out.clone();
    let delivery: Arc<DurableDelivery> = Arc::new(DurableDelivery::new(root, Some(Box::new(
        move |k: &ConversationKey, n: &OperatorNotice| push_out.line(&json!({
            "event": "say", "thread": k.thread_id, "handle": n.handle, "kind": say_json(n.kind), "text": n.text}))))));
    let executable = std::env::current_exe().map_err(|e| e.to_string())?;
    let launcher = Arc::new(match std::env::var_os("RICHOS_WALK_LAUNCHCTL") {
        Some(launchctl) => ProfileLauncher::with(declaration.clone(), &executable, state, &root.join("operator.log"),
                                                 Arc::new(NoPermissionDesk), Box::new(WalkSession(PathBuf::from(launchctl))),
                                                 Box::new(EngineFenceStatus)),
        None => ProfileLauncher::new(declaration.clone(), &executable, state, &root.join("operator.log"), Arc::new(NoPermissionDesk)),
    });
    let settle = Arc::new(RecordedSettle(Mutex::new(std::fs::OpenOptions::new().create(true).append(true)
        .open(root.join("settle-calls.jsonl")).map_err(|e| e.to_string())?)));
    let delivery_dyn: Arc<dyn OperatorDelivery> = delivery.clone();
    let host = OperatorHost::new(declaration.clone(), state, root, launcher.clone(), Arc::new(EngineScripts::new(declaration)),
                                 settle, delivery_dyn.clone(), Arc::new(SayQuestions(delivery_dyn)));
    out.line(&json!({"ready": true, "pid": std::process::id()}));
    for line in std::io::stdin().lock().lines() {
        let Ok(line) = line else { break };
        let Ok(v) = serde_json::from_str::<Value>(&line) else { continue };
        let id = v["id"].clone();
        let answer = match v["cmd"].as_str().unwrap_or("") {
            "register" => {
                let k = key(&v);
                let reg = richos_core::assignment::Registration {
                    entity_id: k.entity_id.clone(), thread_id: k.thread_id.clone(),
                    obligation_id: format!("walk-{}", uuid::Uuid::new_v4()),
                    // The register requires a ledger reference of the conversation's own turn
                    // (`ledger:<thread>:…`, assignment::register_kind); the walk has no ledger, so it
                    // names its own turn in that shape.
                    instruction_ledger_ref: format!("ledger:{}:walk", k.thread_id), instruction_sha256: "0".repeat(64),
                    title: v["title"].as_str().unwrap_or("Walk assignment").to_string(), repositories: vec![],
                    needs_screen: false,
                };
                match richos_core::assignment::register_kind(state, &reg, richos_core::assignment::AssignmentKind::Task) {
                    Ok(r) => json!({"handle": r.id}),
                    Err(e) => json!({"error": e.to_string()}),
                }
            }
            "relay" => match host.relay(&key(&v), v["title"].as_str().unwrap_or(""), v["handle"].as_str(),
                                        v["text"].as_str().unwrap_or(""), origin(v["origin"].as_str().unwrap_or(""))) {
                Ok(Relayed::Sent { uuid }) => json!({"relayed": true, "uuid": uuid}),
                Ok(Relayed::Not { sentence }) => json!({"relayed": false, "sentence": sentence}),
                Err(e) => json!({"error": e}),
            },
            "answer" => match host.deliver_answer(&key(&v), v["title"].as_str().unwrap_or(""), v["handle"].as_str(),
                                                  v["delivery"].as_str().unwrap_or(""), v["text"].as_str().unwrap_or("")) {
                Ok(now) => json!({"delivered_now": now}),
                Err(e) => json!({"error": e}),
            },
            "stop" => {
                let names: Vec<String> = v["names"].as_array().map(|a| a.iter().filter_map(Value::as_str).map(str::to_string).collect())
                    .unwrap_or_default();
                json!({"results": stop_json(&host.stop_named(&names, v["words"].as_str().unwrap_or(""),
                                                               origin(v["origin"].as_str().unwrap_or(""))))})
            }
            "stop-assignment" => json!({"results": stop_json(&host.stop_assignment(&key(&v), v["handle"].as_str().unwrap_or(""),
                v["words"].as_str().unwrap_or(""), origin(v["origin"].as_str().unwrap_or(""))))}),
            "interrupt" => json!({"sentence": host.interrupt(&key(&v))}),
            "read" => json!({"read": host.read(&key(&v), v["every"].as_bool().unwrap_or(false)).iter().map(|r| json!({
                "thread": r.key.thread_id, "lead_running": r.lead_running, "agents": r.agents, "texts": r.texts,
                "open_questions": r.open_questions, "leases": r.leases})).collect::<Vec<_>>()}),
            "team" => {
                let reading = host.team();
                let (liveness, sentence) = richos_core::work_gate::operator_team(&reading);
                json!({"alive": reading.alive, "unknown": reading.unknown, "descendants": reading.descendants,
                       "descendants_unknown": reading.descendants_unknown, "liveness": format!("{liveness:?}"), "sentence": sentence})
            }
            "retire" => json!({"retired": host.retire_idle(Duration::from_secs(v["idle_seconds"].as_u64().unwrap_or(0)))
                .iter().map(|k| k.thread_id.clone()).collect::<Vec<_>>()}),
            "take" => match delivery.take_pending(&key(&v)) {
                Ok(n) => json!({"taken": n.len()}),
                Err(e) => json!({"error": e}),
            },
            "quit" => {
                let quits = host.quit_all();
                launcher.release();
                out.line(&json!({"id": id, "quit": quits.iter().map(|(k, q)| json!([k.thread_id, format!("{q:?}")])).collect::<Vec<_>>()}));
                return Ok(());
            }
            other => json!({"error": format!("unknown command {other:?}")}),
        };
        let mut reply = answer;
        reply["id"] = id;
        out.line(&reply);
    }
    // Stdin closed without a quit: the app's own quit path, all the same.
    host.quit_all();
    launcher.release();
    Ok(())
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let result = match args.get(1).map(String::as_str) {
        Some("--operator-mcp") => richos_core::operator_report::run_stdio(Path::new(args.get(2).map(String::as_str).unwrap_or("")))
            .map_err(|e| e.to_string()),
        Some("gate") => {
            println!("{}", gate_json(Path::new(args.get(2).map(String::as_str).unwrap_or(""))));
            Ok(())
        }
        Some("host") if args.len() == 5 => host(Path::new(&args[2]), Path::new(&args[3]), &PathBuf::from(&args[4])),
        _ => Err("usage: operator_walk --operator-mcp <scope> | gate <data> | host <data> <engine-state> <operator dir>".into()),
    };
    if let Err(e) = result {
        eprintln!("operator_walk: {e}");
        std::process::exit(2);
    }
}
