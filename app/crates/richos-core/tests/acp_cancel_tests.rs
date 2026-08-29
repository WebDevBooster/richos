//! `session/cancel` AGAINST A REAL CHILD PROCESS — the stop that has to actually reach
//! something (UX §9.3 step 2).
//!
//! These do not mock `AcpClient`. They spawn a real child over real stdio and drive the
//! real reader thread, real `dispatch`, real drain loop. The child is a POSIX-`sh` fake
//! adapter (written to a temp file by the test) so nothing here needs Claude, a network,
//! Node, or the `claude-agent-acp` binary.
//!
//! Two adapters, because the two failure modes are different products:
//!   - a COMPLIANT one, which answers the pending `session/prompt` with
//!     `stopReason: "cancelled"` the way the protocol says it must;
//!   - a DEAF one, which ignores `session/cancel` entirely. RichOS must still stop
//!     rendering, and must say which of the two happened rather than reporting both as a
//!     clean cancel.

use richos_core::acp::{AcpClient, STOP_REASON_CANCELLED, STOP_REASON_CANCEL_UNACKNOWLEDGED};
use richos_core::cognition::TurnItem;
use richos_core::steering::TurnCancel;
use std::io::Write;
use std::path::PathBuf;

/// A fake ACP adapter in POSIX sh. `comply=true` answers `session/cancel`; `false` ignores
/// it, which is the whole point of the second test.
///
/// The `case` patterns match the exact bytes `AcpClient` writes: `serde_json` serialises a
/// `json!` object through a `BTreeMap`, so keys come out alphabetically and
/// `"method":"session/cancel"` is a stable substring rather than a hopeful one.
fn fake_adapter(tag: &str, comply: bool) -> PathBuf {
    let path = std::env::temp_dir().join(format!(
        "richos-fake-acp-{tag}-{}-{}.sh",
        std::process::id(),
        richos_core::util::now_millis()
    ));
    let cancel_arm = if comply {
        r#"      if [ -n "$PROMPT_ID" ]; then
        printf '{"jsonrpc":"2.0","id":%s,"result":{"stopReason":"cancelled"}}\n' "$PROMPT_ID"
      fi
"#
    } else {
        "      : # deaf on purpose: this adapter ignores session/cancel\n"
    };
    let script = format!(
        r#"#!/bin/sh
PROMPT_ID=""
while IFS= read -r line; do
  case "$line" in
    *'"method":"initialize"'*)
      id=`printf '%s' "$line" | sed -n 's/.*"id":\([0-9]*\).*/\1/p'`
      printf '{{"jsonrpc":"2.0","id":%s,"result":{{"protocolVersion":1}}}}\n' "$id"
      ;;
    *'"method":"session/new"'*)
      id=`printf '%s' "$line" | sed -n 's/.*"id":\([0-9]*\).*/\1/p'`
      printf '{{"jsonrpc":"2.0","id":%s,"result":{{"sessionId":"sess-fake"}}}}\n' "$id"
      ;;
    *'"method":"session/prompt"'*)
      PROMPT_ID=`printf '%s' "$line" | sed -n 's/.*"id":\([0-9]*\).*/\1/p'`
      printf '{{"jsonrpc":"2.0","method":"session/update","params":{{"update":{{"sessionUpdate":"agent_message_chunk","content":{{"text":"partial answer"}}}}}}}}\n'
      ;;
    *'"method":"session/cancel"'*)
{cancel_arm}      ;;
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

fn connect(script: &PathBuf) -> (AcpClient, String) {
    let client = AcpClient::spawn(std::path::Path::new("/bin/sh"), &[script.to_string_lossy().to_string()]).unwrap();
    client.initialize().unwrap();
    let session = client.new_session(std::path::Path::new("/tmp")).unwrap();
    (client, session)
}

#[test]
fn a_compliant_adapter_ends_the_turn_as_cancelled_and_the_partial_text_survives() {
    let script = fake_adapter("comply", true);
    let (client, session) = connect(&script);
    let cancel = client.cancel_handle(&session);

    let seen = std::sync::Arc::new(std::sync::Mutex::new(String::new()));
    let seen_w = seen.clone();
    // Press stop shortly after the turn starts, from a DIFFERENT thread — which is the
    // real shape of the problem: the turn owns the spine lock, the stop cannot wait for it.
    let presser = std::thread::spawn(move || {
        std::thread::sleep(std::time::Duration::from_millis(250));
        cancel.cancel()
    });

    let stop = client
        .prompt(&session, "take your time", &mut |item| {
            if let TurnItem::Text { text, .. } = item {
                seen_w.lock().unwrap().push_str(text);
            }
        })
        .unwrap();

    assert!(presser.join().unwrap(), "the cancel reached a live prompt");
    assert_eq!(stop, STOP_REASON_CANCELLED);
    // §9.3 step 4: "Preserve partial commentary, activity and assistant output."
    assert_eq!(*seen.lock().unwrap(), "partial answer");
    let _ = std::fs::remove_file(&script);
}

#[test]
fn a_deaf_adapter_does_not_hold_the_turn_open_and_is_reported_as_deaf() {
    // The bound, exercised in milliseconds rather than the shipping 3s.
    std::env::set_var("RICHOS_CANCEL_GRACE_MS", "300");
    let script = fake_adapter("deaf", false);
    let (client, session) = connect(&script);
    let cancel = client.cancel_handle(&session);

    let presser = std::thread::spawn(move || {
        std::thread::sleep(std::time::Duration::from_millis(150));
        cancel.cancel()
    });

    let began = std::time::Instant::now();
    let stop = client.prompt(&session, "ignore me", &mut |_| {}).unwrap();
    let elapsed = began.elapsed();
    assert!(presser.join().unwrap());

    assert_eq!(
        stop, STOP_REASON_CANCEL_UNACKNOWLEDGED,
        "an adapter that ignored the cancel must not be reported as a clean cancel"
    );
    // 150ms before the press + a 300ms grace = 450ms floor. The ceiling is generous
    // because a loaded CI box is not a real-time system; what is being proven is that the
    // loop RETURNS rather than parking forever on a `Done` that never comes.
    assert!(elapsed.as_millis() >= 400, "returned too early: {elapsed:?}");
    assert!(elapsed.as_millis() < 5_000, "the deaf adapter held the turn open: {elapsed:?}");
    std::env::remove_var("RICHOS_CANCEL_GRACE_MS");
    let _ = std::fs::remove_file(&script);
}

#[test]
fn cancelling_with_no_turn_in_flight_reports_that_it_reached_nothing() {
    let script = fake_adapter("idle", true);
    let (client, session) = connect(&script);
    let cancel = client.cancel_handle(&session);
    assert!(!cancel.cancel(), "there was no prompt in flight, and saying otherwise would be a lie");
    let _ = std::fs::remove_file(&script);
}
