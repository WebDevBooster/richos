//! **A RECORDED REAL CLAUDE SESSION, PLAYED BACK AS THE CHILD** (T3 idea 2; richos-hq
//! `docs/plans/2026-10-09-automatic-second-review-and-t3-ideas.md` §3 and §4 row 6).
//!
//! `richos-replay` stands where `claude` stands: the real [`crate::native::NativeClient`] spawns
//! it, writes to its stdin and reads its stdout exactly as it does the provider's. What it
//! writes back is a capture of a real `claude` session, frame for frame, at the recorded
//! spacing. So a test of the work host runs the real client over the provider's real wire, not
//! over a fake written by the person who wrote the code under test: the six "a command finished
//! after the turn ended" defects of 2026-09 and 2026-10 were each found on a real run, never by
//! the hand-written fakes.
//!
//! # The capture
//!
//! JSON lines, the shape `capture.py` wrote on 2026-09-27 (richos-hq
//! `docs/verification/2026-09-27-background-command-finish/`):
//!
//! - `{"t": 0.0, "sent": {...}}` — a line the recorder wrote to `claude`'s stdin;
//! - `{"t": 2.667, "frame": {...}}` — a line `claude` wrote to its stdout;
//! - `{"t": 18.2, "exit": 0, ...}` — the end, ignored here.
//!
//! A `sent` line may carry `"expect": {"contains": "<words>"}`: the message the host sends in
//! its place must contain those words, so a host that asks something else at that point is a
//! divergence and not a silent match on its type.
//!
//! # How it plays
//!
//! The frames between two sends are what the provider wrote after the first and before the
//! second. When the host's message arrives that stands for send `k`, the frames recorded after
//! send `k` are written at their recorded distance from it, divided by `--speed`. A message
//! that arrives while frames recorded BEFORE it are still due waits for them: the provider read
//! it at that point of its own stream in the recording, and the replay keeps that order. The
//! wait is written to the transcript (`held`).
//!
//! The ids the host chose replace the recorded ones everywhere in what is written: the session
//! id (`--session-id`), each message's `uuid` (the `command_uuid` its `command_lifecycle`
//! frames name), and the `request_id` of a control request it sent. The `initialize` reply was
//! never recorded (it carries the account) and is answered with a bare success.
//!
//! # What it refuses
//!
//! A message that is not the next recorded send (another type, another control subtype, a
//! user message without the `expect` words), or any message after the recording has run out,
//! is a **divergence**: written to the transcript and stderr, and the child exits 3. A replay
//! never invents what the provider would have said.

use serde_json::{json, Value};
use std::io::{BufRead, Write};
use std::sync::mpsc;
use std::time::{Duration, Instant};

/// One line the provider wrote, `at` seconds into the recording.
#[derive(Clone, Debug, PartialEq)]
pub struct Frame {
    pub at: f64,
    pub value: Value,
}

/// One line the recorder wrote, and everything the provider wrote after it and before the next.
#[derive(Clone, Debug, PartialEq)]
pub struct Send {
    pub at: f64,
    pub message: Value,
    /// Words the host's message must contain to stand for this one (user messages only).
    pub expect: Option<String>,
    pub frames: Vec<Frame>,
}

/// A parsed capture.
#[derive(Clone, Debug, PartialEq)]
pub struct Capture {
    /// Frames before the first send (a recording normally has none).
    pub opening: Vec<Frame>,
    pub sends: Vec<Send>,
}

