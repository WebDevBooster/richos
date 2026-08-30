//! BETWEEN-TURN TRAFFIC AGAINST A REAL CHILD PROCESS — techy-mode design §1.5, gap #1.
//!
//! *"`acp.rs:150` delivers an update only if `current_prompt` is `Some`. Anything the
//! adapter emits at session start or between turns — `available_commands_update` is the
//! obvious candidate — hits no sink at all."*
//!
//! These do not mock `AcpClient`. They spawn a real child over real stdio and drive the
//! real reader thread, real `dispatch`, real between-turn buffer, following
//! `acp_cancel_tests.rs`'s POSIX-`sh` fake adapter exactly — so nothing here needs Claude,
//! a network, Node, or the `claude-agent-acp` binary.
//!
//! The adapter emits its `available_commands_update` at TWO moments the real one was
//! measured emitting it (probe 2026-08-28, `docs/verification/acp-emission-probe-2026-08-28.md`
//! §4.2): once at session start, and once after the `session/prompt` response has already
//! been returned. Both are moments when `current_prompt` is `None`, which is the whole
//! point — before this change both hit no sink at all.
//!
//! ## Why these poll instead of sleeping a fixed time
//! The trailing notifications are written by the child AFTER the response that unblocks
//! `prompt`, so the reader thread may not have consumed them when `prompt` returns. A fixed
//! sleep would be either flaky or slow. `wait_for` polls to a deadline and FAILS with what
//! it actually saw, so a real regression reads as a regression rather than as a timeout.

use richos_core::acp::AcpClient;
use richos_core::cognition::TurnItem;
use richos_core::machinery::MachineryRecord;
use std::io::Write;
use std::path::PathBuf;
use std::time::{Duration, Instant};

/// A fake ACP adapter in POSIX sh that emits SessionMeta traffic where no turn is running.
///
/// The `case` patterns match the exact bytes `AcpClient` writes: `serde_json` serializes a
/// `json!` object through a `BTreeMap`, so keys come out alphabetically and
/// `"method":"session/prompt"` is a stable substring rather than a hopeful one.
fn fake_adapter(tag: &str) -> PathBuf {
    let path = std::env::temp_dir().join(format!(
        "richos-between-acp-{tag}-{}-{}.sh",
        std::process::id(),
        richos_core::util::now_millis()
    ));
    let script = r#"#!/bin/sh
while IFS= read -r line; do
  case "$line" in
    *'"method":"initialize"'*)
      id=`printf '%s' "$line" | sed -n 's/.*"id":\([0-9]*\).*/\1/p'`
      printf '{"jsonrpc":"2.0","id":%s,"result":{"protocolVersion":1}}\n' "$id"
      ;;
    *'"method":"session/new"'*)
      id=`printf '%s' "$line" | sed -n 's/.*"id":\([0-9]*\).*/\1/p'`
      printf '{"jsonrpc":"2.0","id":%s,"result":{"sessionId":"sess-fake"}}\n' "$id"
      # SESSION-START TRAFFIC. No prompt has been sent, so `current_prompt` is None.
      printf '{"jsonrpc":"2.0","method":"session/update","params":{"update":{"availableCommands":["compact"],"sessionUpdate":"available_commands_update"}}}\n'
      ;;
    *'"method":"session/prompt"'*)
      id=`printf '%s' "$line" | sed -n 's/.*"id":\([0-9]*\).*/\1/p'`
      printf '{"jsonrpc":"2.0","method":"session/update","params":{"update":{"content":{"text":"answer"},"sessionUpdate":"agent_message_chunk"}}}\n'
      printf '{"jsonrpc":"2.0","method":"session/update","params":{"update":{"sessionUpdate":"usage_update","used":30477,"size":1000000}}}\n'
      printf '{"jsonrpc":"2.0","id":%s,"result":{"stopReason":"end_turn"}}\n' "$id"
      # BETWEEN-TURN TRAFFIC: after the response, so `current_prompt` is None again.
      # The commands repeat VERBATIM, exactly as the measured adapter repeats them.
      printf '{"jsonrpc":"2.0","method":"session/update","params":{"update":{"availableCommands":["compact"],"sessionUpdate":"available_commands_update"}}}\n'
      printf '{"jsonrpc":"2.0","method":"session/update","params":{"update":{"sessionUpdate":"session_info_update","title":"a thread"}}}\n'
      ;;
  esac
done
"#;
    let mut f = std::fs::File::create(&path).unwrap();
    f.write_all(script.as_bytes()).unwrap();
    drop(f);
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o755)).unwrap();
    }
    path
}

