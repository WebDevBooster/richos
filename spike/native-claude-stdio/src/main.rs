//! SPIKE PROBE — drive the NATIVE `claude` binary's stream-json stdio from Rust.
//!
//! The question this exists to answer: can `app/acp-adapter`'s single npm package,
//! `@agentclientprotocol/claude-agent-acp`, be deleted — i.e. can Rust speak directly to
//! the native `claude` binary instead of to a Node ACP adapter?
//!
//! The transport is the SAME SHAPE `acp.rs` already speaks: newline-delimited JSON over
//! the child's stdio, one reader thread, an mpsc into the turn loop. Only the message
//! vocabulary differs. So this probe is deliberately written to mirror `acp.rs`'s
//! structure (spawn -> reader thread -> dispatch -> per-turn channel), because "the
//! structure ports" is half of what is being tested.
//!
//! It exercises, in one process, the four things `acp.rs` needs and records raw JSONL:
//!   1. control `initialize`     — the handshake, and what the agent advertises
//!   2. turn + tool + permission — streamed text, `tool_use`/`tool_result`, and the
//!                                 `can_use_tool` control request auto-allowed with
//!                                 EXACTLY acp.rs's in-harness policy (first allow option)
//!   3. a second turn            — session continuity on ONE long-lived process
//!   4. interrupt mid-turn       — cancellation, and whether the lease survives it
//!
//! NOT SHIPPED. Not a workspace member. Nothing here is a port; it is evidence.

use serde_json::{json, Value};
use std::io::{BufRead, BufReader, Write};
use std::process::{ChildStdin, Command, Stdio};
use std::sync::mpsc::{channel, Receiver, Sender};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

/// Every line the child wrote, in order, plus the offset at which we read it. The offsets
/// are the measurement: an interrupt claim is worth nothing without the two timestamps it
/// is the difference of.
struct Capture {
    t0: Instant,
    lines: Vec<(f64, String)>,
}