/// Parse a capture's text. A line that is neither `sent` nor `frame` (the closing `exit`) is
/// skipped; a line that is not JSON is an error, because a fixture nobody can read is no proof.
pub fn parse(text: &str) -> Result<Capture, String> {
    let mut capture = Capture { opening: Vec::new(), sends: Vec::new() };
    for (n, line) in text.lines().enumerate() {
        if line.trim().is_empty() {
            continue;
        }
        let row: Value = serde_json::from_str(line).map_err(|e| format!("line {}: {e}", n + 1))?;
        let at = row.get("t").and_then(Value::as_f64).ok_or_else(|| format!("line {}: no \"t\"", n + 1))?;
        if let Some(message) = row.get("sent") {
            let expect = row.pointer("/expect/contains").and_then(Value::as_str).map(str::to_string);
            capture.sends.push(Send { at, message: message.clone(), expect, frames: Vec::new() });
        } else if let Some(frame) = row.get("frame") {
            let frame = Frame { at, value: frame.clone() };
            match capture.sends.last_mut() {
                Some(send) => send.frames.push(frame),
                None => capture.opening.push(frame),
            }
        }
    }
    if capture.sends.is_empty() {
        return Err("the capture has no sent line".into());
    }
    // **An answer belongs to its question, wherever the recorder's next line fell.** A recorder
    // that wrote `initialize` and the first message back to back (capture.py did) puts the
    // `initialize` reply after the message, but the host sends nothing until that reply comes:
    // played in line order, the two would wait on each other for ever.
    for k in 1..capture.sends.len() {
        let mut stay = Vec::new();
        for frame in std::mem::take(&mut capture.sends[k].frames) {
            match answered_request(&capture.sends[..k], &frame.value) {
                Some(j) => capture.sends[j].frames.push(frame),
                None => stay.push(frame),
            }
        }
        capture.sends[k].frames = stay;
    }
    for send in &mut capture.sends {
        send.frames.sort_by(|a, b| a.at.total_cmp(&b.at));
    }
    Ok(capture)
}

/// The earlier recorded control request `frame` answers, if it is a control response to one: by
/// its `request_id`, or, for the redacted `initialize` reply, the `initialize` request.
fn answered_request(earlier: &[Send], frame: &Value) -> Option<usize> {
    if frame.get("type").and_then(Value::as_str) != Some("control_response") {
        return None;
    }
    let is_request = |s: &Send| s.message.get("type").and_then(Value::as_str) == Some("control_request");
    if frame.get("redacted").is_some() {
        return earlier.iter().rposition(|s| is_request(s) && s.message.pointer("/request/subtype") == Some(&json!("initialize")));
    }
    let id = frame.pointer("/response/request_id")?;
    earlier.iter().rposition(|s| is_request(s) && s.message.get("request_id") == Some(id))
}

/// The words of a user message: its `content` string, or its text blocks joined.
pub fn text_of(message: &Value) -> String {
    match message.pointer("/message/content") {
        Some(Value::String(text)) => text.clone(),
        Some(Value::Array(blocks)) => blocks
            .iter()
            .filter_map(|b| b.get("text").and_then(Value::as_str))
            .collect::<Vec<_>>()
            .join("\n"),
        _ => String::new(),
    }
}

fn kind_of(message: &Value) -> String {
    let ty = message.get("type").and_then(Value::as_str).unwrap_or("?");
    let sub = message
        .pointer("/request/subtype")
        .or_else(|| message.pointer("/response/subtype"))
        .or_else(|| message.get("subtype"))
        .or_else(|| message.get("state"))
        .and_then(Value::as_str);
    match sub {
        Some(sub) => format!("{ty}/{sub}"),
        None => ty.to_string(),
    }
}

/// Does `received` stand for the recorded `send`? `Err` says how it differs.
pub fn matches(send: &Send, received: &Value) -> Result<(), String> {
    let (want, got) = (kind_of(&send.message), kind_of(received));
    let ty = send.message.get("type").and_then(Value::as_str).unwrap_or("");
    if received.get("type").and_then(Value::as_str) != Some(ty) {
        return Err(format!("expected {want}, received {got}"));
    }
    match ty {
        "control_request" if send.message.pointer("/request/subtype") != received.pointer("/request/subtype") => {
            Err(format!("expected {want}, received {got}"))
        }
        // An answer to a request the PROVIDER made: the id is the recording's own, never remapped.
        "control_response"
            if send.message.pointer("/response/request_id") != received.pointer("/response/request_id") =>
        {
            Err(format!(
                "expected the answer to {}, received the answer to {}",
                send.message.pointer("/response/request_id").unwrap_or(&Value::Null),
                received.pointer("/response/request_id").unwrap_or(&Value::Null)
            ))
        }
        "user" => match &send.expect {
            Some(words) if !text_of(received).contains(words.as_str()) => {
                Err(format!("expected a user message containing {words:?}"))
            }
            _ => Ok(()),
        },
        _ => Ok(()),
    }
}

/// Recorded id -> the host's, applied to every string of a frame.
#[derive(Default)]
struct Ids(Vec<(String, String)>);

