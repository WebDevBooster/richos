//! SPIKE PROBE #2 — close caveat **C2** of the 2026-08-31 spike.
//!
//! C2 said, of the native `claude` binary's stream-json stdio:
//!
//! > No intermediate tool status was observed. ... I did not run a long-enough tool to
//! > prove there is nothing in between, so this is NOT OBSERVED, not "absent".
//!
//! The first spike's tools all finished in well under a second, so the question was never
//! actually asked. This probe asks it: it drives ONE tool that runs ~70 s and records
//! every byte that arrives while it runs.
//!
//! Shaped like `acp.rs` for the same reason `main.rs` is — spawn → one reader thread →
//! dispatch → per-turn mpsc, same first-`allow*` auto-approve policy (`acp.rs:469-479`).
//! On top of that it keeps the one piece of state a live-activity renderer needs: a map
//! of in-flight tool calls, updated from whatever intermediate frames arrive. If the
//! stream carries an intermediate status, this map moves while the tool runs; if it does
//! not, the map is frozen from `tool_use` to `tool_result` and the timeline shows the
//! silence with its length.
//!
//! NOT SHIPPED. Not a workspace member. `acp.rs` is not touched.

use serde_json::{json, Value};
use std::collections::BTreeMap;
use std::io::{BufRead, BufReader, Write};
use std::process::{ChildStdin, Command, Stdio};
use std::sync::mpsc::{channel, Receiver, Sender};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

/// Exactly the fields a live activity row needs. `elapsed_s` is the only one that can
/// move between invocation and result, so it is the whole measurement.
#[derive(Debug, Clone)]
struct Activity {
    tool_name: String,
    started_at: f64,
    elapsed_s: Option<i64>,
    updates: usize,
}

struct Capture {
    t0: Instant,
    lines: Vec<(f64, String)>,
}

