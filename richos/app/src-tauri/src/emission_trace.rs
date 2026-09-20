//! Optional metadata-only measurement around the actual webview emit call.
//! An emit receipt is not a renderer receipt and is never labeled as one.
use richos_core::stream::StreamEvent;
use serde_json::{json, Value};
use std::time::{Instant, SystemTime, UNIX_EPOCH};

pub fn emit<R, E>(
    event: &StreamEvent,
    enabled: bool,
    send: impl FnOnce() -> Result<R, E>,
    record: impl FnOnce(Value),
) -> Result<R, E> {
    let StreamEvent::Chunk {
        thread_id,
        turn_id,
        seq,
        at,
        ..
    } = event
    else {
        return send();
    };
    if !enabled {
        return send();
    }
    static ANCHOR: std::sync::OnceLock<Instant> = std::sync::OnceLock::new();
    let anchor = ANCHOR.get_or_init(Instant::now);
    let wall_before = SystemTime::now().duration_since(UNIX_EPOCH).ok();
    let before = anchor.elapsed();
    let result = send();
    let after = anchor.elapsed();
    let wall_after = SystemTime::now().duration_since(UNIX_EPOCH).ok();
    record(json!({
        "event": "rich://chunk", "thread_id": thread_id, "turn_id": turn_id,
        "seq": seq, "durable_at_ms": at, "emit_ok": result.is_ok(),
        "emit_before_us": before.as_micros() as u64,
        "emit_after_us": after.as_micros() as u64,
        "wall_before_us": wall_before.map(|v| v.as_micros() as u64),
        "wall_after_us": wall_after.map(|v| v.as_micros() as u64),
    }));
    result
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::cell::Cell;

    fn chunk() -> StreamEvent {
        StreamEvent::Chunk {
            thread_id: "thread".into(),
            turn_id: "turn".into(),
            seq: 7,
            text_delta: "private reply text".into(),
            at: 123,
        }
    }

    #[test]
    fn records_actual_call_result_without_content() {
        for succeeds in [false, true] {
            let calls = Cell::new(0);
            let mut receipt = None;
            let result = emit(
                &chunk(),
                true,
                || {
                    calls.set(calls.get() + 1);
                    if succeeds {
                        Ok(42)
                    } else {
                        Err("private transport error")
                    }
                },
                |v| receipt = Some(v),
            );
            assert_eq!(calls.get(), 1);
            assert_eq!(result.is_ok(), succeeds);
            let row = receipt.unwrap();
            assert_eq!(row["emit_ok"], succeeds);
            assert_eq!(row["seq"], 7);
            assert_eq!(row["durable_at_ms"], 123);
            assert!(row["emit_after_us"].as_u64() >= row["emit_before_us"].as_u64());
            assert!(!row.to_string().contains("private"));
            assert!(row.get("text_delta").is_none());
        }
    }

    #[test]
    fn disabled_trace_and_non_chunk_events_only_send() {
        for (event, enabled) in [
            (chunk(), false),
            (
                StreamEvent::TurnStarted {
                    thread_id: "thread".into(),
                    turn_id: "turn".into(),
                    at: 123,
                },
                true,
            ),
        ] {
            assert_eq!(
                emit(
                    &event,
                    enabled,
                    || Ok::<_, ()>(42),
                    |_| panic!("unexpected trace")
                ),
                Ok(42)
            );
        }
    }
}