fn connect(script: &PathBuf) -> (AcpClient, String) {
    let client =
        AcpClient::spawn(std::path::Path::new("/bin/sh"), &[script.to_string_lossy().to_string()])
            .unwrap();
    client.initialize().unwrap();
    let session = client.new_session(std::path::Path::new("/tmp")).unwrap();
    (client, session)
}

/// Poll `f` until it returns `Some`, or fail with `what` after 5 seconds.
fn wait_for<T>(what: &str, mut f: impl FnMut() -> Option<T>) -> T {
    let deadline = Instant::now() + Duration::from_secs(5);
    loop {
        if let Some(v) = f() {
            return v;
        }
        if Instant::now() > deadline {
            panic!("timed out waiting for {what}");
        }
        std::thread::sleep(Duration::from_millis(10));
    }
}

#[test]
fn session_start_traffic_reaches_the_lane_instead_of_no_sink_at_all() {
    let script = fake_adapter("start");
    let (client, session) = connect(&script);

    // No prompt has ever been sent on this client. Before §1.5's fix there was, by
    // construction, nowhere for this update to be — `current_prompt` is None and the only
    // sink lived inside it.
    let records: Vec<MachineryRecord> = wait_for("the session-start update", || {
        let r = client.drain_between_turn(&session);
        (!r.is_empty()).then_some(r)
    });

    assert_eq!(records.len(), 1, "one update was emitted at session start");
    assert_eq!(records[0].title, "available_commands_update");
    // §1.4 G4 — the record attaches to the THREAD, not to a turn, because there is no turn
    // it belongs to. Inventing one would be a false attribution.
    assert_eq!(records[0].turn_id, None);
    assert_eq!(records[0].session_id, session, "which lease said it stays reconstructible");
    // Retained verbatim (§1.4 G5): the payload is the wire object, not a summary of it.
    assert_eq!(
        records[0].payload.as_ref().unwrap()["availableCommands"],
        serde_json::json!(["compact"])
    );
    let _ = std::fs::remove_file(&script);
}

#[test]
fn traffic_after_the_prompt_response_lands_in_the_lane_and_not_in_the_finished_turn() {
    let script = fake_adapter("after");
    let (client, session) = connect(&script);
    // Take the session-start record out of the way so this test is about the OTHER moment.
    wait_for("the session-start update", || {
        let r = client.drain_between_turn(&session);
        (!r.is_empty()).then_some(r)
    });

    // Run a real turn. THE IN-TURN PATH IS UNCHANGED: text still arrives as `Text`, the
    // `usage_update` still arrives as in-turn machinery on the shared counter.
    let mut text = String::new();
    let mut in_turn: Vec<(u64, String)> = Vec::new();
    let stop = client
        .prompt(&session, "hello", &mut |item| match item {
            TurnItem::Text { text: t, .. } => text.push_str(t),
            TurnItem::Machinery(m) => in_turn.push((m.seq, m.title.clone())),
        })
        .unwrap();
    assert_eq!(stop, "end_turn");
    assert_eq!(text, "answer");
    assert_eq!(in_turn, vec![(1, "usage_update".to_string())], "in-turn routing is untouched");
    // Every in-turn record still carries its turn: `prompt` hands them to the spine, which
    // stamps the turn id. The lane's records are the ones that cannot.

    let records = wait_for("the post-response updates", || {
        let r = client.drain_between_turn(&session);
        (r.len() >= 1).then_some(r)
    });

    // The repeated `available_commands_update` is byte-identical to the session-start one,
    // so §1.5's `last_session_meta` slot suppresses it and only `session_info_update`
    // survives — §1.2's "last value wins", doing the work that bounds a long session.
    let titles: Vec<&str> = records.iter().map(|r| r.title.as_str()).collect();
    assert_eq!(titles, vec!["session_info_update"], "got {titles:?}");
    assert_eq!(client.suppressed_between_turn_repeats(), 1);
    assert!(records.iter().all(|r| r.turn_id.is_none()));
    // Its own counter, continuing from the session-start record rather than restarting.
    assert_eq!(records[0].seq, 1);
    let _ = std::fs::remove_file(&script);
}

#[test]
fn a_drained_lane_is_empty_and_stays_empty() {
    // The honest empty state at its source: a lane that has been drained reports nothing,
    // and "nothing" here means the adapter said nothing since — never that the channel is
    // broken. The renderer's version of this sentence is checked in `app/ui/tests`.
    let script = fake_adapter("empty");
    let (client, session) = connect(&script);
    wait_for("the session-start update", || {
        let r = client.drain_between_turn(&session);
        (!r.is_empty()).then_some(r)
    });
    assert!(client.drain_between_turn(&session).is_empty());
    assert!(client.drain_between_turn(&session).is_empty());
    let _ = std::fs::remove_file(&script);
}
