//! `control_request{interrupt}` AGAINST A REAL CHILD PROCESS — the stop that has to
//! actually reach something (UX §9.3 step 2).
//!
//! **Ported from `acp_cancel_tests.rs` when the ACP adapter was deleted
//! (`wiki/ceo-decisions.md` §16).** Same three tests, same three invariants, same shape:
//! they do not mock `NativeClient`. They spawn a real child over real stdio and drive the
//! real handshake, the real reader thread, real `dispatch`, real drain loop. The child is a
//! POSIX-`sh` fake agent (written to a temp file by the test) so nothing here needs Claude,
//! a network, Node, or the `claude` binary.
//!
//! Two agents, because the two failure modes are different products:
//!   - a COMPLIANT one, which answers the interrupt with a terminal `result` carrying
//!     `terminal_reason: "aborted_streaming"` — the shape measured on the real binary at
//!     `docs/verification/native-claude-stream-json-2026-08-31/raw/run9-rust-driven.jsonl:65`;
//!   - a DEAF one, which ignores the interrupt entirely. RichOS must still stop rendering,
//!     and must say which of the two happened rather than reporting both as a clean cancel.

use richos_core::cognition::TurnItem;
use richos_core::native::{NativeClient, STOP_REASON_CANCELLED, STOP_REASON_CANCEL_UNACKNOWLEDGED};
use richos_core::steering::TurnCancel;
use std::io::Write;
use std::path::PathBuf;

/// A fake native agent in POSIX sh. `comply=true` answers the interrupt; `false` ignores
/// it, which is the whole point of the second test.
///
/// The `case` patterns match the exact bytes `NativeClient` writes: `serde_json` serializes
/// a `json!` object through a `BTreeMap`, so keys come out alphabetically and
/// `"subtype":"interrupt"` is a stable substring rather than a hopeful one.
///
/// The script is spawned DIRECTLY (`NativeClient::spawn` takes a binary and a cwd, not an
/// argv), so it carries its own shebang and is made executable. The real client's flag
/// vector arrives as arguments and `sh` ignores them, which is what makes this a fake of the
/// binary rather than a fake of the protocol.
fn fake_agent(tag: &str, comply: bool) -> PathBuf {
    let path = std::env::temp_dir().join(format!(
        "richos-fake-claude-{tag}-{}-{}.sh",
        std::process::id(),
        richos_core::util::now_millis()
    ));
    let interrupt_arm = if comply {
        r#"      printf '{"type":"result","subtype":"error_during_execution","stop_reason":null,"is_error":true,"terminal_reason":"aborted_streaming"}\n'
"#
    } else {
        "      : # deaf on purpose: this agent ignores the interrupt\n"
    };
    let script = format!(
        r#"#!/bin/sh
while IFS= read -r line; do
  case "$line" in
    *'"subtype":"initialize"'*)
      printf '{{"type":"control_response","response":{{"subtype":"success","request_id":"req_init","response":{{"account":{{"email":"x@y"}}}}}}}}\n'
      ;;
    *'"subtype":"interrupt"'*)
{interrupt_arm}      ;;
    *'"type":"user"'*)
      printf '{{"type":"stream_event","event":{{"type":"message_start","message":{{"id":"msg_1"}}}}}}\n'
      printf '{{"type":"stream_event","event":{{"type":"content_block_delta","index":0,"delta":{{"type":"text_delta","text":"partial answer"}}}}}}\n'
      ;;
  esac
done
"#
    );
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

/// Spawn and hand back the client. The handshake happens inside `spawn` now — it is not
/// optional and it is not a separate step, which is itself the loud-failure guarantee.
fn connect(script: &PathBuf) -> NativeClient {
    match NativeClient::spawn(script, std::path::Path::new("/tmp")) {
        Ok(c) => c,
        Err(e) => panic!("the fake agent should have completed the handshake: {e}"),
    }
}

#[test]
fn a_compliant_agent_ends_the_turn_as_cancelled_and_the_partial_text_survives() {
    let script = fake_agent("comply", true);
    let client = connect(&script);
    let cancel = client.cancel_handle();

    let seen = std::sync::Arc::new(std::sync::Mutex::new(String::new()));
    let seen_w = seen.clone();
    // Press stop shortly after the turn starts, from a DIFFERENT thread — which is the real
    // shape of the problem: the turn owns the spine lock, the stop cannot wait for it.
    let presser = std::thread::spawn(move || {
        std::thread::sleep(std::time::Duration::from_millis(250));
        cancel.cancel()
    });

    let stop = client
        .prompt("take your time", &mut |item| {
            if let TurnItem::Text { text, .. } = item {
                seen_w.lock().unwrap().push_str(text);
            }
        })
        .unwrap();

    assert!(presser.join().unwrap(), "the cancel reached a live turn");
    // Caveat C1: the agent said `stop_reason: null` and `error_during_execution`. Only
    // `terminal_reason` separates the CEO's stop from a genuine failure, and the client maps
    // it back to the one string the spine and the ledger already reason about.
    assert_eq!(stop, STOP_REASON_CANCELLED);
    // §9.3 step 4: "Preserve partial commentary, activity and assistant output."
    assert_eq!(*seen.lock().unwrap(), "partial answer");
    let _ = std::fs::remove_file(&script);
}

#[test]
fn a_deaf_agent_does_not_hold_the_turn_open_and_is_reported_as_deaf() {
    // The bound, exercised in milliseconds rather than the shipping 3s.
    std::env::set_var("RICHOS_CANCEL_GRACE_MS", "300");
    let script = fake_agent("deaf", false);
    let client = connect(&script);
    let cancel = client.cancel_handle();

    let presser = std::thread::spawn(move || {
        std::thread::sleep(std::time::Duration::from_millis(150));
        cancel.cancel()
    });

    let began = std::time::Instant::now();
    let stop = client.prompt("ignore me", &mut |_| {}).unwrap();
    let elapsed = began.elapsed();
    assert!(presser.join().unwrap());

    assert_eq!(
        stop, STOP_REASON_CANCEL_UNACKNOWLEDGED,
        "an agent that ignored the interrupt must not be reported as a clean cancel"
    );
    // 150ms before the press + a 300ms grace = 450ms floor. The ceiling is generous because
    // a loaded CI box is not a real-time system; what is being proven is that the loop
    // RETURNS rather than parking forever on a `result` that never comes.
    assert!(elapsed.as_millis() >= 400, "returned too early: {elapsed:?}");
    assert!(elapsed.as_millis() < 5_000, "the deaf agent held the turn open: {elapsed:?}");
    std::env::remove_var("RICHOS_CANCEL_GRACE_MS");
    let _ = std::fs::remove_file(&script);
}

#[test]
fn cancelling_with_no_turn_in_flight_reports_that_it_reached_nothing() {
    let script = fake_agent("idle", true);
    let client = connect(&script);
    let cancel = client.cancel_handle();
    assert!(!cancel.cancel(), "there was no turn in flight, and saying otherwise would be a lie");
    let _ = std::fs::remove_file(&script);
}