fn main() {
    let out_dir = std::env::args().nth(1).expect("usage: tool_status <out_dir> <child_cwd>");
    let cwd = std::env::args().nth(2).expect("usage: tool_status <out_dir> <child_cwd>");

    let mut child = Command::new("claude")
        .args([
            "--print",
            "--input-format=stream-json",
            "--output-format=stream-json",
            "--include-partial-messages",
            "--verbose",
            "--model",
            "sonnet",
            "--setting-sources",
            "",
            "--no-session-persistence",
            "--permission-prompt-tool",
            "stdio",
        ])
        .current_dir(&cwd)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .expect("spawn claude");

    let stdin = Arc::new(Mutex::new(child.stdin.take().unwrap()));
    let stdout = child.stdout.take().unwrap();
    let cap = Arc::new(Mutex::new(Capture { t0: Instant::now(), lines: Vec::new() }));
    let live: Arc<Mutex<BTreeMap<String, Activity>>> = Arc::new(Mutex::new(BTreeMap::new()));
    let (tx, rx): (Sender<Value>, Receiver<Value>) = channel();

    {
        let cap = Arc::clone(&cap);
        let stdin = Arc::clone(&stdin);
        let live = Arc::clone(&live);
        std::thread::spawn(move || {
            let reader = BufReader::new(stdout);
            for line in reader.lines() {
                let line = match line {
                    Ok(l) => l,
                    Err(_) => break,
                };
                let dt = {
                    let mut c = cap.lock().unwrap();
                    let dt = c.t0.elapsed().as_secs_f64();
                    c.lines.push((dt, line.clone()));
                    dt
                };
                let msg: Value = match serde_json::from_str(&line) {
                    Ok(v) => v,
                    Err(_) => continue,
                };
                match msg["type"].as_str().unwrap_or("") {
                    // acp.rs's policy verbatim: auto-approve, answer from the reader
                    // thread because the child is blocked on it.
                    "control_request" if msg["request"]["subtype"] == "can_use_tool" => {
                        write_line(&stdin, &json!({
                            "type": "control_response",
                            "response": { "subtype": "success",
                                          "request_id": msg["request_id"],
                                          "response": { "behavior": "allow",
                                                        "updatedInput": msg["request"]["input"] } }
                        }));
                        eprintln!("[{dt:7.3}] can_use_tool {} -> ALLOW", msg["request"]["tool_name"]);
                    }
                    // A tool call is announced complete, as a whole `assistant` message.
                    // This is where a live row would be CREATED.
                    "assistant" => {
                        if let Some(blocks) = msg["message"]["content"].as_array() {
                            for b in blocks {
                                if b["type"] == "tool_use" {
                                    let id = b["id"].as_str().unwrap_or("?").to_string();
                                    let name = b["name"].as_str().unwrap_or("?").to_string();
                                    live.lock().unwrap().insert(id.clone(), Activity {
                                        tool_name: name.clone(),
                                        started_at: dt,
                                        elapsed_s: None,
                                        updates: 0,
                                    });
                                    eprintln!("[{dt:7.3}] ROW OPEN   {name} ({id})");
                                }
                            }
                        }
                    }
                    // The frame C2 was about. If it never arrives, the row never moves.
                    "tool_progress" => {
                        // The heartbeat's own `tool_use_id` is a synthetic
                        // `<id>-heartbeat-N`; the row it belongs to is `parent_tool_use_id`.
                        let key = msg["parent_tool_use_id"].as_str()
                            .or_else(|| msg["tool_use_id"].as_str())
                            .unwrap_or("?").to_string();
                        let elapsed = msg["elapsed_time_seconds"].as_i64();
                        let mut g = live.lock().unwrap();
                        if let Some(a) = g.get_mut(&key) {
                            a.elapsed_s = elapsed;
                            a.updates += 1;
                            eprintln!("[{dt:7.3}] ROW UPDATE {} -> running {}s (heartbeat={}) \
                                       [wall since open {:.3}s]",
                                      a.tool_name, elapsed.unwrap_or(-1),
                                      msg["heartbeat"], dt - a.started_at);
                        } else {
                            eprintln!("[{dt:7.3}] tool_progress for UNKNOWN row {key}: {msg}");
                        }
                    }
                    // Where a live row would be CLOSED.
                    "user" => {
                        if let Some(blocks) = msg["message"]["content"].as_array() {
                            for b in blocks {
                                if b["type"] == "tool_result" {
                                    let id = b["tool_use_id"].as_str().unwrap_or("?").to_string();
                                    let mut g = live.lock().unwrap();
                                    if let Some(a) = g.remove(&id) {
                                        eprintln!("[{dt:7.3}] ROW CLOSE  {} after {:.3}s wall, \
                                                   {} intermediate update(s)",
                                                  a.tool_name, dt - a.started_at, a.updates);
                                    }
                                }
                            }
                        }
                    }
                    "system" => eprintln!("[{dt:7.3}] system/{}", msg["subtype"]),
                    _ => {}
                }
                let _ = tx.send(msg);
            }
            eprintln!("[reader] stdout EOF");
        });
    }

    write_line(&stdin, &json!({
        "type": "control_request", "request_id": "req_init",
        "request": { "subtype": "initialize", "hooks": {} }
    }));
    let _ = wait_for(&rx, |m| m["type"] == "control_response", Duration::from_secs(30));

    // ~70 s of real tool time: 14 iterations x 5 s. Long enough that a 30 s cadence,
    // if one exists, must fire twice — one firing could be an artifact, two is a cadence.
    let t = Instant::now();
    send_user(&stdin, "Use the Bash tool ONCE to run exactly this command in the foreground \
                       (do not background it, do not split it up), passing timeout 200000: \
                       for i in $(seq 1 14); do echo tick-$i; sleep 5; done   \
                       -- then reply with just: LONGTOOL-OK");
    let r = wait_for(&rx, |m| m["type"] == "result", Duration::from_secs(300));
    let ms = t.elapsed().as_secs_f64() * 1000.0;
    match &r {
        Some(m) => eprintln!("[turn] {ms:.0}ms subtype={} stop_reason={} terminal={} result={}",
                             m["subtype"], m["stop_reason"], m["terminal_reason"], m["result"]),
        None => eprintln!("[turn] {ms:.0}ms NO RESULT (timeout)"),
    }

    drop(stdin);
    std::thread::sleep(Duration::from_secs(2));
    let _ = child.kill();
    let _ = child.wait();

    let c = cap.lock().unwrap();
    let mut raw = String::new();
    for (_, l) in &c.lines {
        raw.push_str(l);
        raw.push('\n');
    }
    std::fs::write(format!("{out_dir}/run16-rust-longtool.jsonl"), raw).expect("write raw");
    let mut timings = String::from("offset_s\ttype\tsubtype\n");
    for (dt, l) in &c.lines {
        if let Ok(v) = serde_json::from_str::<Value>(l) {
            let sub = if v["type"] == "stream_event" {
                v["event"]["type"].as_str().unwrap_or("").to_string()
            } else if v["type"] == "control_request" {
                v["request"]["subtype"].as_str().unwrap_or("").to_string()
            } else {
                v["subtype"].as_str().unwrap_or("").to_string()
            };
            timings.push_str(&format!("{dt:.3}\t{}\t{sub}\n", v["type"].as_str().unwrap_or("?")));
        }
    }
    std::fs::write(format!("{out_dir}/run16-rust-longtool.timings.tsv"), timings).expect("write timings");
    eprintln!("captured {} lines", c.lines.len());
}

fn write_line(stdin: &Arc<Mutex<ChildStdin>>, msg: &Value) {
    let mut line = serde_json::to_string(msg).unwrap();
    line.push('\n');
    let mut g = stdin.lock().unwrap();
    let _ = g.write_all(line.as_bytes());
    let _ = g.flush();
}

fn send_user(stdin: &Arc<Mutex<ChildStdin>>, text: &str) {
    eprintln!(">> {}", &text[..text.len().min(70)]);
    write_line(stdin, &json!({
        "type": "user",
        "message": { "role": "user", "content": [{ "type": "text", "text": text }] }
    }));
}

fn wait_for(rx: &Receiver<Value>, pred: impl Fn(&Value) -> bool, budget: Duration) -> Option<Value> {
    let deadline = Instant::now() + budget;
    loop {
        let remaining = deadline.checked_duration_since(Instant::now())?;
        match rx.recv_timeout(remaining) {
            Ok(m) => {
                if pred(&m) {
                    return Some(m);
                }
            }
            Err(_) => return None,
        }
    }
}