impl Ids {
    fn learn(&mut self, recorded: Option<&str>, ours: Option<&str>) {
        if let (Some(recorded), Some(ours)) = (recorded, ours) {
            if !recorded.is_empty() && recorded != ours {
                self.0.push((recorded.to_string(), ours.to_string()));
            }
        }
    }
    fn apply(&self, value: &mut Value) {
        match value {
            Value::String(s) => {
                for (recorded, ours) in &self.0 {
                    if s.contains(recorded.as_str()) {
                        *s = s.replace(recorded.as_str(), ours);
                    }
                }
            }
            Value::Array(items) => items.iter_mut().for_each(|v| self.apply(v)),
            Value::Object(map) => map.values_mut().for_each(|v| self.apply(v)),
            _ => {}
        }
    }
}

/// What the child writes for one recorded frame, given the message that triggered its segment.
fn render(frame: &Value, trigger: Option<&Value>, ids: &Ids) -> Value {
    let mut out = frame.clone();
    if frame.get("type").and_then(Value::as_str) == Some("control_response") {
        let request = trigger.filter(|t| t.get("type").and_then(Value::as_str) == Some("control_request"));
        if let Some(request) = request {
            let id = request.get("request_id").cloned().unwrap_or(Value::Null);
            if frame.get("redacted").is_some() {
                // The `initialize` reply carries the account and was never recorded.
                return json!({"type": "control_response",
                              "response": {"subtype": "success", "request_id": id, "response": {}}});
            }
            if let Some(response) = out.get_mut("response").and_then(Value::as_object_mut) {
                response.insert("request_id".into(), id);
            }
            return out;
        }
    }
    ids.apply(&mut out);
    out
}

/// The command line: `--capture FILE [--speed X] [--transcript FILE] [--] <claude's own flags>`.
/// Of `claude`'s flags only `--session-id` is read.
#[derive(Debug, PartialEq)]
pub struct Options {
    pub capture: std::path::PathBuf,
    pub speed: f64,
    pub transcript: Option<std::path::PathBuf>,
    pub session_id: Option<String>,
}

pub fn options(args: &[String]) -> Result<Options, String> {
    let (mut capture, mut speed, mut transcript, mut session_id) = (None, 1.0, None, None);
    let mut i = 0;
    let mut ours = true;
    while i < args.len() {
        let next = || args.get(i + 1).cloned().ok_or_else(|| format!("{} needs a value", args[i]));
        match args[i].as_str() {
            "--" if ours => ours = false,
            "--capture" if ours => { capture = Some(next()?.into()); i += 1; }
            "--speed" if ours => {
                speed = next()?.parse::<f64>().map_err(|e| format!("--speed: {e}"))?;
                i += 1;
            }
            "--transcript" if ours => { transcript = Some(next()?.into()); i += 1; }
            "--session-id" => { session_id = Some(next()?); i += 1; }
            _ => {}
        }
        i += 1;
    }
    if !(speed.is_finite() && speed > 0.0) {
        return Err("--speed must be a positive number".into());
    }
    Ok(Options { capture: capture.ok_or("--capture FILE is required")?, speed, transcript, session_id })
}

struct Transcript {
    out: Option<std::fs::File>,
    began: Instant,
}

impl Transcript {
    fn note(&mut self, mut event: Value) {
        if let (Some(out), Some(map)) = (self.out.as_mut(), event.as_object_mut()) {
            map.insert("ms".into(), json!(self.began.elapsed().as_millis() as u64));
            // A transcript that cannot be written is said on stderr; the replay goes on.
            if let Err(e) = writeln!(out, "{event}").and_then(|_| out.flush()) {
                eprintln!("[richos-replay] transcript: {e}");
            }
        }
    }
}