fn main() {
    let out_dir = std::env::args().nth(1).expect("usage: probe <out_dir>");
    let cwd = std::env::args().nth(2).expect("usage: probe <out_dir> <child_cwd>");

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
    let (tx, rx): (Sender<Value>, Receiver<Value>) = channel();

    // The reader thread, structurally identical to `acp.rs`'s: one blocking line loop,
    // parse, hand to a dispatcher. The auto-allow answer is written from THIS thread for
    // the same reason acp.rs answers `session/request_permission` from its reader thread —
    // the child is blocked on it, and a record is never worth a millisecond of turn latency.
    {
        let cap = Arc::clone(&cap);
        let stdin = Arc::clone(&stdin);
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
                if msg["type"] == "control_request"
                    && msg["request"]["subtype"] == "can_use_tool"
                {
                    // acp.rs's policy verbatim: auto-approve, record nothing else.
                    let resp = json!({
                        "type": "control_response",
                        "response": {
                            "subtype": "success",
                            "request_id": msg["request_id"],
                            "response": { "behavior": "allow",
                                          "updatedInput": msg["request"]["input"] }
                        }
                    });
                    write_line(&stdin, &resp);
                    eprintln!("[{dt:6.3}] << can_use_tool {} -> ALLOW",
                              msg["request"]["tool_name"]);
                }
                let _ = tx.send(msg);
            }
            eprintln!("[reader] stdout EOF");
        });
    }

    // ---- 1. control initialize -------------------------------------------------------
    write_line(&stdin, &json!({
        "type": "control_request", "request_id": "req_init",
        "request": { "subtype": "initialize", "hooks": {} }
    }));
    let init = wait_for(&rx, |m| m["type"] == "control_response", Duration::from_secs(30));
    let init_ms = elapsed_ms(&cap);
    match &init {
        Some(m) => {
            let r = &m["response"]["response"];
            eprintln!("[{init_ms:7.1}ms] initialize OK: account={} mode={} models={}",
                      r["account"], r["current_permission_mode"],
                      r["models"].as_array().map(|a| a.len()).unwrap_or(0));
        }
        None => eprintln!("initialize TIMED OUT"),
    }

    // ---- 2. turn one: tool call + permission + streamed text --------------------------
    let t = Instant::now();
    send_user(&stdin, "Remember the number 5309. Use the Write tool to create \
                       /private/tmp/claude-501/rust-probe-out.txt containing the word RUSTOK, \
                       then reply with just: TURN1-OK");
    let r1 = wait_for(&rx, |m| m["type"] == "result", Duration::from_secs(180));
    let turn1_ms = t.elapsed().as_secs_f64() * 1000.0;
    report_result("turn1", &r1, turn1_ms);

    // ---- 3. turn two on the SAME process: continuity ----------------------------------
    let t = Instant::now();
    send_user(&stdin, "What number did I ask you to remember? Reply with just the digits.");
    let r2 = wait_for(&rx, |m| m["type"] == "result", Duration::from_secs(180));
    let turn2_ms = t.elapsed().as_secs_f64() * 1000.0;
    report_result("turn2", &r2, turn2_ms);
    let continuity = r2.as_ref()
        .and_then(|m| m["result"].as_str())
        .map(|s| s.contains("5309"))
        .unwrap_or(false);
    eprintln!("CONTINUITY across turns on one process: {}",
              if continuity { "YES (5309 recalled)" } else { "NO" });

    // ---- 4. interrupt mid-turn --------------------------------------------------------
    send_user(&stdin, "Write a 2000-word essay on the history of the second. Start immediately.");
    std::thread::sleep(Duration::from_secs(6));
    let sent_at = Instant::now();
    write_line(&stdin, &json!({
        "type": "control_request", "request_id": "req_int",
        "request": { "subtype": "interrupt" }
    }));
    let ack = wait_for(&rx, |m| m["type"] == "control_response"
        && m["response"]["request_id"] == "req_int", Duration::from_secs(30));
    let ack_ms = sent_at.elapsed().as_secs_f64() * 1000.0;
    let r3 = wait_for(&rx, |m| m["type"] == "result", Duration::from_secs(60));
    let stop_ms = sent_at.elapsed().as_secs_f64() * 1000.0;
    eprintln!("INTERRUPT: ack after {ack_ms:.1}ms ({}), result after {stop_ms:.1}ms",
              if ack.is_some() { "received" } else { "NO ACK" });
    report_result("turn3-interrupted", &r3, stop_ms);

    // Is the lease still usable after a cancel? This is the row the spine cares about:
    // a cancel that kills the process is a cancel that forces a rotation.
    let alive = child.try_wait().ok().flatten().is_none();
    eprintln!("PROCESS ALIVE AFTER INTERRUPT: {alive}");
    let t = Instant::now();
    send_user(&stdin, "Never mind the essay. Reply with just: REUSE-OK");
    let r4 = wait_for(&rx, |m| m["type"] == "result", Duration::from_secs(120));
    report_result("turn4-after-interrupt", &r4, t.elapsed().as_secs_f64() * 1000.0);

    // ---- shut down and write the capture ---------------------------------------------
    drop(stdin);
    std::thread::sleep(Duration::from_secs(2));
    let _ = child.kill();
    let status = child.wait();
    eprintln!("child exit: {status:?}");

    let c = cap.lock().unwrap();
    let mut raw = String::new();
    for (_, l) in &c.lines {
        raw.push_str(l);
        raw.push('\n');
    }
    let path = format!("{out_dir}/run9-rust-driven.jsonl");
    std::fs::write(&path, raw).expect("write raw");
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
    std::fs::write(format!("{out_dir}/run9-rust-driven.timings.tsv"), timings).expect("write timings");
    eprintln!("captured {} lines -> {path}", c.lines.len());
}

fn elapsed_ms(cap: &Arc<Mutex<Capture>>) -> f64 {
    cap.lock().unwrap().t0.elapsed().as_secs_f64() * 1000.0
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

fn report_result(label: &str, r: &Option<Value>, ms: f64) {
    match r {
        Some(m) => eprintln!(
            "[{label}] {ms:.0}ms subtype={} stop_reason={} is_error={} result={} \
             usage.in={} usage.cache_read={} ctxWindow={}",
            m["subtype"], m["stop_reason"], m["is_error"],
            truncate(&m["result"].to_string(), 40),
            m["usage"]["input_tokens"], m["usage"]["cache_read_input_tokens"],
            m["modelUsage"].as_object()
                .and_then(|o| o.values().next())
                .map(|v| v["contextWindow"].clone())
                .unwrap_or(Value::Null)
        ),
        None => eprintln!("[{label}] {ms:.0}ms NO RESULT (timeout)"),
    }
}

fn truncate(s: &str, n: usize) -> String {
    if s.chars().count() <= n { s.to_string() } else { s.chars().take(n).collect::<String>() + "…" }
}