/// Run the child. Exit 0 when the host closes its input, 2 when the capture cannot be read, 3 on
/// a divergence.
pub fn run(args: Vec<String>) -> i32 {
    let options = match options(&args) {
        Ok(o) => o,
        Err(e) => {
            eprintln!("[richos-replay] {e}");
            return 2;
        }
    };
    let capture = match std::fs::read_to_string(&options.capture).map_err(|e| e.to_string()).and_then(|t| parse(&t)) {
        Ok(c) => c,
        Err(e) => {
            eprintln!("[richos-replay] {}: {e}", options.capture.display());
            return 2;
        }
    };
    let began = Instant::now();
    let out = match &options.transcript {
        Some(path) => match std::fs::File::create(path) {
            Ok(f) => Some(f),
            Err(e) => {
                eprintln!("[richos-replay] {}: {e}", path.display());
                return 2;
            }
        },
        None => None,
    };
    let mut transcript = Transcript { out, began };
    let mut ids = Ids::default();
    let recorded_session = capture
        .sends
        .iter()
        .flat_map(|s| s.frames.iter())
        .chain(capture.opening.iter())
        .find_map(|f| f.value.get("session_id").and_then(Value::as_str).map(str::to_string));
    ids.learn(recorded_session.as_deref(), options.session_id.as_deref());

    let (tx, rx) = mpsc::channel::<Option<String>>();
    std::thread::spawn(move || {
        let stdin = std::io::stdin();
        for line in stdin.lock().lines().map_while(Result::ok) {
            if tx.send(Some(line)).is_err() {
                return;
            }
        }
        // A closed receiver means the replay has already ended; there is no one left to tell.
        drop(tx.send(None));
    });

    let stdout = std::io::stdout();
    // Frames due, in recorded order: (when, frame, the message that triggered its segment).
    let mut due: std::collections::VecDeque<(Instant, Value, Option<Value>)> = capture
        .opening
        .iter()
        .map(|f| (began + Duration::from_secs_f64(f.at.max(0.0) / options.speed), f.value.clone(), None))
        .collect();
    let mut waiting: std::collections::VecDeque<(Instant, Value)> = std::collections::VecDeque::new();
    let mut next = 0usize;
    let mut emitted = 0usize;
    loop {
        let now = Instant::now();
        while due.front().is_some_and(|(at, _, _)| *at <= now) {
            let (_, frame, trigger) = due.pop_front().expect("checked above");
            let line = render(&frame, trigger.as_ref(), &ids);
            let mut lock = stdout.lock();
            if writeln!(lock, "{line}").and_then(|_| lock.flush()).is_err() {
                transcript.note(json!({"event": "host-gone"}));
                return 0;
            }
            drop(lock);
            transcript.note(json!({"event": "emitted", "index": emitted, "kind": kind_of(&line)}));
            emitted += 1;
        }
        if due.is_empty() {
            if let Some((arrived, message)) = waiting.pop_front() {
                let Some(send) = capture.sends.get(next) else {
                    return diverge(&mut transcript, &message, "the recording has no more sends");
                };
                if let Err(why) = matches(send, &message) {
                    return diverge(&mut transcript, &message, &format!("at send {next}: {why}"));
                }
                ids.learn(send.message.get("uuid").and_then(Value::as_str), message.get("uuid").and_then(Value::as_str));
                let start = Instant::now();
                let held = start.duration_since(arrived).as_millis() as u64;
                transcript.note(json!({"event": "matched", "send": next, "held_ms": held}));
                for frame in &send.frames {
                    let after = ((frame.at - send.at).max(0.0)) / options.speed;
                    due.push_back((start + Duration::from_secs_f64(after), frame.value.clone(), Some(message.clone())));
                }
                next += 1;
                continue;
            }
        }
        let wait = due.front().map(|(at, _, _)| at.saturating_duration_since(Instant::now())).unwrap_or(Duration::from_secs(3600));
        match rx.recv_timeout(wait) {
            Ok(Some(line)) => {
                let Ok(message) = serde_json::from_str::<Value>(line.trim()) else { continue };
                transcript.note(json!({"event": "received", "kind": kind_of(&message), "text": text_of(&message)}));
                waiting.push_back((Instant::now(), message));
            }
            Ok(None) | Err(mpsc::RecvTimeoutError::Disconnected) => {
                transcript.note(json!({"event": "end-of-input", "sends_matched": next, "sends_recorded": capture.sends.len()}));
                return 0;
            }
            Err(mpsc::RecvTimeoutError::Timeout) => {}
        }
    }
}

fn diverge(transcript: &mut Transcript, message: &Value, why: &str) -> i32 {
    eprintln!("[richos-replay] DIVERGED: {why}");
    transcript.note(json!({"event": "divergence", "why": why, "kind": kind_of(message), "text": text_of(message)}));
    3
}

#[cfg(test)]
mod tests {
    use super::*;

    const CAPTURE: &str = r#"{"t": 0.0, "sent": {"type": "control_request", "request_id": "init_1", "request": {"subtype": "initialize"}}}
{"t": 0.0, "sent": {"type": "user", "uuid": "rec-u1", "message": {"role": "user", "content": "start it"}}}
{"t": 0.4, "frame": {"type": "control_response", "redacted": "initialize reply not recorded (account details)"}}
{"t": 0.5, "frame": {"type": "command_lifecycle", "command_uuid": "rec-u1", "state": "started", "session_id": "rec-s"}}
{"t": 5.0, "frame": {"type": "result", "session_id": "rec-s"}}
{"t": 9.0, "sent": {"type": "user", "uuid": "rec-u2", "message": {"role": "user", "content": "it has ended; report"}}, "expect": {"contains": "has ended"}}
{"t": 9.1, "frame": {"type": "command_lifecycle", "command_uuid": "rec-u2", "state": "queued", "session_id": "rec-s"}}
{"t": 12.0, "exit": 0, "results": 2}
"#;

    #[test]
    fn a_capture_is_cut_at_each_send_and_its_expectation_is_kept() {
        let capture = parse(CAPTURE).unwrap();
        assert!(capture.opening.is_empty());
        assert_eq!(capture.sends.len(), 3);
        // The `initialize` reply follows the first message in the file, and is still its answer:
        // the host sends nothing else until it has it.
        assert_eq!(capture.sends[0].frames.iter().map(|f| f.at).collect::<Vec<_>>(), [0.4]);
        assert_eq!(capture.sends[1].frames.iter().map(|f| f.at).collect::<Vec<_>>(), [0.5, 5.0]);
        assert_eq!(capture.sends[2].expect.as_deref(), Some("has ended"));
        assert!(parse("not json\n").is_err(), "a fixture nobody can read is refused");
        assert!(parse(r#"{"t": 1.0, "frame": {"type": "result"}}"#).is_err(), "a capture with no send is refused");
    }

    #[test]
    fn the_host_message_must_be_the_next_recorded_one() {
        let capture = parse(CAPTURE).unwrap();
        let init = json!({"type": "control_request", "request_id": "req_init", "request": {"subtype": "initialize", "hooks": {}}});
        assert!(matches(&capture.sends[0], &init).is_ok());
        let interrupt = json!({"type": "control_request", "request_id": "x", "request": {"subtype": "interrupt"}});
        assert!(matches(&capture.sends[0], &interrupt).is_err(), "another control subtype is a divergence");
        let user = |text: &str| json!({"type": "user", "uuid": "u", "message": {"content": [{"type": "text", "text": text}]}});
        assert!(matches(&capture.sends[1], &user("anything")).is_ok(), "no expectation: the type decides");
        assert!(matches(&capture.sends[1], &init).is_err());
        assert!(matches(&capture.sends[2], &user("What you started has ended — report")).is_ok());
        assert_eq!(
            matches(&capture.sends[2], &user("Prepare the Northwind summary")),
            Err("expected a user message containing \"has ended\"".into()),
            "a user message in the wrong place is not a match on its type"
        );
    }

    #[test]
    fn the_host_ids_replace_the_recorded_ones_and_the_initialize_reply_is_bare() {
        let mut ids = Ids::default();
        ids.learn(Some("rec-s"), Some("our-session"));
        ids.learn(Some("rec-u1"), Some("our-uuid"));
        let frame = json!({"type": "command_lifecycle", "command_uuid": "rec-u1", "session_id": "rec-s",
                           "path": "/tmp/rec-s/tasks/b1.output"});
        assert_eq!(
            render(&frame, None, &ids),
            json!({"type": "command_lifecycle", "command_uuid": "our-uuid", "session_id": "our-session",
                   "path": "/tmp/our-session/tasks/b1.output"})
        );
        let init = json!({"type": "control_request", "request_id": "req_init", "request": {"subtype": "initialize"}});
        let redacted = json!({"type": "control_response", "redacted": "initialize reply not recorded (account details)"});
        assert_eq!(
            render(&redacted, Some(&init), &ids),
            json!({"type": "control_response", "response": {"subtype": "success", "request_id": "req_init", "response": {}}}),
            "nothing of an account is ever written back"
        );
    }

    #[test]
    fn the_options_take_claudes_session_id_and_refuse_a_bad_speed() {
        let args: Vec<String> = ["--capture", "c.jsonl", "--speed", "4", "--", "--print", "--session-id", "abc", "--verbose"]
            .iter().map(|s| s.to_string()).collect();
        assert_eq!(options(&args).unwrap(), Options {
            capture: "c.jsonl".into(), speed: 4.0, transcript: None, session_id: Some("abc".into()),
        });
        let bad: Vec<String> = ["--capture", "c", "--speed", "0"].iter().map(|s| s.to_string()).collect();
        assert!(options(&bad).is_err());
        assert!(options(&[]).is_err(), "no capture, no replay");
    }
}
